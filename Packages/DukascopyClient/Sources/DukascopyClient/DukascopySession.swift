import Foundation
import os

private let log = Logger(subsystem: "com.swifttrader", category: "native")

/// High-level session: resolves the environment, authenticates, opens the binary
/// transport, completes the login handshake, sends INIT, and keeps the socket alive
/// by answering heartbeats. Market-data / history / account methods are layered on
/// top of this connect core in later slices.
public actor DukascopySession {
    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public enum SessionError: Error, LocalizedError, CustomStringConvertible {
        case noSRP6Servers
        case noUsableAPIServer
        case authFailed(String)
        case notConnected
        case timedOut(String)
        case orderRejected(String, String?)

        public var description: String {
            switch self {
            case .noSRP6Servers: "JNLP returned no SRP6 servers"
            case .noUsableAPIServer: "auth returned no usable API server"
            case .authFailed(let s): "authentication failed: \(s)"
            case .notConnected: "session is not connected"
            case .timedOut(let what): "\(what) timed out"
            case .orderRejected(let state, let reason):
                "order rejected (\(state))" + (reason.map { ": \($0)" } ?? "")
            }
        }

        public var errorDescription: String? { description }
    }

    /// In-flight history request: chunks accumulate by `messageOrder` until
    /// `historyFinished`, then the bars are assembled and the continuation resumed.
    /// `lastActivity` drives an idle timeout — each arriving chunk pushes it back so a
    /// slow-but-progressing cold fetch is never killed mid-transfer.
    private struct PendingHistory {
        var groups: [Int32: CandleHistoryGroup] = [:]
        var maxOrder: Int32 = -1
        var finished = false
        var continuation: CheckedContinuation<[CandleBar], Error>?
        var lastActivity: Date
    }

    /// In-flight closed-trade history request. Mirrors `PendingHistory`: `positionsEncoded`
    /// chunks accumulate by `messageOrder` until `finished`, then the concatenated GZIP blob
    /// is decoded and the continuation resumed. The blob is ONE gzip stream split across
    /// chunks (unlike candle history's per-chunk strings), so chunks are concatenated raw and
    /// gunzipped once. `lastActivity` drives the same per-chunk idle timeout.
    private struct PendingClosed {
        var chunks: [Int32: Data] = [:]
        var maxOrder: Int32 = -1
        var finished = false
        var continuation: CheckedContinuation<[ClosedPosition], Error>?
        var lastActivity: Date
    }

    public private(set) var state: State = .disconnected

    private let environment: DukascopyEnvironment
    private let credentials: AuthCredentials
    private let authClient: AuthClient
    /// Invoked when the account needs a captcha PIN (LIVE on a non-whitelisted IP).
    /// Nil for demo / whitelisted accounts — `connect()` then never prompts.
    private let pinProvider: PinProvider?

    private var transport: Transport?
    private var authSessionId: String?
    private var readerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    /// How often the client pings the server to keep the primary connection alive. The
    /// server closes an idle socket after ~15s, so this stays comfortably under that.
    private let heartbeatInterval: TimeInterval = 5

    /// Bulk history-server base URL, parsed from the settings blob at connect. Enables
    /// deep history (older than the socket's warm window) via `BulkHistoryClient`.
    private var historyServerURL: String?
    private let bulkClient = BulkHistoryClient()

    private var pendingHistory: [String: PendingHistory] = [:]
    private var pendingClosed: [String: PendingClosed] = [:]
    /// In-flight order operations awaiting a broker ack, keyed by requestId. Resolved by
    /// the matchers in `dispatch` (explicit rejection or positive group/order evidence) or
    /// by the ack timeout (→ `.unresolved`, treated as success — never induce a re-submit).
    private var pendingOrderAcks: [String: PendingOrderAck] = [:]
    private var latestAccount: AccountInfo?
    private var accountWaiters: [UUID: CheckedContinuation<AccountInfo, Error>] = [:]
    // Multicast: each consumer of `tickStream()` gets its own continuation, all yielded to
    // when a CurrencyMarket message arrives. Consumers filter to the instruments they care
    // about. Removed on stream termination so this dictionary stays bounded.
    private var tickStreams: [UUID: AsyncStream<CurrencyMarket>.Continuation] = [:]
    /// Most-recent quote per slashed instrument — lets order pricing use the last
    /// known price immediately instead of waiting for the next (possibly seconds-away) tick.
    private var lastQuotes: [String: CurrencyMarket] = [:]
    /// Open positions by `orderGroupId`, seeded from the connect-time PackedAccountInfo
    /// and kept current by live OrderGroup updates (removed when a group goes CLOSE).
    private var positions: [String: OrderGroup] = [:]
    /// Multicast order/position event consumers (mirrors `tickStreams`).
    private var orderEventStreams: [UUID: AsyncStream<OrderEvent>.Continuation] = [:]
    private var newsEventStreams: [UUID: AsyncStream<NewsEvent>.Continuation] = [:]
    /// Multicast consumers of session `State` transitions — lets the app layer (auth
    /// view-model, trading coordinator) react to a transport failure instead of holding
    /// a dead session. Each consumer also gets the current state on subscribe.
    private var stateStreams: [UUID: AsyncStream<State>.Continuation] = [:]
    /// Debounce flag for the silent-DDS watchdog: when a fetchHistory idle-times-out
    /// every subsequent fetchHistory is hung on the same wedged channel, so we trigger
    /// a forced reconnect — but multiple in-flight requests hitting their timeouts
    /// simultaneously must collapse to a single rebuild cycle, not stack on each other.
    private var reconnectInProgress = false

    /// Watchdog-reconnect storm guards. A degraded DDS history endpoint can stay dead across
    /// rebuilds (every fetchHistory hangs), so rebuilding then re-firing the same fetches loops —
    /// and the rebuild's own version handshake can fail over the bad link, killing the session and
    /// forcing a manual relaunch. `triggerWatchdogReconnect` throttles rebuilds with an exponential
    /// cooldown keyed on consecutive rebuilds that didn't restore history, and retries a transient
    /// connect failure instead of one-shotting. The counter resets the instant a history chunk
    /// arrives (`handleHistoryGroup`), so it self-recovers when the channel comes back.
    private var lastWatchdogReconnectAt: Date?
    private var consecutiveWatchdogReconnects = 0
    private let watchdogBaseCooldown: TimeInterval = 30
    private let watchdogMaxCooldown: TimeInterval = 300

    /// A transport read failure (e.g. a sleep/network blip — `POSIXErrorCode 60`) is usually
    /// transient, not a dead account, so we try a bounded number of in-place reconnects before
    /// surfacing a terminal failure (which sends the user back to the login gate). The budget
    /// resets once the connection has stayed up longer than `readReconnectResetInterval`, so a
    /// genuinely flapping connection still falls through to the login gate instead of looping.
    private var readReconnectAttempts = 0
    private var lastReadReconnectAt: Date = .distantPast
    private let maxReadReconnectAttempts = 2
    private let readReconnectResetInterval: TimeInterval = 120

    /// Slashed instrument names currently subscribed for quote ticks. Mutated only on
    /// `subscribeQuotes` (which sends the full set to the server) so `ensureSubscribed`
    /// can compute additions and skip the round-trip when nothing new is needed.
    private var subscribedQuotes: Set<String> = []
    /// When each instrument was (re)subscribed — lets the quote watchdog tell "subscribed
    /// but never ticked" from "just subscribed, give it a moment".
    private var quoteSubscribedAt: [String: Date] = [:]
    /// When each instrument last delivered a tick, and the most recent tick across ALL
    /// instruments. The watchdog only acts when the feed is demonstrably live (something
    /// ticked recently) but a specific subscribed pair has never ticked — the signature of
    /// a dropped/clobbered subscription, distinct from a closed market (nothing ticks).
    private var lastTickAt: [String: Date] = [:]
    private var lastAnyTickAt = Date.distantPast
    /// Debounce for `resubscribeQuotes` so the per-chart and session watchdogs (plus any
    /// concurrent triggers) collapse to a single re-send.
    private var lastResubscribeAt = Date.distantPast
    private var quoteWatchdogTask: Task<Void, Never>?

    public init(
        environment: DukascopyEnvironment,
        credentials: AuthCredentials,
        authClient: AuthClient = AuthClient(),
        pinProvider: PinProvider? = nil
    ) {
        self.environment = environment
        self.credentials = credentials
        self.authClient = authClient
        self.pinProvider = pinProvider
    }

    /// Resolve JNLP → authenticate (trying each SRP6 server) → connect transport →
    /// handshake → INIT. Starts the reader loop on success.
    public func connect(timeout: TimeInterval = 20) async throws {
        if state == .connected { return }
        setState(.connecting)
        log.info("connect: env=\(self.environment.rawValue, privacy: .public) resolving JNLP")
        do {
            let jnlp = try await JNLPClient.fetch(from: environment.jnlpURL)
            guard !jnlp.srp6LoginURLs.isEmpty else { throw SessionError.noSRP6Servers }

            // PIN/captcha pre-flight — done ONCE (not per server) so the user is
            // prompted at most once per connect. Only runs when a pinProvider is set
            // (LIVE accounts); demo/whitelisted skip it entirely. A thrown
            // `pinCancelled`/`badPin` propagates out of connect() to the caller.
            var captchaId: String?
            var pin: String?
            if let pinProvider, let probe = jnlp.srp6LoginURLs.first {
                let info = try await authClient.checkIfPinRequired(
                    baseURL: probe, login: credentials.login
                )
                log.info("connect: login_info checkPin=\(info.checkPin, privacy: .public)")
                if info.checkPin {
                    let challenge = try await authClient.fetchCaptcha(baseURL: probe)
                    let entered = try await pinProvider(challenge)
                    captchaId = challenge.captchaId
                    pin = entered
                }
            }

            var lastError: Error?
            var success: AuthSuccess?
            for serverURL in jnlp.srp6LoginURLs {
                do {
                    success = try await authClient.authenticate(
                        baseURL: serverURL, credentials: credentials,
                        captchaId: captchaId, pin: pin
                    )
                    break
                } catch let e as AuthError {
                    // A wrong PIN is deterministic — every server will reject it, so don't
                    // burn the rest of the list retrying; surface it for a fresh-captcha retry.
                    if case .badPin = e {
                        lastError = e
                        break
                    }
                    log.error("connect: auth failed against \(serverURL.absoluteString, privacy: .public): \(e.description, privacy: .public)")
                    lastError = e
                    continue
                } catch {
                    log.error("connect: auth failed against \(serverURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    lastError = error
                    continue
                }
            }
            guard let auth = success else {
                // Preserve a typed AuthError (e.g. `.badPin`, `.pinCancelled`) so the
                // caller can react — re-prompt with a fresh captcha vs. hard-fail.
                if let authError = lastError as? AuthError { throw authError }
                throw SessionError.authFailed(lastError.map { String(describing: $0) } ?? "unknown")
            }
            guard let first = auth.authApiURLs.first, let address = ServerAddress.parse(first) else {
                throw SessionError.noUsableAPIServer
            }
            log.info("connect: authenticated, api=\(address.description, privacy: .public)")

            let transport = Transport(address: address)
            try await transport.connect(timeout: timeout)
            _ = try await transport.handshake(
                login: credentials.login, ticket: auth.ticket, authSessionId: auth.authSessionId
            )

            var initReq = InitRequest()
            initReq.requestId = UUID().uuidString
            initReq.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            try await transport.sendFrame(initReq.encode())

            self.transport = transport
            self.authSessionId = auth.authSessionId
            if let blob = auth.settingsBlob {
                self.historyServerURL = (try? JavaPropertiesParser.parse(blob))?["history.server.url"]
                log.info("connect: history server = \(self.historyServerURL ?? "none", privacy: .public)")
            }
            setState(.connected)
            startReader(transport: transport)
            startHeartbeat(transport: transport)
            startQuoteWatchdog()
            log.info("connect: CONNECTED")
        } catch {
            log.error("connect: FAILED: \(error.localizedDescription, privacy: .public)")
            await connectDidFail(error)
            throw error
        }
    }

    /// Cleanup after a `connect()` failure. During an in-place `reconnect()` the
    /// multicast consumers MUST stay registered for the retry — finishing them here
    /// silently killed every live stream when reconnect attempt 1 failed and attempt 2
    /// succeeded (fills/SL hits dropped while the session looked healthy). The state
    /// goes `.disconnected`, not `.failed`: terminal failure is `markFailed`'s job, and
    /// a `.failed` broadcast mid-retry makes the app abandon a session that's still
    /// being driven back up. Only an initial (non-reconnect) connect failure is
    /// terminal here. Internal for tests.
    func connectDidFail(_ error: Error) async {
        if reconnectInProgress {
            setState(.disconnected)
            await teardown()
        } else {
            setState(.failed(String(describing: error)))
            await teardown()
            finishMulticastStreams()
        }
    }

    public func close() async {
        await teardown()
        setState(.disconnected)
        finishMulticastStreams()
    }

    /// Tear down the current transport and rebuild the session in-place — used by the
    /// history-idle watchdog when the DDS channel goes silent (heartbeats still flowing,
    /// but every fetchHistory hangs without ever receiving its first chunk). Existing
    /// tick-stream consumers stay registered through the cycle; previously-subscribed
    /// quotes are re-issued after the new INIT so live ticks flow again. Debounced so
    /// concurrent watchdog triggers from multiple in-flight requests collapse to one
    /// rebuild.
    public func reconnect() async throws {
        if reconnectInProgress {
            log.info("reconnect: already in progress, skipping duplicate trigger")
            return
        }
        reconnectInProgress = true
        defer { reconnectInProgress = false }
        log.info("reconnect: tearing down session for forced rebuild")
        let toResubscribe = subscribedQuotes
        subscribedQuotes = []
        await teardown()
        setState(.disconnected)
        try await connect()
        if !toResubscribe.isEmpty {
            log.info("reconnect: re-subscribing \(toResubscribe.count) quote(s) after rebuild")
            try await subscribeQuotes(instruments: toResubscribe)
        }
    }

    // MARK: - State observation

    /// Multicast stream of session `State` transitions. Each consumer gets its own
    /// stream and receives the CURRENT state immediately on subscribe, then every
    /// subsequent transition. Lets the app layer react to a transport failure
    /// (`.failed`) rather than clinging to a dead session. Mirrors `tickStream()`.
    public func stateStream() -> AsyncStream<State> {
        let id = UUID()
        return AsyncStream<State> { continuation in
            Task { [weak self] in await self?.registerStateStream(id: id, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregisterStateStream(id: id) }
            }
        }
    }

    private func registerStateStream(id: UUID, continuation: AsyncStream<State>.Continuation) {
        stateStreams[id] = continuation
        continuation.yield(state)
    }
    private func unregisterStateStream(id: UUID) {
        stateStreams.removeValue(forKey: id)
    }

    /// Single choke point for state changes so every transition is broadcast to
    /// `stateStream()` consumers.
    private func setState(_ newState: State) {
        state = newState
        for (_, c) in stateStreams { c.yield(newState) }
    }

    /// Finish + clear every multicast stream (tick / order / news / state) so their
    /// `for await` consumers terminate instead of hanging forever on a dead session — and
    /// so a consumer that captures `self` strongly (e.g. the trading coordinator's tick
    /// and state observers) releases the session rather than leaking it. The terminal
    /// `.failed` / `.disconnected` is broadcast via `setState` BEFORE this runs, so it's
    /// still delivered (AsyncStream buffers it) ahead of the finish.
    ///
    /// Called only on TERMINAL teardown (`markFailed`, an INITIAL connect failure,
    /// `close`) — never from the reconnect path (see `connectDidFail`), which
    /// deliberately keeps consumers registered across an in-place transport rebuild
    /// so live feeds resume seamlessly.
    private func finishMulticastStreams() {
        for (_, c) in tickStreams { c.finish() }
        tickStreams.removeAll()
        for (_, c) in orderEventStreams { c.finish() }
        orderEventStreams.removeAll()
        for (_, c) in newsEventStreams { c.finish() }
        newsEventStreams.removeAll()
        for (_, c) in stateStreams { c.finish() }
        stateStreams.removeAll()
    }

    // MARK: - History

    /// Fetch historical candles for `[startSeconds, endSeconds]`. Returns just the bars
    /// the call produced — failed bulk chunks are surfaced via `fetchHistoryDetailed`,
    /// not lost silently. Callers that need the gap list (cache layer, gap-recovery)
    /// should call `fetchHistoryDetailed` directly.
    public func fetchHistory(
        instrument: String,
        side: OfferSide = .bid,
        period: CandlePeriod,
        startSeconds: Int64,
        endSeconds: Int64,
        idleTimeout: TimeInterval = 30
    ) async throws -> [CandleBar] {
        try await fetchHistoryDetailed(
            instrument: instrument, side: side, period: period,
            startSeconds: startSeconds, endSeconds: endSeconds, idleTimeout: idleTimeout
        ).bars
    }

    /// Like `fetchHistory`, but returns a `HistoryResult` whose `missingWindows` lists
    /// any bulk chunks that still couldn't be downloaded after an inner retry pass.
    /// When `missingWindows` is empty the result is complete; otherwise the caller
    /// should either retry later or avoid caching `bars` as authoritative — the gap
    /// would otherwise be stored on disk and never noticed.
    public func fetchHistoryDetailed(
        instrument: String,
        side: OfferSide = .bid,
        period: CandlePeriod,
        startSeconds: Int64,
        endSeconds: Int64,
        idleTimeout: TimeInterval = 30
    ) async throws -> HistoryResult {
        do {
            let bars = try await subscribeHistory(
                instrument: instrument, side: side, period: period,
                startSeconds: startSeconds, endSeconds: endSeconds, idleTimeout: idleTimeout
            )
            return HistoryResult(bars: bars)
        } catch let e as ErrorResponse {
            // The socket only caches a recent window and rejects a request reaching before
            // it with "data not in cache" (reporting the range it *does* have). Serve the
            // in-window slice from the socket and fill anything older from the bulk history
            // server (the .bi5 files), then merge — so the chart can scroll back years.
            let range = Self.parseCacheRange(e.reason)
            var socketBars: [CandleBar] = []
            var bulkEndSeconds = endSeconds
            if let (cacheStart, cacheEnd) = range, cacheEnd > cacheStart {
                let cs = max(startSeconds, cacheStart)
                let ce = min(endSeconds, cacheEnd)
                if ce > cs {
                    socketBars = (try? await subscribeHistory(
                        instrument: instrument, side: side, period: period,
                        startSeconds: cs, endSeconds: ce, idleTimeout: idleTimeout
                    )) ?? []
                }
                bulkEndSeconds = min(endSeconds, cacheStart)
            }
            var bulkBars: [CandleBar] = []
            var missing: [HistoryWindow] = []
            if startSeconds < bulkEndSeconds {
                let result = await fetchBulkHistory(
                    instrument: instrument, side: side, period: period,
                    fromMs: startSeconds * 1000, toMs: bulkEndSeconds * 1000
                )
                bulkBars = result.bars
                missing = result.failedChunks.map {
                    HistoryWindow(fromMs: $0.chunkStartMs, toMs: $0.chunkEndMs)
                }
            }
            let combined = Self.dedupSorted(bulk: bulkBars, socket: socketBars)
            if combined.isEmpty, missing.isEmpty { throw e }
            if !missing.isEmpty {
                log.warning("fetchHistory \(instrument, privacy: .public) PARTIAL: \(combined.count) bars, \(missing.count) chunk(s) still missing after retry")
            }
            log.debug("fetchHistory \(instrument, privacy: .public) deep: \(socketBars.count) socket + \(bulkBars.count) bulk = \(combined.count)")
            return HistoryResult(bars: combined, missingWindows: missing)
        }
    }

    /// Fetch the server's in-progress candle for every supported period in one call —
    /// the path JForex SDK uses (`CurvesJsonProtocolHandler.loadDataFromDFS` with
    /// `inProgress=true`). Returns the raw positional `[CandleBar]` as the server
    /// emits it; layout per the decompiled SDK is one candle per period × side, in
    /// order MONTHLY, WEEKLY, DAILY, FOUR_HOURS, ONE_HOUR, THIRTY_MINS, FIFTEEN_MINS,
    /// TEN_MINS, FIVE_MINS, ONE_MIN, TEN_SECS (with ASK and BID interleaved). We log
    /// the bars verbatim on first call so the caller can verify the layout against a
    /// live capture before relying on positional indexing.
    public func fetchInProgressCandles(
        instrument: String,
        side: OfferSide = .bid,
        untilMillis: Int64? = nil,
        idleTimeout: TimeInterval = 30
    ) async throws -> [CandleBar] {
        guard state == .connected, let transport else { throw SessionError.notConnected }
        let until = untilMillis ?? Int64(Date().timeIntervalSince1970 * 1000)
        let reqId = UUID().uuidString
        var req = CandleSubscribeRequest.inProgress(
            instrument: instrument, side: side, untilMillis: until
        )
        req.requestId = reqId
        req.userName = credentials.login
        req.sessionId = authSessionId
        req.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        log.debug("fetchInProgress \(instrument, privacy: .public)/\(side.rawValue, privacy: .public) until=\(until) req=\(reqId, privacy: .public)")

        pendingHistory[reqId] = PendingHistory(lastActivity: Date())
        do {
            try await transport.sendFrame(req.encode())
        } catch {
            pendingHistory[reqId] = nil
            throw error
        }
        let bars: [CandleBar] = try await withCheckedThrowingContinuation { cont in
            guard pendingHistory[reqId] != nil else {
                cont.resume(throwing: SessionError.notConnected)
                return
            }
            pendingHistory[reqId]?.continuation = cont
            resolveHistoryIfReady(reqId)
            scheduleHistoryTimeout(reqId, idle: idleTimeout)
        }
        log.info("fetchInProgress \(instrument, privacy: .public) returned \(bars.count) candle(s)")
        for (i, b) in bars.enumerated() {
            log.info(
                "  [\(i)] t=\(b.timeMillis) o=\(b.open) h=\(b.high) l=\(b.low) c=\(b.close) v=\(b.volume)"
            )
        }
        return bars
    }

    /// Deep history from the bulk server (the part older than the socket's warm window).
    /// Returns empty bars + empty failedChunks when no history URL was parsed or the period
    /// isn't a basic downloadable one (1m/1H/Daily) — non-basic periods are built from those
    /// by the caller. Failed chunks get a single inner retry pass before surfacing; anything
    /// still missing comes back via `failedChunks` so the caller knows the result is partial.
    private func fetchBulkHistory(
        instrument: String, side: OfferSide, period: CandlePeriod, fromMs: Int64, toMs: Int64
    ) async -> BulkHistoryClient.BulkResult {
        guard let historyServerURL else {
            return BulkHistoryClient.BulkResult(bars: [], failedChunks: [])
        }
        let pip = InstrumentPipValue.pipValue(for: instrument)
        let first: BulkHistoryClient.BulkResult
        do {
            first = try await bulkClient.fetchCandles(
                instrument: instrument, side: side, period: period,
                fromMs: fromMs, toMs: toMs, historyServerURL: historyServerURL, pipValue: pip
            )
        } catch {
            log.error("bulk history failed for \(instrument, privacy: .public): \(String(describing: error), privacy: .public)")
            return BulkHistoryClient.BulkResult(bars: [], failedChunks: [])
        }
        guard !first.failedChunks.isEmpty else { return first }
        // One inner retry pass so a flaky moment doesn't become a permanent cached gap.
        log.info("bulk history \(instrument, privacy: .public): retrying \(first.failedChunks.count) failed chunk(s)")
        let retry: BulkHistoryClient.BulkResult
        do {
            retry = try await bulkClient.retryChunks(
                first.failedChunks, historyServerURL: historyServerURL, pipValue: pip
            )
        } catch {
            log.error("bulk history retry failed for \(instrument, privacy: .public): \(String(describing: error), privacy: .public)")
            return first   // keep the partial result + surface the failures
        }
        return BulkHistoryClient.BulkResult(
            bars: Self.dedupSorted(bulk: first.bars, socket: retry.bars),
            failedChunks: retry.failedChunks
        )
    }

    /// Merges bulk + socket bars by timestamp, socket winning on overlap (fresher).
    private static func dedupSorted(bulk: [CandleBar], socket: [CandleBar]) -> [CandleBar] {
        var byTime: [Int64: CandleBar] = [:]
        for b in bulk { byTime[b.timeMillis] = b }
        for b in socket { byTime[b.timeMillis] = b }
        return byTime.values.sorted { $0.timeMillis < $1.timeMillis }
    }

    private func subscribeHistory(
        instrument: String,
        side: OfferSide,
        period: CandlePeriod,
        startSeconds: Int64,
        endSeconds: Int64,
        idleTimeout: TimeInterval
    ) async throws -> [CandleBar] {
        guard state == .connected, let transport else { throw SessionError.notConnected }
        let reqId = UUID().uuidString
        var req = CandleSubscribeRequest(
            instrument: instrument, side: side, period: period,
            startTimeSeconds: startSeconds, endTimeSeconds: endSeconds
        )
        req.requestId = reqId
        req.userName = credentials.login
        req.sessionId = authSessionId
        req.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        log.debug("fetchHistory \(instrument, privacy: .public)/\(side.rawValue, privacy: .public) period=\(period.seconds)s window=[\(startSeconds),\(endSeconds)] req=\(reqId, privacy: .public)")

        pendingHistory[reqId] = PendingHistory(lastActivity: Date())
        do {
            try await transport.sendFrame(req.encode())
        } catch {
            pendingHistory[reqId] = nil
            throw error
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[CandleBar], Error>) in
            // The entry can be gone already if the session failed during the send
            // await (teardown drains pending requests).
            guard pendingHistory[reqId] != nil else {
                cont.resume(throwing: SessionError.notConnected)
                return
            }
            pendingHistory[reqId]?.continuation = cont
            // A fast response may have finished while we were sending; resolve it now.
            resolveHistoryIfReady(reqId)
            scheduleHistoryTimeout(reqId, idle: idleTimeout)
        }
    }

    private func handleHistoryGroup(_ g: CandleHistoryGroup) {
        guard let reqId = g.requestId, pendingHistory[reqId] != nil else { return }
        // A history chunk arrived — the DDS channel is healthy again, so clear the watchdog
        // throttle: the next dead-channel event rebuilds promptly (no lingering cooldown).
        consecutiveWatchdogReconnects = 0
        lastWatchdogReconnectAt = nil
        pendingHistory[reqId]?.lastActivity = Date()
        if let order = g.messageOrder {
            pendingHistory[reqId]?.groups[order] = g
            log.debug("fetchHistory chunk req=\(reqId, privacy: .public) order=\(order) finished=\(g.historyFinished == true)")
            if g.historyFinished == true {
                pendingHistory[reqId]?.maxOrder = order
                pendingHistory[reqId]?.finished = true
            }
        }
        resolveHistoryIfReady(reqId)
    }

    private func resolveHistoryIfReady(_ reqId: String) {
        guard let pending = pendingHistory[reqId], pending.finished,
              let cont = pending.continuation else { return }
        pendingHistory[reqId] = nil
        do {
            var bars: [CandleBar] = []
            if pending.maxOrder >= 0 {
                for order in 0...pending.maxOrder {
                    guard let g = pending.groups[order], let s = g.candles else { continue }
                    bars.append(contentsOf: try HistoryDecoder.decodeCandles(s))
                }
            }
            log.debug("fetchHistory req=\(reqId, privacy: .public) done: \(bars.count) bars from \(pending.maxOrder + 1) chunk(s)")
            cont.resume(returning: bars)
        } catch {
            log.error("fetchHistory req=\(reqId, privacy: .public) decode failed: \(error.localizedDescription, privacy: .public)")
            cont.resume(throwing: error)
        }
    }

    /// Idle timeout: fires only after `idle` seconds elapse with no new chunk. Each
    /// arriving chunk pushes `lastActivity` forward, so a slow cold fetch that keeps
    /// streaming is never killed — only a genuinely stalled request times out.
    private func scheduleHistoryTimeout(_ reqId: String, idle: TimeInterval) {
        Task { [weak self] in
            guard let self else { return }
            while await self.historyStillPending(reqId) {
                let remaining = await self.historyIdleRemaining(reqId, idle: idle)
                if remaining <= 0 {
                    await self.timeoutHistory(reqId)
                    return
                }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    private func historyStillPending(_ reqId: String) -> Bool { pendingHistory[reqId] != nil }

    private func historyIdleRemaining(_ reqId: String, idle: TimeInterval) -> TimeInterval {
        guard let pending = pendingHistory[reqId] else { return 0 }
        return idle - Date().timeIntervalSince(pending.lastActivity)
    }

    private func timeoutHistory(_ reqId: String) {
        guard let cont = pendingHistory[reqId]?.continuation else { return }
        log.error("fetchHistory req=\(reqId, privacy: .public) idle-timed-out — DDS channel likely dead, triggering watchdog reconnect")
        pendingHistory[reqId] = nil
        cont.resume(throwing: SessionError.timedOut("history request (no data received)"))
        // The DDS chart-data channel doesn't self-recover from this state: every subsequent
        // fetchHistory hangs identically until the socket is rebuilt. Trigger a throttled,
        // self-recovering watchdog reconnect (see `triggerWatchdogReconnect`).
        triggerWatchdogReconnect()
    }

    /// Single coordinated entry for watchdog rebuilds, hardened against the reconnect storm seen
    /// when the DDS history endpoint is degraded (every fetchHistory hangs ~30–85s, each timeout
    /// firing a rebuild, the rebuild re-firing the same fetches, and the rebuild's handshake
    /// eventually failing → session death needing a manual relaunch). Two guards:
    ///
    /// - **Exponential cooldown** keyed on `consecutiveWatchdogReconnects`: collapses the burst of
    ///   simultaneous timeouts into one cycle and backs successive rebuilds further apart
    ///   (30s → 60 → 120 → … capped at 300s) so a persistently-dead channel can't storm. It never
    ///   gives up permanently — the counter resets the instant a history chunk arrives, so it
    ///   self-recovers the moment the channel comes back.
    /// - **Transient-failure retry**: the rebuild itself retries a transient connect failure (e.g. a
    ///   garbled version handshake over the bad link) up to 3× with backoff, instead of one-shotting
    ///   to a dead session.
    private func triggerWatchdogReconnect() {
        let cooldown = min(
            watchdogMaxCooldown,
            watchdogBaseCooldown * pow(2, Double(max(0, consecutiveWatchdogReconnects - 1))))
        if let last = lastWatchdogReconnectAt, Date().timeIntervalSince(last) < cooldown {
            log.info("watchdog reconnect suppressed — within \(Int(cooldown), privacy: .public)s cooldown (consecutive=\(self.consecutiveWatchdogReconnects, privacy: .public))")
            return
        }
        lastWatchdogReconnectAt = Date()
        consecutiveWatchdogReconnects += 1
        Task { [weak self] in
            guard let self else { return }
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    try await self.reconnect()
                    return
                } catch {
                    lastError = error
                    log.error("watchdog reconnect attempt \(attempt, privacy: .public)/3 failed: \(error.localizedDescription, privacy: .public)")
                    if attempt < 3 { try? await Task.sleep(for: .seconds(TimeInterval(min(15, 3 * attempt)))) }
                }
            }
            // All rebuilds failed. The session sits .disconnected with consumers still
            // registered and NOTHING left to re-trigger a reconnect (the watchdog only
            // fires from history idle-timeouts, which need a connected session) — a
            // permanent silent zombie. Declare terminal failure so the app surfaces
            // re-login instead of dead-looking charts.
            await self.markFailed(
                "watchdog reconnect failed after 3 attempts: \(lastError?.localizedDescription ?? "unknown")")
        }
    }

    /// Test seam: arrange the reconnect-in-progress flag without driving a real
    /// reconnect, so `connectDidFail`'s two paths are testable offline.
    func setReconnectInProgressForTesting(_ flag: Bool) {
        reconnectInProgress = flag
    }

    /// Resolve a single pending history request with an error (e.g. a server error
    /// correlated to it by requestId), so it fails immediately rather than hanging.
    private func failHistory(_ reqId: String, with error: Error) {
        guard pendingHistory[reqId] != nil else { return }
        let cont = pendingHistory[reqId]?.continuation
        pendingHistory[reqId] = nil
        cont?.resume(throwing: error)
    }

    // MARK: - Closed-trade history

    /// Fetch the account's CLOSED positions (trade history) in `[fromMillis, toMillis]`.
    /// Sends a `dfs.PositionDataRequestMessage` and reassembles the chunked
    /// `PositionBinaryResponse` reply (correlated by requestId, ordered by messageOrder),
    /// decoding the concatenated `GZIP(Bits.writeObject(List<PositionData>))` blob. Mirrors
    /// the candle-history machinery; the idle timeout resets on each chunk so a large
    /// transfer isn't killed mid-flight.
    public func fetchClosedPositions(
        fromMillis: Int64, toMillis: Int64, idleTimeout: TimeInterval = 30
    ) async throws -> [ClosedPosition] {
        guard state == .connected, let transport else { throw SessionError.notConnected }
        let reqId = UUID().uuidString
        let frame = encodePositionDataRequest(
            startMillis: fromMillis, endMillis: toMillis, getClosed: true,
            userName: credentials.login, sessionId: authSessionId,
            userId: latestAccount?.userId, accountLoginId: latestAccount?.accountLoginId,
            requestId: reqId, timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
        log.debug("fetchClosedPositions window=[\(fromMillis),\(toMillis)] req=\(reqId, privacy: .public)")

        pendingClosed[reqId] = PendingClosed(lastActivity: Date())
        do {
            try await transport.sendFrame(frame)
        } catch {
            pendingClosed[reqId] = nil
            throw error
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[ClosedPosition], Error>) in
            guard pendingClosed[reqId] != nil else {
                cont.resume(throwing: SessionError.notConnected)
                return
            }
            pendingClosed[reqId]?.continuation = cont
            resolveClosedIfReady(reqId)
            scheduleClosedTimeout(reqId, idle: idleTimeout)
        }
    }

    private func handleClosedResponse(_ resp: PositionBinaryResponse) {
        guard let reqId = resp.requestId, pendingClosed[reqId] != nil else { return }
        pendingClosed[reqId]?.lastActivity = Date()
        if let order = resp.messageOrder {
            if let blob = resp.positionsEncoded { pendingClosed[reqId]?.chunks[order] = blob }
            log.debug("fetchClosedPositions chunk req=\(reqId, privacy: .public) order=\(order) finished=\(resp.finished == true)")
            if resp.finished == true {
                pendingClosed[reqId]?.maxOrder = order
                pendingClosed[reqId]?.finished = true
            }
        } else if resp.finished == true {
            // Terminal response without an order field — treat as a single, final chunk.
            if let blob = resp.positionsEncoded { pendingClosed[reqId]?.chunks[0] = blob }
            pendingClosed[reqId]?.maxOrder = max(pendingClosed[reqId]?.maxOrder ?? -1, 0)
            pendingClosed[reqId]?.finished = true
        }
        resolveClosedIfReady(reqId)
    }

    private func resolveClosedIfReady(_ reqId: String) {
        guard let pending = pendingClosed[reqId], pending.finished,
              let cont = pending.continuation else { return }
        pendingClosed[reqId] = nil
        do {
            var blob = Data()
            if pending.maxOrder >= 0 {
                for order in 0...pending.maxOrder {
                    if let c = pending.chunks[order] { blob.append(c) }
                }
            }
            let positions = blob.isEmpty ? [] : try PositionDataBitsDecoder.decodeList(blob)
            log.debug("fetchClosedPositions req=\(reqId, privacy: .public) done: \(positions.count) position(s)")
            cont.resume(returning: positions)
        } catch {
            log.error("fetchClosedPositions req=\(reqId, privacy: .public) decode failed: \(error.localizedDescription, privacy: .public)")
            cont.resume(throwing: error)
        }
    }

    private func scheduleClosedTimeout(_ reqId: String, idle: TimeInterval) {
        Task { [weak self] in
            guard let self else { return }
            while await self.closedStillPending(reqId) {
                let remaining = await self.closedIdleRemaining(reqId, idle: idle)
                if remaining <= 0 {
                    await self.timeoutClosed(reqId)
                    return
                }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    private func closedStillPending(_ reqId: String) -> Bool { pendingClosed[reqId] != nil }

    private func closedIdleRemaining(_ reqId: String, idle: TimeInterval) -> TimeInterval {
        guard let pending = pendingClosed[reqId] else { return 0 }
        return idle - Date().timeIntervalSince(pending.lastActivity)
    }

    private func timeoutClosed(_ reqId: String) {
        guard let cont = pendingClosed[reqId]?.continuation else { return }
        pendingClosed[reqId] = nil
        cont.resume(throwing: SessionError.timedOut("closed positions request (no data received)"))
    }

    /// Resolve a pending closed-positions request with an error (server error routed by
    /// requestId), so it fails immediately rather than hanging until its idle timeout.
    private func failClosed(_ reqId: String, with error: Error) {
        guard pendingClosed[reqId] != nil else { return }
        let cont = pendingClosed[reqId]?.continuation
        pendingClosed[reqId] = nil
        cont?.resume(throwing: error)
    }

    /// Extracts the cached `[start, end]` window (epoch seconds) the server reports in a
    /// "data not in cache" error reason: `… data in cache from [yyyy-MM-dd HH:mm:ss.SSS]
    /// to [yyyy-MM-dd HH:mm:ss.SSS] …` (GMT). Returns nil if the reason isn't that error
    /// or the timestamps don't parse.
    static func parseCacheRange(_ reason: String?) -> (Int64, Int64)? {
        guard let reason, reason.contains("not in cache"),
              let anchor = reason.range(of: "data in cache from") else { return nil }
        let brackets = reason[anchor.upperBound...].components(separatedBy: "[")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard brackets.count >= 3,
              let s1 = brackets[1].components(separatedBy: "]").first,
              let s2 = brackets[2].components(separatedBy: "]").first,
              let d1 = formatter.date(from: s1),
              let d2 = formatter.date(from: s2) else { return nil }
        return (Int64(d1.timeIntervalSince1970), Int64(d2.timeIntervalSince1970))
    }

    // MARK: - Live quote subscription

    /// Send a quote-subscribe for the given slashed instruments (e.g. "EUR/USD"). The server
    /// then pushes `CurrencyMarket` messages on price changes, which are fanned out to all
    /// `tickStream()` consumers via `dispatch`.
    public func subscribeQuotes(instruments: Set<String>) async throws {
        guard state == .connected, let transport else { throw SessionError.notConnected }
        var req = QuoteSubscribeRequest(instruments: instruments)
        req.requestId = UUID().uuidString
        req.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        // Claim the new set BEFORE the await. The server replaces (not merges) the quote
        // set, and `ensureSubscribedQuotes` builds its union from `subscribedQuotes`. If we
        // only recorded the set AFTER `sendFrame`, a reentrant subscribe running during the
        // suspension would read the stale set, send a union missing this call's additions,
        // and then this call would overwrite it — silently dropping an instrument from the
        // server's set (it then never ticks). Claiming first closes that window; roll back
        // on failure so a retry re-sends.
        let previous = subscribedQuotes
        let now = Date()
        subscribedQuotes = instruments
        for inst in instruments where quoteSubscribedAt[inst] == nil { quoteSubscribedAt[inst] = now }
        for inst in quoteSubscribedAt.keys where !instruments.contains(inst) { quoteSubscribedAt[inst] = nil }
        do {
            try await transport.sendFrame(req.encode())
        } catch {
            subscribedQuotes = previous
            throw error
        }
        log.info("subscribed to \(instruments.count, privacy: .public) instruments")
    }

    /// Re-send the CURRENT quote subscription set to the server unconditionally (unlike
    /// `ensureSubscribedQuotes`, which skips when nothing new is needed). Recovers a
    /// subscription the server dropped/clobbered — the symptom is a subscribed instrument
    /// that never ticks while others do. Debounced so the per-chart and session watchdogs
    /// collapse to one send. Best-effort: a send failure is logged, not thrown.
    public func resubscribeQuotes() async {
        guard state == .connected, let transport, !subscribedQuotes.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastResubscribeAt) > 5 else { return }
        lastResubscribeAt = now
        var req = QuoteSubscribeRequest(instruments: subscribedQuotes)
        req.requestId = UUID().uuidString
        req.timestamp = Int64(now.timeIntervalSince1970 * 1000)
        do {
            try await transport.sendFrame(req.encode())
            log.info("resubscribed \(self.subscribedQuotes.count, privacy: .public) instruments (recovery)")
        } catch {
            log.error("resubscribe failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Periodic safety net for a dropped/clobbered quote subscription: if a subscribed
    /// instrument has NEVER ticked since it was subscribed ≥10s ago, while the feed is
    /// demonstrably live (some instrument ticked in the last ~12s), re-assert the
    /// subscription. The "feed is live" gate is what distinguishes a broken subscription
    /// from a closed market (where nothing ticks and re-sending wouldn't help), so this
    /// doesn't need a trading-calendar dependency. Started on connect, stopped on teardown.
    private func startQuoteWatchdog() {
        quoteWatchdogTask?.cancel()
        quoteWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                if Task.isCancelled { return }
                await self?.checkQuoteSilence()
            }
        }
    }

    private func checkQuoteSilence() async {
        guard state == .connected else { return }
        if Self.shouldResubscribe(
            subscribed: subscribedQuotes, quoteSubscribedAt: quoteSubscribedAt,
            lastTickAt: lastTickAt, lastAnyTickAt: lastAnyTickAt, now: Date()
        ) {
            log.error("quote watchdog: subscribed instrument silent while feed is live — resubscribing")
            await resubscribeQuotes()
        }
    }

    /// Pure decision for the quote watchdog (extracted so it's unit-testable without a
    /// live socket). Re-assert the subscription when the feed is demonstrably live —
    /// something ticked within `liveWindow` — yet some subscribed instrument has NEVER
    /// ticked since it was subscribed at least `graceSeconds` ago. The live-feed gate is
    /// what separates a dropped subscription from a closed market (nothing ticks at all).
    static func shouldResubscribe(
        subscribed: Set<String>,
        quoteSubscribedAt: [String: Date],
        lastTickAt: [String: Date],
        lastAnyTickAt: Date,
        now: Date,
        liveWindow: TimeInterval = 12,
        graceSeconds: TimeInterval = 10
    ) -> Bool {
        guard !subscribed.isEmpty else { return false }
        guard now.timeIntervalSince(lastAnyTickAt) < liveWindow else { return false }
        return subscribed.contains { inst in
            lastTickAt[inst] == nil
                && (quoteSubscribedAt[inst].map { now.timeIntervalSince($0) > graceSeconds } ?? false)
        }
    }

    /// Idempotent subscription union — adds any not-yet-subscribed instruments to the
    /// existing set and re-sends the FULL set (the server replaces, not merges). No-op
    /// if all of `instruments` are already subscribed. Call this from a chart's
    /// streamCandles consumer so the session only subscribes to instruments actually
    /// being viewed, instead of every pair in `defaultInstruments` up front.
    public func ensureSubscribedQuotes(_ instruments: Set<String>) async throws {
        let additions = instruments.subtracting(subscribedQuotes)
        guard !additions.isEmpty else { return }
        try await subscribeQuotes(instruments: subscribedQuotes.union(additions))
    }

    /// Multicast stream of incoming CurrencyMarket ticks. Each consumer gets its own
    /// AsyncStream; all are yielded to on every tick. Consumers should filter by instrument.
    public func tickStream() -> AsyncStream<CurrencyMarket> {
        let id = UUID()
        return AsyncStream<CurrencyMarket> { continuation in
            Task { [weak self] in await self?.registerTickStream(id: id, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregisterTickStream(id: id) }
            }
        }
    }

    private func registerTickStream(id: UUID, continuation: AsyncStream<CurrencyMarket>.Continuation) {
        tickStreams[id] = continuation
    }

    private func unregisterTickStream(id: UUID) {
        tickStreams.removeValue(forKey: id)
    }

    // MARK: - Account snapshot

    /// Returns the account snapshot delivered after INIT. Resolves immediately if one
    /// has already arrived, otherwise waits for the next `PackedAccountInfo` (or times out).
    public func accountSnapshot(timeout: TimeInterval = 15) async throws -> AccountInfo {
        if let latestAccount { return latestAccount }
        guard state == .connected else { throw SessionError.notConnected }
        let id = UUID()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AccountInfo, Error>) in
            if let latestAccount {
                cont.resume(returning: latestAccount)
                return
            }
            accountWaiters[id] = cont
            scheduleAccountTimeout(id, seconds: timeout)
        }
    }

    private func handleAccountInfo(_ account: AccountInfo) {
        let isFirst = latestAccount == nil
        latestAccount = account
        if isFirst {
            log.info("account snapshot: login=\(account.accountLoginId ?? "-", privacy: .public) currency=\(account.currency ?? "-", privacy: .public) balance=\(account.balance?.description ?? "-", privacy: .public)")
        }
        let waiters = accountWaiters
        accountWaiters.removeAll()
        for (_, cont) in waiters { cont.resume(returning: account) }
    }

    private func scheduleAccountTimeout(_ id: UUID, seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await self?.timeoutAccount(id)
        }
    }

    private func timeoutAccount(_ id: UUID) {
        guard let cont = accountWaiters.removeValue(forKey: id) else { return }
        cont.resume(throwing: SessionError.timedOut("account snapshot"))
    }

    // MARK: - Orders & positions

    /// Snapshot of the currently-open position groups.
    public func positionsSnapshot() -> [OrderGroup] { Array(positions.values) }

    /// Authoritative backstop for a missed close. The live `positions` dict is only pruned by an
    /// inbound `OrderGroup` CLOSE event (see the reader's `.orderGroup` case) — a fire-and-forget
    /// frame Dukascopy can silently drop, which strands a closed position as perpetually "open".
    /// Here we ask the broker's closed-position DB (the same source the History tab trusts) which
    /// positions actually closed in `[sinceMillis, now]` and drop any that are still open locally.
    /// Removal is broker-confirmed, so this can never hide a genuinely open position. Each dropped
    /// group is re-yielded as a CLOSE event so coordinators re-snapshot exactly as if the original
    /// event had arrived. Returns the number of stale positions pruned.
    @discardableResult
    public func reconcileClosedPositions(sinceMillis: Int64, idleTimeout: TimeInterval = 8) async -> Int {
        guard state == .connected, !positions.isEmpty else { return 0 }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard let closed = try? await fetchClosedPositions(
            fromMillis: sinceMillis, toMillis: nowMs, idleTimeout: idleTimeout)
        else { return 0 }
        // `ClosedPosition.positionId` shares the id space with `OrderGroup.orderGroupId` (both are the
        // Dukascopy position id used to close — see `closePosition(positionId:)`), so it's the join key.
        let closedIds = Set(closed.map(\.positionId))
        let stale = Self.stalePositionIds(openIds: Set(positions.keys), brokerClosedIds: closedIds)
        guard !stale.isEmpty else { return 0 }
        for id in stale {
            guard var g = positions.removeValue(forKey: id) else { continue }
            log.info("reconcile: pruned stale open position \(id, privacy: .public) — broker reports closed")
            g.status = "CLOSE"
            for (_, c) in orderEventStreams { c.yield(.group(g)) }
        }
        return stale.count
    }

    /// Pure pruning decision for `reconcileClosedPositions`: of the positions we still show open,
    /// which ones did the broker report closed? The answer is exactly the intersection — a position
    /// is pruned only when it's BOTH locally open AND broker-confirmed closed, so an id the broker
    /// doesn't mention is never touched (it stays open). Extracted as a pure, static function so the
    /// safety invariant is unit-tested without a live session.
    static func stalePositionIds(openIds: Set<String>, brokerClosedIds: Set<String>) -> Set<String> {
        openIds.intersection(brokerClosedIds)
    }

    /// Multicast stream of inbound order/position events (acks + live updates).
    public func orderEvents() -> AsyncStream<OrderEvent> {
        let id = UUID()
        return AsyncStream<OrderEvent> { continuation in
            Task { [weak self] in await self?.registerOrderStream(id: id, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregisterOrderStream(id: id) }
            }
        }
    }

    private func registerOrderStream(id: UUID, continuation: AsyncStream<OrderEvent>.Continuation) {
        orderEventStreams[id] = continuation
    }
    private func unregisterOrderStream(id: UUID) {
        orderEventStreams.removeValue(forKey: id)
    }

    /// Multicast stream of inbound news/calendar events (after `subscribeNews`).
    public func newsEvents() -> AsyncStream<NewsEvent> {
        let id = UUID()
        return AsyncStream<NewsEvent> { continuation in
            Task { [weak self] in await self?.registerNewsStream(id: id, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregisterNewsStream(id: id) }
            }
        }
    }
    private func registerNewsStream(id: UUID, continuation: AsyncStream<NewsEvent>.Continuation) {
        newsEventStreams[id] = continuation
    }
    private func unregisterNewsStream(id: UUID) {
        newsEventStreams.removeValue(forKey: id)
    }

    /// Subscribe to the news/calendar feed. `sources` are `NewsSource` constant names
    /// ("DJ_LIVE_CALENDAR" for the economic calendar, "FXSPIDER_NEWS" for headlines).
    /// Events then arrive on `newsEvents()`.
    @discardableResult
    public func subscribeNews(
        sources: [String], from: Int64, to: Int64, calendarType: String?
    ) async throws -> String {
        guard state == .connected, let transport else { throw SessionError.notConnected }
        let reqId = UUID().uuidString
        let frame = encodeNewsSubscribeRequest(
            sources: sources, from: from, to: to, calendarType: calendarType,
            userId: latestAccount?.userId, accountLoginId: latestAccount?.accountLoginId,
            sessionId: authSessionId, requestId: reqId,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try await transport.sendFrame(frame)
        return reqId
    }

    /// Submit a MARKET order by sending an `OrderGroupMessage` (the desktop client's
    /// path). The resulting order/position state streams back via `orderEvents()`;
    /// after sending, this waits briefly for a broker ack and throws
    /// `SessionError.orderRejected` on an explicit rejection (silence still returns
    /// success). Returns the `requestId` so the caller can correlate.
    /// `priceClient` is the current market price the user is acting on.
    @discardableResult
    public func submitMarketOrder(
        instrument: String, side: String, amount: BigDecimalValue,
        priceClient: BigDecimalValue? = nil,
        stopLoss: BigDecimalValue? = nil, takeProfit: BigDecimalValue? = nil, label: String
    ) async throws -> String {
        guard state == .connected, let transport else { throw SessionError.notConnected }
        let price: BigDecimalValue
        if let priceClient { price = priceClient }
        else if let p = await currentPrice(instrument: instrument, buy: side == "BUY") { price = p }
        else { throw SessionError.timedOut("market: no price for \(instrument)") }
        let reqId = UUID().uuidString
        let frame = encodeMarketOrderGroup(
            instrument: instrument, side: side, amount: amount, priceClient: price,
            label: label, stopLoss: stopLoss, takeProfit: takeProfit,
            userId: latestAccount?.userId, accountLoginId: latestAccount?.accountLoginId,
            sessionId: authSessionId,
            requestId: reqId, timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try await transport.sendFrame(frame)
        try await checkOrderAck(
            requestId: reqId,
            meta: PendingOrderAckMeta(instrument: instrument, label: label,
                                      orderGroupId: nil, submittedAt: Date()),
            op: "market order")
        return reqId
    }

    /// Submit a pending LIMIT/STOP entry order at `triggerPrice`. The resulting pending
    /// order arrives via `orderEvents()`; an explicit broker rejection throws.
    @discardableResult
    public func submitPendingOrder(
        instrument: String, side: String, kind: PendingKind,
        amount: BigDecimalValue, triggerPrice: BigDecimalValue,
        stopLoss: BigDecimalValue? = nil, takeProfit: BigDecimalValue? = nil, label: String
    ) async throws -> String {
        guard state == .connected, let transport else { throw SessionError.notConnected }
        // `priceClient` is just the reference market price; if no tick arrives quickly
        // (e.g. a quiet pair that wasn't subscribed) fall back to the trigger price so
        // the order isn't blocked — the trigger is what actually matters for a pending.
        let priceClient = await currentPrice(instrument: instrument, buy: side == "BUY") ?? triggerPrice
        let reqId = UUID().uuidString
        let frame = encodePendingOrderGroup(
            instrument: instrument, side: side, kind: kind, amount: amount,
            triggerPrice: triggerPrice, priceClient: priceClient, label: label,
            stopLoss: stopLoss, takeProfit: takeProfit,
            userId: latestAccount?.userId, sessionId: authSessionId,
            requestId: reqId, timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try await transport.sendFrame(frame)
        try await checkOrderAck(
            requestId: reqId,
            meta: PendingOrderAckMeta(instrument: instrument, label: label,
                                      orderGroupId: nil, submittedAt: Date()),
            op: "pending order")
        return reqId
    }

    /// Close an entire position group by its `orderGroupId`. Sends the position group
    /// with a nested CLOSE order at the current market price. The resulting state
    /// change arrives via `orderEvents()`; an explicit broker rejection throws.
    @discardableResult
    public func closePosition(positionId: String) async throws -> String {
        guard state == .connected, let transport else { throw SessionError.notConnected }
        guard let group = positions[positionId],
              let instrument = group.instrument,
              let side = group.side,
              let amount = group.amount else {
            throw SessionError.timedOut("close: unknown position \(positionId)")
        }
        // Close a LONG by SELL (at bid); a SHORT by BUY (at ask).
        let closeSideBuy = side != "BUY"
        guard let price = await currentPrice(instrument: instrument, buy: closeSideBuy) else {
            throw SessionError.timedOut("close: no price for \(instrument)")
        }
        let reqId = UUID().uuidString
        let frame = encodeCloseOrderGroup(
            orderGroupId: positionId, instrument: instrument, positionSide: side, amount: amount,
            pricePosOpen: group.pricePosOpen, priceClient: price,
            userId: latestAccount?.userId, sessionId: authSessionId,
            requestId: reqId, timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try await transport.sendFrame(frame)
        try await checkOrderAck(
            requestId: reqId,
            meta: PendingOrderAckMeta(instrument: instrument, label: nil,
                                      orderGroupId: positionId, submittedAt: Date()),
            op: "close position")
        return reqId
    }

    /// Cancel a pending order by `orderId` (found among the stored position groups).
    @discardableResult
    public func cancelOrder(orderId: String) async throws -> String {
        guard state == .connected, let transport else { throw SessionError.notConnected }
        var found: OrderMsg?
        var owningGroup: OrderGroup?
        for g in positions.values {
            if let o = g.orders.first(where: { $0.orderId == orderId }) {
                found = o
                owningGroup = g
                break
            }
        }
        guard let order = found else { throw SessionError.timedOut("cancel: unknown order \(orderId)") }
        let reqId = UUID().uuidString
        let frame = encodeCancelOrder(
            order: order, userId: latestAccount?.userId, sessionId: authSessionId,
            requestId: reqId, timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try await transport.sendFrame(frame)
        try await checkOrderAck(
            requestId: reqId,
            meta: PendingOrderAckMeta(instrument: owningGroup?.instrument, label: nil,
                                      orderGroupId: order.orderGroupId ?? owningGroup?.orderGroupId,
                                      submittedAt: Date()),
            op: "cancel order")
        return reqId
    }

    /// Add or change a protective SL/TP order on the position/pending group `orderGroupId`.
    /// `existingProtectiveOrderId` set → amend that protective order; nil → create a new one.
    /// To remove a protective order entirely, call `cancelOrder(orderId:)` on it.
    @discardableResult
    public func modifyProtectiveOrder(
        orderGroupId: String, isTakeProfit: Bool, newPrice: BigDecimalValue,
        existingProtectiveOrderId: String?
    ) async throws -> String {
        guard state == .connected, let transport else { throw SessionError.notConnected }
        guard let group = positions[orderGroupId], let instrument = group.instrument else {
            throw SessionError.timedOut("modify: unknown group \(orderGroupId)")
        }
        let opening = group.orders.first { $0.direction == "OPEN" }
        // A resting pending order has no net position yet, so `group.amount` is zero — the size lives
        // on the opening order. Prefer the first NON-ZERO amount, else the server rejects with
        // "order amount is empty or zero".
        guard let side = group.side ?? opening?.side,
              let amount = nonZeroAmount(group.amount, opening?.amount) else {
            throw SessionError.timedOut("modify: incomplete group \(orderGroupId)")
        }
        let reqId = UUID().uuidString
        let frame = encodeModifyProtectiveOrder(
            existingProtectiveOrderId: existingProtectiveOrderId, orderGroupId: orderGroupId,
            instrument: instrument, positionSide: side, amount: amount,
            newPrice: newPrice, isTakeProfit: isTakeProfit,
            userId: latestAccount?.userId, sessionId: authSessionId,
            requestId: reqId, timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try await transport.sendFrame(frame)
        try await checkOrderAck(
            requestId: reqId,
            meta: PendingOrderAckMeta(instrument: instrument, label: nil,
                                      orderGroupId: orderGroupId, submittedAt: Date()),
            op: "modify SL/TP")
        return reqId
    }

    /// First non-zero amount among the candidates (a resting pending order's group net size is 0, so
    /// the size must come from the opening order, else the server rejects "order amount is empty or zero").
    private func nonZeroAmount(_ candidates: BigDecimalValue?...) -> BigDecimalValue? {
        candidates.compactMap { $0 }.first { $0.doubleValue != 0 }
    }

    /// Amend the ENTRY/trigger price of a resting pending (limit/stop) entry order in place. `orderId`
    /// is the opening order's id; `orderGroupId` its group. The order kind (limit/stop) is preserved.
    @discardableResult
    public func modifyPendingEntry(
        orderGroupId: String, orderId: String, newTriggerPrice: BigDecimalValue, isLimit: Bool
    ) async throws -> String {
        guard state == .connected, let transport else { throw SessionError.notConnected }
        guard let group = positions[orderGroupId], let instrument = group.instrument else {
            throw SessionError.timedOut("modify entry: unknown group \(orderGroupId)")
        }
        let opening = group.orders.first { $0.direction == "OPEN" }
        guard let side = opening?.side ?? group.side,
              let amount = nonZeroAmount(opening?.amount, group.amount) else {
            throw SessionError.timedOut("modify entry: incomplete group \(orderGroupId)")
        }
        // priceClient is the reference market at amend time (ask for a BUY, bid for a SELL); fall back
        // to the new trigger if no quote is cached/arrives.
        let market = await currentPrice(instrument: instrument, buy: side == "BUY") ?? newTriggerPrice
        let reqId = UUID().uuidString
        let frame = encodeModifyPendingEntryOrder(
            orderId: orderId, orderGroupId: orderGroupId, instrument: instrument, side: side,
            kind: isLimit ? .limit : .stop, amount: amount, newTriggerPrice: newTriggerPrice,
            priceClient: market, userId: latestAccount?.userId, sessionId: authSessionId,
            requestId: reqId, timestamp: Int64(Date().timeIntervalSince1970 * 1000))
        try await transport.sendFrame(frame)
        try await checkOrderAck(
            requestId: reqId,
            meta: PendingOrderAckMeta(instrument: instrument, label: nil,
                                      orderGroupId: orderGroupId, submittedAt: Date()),
            op: "modify pending entry")
        return reqId
    }

    /// Current price for `instrument` (ask if `buy`, else bid). Uses the last-known
    /// quote immediately when available (FX pairs can go 5–10s between ticks, so
    /// waiting for the *next* tick is unreliable); otherwise subscribes and waits up
    /// to `timeout` for the first tick.
    private func currentPrice(instrument: String, buy: Bool, timeout: TimeInterval = 8) async -> BigDecimalValue? {
        if let cached = lastQuotes[instrument] {
            if let p = buy ? cached.bestAsk : cached.bestBid { return p }
        }
        try? await ensureSubscribedQuotes([instrument])
        return await withTaskGroup(of: BigDecimalValue?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                for await t in await self.tickStream() where t.instrument == instrument {
                    return buy ? t.bestAsk : t.bestBid
                }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Broadcasts a server order ack on `orderEvents()`. The desktop order path is
    /// fire-and-forget — order/position state changes arrive as OrderGroup/OrderMsg
    /// updates; an `ExtApiOrderResponse` (if the server ever sends one) is surfaced here too.
    private func handleOrderResponse(_ r: ExtApiOrderResponse) {
        log.info("order response: state=\(r.state ?? "-", privacy: .public) orderId=\(r.orderId ?? "-", privacy: .public) positionId=\(r.positionId ?? "-", privacy: .public) reqId=\(r.requestId ?? "-", privacy: .public)")
        for (_, c) in orderEventStreams { c.yield(.response(r)) }
        if let (key, outcome) = Self.ackMatch(response: r, pending: pendingOrderAcks.mapValues(\.meta)) {
            resolveOrderAck(key, outcome)
        }
    }

    // MARK: - Order acks

    /// Outcome of waiting for a broker ack on an order operation.
    enum OrderAckOutcome: Sendable, Equatable {
        case accepted                                  // positive evidence (group/order update)
        case rejected(state: String, reason: String?)  // explicit broker rejection → throw
        case unresolved                                // timeout / teardown → status quo: success
    }

    /// What an in-flight order op looks like to the matchers. `orderGroupId` is set for
    /// ops on an existing group (close/cancel/modify); submits don't know theirs yet.
    struct PendingOrderAckMeta: Sendable {
        let instrument: String?    // slashed, as sent
        let label: String?
        let orderGroupId: String?
        let submittedAt: Date
    }

    private struct PendingOrderAck {
        let meta: PendingOrderAckMeta
        var continuation: CheckedContinuation<OrderAckOutcome, Never>?
    }

    /// Register the op and suspend until an inbound event resolves it or the timeout
    /// fires. Never throws and never resolves `.rejected` without explicit broker evidence:
    /// silence is `.unresolved` (success) so a slow ack can't goad the caller into a
    /// double submit.
    private func awaitOrderAck(
        requestId: String, meta: PendingOrderAckMeta, timeout: TimeInterval = 3
    ) async -> OrderAckOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<OrderAckOutcome, Never>) in
            pendingOrderAcks[requestId] = PendingOrderAck(meta: meta, continuation: cont)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.resolveOrderAck(requestId, .unresolved)
            }
        }
    }

    private func resolveOrderAck(_ key: String, _ outcome: OrderAckOutcome) {
        guard var pending = pendingOrderAcks.removeValue(forKey: key) else { return }
        pending.continuation?.resume(returning: outcome)
        pending.continuation = nil
    }

    /// Throw on an explicit rejection; `.accepted`/`.unresolved` both return normally.
    private func checkOrderAck(requestId: String, meta: PendingOrderAckMeta, op: String) async throws {
        let outcome = await awaitOrderAck(requestId: requestId, meta: meta)
        switch outcome {
        case .rejected(let state, let reason):
            log.error("\(op, privacy: .public) rejected: state=\(state, privacy: .public) reason=\(reason ?? "-", privacy: .public)")
            throw SessionError.orderRejected(state, reason)
        case .unresolved:
            log.notice("\(op, privacy: .public) ack unresolved within timeout (treated as accepted)")
        case .accepted:
            break
        }
    }

    private static let rejectedOrderStates: Set<String> = ["REJECTED", "ERROR", "REVOKED"]

    /// Match an `ExtApiOrderResponse` against in-flight ops: exact requestId echo first;
    /// a rejection without one falls back to the newest op sharing the label (or
    /// instrument) — a rejection usually follows the most recent send.
    static func ackMatch(
        response: ExtApiOrderResponse, pending: [String: PendingOrderAckMeta]
    ) -> (key: String, outcome: OrderAckOutcome)? {
        let outcome: OrderAckOutcome = response.isRejected
            ? .rejected(state: response.state ?? "REJECTED", reason: response.notes ?? response.comments)
            : .accepted
        if let rid = response.requestId, pending[rid] != nil {
            return (rid, outcome)
        }
        guard response.isRejected else { return nil }
        let candidates = pending.filter { _, meta in
            if let label = response.label, let metaLabel = meta.label { return label == metaLabel }
            if let inst = response.instrument, let metaInst = meta.instrument { return inst == metaInst }
            return false
        }
        guard let newest = candidates.max(by: { $0.value.submittedAt < $1.value.submittedAt }) else { return nil }
        return (newest.key, outcome)
    }

    /// Match a single-order update: a rejected state resolves the op on its group
    /// (close/cancel/modify) or, for submits, the newest op on the same instrument.
    /// Non-rejected order updates are not treated as acks (too ambiguous).
    static func ackMatch(
        order: OrderMsg, pending: [String: PendingOrderAckMeta]
    ) -> (key: String, outcome: OrderAckOutcome)? {
        guard let state = order.state, rejectedOrderStates.contains(state) else { return nil }
        let outcome = OrderAckOutcome.rejected(state: state, reason: nil)
        if let gid = order.orderGroupId,
           let hit = pending.first(where: { $0.value.orderGroupId == gid }) {
            return (hit.key, outcome)
        }
        let candidates = pending.filter { _, meta in
            meta.orderGroupId == nil && meta.instrument != nil && meta.instrument == order.instrument
        }
        guard let newest = candidates.max(by: { $0.value.submittedAt < $1.value.submittedAt }) else { return nil }
        return (newest.key, outcome)
    }

    /// Match a group update: a nested rejected order resolves `.rejected`; otherwise the
    /// update is positive evidence — it confirms ops targeting that group (close/cancel/
    /// modify), and an OPEN group confirms the oldest in-flight submit on its instrument
    /// (FIFO, matching broker processing order).
    static func ackMatch(
        group: OrderGroup, pending: [String: PendingOrderAckMeta]
    ) -> (key: String, outcome: OrderAckOutcome)? {
        if let bad = group.orders.first(where: { rejectedOrderStates.contains($0.state ?? "") }) {
            let rejected = OrderAckOutcome.rejected(state: bad.state ?? "REJECTED", reason: nil)
            if let gid = group.orderGroupId,
               let hit = pending.first(where: { $0.value.orderGroupId == gid }) {
                return (hit.key, rejected)
            }
            let candidates = pending.filter { _, meta in
                meta.orderGroupId == nil && meta.instrument != nil && meta.instrument == group.instrument
            }
            if let newest = candidates.max(by: { $0.value.submittedAt < $1.value.submittedAt }) {
                return (newest.key, rejected)
            }
            return nil
        }
        if let gid = group.orderGroupId,
           let hit = pending.first(where: { $0.value.orderGroupId == gid }) {
            return (hit.key, .accepted)
        }
        guard group.isOpen else { return nil }
        let candidates = pending.filter { _, meta in
            meta.orderGroupId == nil && meta.instrument != nil && meta.instrument == group.instrument
        }
        guard let oldest = candidates.min(by: { $0.value.submittedAt < $1.value.submittedAt }) else { return nil }
        return (oldest.key, .accepted)
    }

    /// Fail every in-flight history request and account waiter — called on teardown
    /// so a socket drop / server error / `close()` never leaves a caller suspended forever.
    private func failAllPending(_ error: Error) {
        let histories = pendingHistory
        pendingHistory.removeAll()
        for (_, p) in histories { p.continuation?.resume(throwing: error) }

        let closed = pendingClosed
        pendingClosed.removeAll()
        for (_, p) in closed { p.continuation?.resume(throwing: error) }

        let waiters = accountWaiters
        accountWaiters.removeAll()
        for (_, cont) in waiters { cont.resume(throwing: error) }

        // Order acks resolve `.unresolved`, NOT an error: the frame may have been
        // delivered, so this must read as "outcome unknown" (the snapshot stream
        // reconciles after reconnect) — an error here could trigger a double submit.
        let acks = pendingOrderAcks
        pendingOrderAcks.removeAll()
        for (_, var p) in acks { p.continuation?.resume(returning: .unresolved); p.continuation = nil }
    }

    // MARK: - Reader loop

    private func startReader(transport: Transport) {
        readerTask = Task { [weak self] in
            await self?.readLoop(transport: transport)
        }
    }

    /// Client-initiated keepalive: the server sends no heartbeats of its own and closes
    /// a silent socket after ~15s, so we periodically send a heartbeat to keep the
    /// primary connection up. Fire-and-forget — the server's reply isn't needed, only
    /// the inbound traffic that resets its idle timer.
    private func startHeartbeat(transport: Transport) {
        heartbeatTask = Task { [weak self, heartbeatInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(heartbeatInterval))
                if Task.isCancelled { return }
                await self?.sendHeartbeat(transport: transport)
            }
        }
    }

    private func sendHeartbeat(transport: Transport) async {
        guard state == .connected else { return }
        let ping = HeartbeatRequest(requestTime: Int64(Date().timeIntervalSince1970 * 1000))
        do {
            try await transport.sendFrame(ping.encode())
            log.debug("heartbeat sent")
        } catch {
            log.error("heartbeat send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readLoop(transport: Transport) async {
        while !Task.isCancelled {
            let frame: Data
            do {
                frame = try await transport.receiveFrame()
            } catch {
                if !Task.isCancelled { await handleReadFailure(error) }
                return
            }
            guard let msg = try? MessageDecoder.decode(frame) else {
                log.debug("reader: undecodable frame (\(frame.count) bytes), skipping")
                continue
            }
            await dispatch(msg, transport: transport)
        }
    }

    private func dispatch(_ msg: InboundMessage, transport: Transport) async {
        switch msg {
        case .heartbeatRequest(let h):
            let resp = HeartbeatOkResponse(
                requestTime: h.requestTime ?? 0,
                receiveTime: Int64(Date().timeIntervalSince1970 * 1000),
                synchRequestId: h.synchRequestId
            )
            do {
                try await transport.sendFrame(resp.encode())
            } catch {
                log.error("heartbeat reply failed: \(error.localizedDescription, privacy: .public)")
            }
        case .error(let e):
            // Only a FATAL server error should drop the whole connection. A non-fatal
            // error (e.g. one bad/oversized history request) is logged and routed to the
            // request it belongs to so that request fails fast instead of hanging until
            // its idle timeout — and so it can't take down every other chart's session.
            let routedToHistory = e.requestId.map { pendingHistory[$0] != nil } ?? false
            if e.fatal == true {
                log.error("server error (fatal): reason=\(e.reason ?? "-", privacy: .public)")
            } else if routedToHistory {
                // Expected control flow: a history request reached before the socket's warm
                // window, so the server reports "not in cache" and the owning fetchHistory
                // falls back to the bulk server. Debug-only so it doesn't flood the log.
                log.debug("server error (non-fatal, routed): reason=\(e.reason ?? "-", privacy: .public)")
            } else {
                log.notice("server error (non-fatal): reason=\(e.reason ?? "-", privacy: .public)")
            }
            if let reqId = e.requestId, pendingHistory[reqId] != nil {
                failHistory(reqId, with: e)
            }
            if let reqId = e.requestId, pendingClosed[reqId] != nil {
                failClosed(reqId, with: e)
            }
            // A server error echoing an order op's requestId is that op's rejection.
            if let reqId = e.requestId, pendingOrderAcks[reqId] != nil {
                resolveOrderAck(reqId, .rejected(state: "ERROR", reason: e.reason))
            }
            if e.fatal == true {
                await markFailed("server error: \(e.reason ?? "unknown")")
            }
        case .candleHistoryGroup(let g):
            handleHistoryGroup(g)
        case .positionBinaryResponse(let resp):
            handleClosedResponse(resp)
        case .packedAccountInfo(let p):
            handleAccountInfo(p.account)
            for g in p.groups where g.orderGroupId != nil {
                positions[g.orderGroupId!] = g
            }
            // Resting pending (limit/stop) orders arrive as loose `orders`, not `groups` — rebuild a
            // group per orderGroupId so they surface like a live-placed one. Skip ids already present
            // as a position group.
            for g in p.pendingOrderGroups() where g.orderGroupId.map({ positions[$0] == nil }) ?? false {
                positions[g.orderGroupId!] = g
            }
            if !p.groups.isEmpty || !p.orders.isEmpty {
                log.info("packed account info: \(p.groups.count) position group(s), \(p.orders.count) order(s)")
            }
        case .orderGroup(let g):
            if let id = g.orderGroupId {
                if g.isOpen { positions[id] = g } else { positions.removeValue(forKey: id) }
            }
            for (_, c) in orderEventStreams { c.yield(.group(g)) }
            if let (key, outcome) = Self.ackMatch(group: g, pending: pendingOrderAcks.mapValues(\.meta)) {
                resolveOrderAck(key, outcome)
            }
        case .order(let o):
            for (_, c) in orderEventStreams { c.yield(.order(o)) }
            if let (key, outcome) = Self.ackMatch(order: o, pending: pendingOrderAcks.mapValues(\.meta)) {
                resolveOrderAck(key, outcome)
            }
        case .orderResponse(let r):
            handleOrderResponse(r)
        case .calendarEvent(let e):
            log.debug("calendar event: \(e.country ?? "-", privacy: .public) [\(e.eventCategory ?? "-", privacy: .public)] \(e.description ?? "-", privacy: .public)")
            for (_, c) in newsEventStreams { c.yield(.calendar(e, story: NewsStoryMsg())) }
        case .newsStory(let s):
            if let cal = s.content {
                // Calendar entries arrive embedded in a NewsStoryMessage's content.
                log.debug("calendar event: \(cal.country ?? "-", privacy: .public) [\(cal.eventCategory ?? "-", privacy: .public)] \(cal.description ?? "-", privacy: .public)")
                for (_, c) in newsEventStreams { c.yield(.calendar(cal, story: s)) }
            } else {
                log.debug("news story: [hot=\(s.hot)] \(s.header ?? "-", privacy: .public)")
                for (_, c) in newsEventStreams { c.yield(.story(s)) }
            }
        case .currencyMarket(let cm):
            log.debug("tick \(cm.instrument, privacy: .public) bid=\(cm.bestBid?.description ?? "-", privacy: .public)")
            lastQuotes[cm.instrument] = cm   // most-recent quote per instrument, for order pricing
            let nowTick = Date()
            lastTickAt[cm.instrument] = nowTick
            lastAnyTickAt = nowTick
            for (_, c) in tickStreams { c.yield(cm) }
        case .unknown(let classId, let body):
            // The server sends a primary-socket auth acceptor shortly after connect and
            // expects it echoed back verbatim to complete the primary connection; without
            // the echo the server closes the socket after ~15s. Reconstruct the exact
            // frame (classId + body) and send it straight back.
            if classId == javaStringHashCode(WireClass.primarySocketAuthAcceptor) {
                var w = BinaryWriter()
                w.writeInt32BE(classId)
                w.writeBytes(body)
                do {
                    try await transport.sendFrame(w.data)
                    log.info("primary socket auth acceptor echoed")
                } catch {
                    log.error("primary socket auth echo failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                log.debug("unknown inbound frame classId=\(classId) len=\(body.count)")
            }
        default:
            // Market / position routing layers onto dispatch in later slices.
            break
        }
    }

    /// Decide what to do when the reader's transport read throws. A read failure is usually a
    /// transient drop (sleep/network), so attempt a bounded in-place `reconnect()` — which keeps
    /// the multicast consumers registered, so charts resume seamlessly — before marking the
    /// session failed. The reconnect is fired on a SEPARATE task (mirroring the history
    /// watchdog): `reconnect()` tears down + cancels THIS reader task and starts a fresh one, so
    /// it must not run on the dying reader task. This loop simply returns after triggering it.
    private func handleReadFailure(_ error: Error) async {
        let now = Date()
        if now.timeIntervalSince(lastReadReconnectAt) > readReconnectResetInterval {
            readReconnectAttempts = 0   // connection had been stable — fresh budget for this blip
        }
        guard readReconnectAttempts < maxReadReconnectAttempts else {
            await markFailed("read: \(error) — \(readReconnectAttempts) in-place reconnect(s) exhausted")
            return
        }
        readReconnectAttempts += 1
        lastReadReconnectAt = now
        let attempt = readReconnectAttempts
        log.warning("transport read failed (\(error.localizedDescription, privacy: .public)); in-place reconnect attempt \(attempt)/\(self.maxReadReconnectAttempts)")
        Task { [weak self] in
            do {
                try await self?.reconnect()
                log.info("in-place reconnect succeeded after transport read failure")
            } catch {
                await self?.markFailed("read failure; reconnect failed: \(error.localizedDescription)")
            }
        }
    }

    private func markFailed(_ reason: String) async {
        log.error("session FAILED: \(reason, privacy: .public)")
        setState(.failed(reason))
        await teardown()
        finishMulticastStreams()
    }

    private func teardown() async {
        failAllPending(SessionError.notConnected)
        readerTask?.cancel()
        readerTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        quoteWatchdogTask?.cancel()
        quoteWatchdogTask = nil
        // Clear per-instrument tick tracking so a fresh connect (incl. `reconnect()`'s
        // rebuild) re-evaluates silence from scratch rather than trusting pre-rebuild ticks.
        lastTickAt.removeAll()
        lastAnyTickAt = .distantPast
        if let transport { await transport.close() }
        transport = nil
    }
}
