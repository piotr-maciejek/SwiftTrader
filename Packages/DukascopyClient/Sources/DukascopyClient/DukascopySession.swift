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

    public init(
        environment: DukascopyEnvironment,
        credentials: AuthCredentials,
        authClient: AuthClient = AuthClient()
    ) {
        self.environment = environment
        self.credentials = credentials
        self.authClient = authClient
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

            var lastError: Error?
            var success: AuthSuccess?
            for serverURL in jnlp.srp6LoginURLs {
                do {
                    success = try await authClient.authenticate(baseURL: serverURL, credentials: credentials)
                    break
                } catch {
                    log.error("connect: auth failed against \(serverURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    lastError = error
                    continue
                }
            }
            guard let auth = success else {
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

    // MARK: - History

    /// Fetch historical candles for `[startSeconds, endSeconds]`. Sends a candle
    /// subscribe request and reassembles the chunked `CandleHistoryGroup` response
    /// (correlated by request id) into bars.
    public func fetchHistory(
        instrument: String,
        side: OfferSide = .bid,
        period: CandlePeriod,
        startSeconds: Int64,
        endSeconds: Int64,
        idleTimeout: TimeInterval = 120
    ) async throws -> [CandleBar] {
        do {
            return try await subscribeHistory(
                instrument: instrument, side: side, period: period,
                startSeconds: startSeconds, endSeconds: endSeconds, idleTimeout: idleTimeout
            )
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
            if startSeconds < bulkEndSeconds {
                bulkBars = await fetchBulkHistory(
                    instrument: instrument, side: side, period: period,
                    fromMs: startSeconds * 1000, toMs: bulkEndSeconds * 1000
                )
            }
            let combined = Self.dedupSorted(bulk: bulkBars, socket: socketBars)
            if combined.isEmpty { throw e }
            log.info("fetchHistory \(instrument, privacy: .public) deep: \(socketBars.count) socket + \(bulkBars.count) bulk = \(combined.count)")
            return combined
        }
    }

    /// Deep history from the bulk server (the part older than the socket's warm window).
    /// Returns [] when no history URL was parsed or the period isn't a basic downloadable
    /// one (1m/1H/Daily) — non-basic periods are built from those by the caller.
    private func fetchBulkHistory(
        instrument: String, side: OfferSide, period: CandlePeriod, fromMs: Int64, toMs: Int64
    ) async -> [CandleBar] {
        guard let historyServerURL else { return [] }
        let pip = InstrumentPipValue.pipValue(for: instrument)
        do {
            return try await bulkClient.fetchCandles(
                instrument: instrument, side: side, period: period,
                fromMs: fromMs, toMs: toMs, historyServerURL: historyServerURL, pipValue: pip
            )
        } catch {
            log.error("bulk history failed for \(instrument, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
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
        log.info("fetchHistory \(instrument, privacy: .public)/\(side.rawValue, privacy: .public) period=\(period.seconds)s window=[\(startSeconds),\(endSeconds)] req=\(reqId, privacy: .public)")

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
            log.info("fetchHistory req=\(reqId, privacy: .public) done: \(bars.count) bars from \(pending.maxOrder + 1) chunk(s)")
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
        log.error("fetchHistory req=\(reqId, privacy: .public) idle-timed-out (no data)")
        pendingHistory[reqId] = nil
        cont.resume(throwing: SessionError.timedOut("history request (no data received)"))
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
            var peek = BinaryReader(frame)
            let cid = (try? peek.readInt32BE()) ?? 0
            log.debug("reader: frame classId=\(cid) bytes=\(frame.count)")
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
            log.error("server error: reason=\(e.reason ?? "-", privacy: .public) fatal=\(e.fatal == true)")
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
