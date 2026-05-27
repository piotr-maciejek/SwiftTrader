import BigInt
import Foundation

public struct AuthSuccess: Sendable {
    public let authApiURLs: [String]
    public let ticket: String
    /// `urlA@urlB@…@ticket` — packed form expected by the transport layer.
    public let packedTicket: String
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
        }
    }
}

public struct AuthCredentials: Sendable {
    public let login: String
    public let password: String
    public init(login: String, password: String) {
        self.login = login
        self.password = password
    }
}

public struct AuthClient {
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
        let sessionId = UUID().uuidString
        let requestId = UUID().uuidString
        let loginHash = AuthCredentialEncoder.hashIdentity(credentials.login)
        let passwordHash = AuthCredentialEncoder.hashIdentity(credentials.password)
        let srpSession = SRP6ClientSession(loginHash: loginHash, passwordHash: passwordHash)

        let step1 = try await performStep1(
            baseURL: baseURL, sessionId: sessionId, requestId: requestId, loginHash: loginHash
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

        let step2 = try await performStep2(
            baseURL: baseURL, sessionId: sessionId, requestId: requestId, A: A, M1: M1
        )

        do {
            try srpSession.step3(serverM2Hex: step2.M2)
        } catch let e as SRP6Error {
            throw AuthError.srp6(e)
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
            settingsBlob: step3.settingsBlob,
            step3Headers: step3.headers
        )
    }

    // MARK: - Steps

    private struct Step1Response {
        let N, G, H, S, B: String
    }

    private struct Step2Response {
        let M2: String
    }

    private struct Step3Response {
        let authApiURLs: [String]?
        let settingsBlob: Data?
        let headers: [String: String]
    }

    private func performStep1(
        baseURL: URL, sessionId: String, requestId: String, loginHash: String
    ) async throws -> Step1Response {
        var params = baseParams(sessionId: sessionId, step: 1)
        params["appello"] = loginHash
        params["obsecro_id"] = requestId

        let (data, _) = try await get(baseURL: baseURL, params: params, step: 1)
        let json = try parseJSON(data: data, step: 1)
        guard
            let N = json["N"] as? String,
            let G = json["G"] as? String,
            let H = json["H"] as? String,
            let S = json["S"] as? String,
            let B = json["B"] as? String
        else { throw AuthError.missingField(step: 1, field: "N/G/H/S/B") }
        return Step1Response(N: N, G: G, H: H, S: S, B: B)
    }

    private func performStep2(
        baseURL: URL, sessionId: String, requestId: String, A: String, M1: String
    ) async throws -> Step2Response {
        var params = baseParams(sessionId: sessionId, step: 2)
        params["publicus_pendo"] = A
        params["testimonium_nuntius"] = M1
        params["obsecro_id"] = requestId

        let (data, _) = try await get(baseURL: baseURL, params: params, step: 2)
        let json = try parseJSON(data: data, step: 2)
        guard let M2 = json["M2"] as? String else {
            throw AuthError.missingField(step: 2, field: "M2")
        }
        return Step2Response(M2: M2)
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
        let json = try parseJSON(data: data, step: 3)

        let urls = (json["authApiURLs"] as? [Any])?.compactMap { $0 as? String }

        var settingsBlob: Data?
        if let encoded = json["occasus"] as? String {
            settingsBlob = Data(base64Encoded: encoded)
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

    private func parseJSON(data: Data, step: Int) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.invalidJSON(step: step, body: body)
        }
        return obj
    }
}
