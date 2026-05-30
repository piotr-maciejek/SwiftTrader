import BigInt
import CryptoKit
import Foundation
import Testing
@testable import DukascopyClient

/// Covers the dual-SRP6 PIN/captcha additions to `AuthClient`: the response
/// parsing of the `_C` / `M2_C` fields, and the fact that the PIN session reuses
/// the exact same SRP6 math as the password session but with the captcha id and
/// raw PIN as its (identity, secret) — neither pre-hashed.
@Suite("AuthClient PIN")
struct AuthClientPinTests {

    // RFC 5054 1024-bit group — deterministic math, same baseline as SRP6Tests.
    private let N: BigUInt = BigUInt("""
        EEAF0AB9ADB38DD69C33F80AFA8FC5E86072618775FF3C0B9EA2314C9C256576\
        D674DF7496EA81D3383B4813D692C6E0E0D5D8E250B98BE48E495C1D6089DAD1\
        5DC7D7B46154D6B6CE8EF4AD69B15D4982559B297BCF1885C529F566660E57EC\
        68EDBC3C05726CC02FD4CBF4976EAA9AFD5138FE8376435B9FC61D2FC0EB06E3
        """.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: ""), radix: 16)!
    private let g: BigUInt = 2
    private func params(_ hash: SRP6HashAlgorithm = .sha1) -> SRP6CryptoParams {
        SRP6CryptoParams(N: N, g: g, hash: hash)
    }

    // MARK: - Step-1 parsing

    private func step1JSON(includeC: Bool) -> [String: Any] {
        var j: [String: Any] = [
            "N": "abc1", "G": "02", "H": "SHA-1", "S": "00ff", "B": "1234",
        ]
        if includeC {
            j["N_C"] = "def2"; j["G_C"] = "05"; j["H_C"] = "SHA-256"
            j["S_C"] = "11aa"; j["B_C"] = "5678"
        }
        return j
    }

    @Test("parseStep1 without PIN ignores any _C fields")
    func parseStep1NoPin() throws {
        let r = try AuthClient.parseStep1(step1JSON(includeC: true), expectsPin: false)
        #expect(r.N == "abc1")
        #expect(r.H == "SHA-1")
        #expect(r.pin == nil)
    }

    @Test("parseStep1 with PIN parses the _C fields into PinFields")
    func parseStep1WithPin() throws {
        let r = try AuthClient.parseStep1(step1JSON(includeC: true), expectsPin: true)
        #expect(r.pin?.N == "def2")
        #expect(r.pin?.G == "05")
        #expect(r.pin?.H == "SHA-256")
        #expect(r.pin?.S == "11aa")
        #expect(r.pin?.B == "5678")
    }

    @Test("parseStep1 expecting PIN but missing _C fields throws")
    func parseStep1MissingC() {
        #expect(throws: AuthError.self) {
            _ = try AuthClient.parseStep1(self.step1JSON(includeC: false), expectsPin: true)
        }
    }

    // MARK: - Step-2 parsing

    @Test("parseStep2 without PIN returns M2 only")
    func parseStep2NoPin() throws {
        let r = try AuthClient.parseStep2(["M2": "aa", "M2_C": "bb"], expectsPin: false)
        #expect(r.M2 == "aa")
        #expect(r.M2_C == nil)
    }

    @Test("parseStep2 with PIN parses M2_C")
    func parseStep2WithPin() throws {
        let r = try AuthClient.parseStep2(["M2": "aa", "M2_C": "bb"], expectsPin: true)
        #expect(r.M2 == "aa")
        #expect(r.M2_C == "bb")
    }

    @Test("parseStep2 expecting PIN but missing M2_C throws")
    func parseStep2MissingM2C() {
        #expect(throws: AuthError.self) {
            _ = try AuthClient.parseStep2(["M2": "aa"], expectsPin: true)
        }
    }

    // MARK: - PIN session math

    @Test("PIN session computeX uses captchaId:pin RAW (not pre-hashed)")
    func pinSessionComputeXRaw() {
        let captchaId = "CAPTCHA-XYZ-123"
        let pin = "4815"
        let session = SRP6ClientSession(loginHash: captchaId, passwordHash: pin)
        let p = params(.sha1)
        let salt: BigUInt = 0x00ff

        let x = session.computeX(params: p, salt: salt)

        // Mirror the hex X-routine with captchaId/pin used verbatim:
        //   x = SHA1( UPPER( hex(salt) || lower(hex( SHA1(captchaId ":" pin) )) ) )
        let inner = Data(Insecure.SHA1.hash(data: Data("\(captchaId):\(pin)".utf8)))
        let innerHexLower = Hex.encode(inner)
        let concatUpper = (salt.lowercaseHex + innerHexLower).uppercased()
        let expected = BigUInt(hex: Hex.encode(Data(Insecure.SHA1.hash(data: Data(concatUpper.utf8)))))!

        #expect(x == expected)
    }

    @Test("PIN session verifies its own M2 (good) and rejects a wrong one (badPin path)")
    func pinSessionVerifiesM2() throws {
        let fixedA: BigUInt = 0xDEADBEEF
        let session = SRP6ClientSession(loginHash: "CAPTCHA-1", passwordHash: "9999")
        let p = params(.sha1)
        let salt: BigUInt = 0x42
        let serverB: BigUInt = 0xABCDEF

        _ = try session.step2(params: p, salt: salt, B: serverB) { fixedA }

        // Re-derive the server's expected S/M1/M2 the same way the session did.
        let A = p.g.power(fixedA, modulus: p.N)
        let k = session.computeK(params: p)
        let u = session.computeU(params: p, A: A, B: serverB)
        let x = session.computeX(params: p, salt: salt)
        let gx = p.g.power(x, modulus: p.N)
        let base = (serverB + p.N - (k * gx) % p.N) % p.N
        let S = base.power(fixedA + u * x, modulus: p.N)
        let M1 = session.computeM1(params: p, A: A, B: serverB, S: S)
        let M2 = session.computeM2(params: p, A: A, M1: M1, S: S)

        // Correct evidence verifies.
        try session.step3(serverM2Hex: M2.lowercaseHex)

        // Wrong evidence (the wrong-PIN case) surfaces as badServerEvidence, which
        // `AuthClient.authenticate` maps to `AuthError.badPin`.
        let badSession = SRP6ClientSession(loginHash: "CAPTCHA-1", passwordHash: "0000")
        _ = try badSession.step2(params: p, salt: salt, B: serverB) { fixedA }
        #expect(throws: SRP6Error.badServerEvidence) {
            try badSession.step3(serverM2Hex: M2.lowercaseHex)
        }
    }
}
