import BigInt
import CryptoKit
import Foundation
import Testing
@testable import DukascopyClient

@Suite("SRP6")
struct SRP6Tests {
    /// Standard RFC 5054 1024-bit group used as a baseline. The Dukascopy server
    /// actually sends N and g in step 1, but using a known group for the math
    /// tests keeps them deterministic.
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

    @Test("Identity hash matches Java SHA1 upper-hex")
    func identityHashMatchesJavaSHA1UpperHex() {
        // SHA1("user") = 12dea96fec20593566ab75692c9949596833adc9
        #expect(AuthCredentialEncoder.hashIdentity("user") == "12DEA96FEC20593566AB75692C9949596833ADC9")
        // SHA1("") = da39a3ee5e6b4b0d3255bfef95601890afd80709
        #expect(AuthCredentialEncoder.hashIdentity("") == "DA39A3EE5E6B4B0D3255BFEF95601890AFD80709")
    }

    @Test("k = H(PAD(N) || PAD(g))")
    func computeKMatchesPaddedConcatenation() {
        let session = SRP6ClientSession(loginHash: "L", passwordHash: "P")
        let params = params(.sha1)
        let k = session.computeK(params: params)

        let length = (params.N.bitWidth + 7) / 8
        var expected = Data()
        expected.append(params.N.bytes(paddedTo: length))
        expected.append(params.g.bytes(paddedTo: length))
        let expectedK = BigUInt(Data(Insecure.SHA1.hash(data: expected)))

        #expect(k == expectedK)
    }

    @Test("u = H(hex(A) || hex(B))")
    func computeUMatchesHexConcat() {
        let session = SRP6ClientSession(loginHash: "L", passwordHash: "P")
        let A = BigUInt(42)
        let B = BigUInt(1729)
        let u = session.computeU(params: params(.sha1), A: A, B: B)

        let expectedInput = Data((A.lowercaseHex + B.lowercaseHex).utf8)
        let expectedU = BigUInt(Data(Insecure.SHA1.hash(data: expectedInput)))
        #expect(u == expectedU)
    }

    @Test("M1 = H(hex(A) || hex(B) || hex(S))")
    func computeM1MatchesHexConcat() {
        let session = SRP6ClientSession(loginHash: "L", passwordHash: "P")
        let A = BigUInt(0xDEADBEEF)
        let B = BigUInt(0xCAFEBABE)
        let S = BigUInt(0xFEEDFACE)
        let m1 = session.computeM1(params: params(.sha1), A: A, B: B, S: S)
        let expectedInput = Data((A.lowercaseHex + B.lowercaseHex + S.lowercaseHex).utf8)
        let expected = BigUInt(Data(Insecure.SHA1.hash(data: expectedInput)))
        #expect(m1 == expected)
    }

    @Test("x = H(UPPER(hex(salt) || lower(hex(H(login:pwd)))))")
    func computeXMatchesDoubleHashFormula() {
        let loginHash = "ABCDEF"
        let passwordHash = "012345"
        let session = SRP6ClientSession(loginHash: loginHash, passwordHash: passwordHash)
        let salt = BigUInt(0x1234567890ABCDEF as UInt64)
        let x = session.computeX(params: params(.sha1), salt: salt)

        let h1 = Data(Insecure.SHA1.hash(data: Data("\(loginHash):\(passwordHash)".utf8)))
        let h1Hex = Hex.encode(h1)
        let concat = (salt.lowercaseHex + h1Hex).uppercased()
        let h2 = Data(Insecure.SHA1.hash(data: Data(concat.utf8)))
        let expectedX = BigUInt(hex: Hex.encode(h2))
        #expect(x == expectedX)
    }

    @Test("Ticket is H(utf8(hex(S))) — 40 hex chars for SHA-1")
    func ticketIsHashOfHexS() throws {
        let session = SRP6ClientSession(loginHash: "A", passwordHash: "B")
        // Deterministic: fixed `a` so step2 produces a fixed S/A.
        let fixedA: BigUInt = 12345
        let salt: BigUInt = 0x42
        let serverB: BigUInt = 0x999

        _ = try session.step2(params: params(.sha1), salt: salt, B: serverB) { fixedA }

        let ticket = session.ticket()
        #expect(ticket != nil)
        #expect(ticket?.count == 40)  // SHA-1 = 20 bytes = 40 hex chars
    }

    @Test("step3 verifies a good server M2 and rejects a bad one")
    func step3VerifiesServerM2() throws {
        let session = SRP6ClientSession(loginHash: "A", passwordHash: "B")
        let fixedA: BigUInt = 0xAA
        let salt: BigUInt = 0x42
        let serverB: BigUInt = 0x999
        _ = try session.step2(params: params(.sha1), salt: salt, B: serverB) { fixedA }

        // Re-derive A, M1, S the same way the session did, then the expected M2.
        let mirrorParams = params(.sha1)
        let aValue: BigUInt = fixedA
        let A = mirrorParams.g.power(aValue, modulus: mirrorParams.N)
        let k = session.computeK(params: mirrorParams)
        let u = session.computeU(params: mirrorParams, A: A, B: serverB)
        let x = session.computeX(params: mirrorParams, salt: salt)
        let gx = mirrorParams.g.power(x, modulus: mirrorParams.N)
        let base = (serverB + mirrorParams.N - (k * gx) % mirrorParams.N) % mirrorParams.N
        let exp = aValue + u * x
        let S = base.power(exp, modulus: mirrorParams.N)
        let M1 = session.computeM1(params: mirrorParams, A: A, B: serverB, S: S)
        let M2 = session.computeM2(params: mirrorParams, A: A, M1: M1, S: S)

        // Good M2 verifies (no throw).
        try session.step3(serverM2Hex: M2.lowercaseHex)

        // Bad M2 throws.
        let badM2 = (M2 + 1).lowercaseHex
        #expect(throws: SRP6Error.badServerEvidence) {
            try session.step3(serverM2Hex: badM2)
        }
    }

    @Test("step2 rejects B ≡ 0 (mod N)")
    func step2RejectsZeroBModN() {
        let session = SRP6ClientSession(loginHash: "A", passwordHash: "B")
        #expect(throws: SRP6Error.invalidServerPublicValue) {
            try session.step2(params: params(.sha1), salt: 1, B: N) { 1 }
        }
    }

    @Test("Hash algorithm name parsing")
    func hashAlgorithmParsing() {
        #expect(SRP6HashAlgorithm.parse("SHA-1") == .sha1)
        #expect(SRP6HashAlgorithm.parse("sha-1") == .sha1)
        #expect(SRP6HashAlgorithm.parse("SHA_256") == .sha256)
        #expect(SRP6HashAlgorithm.parse("MD5") == nil)
    }
}
