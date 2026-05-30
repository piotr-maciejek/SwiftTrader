import BigInt
import Foundation

public struct AuthSuccess: Sendable {
    public let authApiURLs: [String]
    public let ticket: String
    /// `urlA@urlB@…@ticket` — packed form expected by the transport layer.
    public let packedTicket: String
    /// SRP6 session id used as the `sermo` query parameter; required again by
    /// the binary login step on the transport socket.
    public let authSessionId: String
    /// Server-supplied settings blob. Parsing deferred to a later phase.
    public let settingsBlob: Data?
    public let step3Headers: [String: String]
}

public enum AuthError: Error, CustomStringConvertible {
    case httpStatus(step: Int, code: Int, body: String)
    case invalidJSON(step: Int, body: String)
    case missingField(step: Int, field: String)
    case unsupportedHash(String)
    case srp6(SRP6Error)
    case authApiURLsMissing
    /// The captcha response carried no `X-CaptchaID` header.
    case captchaIdMissing
    /// The user dismissed the PIN prompt without submitting a code.
    case pinCancelled
    /// The PIN session's server evidence (`M2_C`) did not verify — i.e. the entered
    /// PIN was wrong. Distinct from `.srp6` so callers can re-prompt with a fresh
    /// captcha instead of treating it as a hard auth failure.
    case badPin

    public var description: String {
        switch self {
        case .httpStatus(let step, let code, let body):
            "step \(step) returned HTTP \(code): \(body.prefix(200))"
        case .invalidJSON(let step, let body):
            "step \(step) returned non-JSON body: \(body.prefix(200))"
        case .missingField(let step, let field):
            "step \(step) response missing required field \(field)"
        case .unsupportedHash(let h):
            "server requested unsupported hash algorithm \(h)"
        case .srp6(let e): "SRP6: \(e.description)"
        case .authApiURLsMissing: "step 3 response did not include authApiURLs"
        case .captchaIdMissing: "captcha response missing X-CaptchaID header"
        case .pinCancelled: "PIN entry was cancelled"
        case .badPin: "incorrect PIN"
        }
    }
}

/// A captcha challenge to show the user: the PNG image bytes plus the server's
/// opaque captcha id, which becomes the PIN SRP6 session's identity.
public struct PinChallenge: Sendable {
    public let captcha: Data
    public let captchaId: String

    public init(captcha: Data, captchaId: String) {
        self.captcha = captcha
        self.captchaId = captchaId
    }
}

/// Async hook the session invokes when a LIVE account on a non-whitelisted IP
/// requires a captcha PIN. Receives the captcha image; returns the typed PIN.
/// Throw `AuthError.pinCancelled` to abort.
public typealias PinProvider = @Sendable (PinChallenge) async throws -> String

/// Result of the `login_info` pre-check: whether the account currently needs a
/// captcha PIN to authenticate from this IP.
public struct LoginInfo: Sendable {
    public let checkPin: Bool
    public let wlPartnerId: Int?

    public init(checkPin: Bool, wlPartnerId: Int?) {
        self.checkPin = checkPin
        self.wlPartnerId = wlPartnerId
    }
}

public struct AuthCredentials: Sendable {
    public let login: String
    /// `UPPER(hex(SHA1(password)))` — the only password derivative the SRP6 flow uses.
    /// Lets callers persist the hash instead of the plaintext password.
    public let passwordHash: String

    public init(login: String, passwordHash: String) {
        self.login = login
        self.passwordHash = passwordHash
    }

    public init(login: String, password: String) {
        self.init(login: login, passwordHash: AuthCredentialEncoder.hashIdentity(password))
    }
}

public struct AuthClient: Sendable {
    public static let platform = "DDS3_JFOREX"
    public static let defaultVersion = "99.99.99"
    public static let service = "srp_api"
    public static let userAgent = "DukascopyClient/0.1 (SwiftTrader)"

    public var session: URLSession
    public var version: String
    public var requestSettings: Bool

    public init(
        session: URLSession = .shared,
        version: String = AuthClient.defaultVersion,
        requestSettings: Bool = true
    ) {
        self.session = session
        self.version = version
        self.requestSettings = requestSettings
    }

    /// Authenticate against a single SRP6 server. The caller is responsible for
    /// iterating across multiple servers on failure.
    public func authenticate(
        baseURL: URL,
        credentials: AuthCredentials
    ) async throws -> AuthSuccess {
        try await authenticate(
            baseURL: baseURL, credentials: credentials, captchaId: nil, pin: nil
        )
    }

