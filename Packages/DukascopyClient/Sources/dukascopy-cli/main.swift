import ArgumentParser
import DukascopyClient
import Foundation
import SWCompression

@main
struct DukascopyCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dukascopy-cli",
        abstract: "Dukascopy native protocol prototyping CLI.",
        subcommands: [JNLPCommand.self, AuthCommand.self, LoginInfoCommand.self, CaptchaCommand.self, ConnectTestCommand.self, StreamCommand.self, AccountCommand.self, HistoryCommand.self, SessionCommand.self, BulkSpikeCommand.self, PositionsCommand.self, SubmitCommand.self, CloseCommand.self, CancelCommand.self, ModifyCommand.self, NewsCommand.self, ClosedTradesCommand.self, HashOfCommand.self]
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

    @Option(name: .long, help: "Captcha PIN. Forces the dual-SRP6 PIN flow. A wrong PIN (e.g. 0000) is a safe, non-consuming end-to-end probe of the wire path.")
    var pin: String?

    @Option(name: .long, help: "Captcha id from a prior `captcha` fetch (use the SAME --url). If omitted while --pin is set, a fresh captcha is fetched here.")
    var captchaId: String?

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

        // PIN flow: the captcha id is bound to the server that issued it, so the whole
        // dual-session must run against ONE base URL. Fetch a fresh captcha here unless
        // the caller supplied an id from a prior `captcha` fetch on the same --url.
        if let pin {
            let base = srp6URLs[0]
            let resolvedCaptchaId: String
            if let captchaId {
                resolvedCaptchaId = captchaId
            } else {
                print("Fetching captcha from \(base.absoluteString) …")
                let challenge = try await client.fetchCaptcha(baseURL: base)
                let out = "/tmp/dukascopy-captcha.png"
                try? challenge.captcha.write(to: URL(fileURLWithPath: out))
                print("  captchaId: \(challenge.captchaId)")
                print("  saved image: \(out) (\(challenge.captcha.count) bytes)")
                resolvedCaptchaId = challenge.captchaId
            }
            do {
                let result = try await client.authenticate(
                    baseURL: base, credentials: creds, captchaId: resolvedCaptchaId, pin: pin
                )
                print("\nPIN auth SUCCEEDED.")
                printSuccess(result)
            } catch AuthError.badPin {
                print("\nPIN auth reached the server cleanly but the PIN was REJECTED "
                    + "(M2_C mismatch). This is the expected result for a wrong PIN — it "
                    + "PROVES the dual-SRP6 wire path (verbum_id / pin_ params / _C / M2_C) "
                    + "is correct.")
            }
            return
        }

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

/// Non-consuming pre-check: does this account currently need a captcha PIN from
/// this IP? Safe to run repeatedly — it does not authenticate.
struct LoginInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login-info",
        abstract: "Check whether an account needs a captcha PIN (munus=login_info)."
    )

    @Option(name: .long, help: "Target environment: demo or live")
    var env: String = "demo"

    @Option(name: .long, help: "Dukascopy login (account number / username)")
    var user: String

    @Option(name: .long, help: "Override the SRP6 base URL (skip JNLP lookup)")
    var url: String?

    func run() async throws {
        let base = try await resolveFirstSRP6URL(env: env, urlOverride: url)
        let info = try await AuthClient().checkIfPinRequired(baseURL: base, login: user)
        print("checkPin:    \(info.checkPin)")
        print("wlPartnerId: \(info.wlPartnerId.map(String.init) ?? "—")")
        if !info.checkPin {
            print("\nNo PIN required right now (IP whitelisted or already trusted today).")
        } else {
            print("\nPIN required — fetch a captcha and run `auth --pin …`.")
        }
    }
}

