import ArgumentParser
import DukascopyClient
import Foundation

@main
struct DukascopyCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dukascopy-cli",
        abstract: "Dukascopy native protocol prototyping CLI.",
        subcommands: [JNLPCommand.self, AuthCommand.self, ConnectTestCommand.self, StreamCommand.self]
    )
}

struct JNLPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jnlp",
        abstract: "Fetch and parse the JNLP config for a Dukascopy environment."
    )

    @Option(name: .long, help: "Target environment: demo or live")
    var env: String = "demo"

    @Option(name: .long, help: "Override JNLP URL (takes precedence over --env)")
    var url: String?

    func run() async throws {
        let jnlpURL: URL
        if let raw = url, let parsed = URL(string: raw) {
            jnlpURL = parsed
        } else {
            guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
                throw ValidationError("env must be 'demo' or 'live'")
            }
            jnlpURL = target.jnlpURL
        }

        let config = try await JNLPClient.fetch(from: jnlpURL)
        print("Source:  \(jnlpURL.absoluteString)")
        print("Mode:    \(config.clientMode.rawValue)")
        print("SRP6 servers (\(config.srp6LoginURLs.count)):")
        for url in config.srp6LoginURLs { print("  \(url.absoluteString)") }
        if !config.legacyLoginURLs.isEmpty {
            print("Legacy servers (\(config.legacyLoginURLs.count)):")
            for url in config.legacyLoginURLs { print("  \(url.absoluteString)") }
        }
    }
}

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Run the full SRP6 handshake against an environment and print the result."
    )

    @Option(name: .long, help: "Target environment: demo or live")
    var env: String = "demo"

    @Option(name: .long, help: "Dukascopy login (account number / username)")
    var user: String

    @Option(name: .long, help: "Password")
    var pass: String

    @Option(name: .long, help: "Override the SRP6 base URL (skip JNLP lookup)")
    var url: String?

    @Flag(name: .long, help: "Skip requesting the occasus settings blob")
    var noSettings: Bool = false

    func run() async throws {
        let srp6URLs: [URL]
        if let raw = url, let u = URL(string: raw) {
            srp6URLs = [u]
        } else {
            guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
                throw ValidationError("env must be 'demo' or 'live'")
            }
            let config = try await JNLPClient.fetch(from: target.jnlpURL)
            guard !config.srp6LoginURLs.isEmpty else {
                throw ValidationError("JNLP returned no SRP6 servers")
            }
            srp6URLs = config.srp6LoginURLs
        }

        let creds = AuthCredentials(login: user, password: pass)
        let client = AuthClient(requestSettings: !noSettings)

        var lastError: Error?
        for serverURL in srp6URLs {
            do {
                print("Trying \(serverURL.absoluteString) …")
                let result = try await client.authenticate(baseURL: serverURL, credentials: creds)
                printSuccess(result)
                return
            } catch {
                FileHandle.standardError.write(Data("  failed: \(error)\n".utf8))
                lastError = error
                continue
            }
        }
        throw lastError ?? ValidationError("authentication failed against all SRP6 servers")
    }

    private func printSuccess(_ r: AuthSuccess) {
        print("")
        print("Authenticated.")
        print("authApiURLs (\(r.authApiURLs.count)):")
        for u in r.authApiURLs { print("  \(u)") }
        print("ticket:      \(r.ticket)")
        print("packed:      \(r.packedTicket)")
        if let blob = r.settingsBlob {
            print("settings:    \(blob.count) bytes (parsing deferred)")
        }
    }
}

