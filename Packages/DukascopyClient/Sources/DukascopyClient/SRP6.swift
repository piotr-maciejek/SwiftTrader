import BigInt
import CryptoKit
import Foundation

public enum SRP6HashAlgorithm: String, Sendable {
    case sha1 = "SHA-1"
    case sha256 = "SHA-256"
    case sha384 = "SHA-384"
    case sha512 = "SHA-512"

    public static func parse(_ name: String) -> SRP6HashAlgorithm? {
        let normalized = name.uppercased().replacingOccurrences(of: "_", with: "-")
        return Self(rawValue: normalized)
    }

    func hash(_ data: Data) -> Data {
        switch self {
        case .sha1:   return Data(Insecure.SHA1.hash(data: data))
        case .sha256: return Data(SHA256.hash(data: data))
        case .sha384: return Data(SHA384.hash(data: data))
        case .sha512: return Data(SHA512.hash(data: data))
        }
    }
}

public struct SRP6CryptoParams: Sendable {
    public let N: BigUInt
    public let g: BigUInt
    public let hash: SRP6HashAlgorithm

    public init(N: BigUInt, g: BigUInt, hash: SRP6HashAlgorithm) {
        self.N = N
        self.g = g
        self.hash = hash
    }
}

public enum SRP6Error: Error, CustomStringConvertible, Equatable {
    case invalidServerPublicValue
    case badServerEvidence
    case sessionNotInStep2

    public var description: String {
        switch self {
        case .invalidServerPublicValue: "Server public value B ≡ 0 (mod N)"
        case .badServerEvidence: "Server evidence M2 did not match expected value"
        case .sessionNotInStep2: "step3 called before step2"
        }
    }
}

public final class SRP6ClientSession {
    public let loginHash: String
    public let passwordHash: String

    private var crypto: SRP6CryptoParams?
    private var a: BigUInt?
    private var A: BigUInt?
    private var S: BigUInt?
    private var M1: BigUInt?

    public init(loginHash: String, passwordHash: String) {
        self.loginHash = loginHash
        self.passwordHash = passwordHash
    }

    /// Performs the client side of step 2 given the server's step-1 response.
    /// Returns the lowercase-hex `A` (client public value) and `M1` (client evidence)
    /// that must be sent to the server.
    public func step2(
        params: SRP6CryptoParams,
        salt: BigUInt,
        B: BigUInt,
        randomA: (() -> BigUInt)? = nil
    ) throws -> (A: String, M1: String) {
        guard B % params.N != 0 else { throw SRP6Error.invalidServerPublicValue }
        self.crypto = params

        let x = computeX(params: params, salt: salt)

        let a = randomA?() ?? Self.generatePrivateValue(N: params.N)
        self.a = a
        let A = params.g.power(a, modulus: params.N)
        self.A = A

        let k = computeK(params: params)
        let u = computeU(params: params, A: A, B: B)

        // S = (B - k * g^x mod N) ^ (a + u*x) mod N
        // computed as (B - (k * g^x mod N) + N) mod N to keep base positive
        let gx = params.g.power(x, modulus: params.N)
        var base = (B + params.N - (k * gx) % params.N) % params.N
        let exp = a + u * x
        let S = base.power(exp, modulus: params.N)
        self.S = S
        base = 0  // not strictly necessary; just documenting intent

        let M1 = computeM1(params: params, A: A, B: B, S: S)
        self.M1 = M1

        return (A: A.lowercaseHex, M1: M1.lowercaseHex)
    }

    /// Verifies the server's M2 evidence message.
    public func step3(serverM2Hex: String) throws {
        guard
            let params = crypto,
            let A = self.A,
            let M1 = self.M1,
            let S = self.S
        else { throw SRP6Error.sessionNotInStep2 }

        guard let expectedM2Raw = BigUInt(hex: serverM2Hex) else {
            throw SRP6Error.badServerEvidence
        }
        let computedM2 = computeM2(params: params, A: A, M1: M1, S: S)
        if computedM2 != expectedM2Raw {
            throw SRP6Error.badServerEvidence
        }
    }