/// Fetch one captcha image + its id. Non-consuming. Pairs with `auth --pin --captcha-id`
/// for the correct-PIN two-step (view the saved image, then submit the digits you read).
struct CaptchaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "captcha",
        abstract: "Fetch a captcha PNG and print its X-CaptchaID."
    )

    @Option(name: .long, help: "Target environment: demo or live")
    var env: String = "demo"

    @Option(name: .long, help: "Override the SRP6 base URL (skip JNLP lookup)")
    var url: String?

    @Option(name: .long, help: "Where to save the PNG")
    var out: String = "/tmp/dukascopy-captcha.png"

    func run() async throws {
        let base = try await resolveFirstSRP6URL(env: env, urlOverride: url)
        let challenge = try await AuthClient().fetchCaptcha(baseURL: base)
        try challenge.captcha.write(to: URL(fileURLWithPath: out))
        print("captchaId: \(challenge.captchaId)")
        print("saved:     \(out) (\(challenge.captcha.count) bytes)")
        print("base URL:  \(base.absoluteString)")
        print("\nNext: open the image, then run")
        print("  dukascopy-cli auth --env \(env) --user <login> --pass <pwd> \\")
        print("    --url \(base.absoluteString) --captcha-id \(challenge.captchaId) --pin <digits>")
    }
}

/// Resolve the first SRP6 login URL for an environment, or use an explicit override.
private func resolveFirstSRP6URL(env: String, urlOverride: String?) async throws -> URL {
    if let raw = urlOverride, let u = URL(string: raw) { return u }
    guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
        throw ValidationError("env must be 'demo' or 'live'")
    }
    let config = try await JNLPClient.fetch(from: target.jnlpURL)
    guard let first = config.srp6LoginURLs.first else {
        throw ValidationError("JNLP returned no SRP6 servers")
    }
    return first
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
            case .ok, .halo, .packedAccountInfo, .candleHistoryGroup, .orderGroup, .order, .orderResponse,
                 .calendarEvent, .newsStory, .positionBinaryResponse:
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
        print("userId:       \(a.userId ?? "-")")
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

private func printGroup(_ g: OrderGroup) {
    print("  position \(g.orderGroupId ?? "-")  \(g.instrument ?? "-")  \(g.side ?? "-")  \(g.status ?? "-")  amount=\(g.amount?.description ?? "-")  open=\(g.pricePosOpen?.description ?? "-")  pl@=\(g.pricePl?.description ?? "-")")
    for o in g.orders {
        print("    order \(o.orderId ?? "-")  \(o.state ?? "-")  SL=\(o.priceStop?.description ?? "-")  TP=\(o.priceLimit?.description ?? "-")")
    }
}

private func printOrderEvent(_ ev: OrderEvent) {
    switch ev {
    case .response(let r):
        print("  «response» state=\(r.state ?? "-")  orderId=\(r.orderId ?? "-")  positionId=\(r.positionId ?? "-")  side=\(r.side ?? "-")  price=\(r.price?.description ?? "-")  reqId=\(r.requestId ?? "(none echoed)")  rejected=\(r.isRejected)")
    case .group(let g):
        print("  «group» \(g.orderGroupId ?? "-")  \(g.instrument ?? "-")  \(g.status ?? "-")  open=\(g.pricePosOpen?.description ?? "-")")
    case .order(let o):
        print("  «order» \(o.orderId ?? "-")  \(o.state ?? "-")  group=\(o.orderGroupId ?? "-")")
    }
}

struct HashOfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hashof", abstract: "Print javaStringHashCode of a string.")
    @Argument(help: "string to hash") var value: String
    func run() { print(javaStringHashCode(value)) }
}

struct PositionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "positions",
        abstract: "Connect and list open positions."
    )
    @Option(name: .long, help: "Target environment: demo or live") var env: String = "demo"
    @Option(name: .long, help: "Login") var user: String
    @Option(name: .long, help: "Password") var pass: String

    func run() async throws {
        guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
            throw ValidationError("env must be 'demo' or 'live'")
        }
        let session = DukascopySession(
            environment: target, credentials: AuthCredentials(login: user, password: pass)
        )
        try await session.connect()
        _ = try? await session.accountSnapshot()
        try? await Task.sleep(for: .seconds(1))   // let any groups arrive
        let positions = await session.positionsSnapshot()
        print(positions.isEmpty ? "(no open positions)" : "open positions:")
        for g in positions { printGroup(g) }
        await session.close()
    }
}