    /// Authenticate, optionally running a parallel PIN SRP6 session when a captcha
    /// PIN is required (LIVE on a non-whitelisted IP). When `captchaId`/`pin` are
    /// nil this is the plain password-only flow. When present, the PIN session uses
    /// `captchaId` as its identity and the raw `pin` as its password (both used
    /// verbatim — the server derives the matching verifier from the captcha it
    /// issued). Mirrors the JForex SDK's `SRPAuthClient` dual-session flow:
    /// step1 adds `verbum_id` and parses the `_C` fields, step2 adds the
    /// `pin_`-prefixed public value / evidence and parses `M2_C`, step3 is unchanged.
    public func authenticate(
        baseURL: URL,
        credentials: AuthCredentials,
        captchaId: String?,
        pin: String?
    ) async throws -> AuthSuccess {
        let sessionId = UUID().uuidString
        let requestId = UUID().uuidString
        let loginHash = AuthCredentialEncoder.hashIdentity(credentials.login)
        let passwordHash = credentials.passwordHash
        let srpSession = SRP6ClientSession(loginHash: loginHash, passwordHash: passwordHash)

        // The PIN session's identity is the captcha id and its "password" is the raw
        // PIN — neither is pre-hashed (the hex X-routine hashes them internally).
        let pinSession: SRP6ClientSession?
        if let captchaId, let pin {
            pinSession = SRP6ClientSession(loginHash: captchaId, passwordHash: pin)
        } else {
            pinSession = nil
        }

        let step1 = try await performStep1(
            baseURL: baseURL, sessionId: sessionId, requestId: requestId,
            loginHash: loginHash, captchaId: captchaId
        )
        guard let hash = SRP6HashAlgorithm.parse(step1.H) else {
            throw AuthError.unsupportedHash(step1.H)
        }
        guard
            let N = BigUInt(hex: step1.N),
            let g = BigUInt(hex: step1.G),
            let salt = BigUInt(hex: step1.S),
            let B = BigUInt(hex: step1.B)
        else { throw AuthError.missingField(step: 1, field: "N/G/S/B (bad hex)") }

        let params = SRP6CryptoParams(N: N, g: g, hash: hash)
        let (A, M1): (String, String)
        do {
            (A, M1) = try srpSession.step2(params: params, salt: salt, B: B)
        } catch let e as SRP6Error {
            throw AuthError.srp6(e)
        }

        // Compute the PIN session's A/M1 from its own (`_C`) step-1 parameters.
        var pinA: String?
        var pinM1: String?
        if let pinSession, let pinFields = step1.pin {
            guard let pinHash = SRP6HashAlgorithm.parse(pinFields.H) else {
                throw AuthError.unsupportedHash(pinFields.H)
            }
            guard
                let pinN = BigUInt(hex: pinFields.N),
                let pinG = BigUInt(hex: pinFields.G),
                let pinSalt = BigUInt(hex: pinFields.S),
                let pinB = BigUInt(hex: pinFields.B)
            else { throw AuthError.missingField(step: 1, field: "N_C/G_C/S_C/B_C (bad hex)") }
            let pinParams = SRP6CryptoParams(N: pinN, g: pinG, hash: pinHash)
            do {
                (pinA, pinM1) = try pinSession.step2(params: pinParams, salt: pinSalt, B: pinB)
            } catch let e as SRP6Error {
                throw AuthError.srp6(e)
            }
        }

        let step2: Step2Response
        do {
            step2 = try await performStep2(
                baseURL: baseURL, sessionId: sessionId, requestId: requestId,
                A: A, M1: M1, pinA: pinA, pinM1: pinM1
            )
        } catch let AuthError.httpStatus(step, code, _)
            where pinSession != nil && step == 2 && (code == 801 || code == 401) {
            // Confirmed against the live server: a wrong PIN is rejected at the step-2
            // HTTP layer with code 801 (= 401 + ERROR_CODE_OFFSET 400,
            // "Authentication failed"), NOT a 200 body with a mismatched M2_C. The
            // password session is otherwise valid, so in the dual flow this means the
            // entered PIN was wrong — surface it as `.badPin` so callers re-prompt.
            throw AuthError.badPin
        }

        do {
            try srpSession.step3(serverM2Hex: step2.M2)
        } catch let e as SRP6Error {
            throw AuthError.srp6(e)
        }

        // Verify the PIN session's evidence — a mismatch means the typed PIN was wrong.
        if let pinSession {
            guard let m2c = step2.M2_C else {
                throw AuthError.missingField(step: 2, field: "M2_C")
            }
            do {
                try pinSession.step3(serverM2Hex: m2c)
            } catch SRP6Error.badServerEvidence {
                throw AuthError.badPin
            } catch let e as SRP6Error {
                throw AuthError.srp6(e)
            }
        }

        guard let ticket = srpSession.ticket() else {
            // Should never happen — step3 succeeded so session has S.
            throw AuthError.srp6(.sessionNotInStep2)
        }

        let step3 = try await performStep3(
            baseURL: baseURL, sessionId: sessionId, requestId: requestId
        )

        guard let urls = step3.authApiURLs, !urls.isEmpty else {
            throw AuthError.authApiURLsMissing
        }
        let packed = urls.joined(separator: "@") + "@" + ticket

        return AuthSuccess(
            authApiURLs: urls,
            ticket: ticket,
            packedTicket: packed,
            authSessionId: sessionId,
            settingsBlob: step3.settingsBlob,
            step3Headers: step3.headers
        )
    }

