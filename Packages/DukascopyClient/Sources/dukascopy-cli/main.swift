import ArgumentParser
import DukascopyClient
import Foundation
import SWCompression

@main
struct DukascopyCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dukascopy-cli",
        abstract: "Dukascopy native protocol prototyping CLI.",
        subcommands: [JNLPCommand.self, AuthCommand.self, ConnectTestCommand.self, StreamCommand.self, AccountCommand.self, HistoryCommand.self, SessionCommand.self, BulkSpikeCommand.self]
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
            case .ok, .halo, .packedAccountInfo, .candleHistoryGroup:
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

struct AccountCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "account",
        abstract: "Authenticate, connect, and print the account snapshot."
    )

    @Option(name: .long, help: "Target environment: demo or live")
    var env: String = "demo"

    @Option(name: .long, help: "Login")
    var user: String

    @Option(name: .long, help: "Password")
    var pass: String

    @Option(name: .long, help: "Snapshot wait timeout in seconds")
    var timeout: Double = 15

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
        let transport = Transport(address: address)
        try await transport.connect()
        _ = try await transport.handshake(
            login: user, ticket: auth.ticket, authSessionId: auth.authSessionId
        )

        var initReq = InitRequest()
        initReq.requestId = UUID().uuidString
        initReq.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        try await transport.sendFrame(initReq.encode())

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frame = try await transport.receiveFrame()
            // Peek at the classId before dispatching so we can hex-dump the
            // PackedAccountInfo frame for debugging if decode fails.
            var peek = BinaryReader(frame)
            let classId = try peek.readInt32BE()
            _ = classId
            let msg = try MessageDecoder.decode(frame)
            switch msg {
            case .packedAccountInfo(let p):
                printAccount(p.account)
                await transport.close()
                return
            case .heartbeatRequest(let h):
                let resp = HeartbeatOkResponse(
                    requestTime: h.requestTime ?? 0,
                    receiveTime: Int64(Date().timeIntervalSince1970 * 1000)
                )
                try await transport.sendFrame(resp.encode())
            case .error(let e):
                throw ValidationError("server error: \(e)")
            default:
                continue
            }
        }
        throw ValidationError("no account snapshot within \(timeout)s")
    }

    private func printAccount(_ a: AccountInfo) {
        print("login:        \(a.accountLoginId ?? "-")")
        print("currency:     \(a.currency ?? "-")")
        print("balance:      \(a.balance?.description ?? "-")")
        print("equity:       \(a.equity?.description ?? "-")")
        print("usableMargin: \(a.usableMargin?.description ?? "-")")
        if let used = a.usedMargin {
            print("usedMargin:   \(used.description)  (equity − usableMargin)")
        }
        print("leverage:     \(a.leverage.map(String.init) ?? "-")")
        print("state:        \(a.state ?? "-")")
    }
}

struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Fetch historical bars and print them."
    )

    @Option(name: .long, help: "Target environment: demo or live")
    var env: String = "demo"

    @Option(name: .long, help: "Login")
    var user: String

    @Option(name: .long, help: "Password")
    var pass: String

    @Argument(help: "Instrument in BASE/QUOTE form, e.g. EUR/USD")
    var instrument: String

    @Argument(help: "Period: ONE_MIN, FIVE_MINS, FIFTEEN_MINS, ONE_HOUR, FOUR_HOURS, DAILY, …")
    var period: String

    @Option(name: .long, help: "Number of bars to fetch (going backwards from now)")
    var count: Int = 100

    @Option(name: .long, help: "Bid or Ask side")
    var side: String = "Bid"

    @Option(name: .long, help: "End the window before this epoch-ms (test older windows)")
    var before: Int64?

    func run() async throws {
        guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
            throw ValidationError("env must be 'demo' or 'live'")
        }
        guard let cp = CandlePeriod.parse(period) else {
            throw ValidationError("unknown period \(period)")
        }
        guard let offerSide = OfferSide(rawValue: side.capitalized) else {
            throw ValidationError("side must be Bid or Ask")
        }

        // Drives the same DukascopySession the app uses, so this exercises the real path:
        // keepalive, clamp-to-cache retry, and per-request error routing.
        let session = DukascopySession(
            environment: target,
            credentials: AuthCredentials(login: user, password: pass)
        )
        try await session.connect()

        let endSec = before.map { $0 / 1000 } ?? Int64(Date().timeIntervalSince1970)
        let startSec = endSec - cp.seconds * Int64(count)
        let bars = try await session.fetchHistory(
            instrument: instrument, side: offerSide, period: cp,
            startSeconds: startSec, endSeconds: endSec
        )
        await session.close()

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        for bar in bars.suffix(count) {
            let ts = Date(timeIntervalSince1970: Double(bar.timeMillis) / 1000)
            print(String(format: "%@  o=%.5f h=%.5f l=%.5f c=%.5f v=%.0f",
                         f.string(from: ts), bar.open, bar.high, bar.low, bar.close, bar.volume))
        }
        print("\(bars.count) bars total.")
    }
}

struct SessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Connect via DukascopySession, hold the socket open, and print state transitions."
    )

    @Option(name: .long, help: "Target environment: demo or live")
    var env: String = "demo"

    @Option(name: .long, help: "Login")
    var user: String

    @Option(name: .long, help: "Password")
    var pass: String

    @Option(name: .long, help: "Seconds to hold the connection open")
    var seconds: Double = 8

    func run() async throws {
        guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
            throw ValidationError("env must be 'demo' or 'live'")
        }
        let session = DukascopySession(
            environment: target,
            credentials: AuthCredentials(login: user, password: pass)
        )
        print("connecting …")
        try await session.connect()
        print("state: \(await session.state)")
        print("holding for \(seconds)s (answering heartbeats) …")
        try await Task.sleep(for: .seconds(seconds))
        print("state: \(await session.state)")
        await session.close()
        print("closed. state: \(await session.state)")
    }
}

