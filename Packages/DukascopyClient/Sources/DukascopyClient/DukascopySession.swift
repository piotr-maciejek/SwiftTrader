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

        public var description: String {
            switch self {
            case .noSRP6Servers: "JNLP returned no SRP6 servers"
            case .noUsableAPIServer: "auth returned no usable API server"
            case .authFailed(let s): "authentication failed: \(s)"
            case .notConnected: "session is not connected"
            case .timedOut(let what): "\(what) timed out"
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
    private var latestAccount: AccountInfo?
    private var accountWaiters: [UUID: CheckedContinuation<AccountInfo, Error>] = [:]
    // Multicast: each consumer of `tickStream()` gets its own continuation, all yielded to
    // when a CurrencyMarket message arrives. Consumers filter to the instruments they care
    // about. Removed on stream termination so this dictionary stays bounded.
    private var tickStreams: [UUID: AsyncStream<CurrencyMarket>.Continuation] = [:]
    /// Debounce flag for the silent-DDS watchdog: when a fetchHistory idle-times-out
    /// every subsequent fetchHistory is hung on the same wedged channel, so we trigger
    /// a forced reconnect — but multiple in-flight requests hitting their timeouts
    /// simultaneously must collapse to a single rebuild cycle, not stack on each other.
    private var reconnectInProgress = false

    /// Slashed instrument names currently subscribed for quote ticks. Mutated only on
    /// `subscribeQuotes` (which sends the full set to the server) so `ensureSubscribed`
    /// can compute additions and skip the round-trip when nothing new is needed.
    private var subscribedQuotes: Set<String> = []

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
        state = .connecting
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
            self.state = .connected
            startReader(transport: transport)
            startHeartbeat(transport: transport)
            log.info("connect: CONNECTED")
        } catch {
            log.error("connect: FAILED: \(error.localizedDescription, privacy: .public)")
            state = .failed(String(describing: error))
            await teardown()
            throw error
        }
    }

    public func close() async {
        await teardown()
        state = .disconnected
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
        state = .disconnected
        try await connect()
        if !toResubscribe.isEmpty {
            log.info("reconnect: re-subscribing \(toResubscribe.count) quote(s) after rebuild")
            try await subscribeQuotes(instruments: toResubscribe)
        }
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
        // The DDS chart-data channel doesn't self-recover from this state: every
        // subsequent fetchHistory hangs identically until the socket is rebuilt. Fire a
        // reconnect now; the debounce flag inside `reconnect()` collapses simultaneous
        // timeouts to one cycle. Caller's catch sees the .timedOut error and can retry —
        // by the time it does, the rebuilt session is up and the retry succeeds.
        Task { [weak self] in
            do {
                try await self?.reconnect()
            } catch {
                log.error("watchdog reconnect failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Resolve a single pending history request with an error (e.g. a server error
    /// correlated to it by requestId), so it fails immediately rather than hanging.
    private func failHistory(_ reqId: String, with error: Error) {
        guard pendingHistory[reqId] != nil else { return }
        let cont = pendingHistory[reqId]?.continuation
        pendingHistory[reqId] = nil
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
        try await transport.sendFrame(req.encode())
        subscribedQuotes = instruments
        log.info("subscribed to \(instruments.count, privacy: .public) instruments")
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

    /// Fail every in-flight history request and account waiter — called on teardown so
    /// a socket drop / server error / `close()` never leaves a caller suspended forever.
    private func failAllPending(_ error: Error) {
        let histories = pendingHistory
        pendingHistory.removeAll()
        for (_, p) in histories { p.continuation?.resume(throwing: error) }

        let waiters = accountWaiters
        accountWaiters.removeAll()
        for (_, cont) in waiters { cont.resume(throwing: error) }
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
                if !Task.isCancelled { await markFailed("read: \(error)") }
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
            if e.fatal == true {
                await markFailed("server error: \(e.reason ?? "unknown")")
            }
        case .candleHistoryGroup(let g):
            handleHistoryGroup(g)
        case .packedAccountInfo(let p):
            handleAccountInfo(p.account)
        case .currencyMarket(let cm):
            log.debug("tick \(cm.instrument, privacy: .public) bid=\(cm.bestBid?.description ?? "-", privacy: .public)")
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
            }
        default:
            // Market / position routing layers onto dispatch in later slices.
            break
        }
    }

    private func markFailed(_ reason: String) async {
        log.error("session FAILED: \(reason, privacy: .public)")
        state = .failed(reason)
        await teardown()
    }

    private func teardown() async {
        failAllPending(SessionError.notConnected)
        readerTask?.cancel()
        readerTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let transport { await transport.close() }
        transport = nil
    }
}