struct SubmitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submit",
        abstract: "Submit a MARKET order on the demo account and watch the server response."
    )
    @Option(name: .long, help: "Target environment: demo or live") var env: String = "demo"
    @Option(name: .long, help: "Login") var user: String
    @Option(name: .long, help: "Password") var pass: String
    @Argument(help: "Instrument in BASE/QUOTE form, e.g. EUR/USD") var instrument: String
    @Argument(help: "BUY or SELL") var side: String
    @Option(name: .long, help: "Amount in UNITS (e.g. 1000 = micro lot)") var amount: Double = 1000
    @Option(name: .long, help: "Order type: market, limit, or stop") var type: String = "market"
    @Option(name: .long, help: "Trigger price (required for limit/stop)") var price: Double?
    @Option(name: .long, help: "Stop-loss price (optional)") var sl: Double?
    @Option(name: .long, help: "Take-profit price (optional)") var tp: Double?
    @Option(name: .long, help: "Order label") var label: String = "CLI"
    @Option(name: .long, help: "Seconds to watch order events after submit") var observe: Double = 8

    func run() async throws {
        guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
            throw ValidationError("env must be 'demo' or 'live'")
        }
        let sideUpper = side.uppercased()
        guard sideUpper == "BUY" || sideUpper == "SELL" else {
            throw ValidationError("side must be BUY or SELL")
        }
        let session = DukascopySession(
            environment: target, credentials: AuthCredentials(login: user, password: pass)
        )
        try await session.connect()
        _ = try? await session.accountSnapshot()

        let kindStr = type.lowercased()
        guard ["market", "limit", "stop"].contains(kindStr) else {
            throw ValidationError("type must be market, limit, or stop")
        }
        if kindStr != "market" && price == nil {
            throw ValidationError("--price (trigger) is required for limit/stop")
        }

        let events = await session.orderEvents()
        let printer = Task { for await ev in events { printOrderEvent(ev) } }
        let amt = BigDecimalValue(amount, scale: 5)
        let slv = sl.map { BigDecimalValue($0, scale: 5) }
        let tpv = tp.map { BigDecimalValue($0, scale: 5) }
        let slStr: String = sl != nil ? String(sl!) : "-"
        let tpStr: String = tp != nil ? String(tp!) : "-"

        do {
            let reqId: String
            switch kindStr {
            case "market":
                print("submitting MARKET \(sideUpper) \(instrument) amount=\(amount) sl=\(slStr) tp=\(tpStr) label=\(label) …")
                reqId = try await session.submitMarketOrder(
                    instrument: instrument, side: sideUpper, amount: amt,
                    stopLoss: slv, takeProfit: tpv, label: label
                )
            default:
                let kind: PendingKind = kindStr == "limit" ? .limit : .stop
                let trigStr = String(price!)
                print("submitting \(kindStr.uppercased()) \(sideUpper) \(instrument) amount=\(amount) trigger=\(trigStr) sl=\(slStr) tp=\(tpStr) label=\(label) …")
                reqId = try await session.submitPendingOrder(
                    instrument: instrument, side: sideUpper, kind: kind, amount: amt,
                    triggerPrice: BigDecimalValue(price!, scale: 5),
                    stopLoss: slv, takeProfit: tpv, label: label
                )
            }
            print("SUBMIT SENT: reqId=\(reqId) — watching for \(Int(observe))s …")
        } catch {
            print("SUBMIT FAILED: \(error)")
        }
        try? await Task.sleep(for: .seconds(observe))
        printer.cancel()
        print("--- positions after ---")
        for g in await session.positionsSnapshot() { printGroup(g) }
        await session.close()
    }
}

