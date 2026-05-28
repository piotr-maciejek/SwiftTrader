import Foundation

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

    public enum SessionError: Error, CustomStringConvertible {
        case noSRP6Servers
        case noUsableAPIServer
        case authFailed(String)
        case notConnected

        public var description: String {
            switch self {
            case .noSRP6Servers: "JNLP returned no SRP6 servers"
            case .noUsableAPIServer: "auth returned no usable API server"
            case .authFailed(let s): "authentication failed: \(s)"
            case .notConnected: "session is not connected"
            }
        }
    }

    public private(set) var state: State = .disconnected

    private let environment: DukascopyEnvironment
    private let credentials: AuthCredentials
    private let authClient: AuthClient

    private var transport: Transport?
    private var authSessionId: String?
    private var readerTask: Task<Void, Never>?

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
            self.state = .connected
            startReader(transport: transport)
        } catch {
            state = .failed(String(describing: error))
            await teardown()
            throw error
        }
    }

    public func close() async {
        await teardown()
        state = .disconnected
    }

    // MARK: - Reader loop

    private func startReader(transport: Transport) {
        readerTask = Task { [weak self] in
            await self?.readLoop(transport: transport)
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
            guard let msg = try? MessageDecoder.decode(frame) else { continue }
            await dispatch(msg, transport: transport)
        }
    }

    private func dispatch(_ msg: InboundMessage, transport: Transport) async {
        switch msg {
        case .heartbeatRequest(let h):
            let resp = HeartbeatOkResponse(
                requestTime: h.requestTime ?? 0,
                receiveTime: Int64(Date().timeIntervalSince1970 * 1000)
            )
            try? await transport.sendFrame(resp.encode())
        case .error(let e):
            await markFailed("server error: \(e)")
        default:
            // History / market / account routing layers onto dispatch in later slices.
            break
        }
    }

    private func markFailed(_ reason: String) async {
        state = .failed(reason)
        await teardown()
    }

    private func teardown() async {
        readerTask?.cancel()
        readerTask = nil
        if let transport { await transport.close() }
        transport = nil
    }
}
