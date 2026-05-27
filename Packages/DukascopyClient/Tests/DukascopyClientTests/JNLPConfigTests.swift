import XCTest
@testable import DukascopyClient

final class JNLPConfigTests: XCTestCase {
    func testParseMinimalDemo() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <jnlp>
          <resources>
            <property name="jnlp.client.mode" value="DEMO"/>
            <property name="jnlp.srp6.login.url" value="https://platform.dukascopy.com/demo/,https://platform2.dukascopy.com/demo/"/>
            <property name="jnlp.login.url" value="https://legacy1.dukascopy.com/,https://legacy2.dukascopy.com/"/>
          </resources>
        </jnlp>
        """
        let config = try JNLPClient.parse(data: Data(xml.utf8))
        XCTAssertEqual(config.clientMode, .demo)
        XCTAssertEqual(config.srp6LoginURLs.map { $0.absoluteString }, [
            "https://platform.dukascopy.com/demo/",
            "https://platform2.dukascopy.com/demo/",
        ])
        XCTAssertEqual(config.legacyLoginURLs.count, 2)
    }

    func testParseLive() throws {
        let xml = """
        <jnlp><resources>
          <property name="jnlp.client.mode" value="LIVE"/>
          <property name="jnlp.srp6.login.url" value="https://platform.dukascopy.com/live/"/>
        </resources></jnlp>
        """
        let config = try JNLPClient.parse(data: Data(xml.utf8))
        XCTAssertEqual(config.clientMode, .live)
        XCTAssertEqual(config.srp6LoginURLs.count, 1)
        XCTAssertTrue(config.legacyLoginURLs.isEmpty)
    }

    func testTrimsWhitespaceInCSV() throws {
        let xml = """
        <jnlp><resources>
          <property name="jnlp.client.mode" value="DEMO"/>
          <property name="jnlp.srp6.login.url" value=" https://a/ , https://b/ "/>
        </resources></jnlp>
        """
        let config = try JNLPClient.parse(data: Data(xml.utf8))
        XCTAssertEqual(config.srp6LoginURLs.map { $0.absoluteString }, [
            "https://a/", "https://b/",
        ])
    }

    func testMissingMode() {
        let xml = """
        <jnlp><resources>
          <property name="jnlp.srp6.login.url" value="https://x/"/>
        </resources></jnlp>
        """
        XCTAssertThrowsError(try JNLPClient.parse(data: Data(xml.utf8))) { err in
            XCTAssertEqual(err as? JNLPError, .missingProperty("jnlp.client.mode"))
        }
    }

    func testMissingSRP6URLs() {
        let xml = """
        <jnlp><resources>
          <property name="jnlp.client.mode" value="DEMO"/>
        </resources></jnlp>
        """
        XCTAssertThrowsError(try JNLPClient.parse(data: Data(xml.utf8))) { err in
            XCTAssertEqual(err as? JNLPError, .missingProperty("jnlp.srp6.login.url"))
        }
    }

    func testUnknownClientMode() {
        let xml = """
        <jnlp><resources>
          <property name="jnlp.client.mode" value="WAT"/>
          <property name="jnlp.srp6.login.url" value="https://x/"/>
        </resources></jnlp>
        """
        XCTAssertThrowsError(try JNLPClient.parse(data: Data(xml.utf8))) { err in
            XCTAssertEqual(err as? JNLPError, .unknownClientMode("WAT"))
        }
    }

    func testEnvironmentURLs() {
        XCTAssertEqual(
            DukascopyEnvironment.demo.jnlpURL.absoluteString,
            "http://platform.dukascopy.com/demo/jforex.jnlp"
        )
        XCTAssertEqual(
            DukascopyEnvironment.live.jnlpURL.absoluteString,
            "http://platform.dukascopy.com/live_3/jforex_3.jnlp"
        )
    }
}
