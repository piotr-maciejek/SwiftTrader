import Foundation

public struct HandshakeResult: Sendable {
    public let transportSessionId: String
    public let challenge: String?
    public let udpSupportedByServer: Bool?
}

public enum HandshakeError: Error, CustomStringConvertible {
    case unexpectedHaloMessage(InboundMessage)
    case haloMissingSessionId
    case unexpectedLoginResponse(InboundMessage)
    case loginRejected(ErrorResponse)

    public var description: String {
        switch self {
        case .unexpectedHaloMessage(let m): "halo: unexpected response \(m)"
        case .haloMissingSessionId:         "halo: response did not include a session id"
        case .unexpectedLoginResponse(let m): "login: unexpected response \(m)"
        case .loginRejected(let e):         "login rejected: \(e)"
        }
    }
}

public extension Transport {
    /// Performs the binary HALO + LOGIN handshake. `auth.packedTicket` is not
    /// needed here; only `auth.ticket` (the lowercase-hex session ticket from
    /// the SRP6 flow), the login, and the SRP6 sermo session id are required.
    func handshake(
        login: String,
        ticket: String,
        authSessionId: String,
        useragent: String = "DukascopyClient/0.1 (SwiftTrader)",
        sessionName: String? = nil
    ) async throws -> HandshakeResult {
        var halo = HaloRequest()
        halo.useragent = useragent
        halo.pingable = true
        halo.secondaryConnectionDisabled = true
        halo.secondaryConnectionMessagesTTL = 0
        halo.sessionName = sessionName
        halo.udpSupportedByClient = false
        halo.requestId = UUID().uuidString
        halo.timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        try await sendFrame(halo.encode())
        let haloFrame = try await receiveFrame()
        let haloMsg = try MessageDecoder.decode(haloFrame)
        let haloResponse: HaloResponse
        switch haloMsg {
        case .halo(let h):     haloResponse = h
        case .error(let e):    throw HandshakeError.loginRejected(e)
        default:               throw HandshakeError.unexpectedHaloMessage(haloMsg)
        }
        guard let transportSessionId = haloResponse.sessionId else {
            throw HandshakeError.haloMissingSessionId
        }

        var loginReq = LoginRequest(
            username: login,
            ticket: ticket,
            sessionId: authSessionId
        )
        loginReq.requestId = UUID().uuidString
        loginReq.timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        try await sendFrame(loginReq.encode())
        let loginFrame = try await receiveFrame()
        let loginMsg = try MessageDecoder.decode(loginFrame)
        switch loginMsg {
        case .ok:
            return HandshakeResult(
                transportSessionId: transportSessionId,
                challenge: haloResponse.challenge,
                udpSupportedByServer: haloResponse.udpSupportedByServer
            )
        case .error(let e):
            throw HandshakeError.loginRejected(e)
        default:
            throw HandshakeError.unexpectedLoginResponse(loginMsg)
        }
    }
}