struct CloseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a position by its positionId (from `positions`)."
    )
    @Option(name: .long, help: "Target environment: demo or live") var env: String = "demo"
    @Option(name: .long, help: "Login") var user: String
    @Option(name: .long, help: "Password") var pass: String
    @Argument(help: "positionId / orderGroupId to close") var positionId: String
    @Option(name: .long, help: "Seconds to watch order events after close") var observe: Double = 8

    func run() async throws {
        guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
            throw ValidationError("env must be 'demo' or 'live'")
        }
        let session = DukascopySession(
            environment: target, credentials: AuthCredentials(login: user, password: pass)
        )
        try await session.connect()
        _ = try? await session.accountSnapshot()

        let events = await session.orderEvents()
        let printer = Task { for await ev in events { printOrderEvent(ev) } }

        print("closing position \(positionId) …")
        do {
            let reqId = try await session.closePosition(positionId: positionId)
            print("CLOSE SENT: reqId=\(reqId) — watching for \(Int(observe))s …")
        } catch {
            print("CLOSE FAILED: \(error)")
        }
        try? await Task.sleep(for: .seconds(observe))
        printer.cancel()
        print("--- positions after ---")
        for g in await session.positionsSnapshot() { printGroup(g) }
        await session.close()
    }
}

struct CancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Cancel a pending order by its orderId (from `positions`)."
    )
    @Option(name: .long, help: "Target environment: demo or live") var env: String = "demo"
    @Option(name: .long, help: "Login") var user: String
    @Option(name: .long, help: "Password") var pass: String
    @Argument(help: "orderId to cancel") var orderId: String
    @Option(name: .long, help: "Seconds to watch order events after cancel") var observe: Double = 8

    func run() async throws {
        guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
            throw ValidationError("env must be 'demo' or 'live'")
        }
        let session = DukascopySession(
            environment: target, credentials: AuthCredentials(login: user, password: pass)
        )
        try await session.connect()
        _ = try? await session.accountSnapshot()
        try? await Task.sleep(for: .seconds(1))   // let position groups arrive

        let events = await session.orderEvents()
        let printer = Task { for await ev in events { printOrderEvent(ev) } }
        print("cancelling order \(orderId) …")
        do {
            let reqId = try await session.cancelOrder(orderId: orderId)
            print("CANCEL SENT: reqId=\(reqId) — watching for \(Int(observe))s …")
        } catch {
            print("CANCEL FAILED: \(error)")
        }
        try? await Task.sleep(for: .seconds(observe))
        printer.cancel()
        print("--- positions after ---")
        for g in await session.positionsSnapshot() { printGroup(g) }
        await session.close()
    }
}

struct ModifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "modify",
        abstract: "Modify/add/remove SL and/or TP on a position or pending group (by orderGroupId)."
    )
    @Option(name: .long, help: "Target environment: demo or live") var env: String = "demo"
    @Option(name: .long, help: "Login") var user: String
    @Option(name: .long, help: "Password") var pass: String
    @Argument(help: "orderGroupId of the position/pending group (from `positions`)") var orderGroupId: String
    @Option(name: .long, help: "New stop-loss price (0 to remove the SL)") var sl: Double?
    @Option(name: .long, help: "New take-profit price (0 to remove the TP)") var tp: Double?
    @Option(name: .long, help: "Seconds to watch order events after modify") var observe: Double = 8

    func run() async throws {
        guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
            throw ValidationError("env must be 'demo' or 'live'")
        }
        if sl == nil && tp == nil { throw ValidationError("provide --sl and/or --tp") }
        let session = DukascopySession(
            environment: target, credentials: AuthCredentials(login: user, password: pass)
        )
        try await session.connect()
        _ = try? await session.accountSnapshot()
        try? await Task.sleep(for: .seconds(1))   // let position groups arrive

        guard let group = await session.positionsSnapshot().first(where: { $0.orderGroupId == orderGroupId }) else {
            print("no group with orderGroupId \(orderGroupId)")
            await session.close(); return
        }
        // Classify existing protective CLOSE orders by stopDirection (SL vs TP).
        var slOrderId: String?, tpOrderId: String?
        for o in group.orders where o.direction == "CLOSE" {
            switch o.stopDirection {
            case "LESS_BID", "GREATER_ASK": slOrderId = o.orderId
            case "GREATER_BID", "LESS_ASK": tpOrderId = o.orderId
            default: break
            }
        }
        let inst = group.instrument ?? ""
        let scale = inst.contains("JPY") ? 3 : 5
        print("group \(orderGroupId) \(inst): existing SL=\(slOrderId ?? "-") TP=\(tpOrderId ?? "-")")

        let events = await session.orderEvents()
        let printer = Task { for await ev in events { printOrderEvent(ev) } }

        func apply(_ price: Double?, isTP: Bool, existing: String?) async {
            guard let price else { return }
            let kind = isTP ? "TP" : "SL"
            do {
                if price <= 0 {
                    guard let existing else { print("\(kind): nothing to remove"); return }
                    print("removing \(kind) (order \(existing)) …")
                    let r = try await session.cancelOrder(orderId: existing)
                    print("\(kind) REMOVE SENT: reqId=\(r)")
                } else {
                    print("\(existing == nil ? "adding" : "modifying") \(kind) → \(price) …")
                    let r = try await session.modifyProtectiveOrder(
                        orderGroupId: orderGroupId, isTakeProfit: isTP,
                        newPrice: BigDecimalValue(price, scale: scale), existingProtectiveOrderId: existing)
                    print("\(kind) SENT: reqId=\(r)")
                }
            } catch { print("\(kind) FAILED: \(error)") }
        }
        await apply(sl, isTP: false, existing: slOrderId)
        await apply(tp, isTP: true, existing: tpOrderId)

        try? await Task.sleep(for: .seconds(observe))
        printer.cancel()
        print("--- group after ---")
        for g in await session.positionsSnapshot() where g.orderGroupId == orderGroupId { printGroup(g) }
        await session.close()
    }
}