struct ConnectTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect-test",
        abstract: "Authenticate, open a TLS connection to the first API server, and negotiate the transport version."
    )

    @Option(name: .long, help: "Target environment: demo or live")
    var env: String = "demo"

    @Option(name: .long, help: "Login (account number / username)")
    var user: String

    @Option(name: .long, help: "Password")
    var pass: String

    @Option(name: .long, help: "Connect timeout in seconds")
    var timeout: Double = 15

    func run() async throws {
        guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
            throw ValidationError("env must be 'demo' or 'live'")
        }
        let jnlp = try await JNLPClient.fetch(from: target.jnlpURL)
        guard let serverURL = jnlp.srp6LoginURLs.first else {
            throw ValidationError("JNLP returned no SRP6 servers")
        }

        print("auth:    \(serverURL.absoluteString)")
        let auth = try await AuthClient().authenticate(
            baseURL: serverURL,
            credentials: AuthCredentials(login: user, password: pass)
        )
        guard let first = auth.authApiURLs.first,
              let address = ServerAddress.parse(first) else {
            throw ValidationError("no usable authApiURL")
        }
        print("api:     \(address)")
        print("ticket:  \(auth.ticket)")

        let transport = Transport(address: address)
        try await transport.connect(timeout: timeout)
        let version = await transport.negotiatedVersion ?? -1
        print("version: \(version) negotiated.")

        let handshake = try await transport.handshake(
            login: user,
            ticket: auth.ticket,
            authSessionId: auth.authSessionId
        )
        print("session: \(handshake.transportSessionId)")
        if let challenge = handshake.challenge {
            print("challenge: \(challenge)")
        }
        print("LOGIN: ok.")

        await transport.close()
    }
}

struct StreamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stream",
        abstract: "Stream live ticks for the given instruments (Ctrl-C to stop)."
    )

    @Option(name: .long, help: "Target environment: demo or live")
    var env: String = "demo"

    @Option(name: .long, help: "Login (account number / username)")
    var user: String

    @Option(name: .long, help: "Password")
    var pass: String

    @Argument(help: "Comma-separated instruments in BASE/QUOTE form, e.g. EUR/USD,GBP/USD")
    var instruments: String

    func run() async throws {
        guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
            throw ValidationError("env must be 'demo' or 'live'")
        }
        let jnlp = try await JNLPClient.fetch(from: target.jnlpURL)
        guard let serverURL = jnlp.srp6LoginURLs.first else {
            throw ValidationError("JNLP returned no SRP6 servers")
        }

        let auth = try await AuthClient().authenticate(
            baseURL: serverURL,
            credentials: AuthCredentials(login: user, password: pass)
        )
        guard let first = auth.authApiURLs.first,
              let address = ServerAddress.parse(first) else {
            throw ValidationError("no usable authApiURL")
        }
        print("connecting to \(address) …")

        let transport = Transport(address: address)
        try await transport.connect()
        _ = try await transport.handshake(
            login: user, ticket: auth.ticket, authSessionId: auth.authSessionId
        )
        print("logged in.")

        var initReq = InitRequest()
        initReq.sendGroups = true
        initReq.sendPacked = true
        initReq.sendSettlementPrices = true
        initReq.requestId = UUID().uuidString
        initReq.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        try await transport.sendFrame(initReq.encode())

        let pairs = instruments.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var sub = QuoteSubscribeRequest(instruments: Set(pairs))
        sub.requestId = UUID().uuidString
        sub.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        try await transport.sendFrame(sub.encode())
        print("subscribed: \(pairs.joined(separator: ", "))")
        print("waiting for ticks …")

        while !Task.isCancelled {
            let frame = try await transport.receiveFrame()
            let msg = try MessageDecoder.decode(frame)
            switch msg {
            case .currencyMarket(let m):
                let bid = m.bestBid?.description ?? "—"
                let ask = m.bestAsk?.description ?? "—"
                let ts = Date(timeIntervalSince1970: Double(m.creationTimestampMillis) / 1000)
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss.SSS"
                f.timeZone = .current
                print("\(f.string(from: ts)) \(m.instrument)  bid=\(bid)  ask=\(ask)")
            case .heartbeatRequest(let h):
                let resp = HeartbeatOkResponse(
                    requestTime: h.requestTime ?? 0,
                    receiveTime: Int64(Date().timeIntervalSince1970 * 1000)
                )
                try await transport.sendFrame(resp.encode())
            case .error(let e):
                FileHandle.standardError.write(Data("server error: \(e)\n".utf8))
                return
            case .ok, .halo:
                break
            case .unknown(let classId, let body):
                if ProcessInfo.processInfo.environment["DUKASCOPY_CLI_VERBOSE"] != nil {
                    FileHandle.standardError.write(Data(
                        "unknown classId=\(classId) bytes=\(body.count)\n".utf8
                    ))
                }
            }
        }
        await transport.close()
    }
}