    // MARK: - PIN / captcha pre-flight

    /// Ask the auth server whether `login` currently needs a captcha PIN from this
    /// IP (the `munus=login_info` single-request call). `checkPin == true` means the
    /// caller must fetch a captcha and run the dual-session authenticate.
    public func checkIfPinRequired(baseURL: URL, login: String) async throws -> LoginInfo {
        let params: [String: String] = [
            "putent_genus": "0",
            "munus": "login_info",
            "appello": AuthCredentialEncoder.hashIdentity(login),
        ]
        let (data, _) = try await get(baseURL: baseURL, params: params, step: 0)
        let json = try parseJSON(data: data, step: 0)
        let checkPin = (json["checkPin"] as? Bool) ?? false
        let wlPartnerId = json["wlPartnerId"] as? Int
        return LoginInfo(checkPin: checkPin, wlPartnerId: wlPartnerId)
    }

    /// Fetch a fresh captcha image (`GET <base>/captcha`). The PNG bytes are the
    /// body; the opaque captcha id arrives in the `X-CaptchaID` response header.
    public func fetchCaptcha(baseURL: URL) async throws -> PinChallenge {
        let url = captchaURL(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(AuthClient.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.httpStatus(step: 0, code: http.statusCode, body: body)
        }
        guard
            let http = response as? HTTPURLResponse,
            let captchaId = http.value(forHTTPHeaderField: "X-CaptchaID")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !captchaId.isEmpty
        else { throw AuthError.captchaIdMissing }
        return PinChallenge(captcha: data, captchaId: captchaId)
    }

    // MARK: - Steps

    // Internal (not private) so the pure `parseStep1`/`parseStep2` helpers can be
    // unit-tested via `@testable import` against canned JSON.
    struct Step1Response {
        let N, G, H, S, B: String
        /// The PIN session's SRP6 parameters (`_C`-suffixed), present only when the
        /// request carried a `verbum_id` and the server is running a PIN session.
        let pin: PinFields?
    }

    struct PinFields {
        let N, G, H, S, B: String
    }

    struct Step2Response {
        let M2: String
        /// The PIN session's server evidence (`M2_C`), present only in the dual flow.
        let M2_C: String?
    }

    private struct Step3Response {
        let authApiURLs: [String]?
        let settingsBlob: Data?
        let headers: [String: String]
    }

    private func performStep1(
        baseURL: URL, sessionId: String, requestId: String, loginHash: String,
        captchaId: String?
    ) async throws -> Step1Response {
        var params = baseParams(sessionId: sessionId, step: 1)
        params["appello"] = loginHash
        params["obsecro_id"] = requestId
        if let captchaId {
            params["verbum_id"] = captchaId
        }

        let (data, _) = try await get(baseURL: baseURL, params: params, step: 1)
        let json = try parseJSON(data: data, step: 1)
        return try Self.parseStep1(json, expectsPin: captchaId != nil)
    }

    /// Pure parse of a step-1 response body. Split out so it's unit-testable against
    /// canned JSON without a live server.
    static func parseStep1(_ json: [String: Any], expectsPin: Bool) throws -> Step1Response {
        guard
            let N = json["N"] as? String,
            let G = json["G"] as? String,
            let H = json["H"] as? String,
            let S = json["S"] as? String,
            let B = json["B"] as? String
        else { throw AuthError.missingField(step: 1, field: "N/G/H/S/B") }

        var pin: PinFields?
        if expectsPin {
            guard
                let nc = json["N_C"] as? String,
                let gc = json["G_C"] as? String,
                let hc = json["H_C"] as? String,
                let sc = json["S_C"] as? String,
                let bc = json["B_C"] as? String
            else { throw AuthError.missingField(step: 1, field: "N_C/G_C/H_C/S_C/B_C") }
            pin = PinFields(N: nc, G: gc, H: hc, S: sc, B: bc)
        }
        return Step1Response(N: N, G: G, H: H, S: S, B: B, pin: pin)
    }

    private func performStep2(
        baseURL: URL, sessionId: String, requestId: String,
        A: String, M1: String, pinA: String?, pinM1: String?
    ) async throws -> Step2Response {
        var params = baseParams(sessionId: sessionId, step: 2)
        params["publicus_pendo"] = A
        params["testimonium_nuntius"] = M1
        if let pinA, let pinM1 {
            params["pin_publicus_pendo"] = pinA
            params["pin_testimonium_nuntius"] = pinM1
        }
        params["obsecro_id"] = requestId

        let (data, _) = try await get(baseURL: baseURL, params: params, step: 2)
        let json = try parseJSON(data: data, step: 2)
        return try Self.parseStep2(json, expectsPin: pinA != nil)
    }

    /// Pure parse of a step-2 response body. Unit-testable against canned JSON.
    static func parseStep2(_ json: [String: Any], expectsPin: Bool) throws -> Step2Response {
        guard let M2 = json["M2"] as? String else {
            throw AuthError.missingField(step: 2, field: "M2")
        }
        var m2c: String?
        if expectsPin {
            guard let v = json["M2_C"] as? String else {
                throw AuthError.missingField(step: 2, field: "M2_C")
            }
            m2c = v
        }
        return Step2Response(M2: M2, M2_C: m2c)
    }

    private func performStep3(
        baseURL: URL, sessionId: String, requestId: String
    ) async throws -> Step3Response {
        var params = baseParams(sessionId: sessionId, step: 3)
        params["platform"] = AuthClient.platform
        params["versio"] = version
        params["willPing"] = "true"
        if requestSettings {
            params["occasus"] = "true"
        }
        params["obsecro_id"] = requestId

        let (data, response) = try await get(baseURL: baseURL, params: params, step: 3)
        if ProcessInfo.processInfo.environment["DUKASCOPY_DUMP_STEP3"] != nil {
            try? data.write(to: URL(fileURLWithPath: "/tmp/step3.json"))
        }
        let json = try parseJSON(data: data, step: 3)

        let urls = (json["authApiURLs"] as? [Any])?.compactMap { $0 as? String }

        var settingsBlob: Data?
        if let encoded = json["occasus"] as? String {
            // The server wraps the base64 with CRLFs (MIME style); strict decoding fails,
            // so ignore non-base64 characters.
            settingsBlob = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        }

        var headers: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
            for (k, v) in http.allHeaderFields {
                if let key = k as? String, let value = v as? String {
                    headers[key] = value
                }
            }
        }

        return Step3Response(authApiURLs: urls, settingsBlob: settingsBlob, headers: headers)
    }

    private func baseParams(sessionId: String, step: Int) -> [String: String] {
        return [
            "putent_genus": "0",
            "munus": AuthClient.service,
            "sermo": sessionId,
            "passus": String(step),
            "srp_versio": "1",
        ]
    }

    // MARK: - HTTP

    private func get(
        baseURL: URL, params: [String: String], step: Int
    ) async throws -> (Data, URLResponse) {
        let url = buildURL(baseURL: baseURL, params: params)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(AuthClient.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.httpStatus(step: step, code: http.statusCode, body: body)
        }
        return (data, response)
    }

    private func buildURL(baseURL: URL, params: [String: String]) -> URL {
        var path = baseURL.path
        if !path.hasSuffix("/") { path += "/" }
        path += "auth"
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = path
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    /// `<base>/captcha` — same host/port as the auth endpoint, different path.
    private func captchaURL(baseURL: URL) -> URL {
        var path = baseURL.path
        if !path.hasSuffix("/") { path += "/" }
        path += "captcha"
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = path
        return components.url!
    }

    private func parseJSON(data: Data, step: Int) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.invalidJSON(step: step, body: body)
        }
        return obj
    }
}