private func fmtNewsMs(_ ms: Int64) -> String {
    guard ms > 0 else { return "-" }
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
}

struct NewsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "news",
        abstract: "Subscribe to the Dukascopy news/calendar feed and print incoming events."
    )
    @Option(name: .long, help: "Target environment: demo or live") var env: String = "demo"
    @Option(name: .long, help: "Login") var user: String
    @Option(name: .long, help: "Password") var pass: String
    @Option(name: .long, help: "Comma-separated NewsSource names (e.g. DJ_LIVE_CALENDAR,FXSPIDER_NEWS)") var sources: String = "DJ_LIVE_CALENDAR"
    @Option(name: .long, help: "CalendarType (ICC/IEP/IDC) or empty to omit") var calendarType: String = "ICC"
    @Option(name: .long, help: "Window start: days before now") var fromDays: Int = 7
    @Option(name: .long, help: "Window end: days after now") var toDays: Int = 7
    @Option(name: .long, help: "Seconds to watch for events") var observe: Double = 20

    func run() async throws {
        guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
            throw ValidationError("env must be 'demo' or 'live'")
        }
        let session = DukascopySession(
            environment: target, credentials: AuthCredentials(login: user, password: pass)
        )
        try await session.connect()
        _ = try? await session.accountSnapshot()

        let events = await session.newsEvents()
        let printer = Task {
            for await ev in events {
                switch ev {
                case .calendar(let e, let story):
                    let t = e.eventTimestamp ?? e.eventDate ?? story.publishDate ?? 0
                    print("CAL \(fmtNewsMs(t)) \(e.country ?? "-") [\(e.eventCategory ?? "-")] \(e.description ?? story.header ?? "-")")
                    for d in e.details {
                        print("      • \(d.description ?? "") act=\(d.actual ?? "-") exp=\(d.expected ?? "-") prev=\(d.previous ?? "-") imp=\(d.importance ?? "-")")
                    }
                case .story(let s):
                    print("NEWS \(fmtNewsMs(s.publishDate ?? 0)) [hot=\(s.hot)] \(s.header ?? "-")  \(s.currencies.sorted().joined(separator: ","))")
                }
            }
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let from = nowMs - Int64(fromDays) * 86_400_000
        let to = nowMs + Int64(toDays) * 86_400_000
        let srcList = sources.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let ct = calendarType.isEmpty ? nil : calendarType
        print("subscribing sources=\(srcList) calendarType=\(ct ?? "-") from=\(fmtNewsMs(from)) to=\(fmtNewsMs(to)) …")
        do {
            let r = try await session.subscribeNews(sources: srcList, from: from, to: to, calendarType: ct)
            print("SUBSCRIBE SENT: reqId=\(r) — watching for \(Int(observe))s …")
        } catch {
            print("SUBSCRIBE FAILED: \(error)")
        }
        try? await Task.sleep(for: .seconds(observe))
        printer.cancel()
        print("--- done watching ---")
        await session.close()
    }
}