    /// The ticket the upstream code calls "session key" — `lower(hex( H( utf8(hex(S)) ) ))`.
    public func ticket() -> String? {
        guard let params = crypto, let S = self.S else { return nil }
        let sHex = S.lowercaseHex
        let digest = params.hash.hash(Data(sHex.utf8))
        return Hex.encode(digest)
    }

    // MARK: - Internals (visible for testing)

    static func generatePrivateValue(N: BigUInt) -> BigUInt {
        // RFC 5054 §3: the client private exponent `a` SHOULD be at least 256 bits. Sizing it
        // to the full width of N (Dukascopy uses a 4096-bit group) makes `g^a mod N` ~16x
        // slower for ZERO security gain — the server only ever sees `A = g^a mod N`, never `a`.
        // A 256-bit exponent is the standard choice and keeps auth fast.
        let byteCount = 256 / 8
        var raw = Data(count: byteCount)
        while true {
            _ = raw.withUnsafeMutableBytes { buf in
                SecRandomCopyBytes(kSecRandomDefault, byteCount, buf.baseAddress!)
            }
            let value = BigUInt(raw) % N
            if value != 0 { return value }
        }
    }

    /// k = H( PAD(N) || PAD(g) ), output as unsigned BigUInt.
    func computeK(params: SRP6CryptoParams) -> BigUInt {
        let length = (params.N.bitWidth + 7) / 8
        var data = params.N.bytes(paddedTo: length)
        data.append(params.g.bytes(paddedTo: length))
        return BigUInt(params.hash.hash(data))
    }

    /// u = H( utf8( hex(A) || hex(B) ) ), output as unsigned BigUInt.
    func computeU(params: SRP6CryptoParams, A: BigUInt, B: BigUInt) -> BigUInt {
        let s = A.lowercaseHex + B.lowercaseHex
        return BigUInt(params.hash.hash(Data(s.utf8)))
    }

    /// x = BigInt parsed from the hex digest of:
    ///   UPPER( hex(salt) || lower(hex( H( loginHash ":" passwordHash ) )) )
    /// hashed once more.
    func computeX(params: SRP6CryptoParams, salt: BigUInt) -> BigUInt {
        let h1 = params.hash.hash(Data("\(loginHash):\(passwordHash)".utf8))
        let h1HexLower = Hex.encode(h1)
        let saltHexLower = salt.lowercaseHex
        let concatUpper = (saltHexLower + h1HexLower).uppercased()
        let h2 = params.hash.hash(Data(concatUpper.utf8))
        let xHex = Hex.encode(h2)
        return BigUInt(hex: xHex) ?? 0
    }

    /// M1 = H( utf8( hex(A) || hex(B) || hex(S) ) )
    func computeM1(params: SRP6CryptoParams, A: BigUInt, B: BigUInt, S: BigUInt) -> BigUInt {
        let s = A.lowercaseHex + B.lowercaseHex + S.lowercaseHex
        return BigUInt(params.hash.hash(Data(s.utf8)))
    }

    /// M2 = H( utf8( hex(A) || hex(M1) || hex(S) ) )
    func computeM2(params: SRP6CryptoParams, A: BigUInt, M1: BigUInt, S: BigUInt) -> BigUInt {
        let s = A.lowercaseHex + M1.lowercaseHex + S.lowercaseHex
        return BigUInt(params.hash.hash(Data(s.utf8)))
    }
}

public enum AuthCredentialEncoder {
    public static func hashIdentity(_ s: String) -> String {
        let bytes = s.data(using: .isoLatin1) ?? Data(s.utf8)
        let digest = Insecure.SHA1.hash(data: bytes)
        return Hex.encode(Data(digest)).uppercased()
    }
}