/// Spike for the deep-history (.bi5) phase: authenticate, parse the settings blob to find
/// `history.server.url`, download ONE per-period candle chunk file, LZMA-decode it, and
/// decode the 24-byte candle records — printing enough to sanity-check the whole pipeline
/// before building the real client.
struct BulkSpikeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bulk-spike",
        abstract: "Fetch + decode one candle .bi5 chunk from the history server (deep-history spike)."
    )

    @Option(name: .long, help: "Target environment: demo or live")
    var env: String = "demo"

    @Option(name: .long, help: "Login")
    var user: String

    @Option(name: .long, help: "Password")
    var pass: String

    @Option(name: .long, help: "Instrument, slashless (e.g. EURUSD)")
    var instrument: String = "EURUSD"

    @Option(name: .long, help: "Period token: min_15, min_5, min_30, hour_1")
    var period: String = "min_15"

    @Option(name: .long, help: "Calendar year of the chunk")
    var year: Int = 2026

    @Option(name: .long, help: "Calendar month 1-12 (converted to 0-based in the URL)")
    var month: Int = 4

    @Option(name: .long, help: "pipValue for price scaling (EURUSD 0.0001, USDJPY 0.01)")
    var pip: Double = 0.0001

    @Option(name: .long, help: "Dump the raw settings blob to this path")
    var dumpBlob: String?

    func run() async throws {
        guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
            throw ValidationError("env must be 'demo' or 'live'")
        }
        let jnlp = try await JNLPClient.fetch(from: target.jnlpURL)
        guard let serverURL = jnlp.srp6LoginURLs.first else {
            throw ValidationError("JNLP returned no SRP6 servers")
        }
        let auth = try await AuthClient().authenticate(
            baseURL: serverURL, credentials: AuthCredentials(login: user, password: pass)
        )
        guard let blob = auth.settingsBlob else { throw ValidationError("no settings blob in auth response") }
        print("settings blob: \(blob.count) bytes")
        if let dumpBlob { try blob.write(to: URL(fileURLWithPath: dumpBlob)); print("blob written to \(dumpBlob)") }

        let props = try JavaPropertiesParser.parse(blob)
        print("parsed \(props.count) properties")
        guard let historyURL = props["history.server.url"] else {
            print("keys: \(props.keys.sorted().joined(separator: ", "))")
            throw ValidationError("history.server.url not found in settings blob")
        }
        print("history.server.url = \(historyURL)")

        // Build the chunk URL: <history>/INSTR/YYYY/MM(0-based,padded)/BID_candles_<period>.bi5
        let base = historyURL.hasSuffix("/") ? String(historyURL.dropLast()) : historyURL
        let mm0 = String(format: "%02d", month - 1)
        let relative = "\(instrument)/\(year)/\(mm0)/BID_candles_\(period).bi5"
        let urlString = "\(base)/\(relative)"
        print("GET \(urlString)")
        guard let url = URL(string: urlString) else { throw ValidationError("bad URL") }

        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("HTTP \(status), \(data.count) compressed bytes")
        guard status == 200, !data.isEmpty else { throw ValidationError("no data (status \(status))") }
        print("first 13 bytes: \(data.prefix(13).map { String(format: "%02x", $0) }.joined(separator: " "))")

        let decompressed = try LZMA.decompress(data: data)
        print("decompressed \(decompressed.count) bytes, %24 = \(decompressed.count % 24)")
        guard decompressed.count % 24 == 0 else { throw ValidationError("not a multiple of 24 — wrong format") }

        // chunk start = first day of the GMT month
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        let comps = DateComponents(year: year, month: month, day: 1, hour: 0, minute: 0, second: 0)
        let chunkStartMs = Int64(cal.date(from: comps)!.timeIntervalSince1970 * 1000)

        let bars = Self.decodeCandles(decompressed, chunkStartMs: chunkStartMs, pipValue: pip)
        print("\(bars.count) candles decoded")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "GMT")
        for bar in bars.prefix(3) + bars.suffix(3) {
            let ts = Date(timeIntervalSince1970: Double(bar.timeMillis) / 1000)
            print(String(format: "%@  o=%.5f h=%.5f l=%.5f c=%.5f v=%.1f",
                         f.string(from: ts), bar.open, bar.high, bar.low, bar.close, bar.volume))
        }
    }

    /// Decodes v5 candle records (24 bytes, big-endian): int32 secOffset, int32 open,
    /// int32 close, int32 low, int32 high, float32 volume. Price = round(raw/10*pip, 5dp).
    static func decodeCandles(_ data: Data, chunkStartMs: Int64, pipValue: Double) -> [CandleBar] {
        var reader = BinaryReader(data)
        var bars: [CandleBar] = []
        let count = data.count / 24
        bars.reserveCapacity(count)
        func price(_ raw: Int32) -> Double {
            Double(Int64(Double(raw) / 10.0 * pipValue * 100000.0 + 0.5)) / 100000.0
        }
        for _ in 0..<count {
            guard let secOffset = try? reader.readInt32BE(),
                  let open = try? reader.readInt32BE(),
                  let close = try? reader.readInt32BE(),
                  let low = try? reader.readInt32BE(),
                  let high = try? reader.readInt32BE(),
                  let volBits = try? reader.readInt32BE() else { break }
            let vol = Double(Float(bitPattern: UInt32(bitPattern: volBits)))
            bars.append(CandleBar(
                timeMillis: chunkStartMs + Int64(secOffset) * 1000,
                open: price(open), high: price(high), low: price(low), close: price(close),
                volume: vol
            ))
        }
        return bars
    }
}