/// GATING probe for native closed-trade history (review issue #1, Stage A). Builds the
/// transport directly (like `account`) so we can dump EVERY inbound frame's classId + head
/// after sending a `PositionDataRequestMessage`. Confirms the desktop server actually
/// answers this on the DDS socket (the `extapi.Submit*` requests are silently ignored — the
/// same risk), reveals the byte[] inner framing for `positionsEncoded`, and saves the gzip
/// blob to a file so it can become the Stage-E decode fixture. No app/library decode of the
/// blob yet — that's Stage B.
struct ClosedTradesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "closed-trades",
        abstract: "PROBE: send PositionDataRequestMessage and dump the server's reply frames."
    )
    @Option(name: .long, help: "Target environment: demo or live") var env: String = "demo"
    @Option(name: .long, help: "Login") var user: String
    @Option(name: .long, help: "Password") var pass: String
    @Option(name: .long, help: "Window start: days before now") var fromDays: Int = 90
    @Option(name: .long, help: "Seconds to watch for response frames") var observe: Double = 15
    @Option(name: .long, help: "Where to save the raw positionsEncoded gzip blob") var out: String = "/tmp/dukascopy-closed-positions.gz"
    @Flag(name: .long, help: "Drive the high-level DukascopySession.fetchClosedPositions path instead of the raw-frame probe") var viaSession: Bool = false

    private func hexHead(_ data: Data, _ n: Int = 32) -> String {
        data.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    func run() async throws {
        guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
            throw ValidationError("env must be 'demo' or 'live'")
        }
        if viaSession { try await runViaSession(target); return }
        let jnlp = try await JNLPClient.fetch(from: target.jnlpURL)
        guard let serverURL = jnlp.srp6LoginURLs.first else {
            throw ValidationError("JNLP returned no SRP6 servers")
        }
        let auth = try await AuthClient().authenticate(
            baseURL: serverURL, credentials: AuthCredentials(login: user, password: pass)
        )
        guard let first = auth.authApiURLs.first, let address = ServerAddress.parse(first) else {
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

        // Wait for the account snapshot so we can populate userId/accountLoginId on the
        // request (the order/news requests carry these — best chance of a real answer).
        var account: AccountInfo?
        let snapDeadline = Date().addingTimeInterval(15)
        while account == nil, Date() < snapDeadline {
            let frame = try await transport.receiveFrame()
            switch try MessageDecoder.decode(frame) {
            case .packedAccountInfo(let p): account = p.account
            case .heartbeatRequest(let h):
                try await transport.sendFrame(HeartbeatOkResponse(
                    requestTime: h.requestTime ?? 0,
                    receiveTime: Int64(Date().timeIntervalSince1970 * 1000)
                ).encode())
            case .error(let e): throw ValidationError("server error before snapshot: \(e)")
            default: continue
            }
        }
        print("account: login=\(account?.accountLoginId ?? "-") userId=\(account?.userId ?? "-")")

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let fromMs = nowMs - Int64(fromDays) * 86_400_000
        let reqId = UUID().uuidString
        let frame = encodePositionDataRequest(
            startMillis: fromMs, endMillis: nowMs, getClosed: true,
            userName: user, sessionId: auth.authSessionId,
            userId: account?.userId, accountLoginId: account?.accountLoginId,
            requestId: reqId, timestamp: nowMs
        )
        print("REQUEST classId=\(javaStringHashCode(WireClass.positionDataRequest)) reqId=\(reqId) bytes=\(frame.count)")
        print("  \(hexHead(frame, 48))")
        try await transport.sendFrame(frame)
        print("sent PositionDataRequestMessage — watching for \(Int(observe))s …\n")

        let posRespId = javaStringHashCode(WireClass.positionBinaryResponse)
        var chunks: [Int32: Data] = [:]
        var finished = false
        var sawAnyResponse = false
        let deadline = Date().addingTimeInterval(observe)
        while Date() < deadline, !finished {
            let frame = try await transport.receiveFrame()
            var peek = BinaryReader(frame)
            let classId = try peek.readInt32BE()
            print("frame classId=\(classId) bytes=\(frame.count) head=[\(hexHead(frame))]")
            if classId == posRespId {
                sawAnyResponse = true
                var r = BinaryReader(frame)
                _ = try r.readInt32BE()
                let resp = try PositionBinaryResponse.decode(from: &r)
                let blobLen = resp.positionsEncoded?.count ?? 0
                print("  → PositionBinaryResponse order=\(resp.messageOrder.map(String.init) ?? "-") "
                    + "finished=\(resp.finished.map(String.init) ?? "-") reqId=\(resp.requestId ?? "-") "
                    + "blob=\(blobLen) bytes")
                if let blob = resp.positionsEncoded, !blob.isEmpty {
                    print("    blob head: \(hexHead(blob))")
                    chunks[resp.messageOrder ?? Int32(chunks.count)] = blob
                }
                if resp.finished == true { finished = true }
                continue
            }
            switch try MessageDecoder.decode(frame) {
            case .heartbeatRequest(let h):
                try await transport.sendFrame(HeartbeatOkResponse(
                    requestTime: h.requestTime ?? 0,
                    receiveTime: Int64(Date().timeIntervalSince1970 * 1000)
                ).encode())
            case .error(let e):
                print("  → server ERROR: \(e)")
            default:
                break
            }
        }

        print("\n--- probe result ---")
        if !sawAnyResponse {
            print("NO PositionBinaryResponse frames received in \(Int(observe))s.")
            print("→ The server likely IGNORES PositionDataRequestMessage on the DDS socket")
            print("  (same as extapi.Submit*). GATE FAILS — keep server-mode REST for history.")
        } else {
            let combined = chunks.keys.sorted().reduce(into: Data()) { $0.append(chunks[$1]!) }
            print("GATE PASSES — server answered. \(chunks.count) chunk(s), \(combined.count) blob bytes total, finished=\(finished).")
            if !combined.isEmpty {
                let gzipMagic = combined.prefix(2) == Data([0x1f, 0x8b])
                print("blob starts with GZIP magic (1f 8b): \(gzipMagic)")
                try? combined.write(to: URL(fileURLWithPath: out))
                print("saved blob → \(out) (use as the Stage-E decodeList fixture)")
            } else {
                print("blob empty — account may have no closed trades in this window; widen --from-days.")
            }
        }
        await transport.close()
    }

    /// End-to-end check of the real Stage-B integration: connect a `DukascopySession`,
    /// wait for the account snapshot, then call `fetchClosedPositions` and print the
    /// decoded trades.
    private func runViaSession(_ target: DukascopyEnvironment) async throws {
        let session = DukascopySession(
            environment: target, credentials: AuthCredentials(login: user, password: pass)
        )
        try await session.connect()
        _ = try? await session.accountSnapshot()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let fromMs = nowMs - Int64(fromDays) * 86_400_000
        let positions = try await session.fetchClosedPositions(fromMillis: fromMs, toMillis: nowMs)
        await session.close()

        print(positions.isEmpty ? "(no closed positions in window)" : "closed positions (\(positions.count)):")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        for p in positions {
            let opened = p.openDateMillis.map { f.string(from: Date(timeIntervalSince1970: Double($0) / 1000)) } ?? "-"
            let closed = p.closeDateMillis.map { f.string(from: Date(timeIntervalSince1970: Double($0) / 1000)) } ?? "-"
            print("  \(p.positionId)  \(p.isLong ? "LONG " : "SHORT")  \(p.instrument)  amt=\(p.amount.map { String($0) } ?? "-")  "
                + "open=\(p.openPrice.map { String($0) } ?? "-")  close=\(p.closePrice.map { String($0) } ?? "-")  "
                + "P/L=\(p.profitLoss.map { String($0) } ?? "-")  \(opened) → \(closed)")
        }
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
