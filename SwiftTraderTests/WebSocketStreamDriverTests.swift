import Foundation
import Testing
@testable import SwiftTrader

@Suite("WebSocketStreamError")
struct WebSocketStreamErrorTests {

    @Test("stale description mentions elapsed seconds")
    func staleDescription() {
        let err = WebSocketStreamError.stale(secondsSilent: 120)
        #expect(err.errorDescription?.contains("120") == true)
        #expect(err.errorDescription?.contains("dead") == true)
    }

    @Test("decode description mentions failure reason")
    func decodeDescription() {
        let err = WebSocketStreamError.decode("missing field")
        #expect(err.errorDescription?.contains("missing field") == true)
    }

    @Test("equality distinguishes cases")
    func equality() {
        #expect(WebSocketStreamError.stale(secondsSilent: 5) == .stale(secondsSilent: 5))
        #expect(WebSocketStreamError.stale(secondsSilent: 5) != .stale(secondsSilent: 6))
        #expect(WebSocketStreamError.decode("a") == .decode("a"))
        #expect(WebSocketStreamError.decode("a") != .decode("b"))
        #expect(WebSocketStreamError.stale(secondsSilent: 5) != .decode("a"))
    }
}

@Suite("WebSocketStreamDriver.decode")
struct WebSocketStreamDriverDecodeTests {

    struct SamplePayload: Decodable, Equatable {
        let value: Int
        let label: String
    }

    @Test("valid JSON decodes into the requested type")
    func decodesValidPayload() throws {
        let json = #"{"value":42,"label":"hello"}"#.data(using: .utf8)!
        let result = WebSocketStreamDriver.decode(json, as: SamplePayload.self)
        switch result {
        case .success(let payload):
            #expect(payload == SamplePayload(value: 42, label: "hello"))
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
    }

    @Test("arrays decode — matches the NewsCoordinator shape")
    func decodesArray() throws {
        let json = #"[{"value":1,"label":"a"},{"value":2,"label":"b"}]"#.data(using: .utf8)!
        let result = WebSocketStreamDriver.decode(json, as: [SamplePayload].self)
        switch result {
        case .success(let payloads):
            #expect(payloads.count == 2)
            #expect(payloads[0].value == 1)
            #expect(payloads[1].label == "b")
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
    }

    @Test("malformed JSON becomes a .decode error — stream stays open for caller to reconnect")
    func malformedBecomesDecodeError() {
        let garbage = Data("not json".utf8)
        let result = WebSocketStreamDriver.decode(garbage, as: SamplePayload.self)
        switch result {
        case .success:
            Issue.record("expected failure on garbage input")
        case .failure(let error):
            if case .decode = error {
                // Pass — caller will surface this via the continuation's throwing finish.
            } else {
                Issue.record("expected .decode, got \(error)")
            }
        }
    }

    @Test("missing required field becomes a .decode error")
    func missingFieldBecomesDecodeError() {
        let json = #"{"value":42}"#.data(using: .utf8)!
        let result = WebSocketStreamDriver.decode(json, as: SamplePayload.self)
        switch result {
        case .success:
            Issue.record("expected failure when field missing")
        case .failure(let error):
            if case .decode = error { } else {
                Issue.record("expected .decode, got \(error)")
            }
        }
    }
}
