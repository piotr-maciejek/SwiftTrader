import Foundation
import Testing
@testable import DukascopyClient

@Suite("JNLP config")
struct JNLPConfigTests {
    @Test("Parses a minimal DEMO config")
    func parseMinimalDemo() throws {
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
        #expect(config.clientMode == .demo)
        #expect(config.srp6LoginURLs.map { $0.absoluteString } == [
            "https://platform.dukascopy.com/demo/",
            "https://platform2.dukascopy.com/demo/",
        ])
        #expect(config.legacyLoginURLs.count == 2)
    }

    @Test("Parses a LIVE config with no legacy URLs")
    func parseLive() throws {
        let xml = """
        <jnlp><resources>
          <property name="jnlp.client.mode" value="LIVE"/>
          <property name="jnlp.srp6.login.url" value="https://platform.dukascopy.com/live/"/>
        </resources></jnlp>
        """
        let config = try JNLPClient.parse(data: Data(xml.utf8))
        #expect(config.clientMode == .live)
        #expect(config.srp6LoginURLs.count == 1)
        #expect(config.legacyLoginURLs.isEmpty)
    }

    @Test("Trims whitespace in CSV URL lists")
    func trimsWhitespaceInCSV() throws {
        let xml = """
        <jnlp><resources>
          <property name="jnlp.client.mode" value="DEMO"/>
          <property name="jnlp.srp6.login.url" value=" https://a/ , https://b/ "/>
        </resources></jnlp>
        """
        let config = try JNLPClient.parse(data: Data(xml.utf8))
        #expect(config.srp6LoginURLs.map { $0.absoluteString } == ["https://a/", "https://b/"])
    }

    @Test("Missing client.mode throws")
    func missingMode() {
        let xml = """
        <jnlp><resources>
          <property name="jnlp.srp6.login.url" value="https://x/"/>
        </resources></jnlp>
        """
        #expect(throws: JNLPError.missingProperty("jnlp.client.mode")) {
            try JNLPClient.parse(data: Data(xml.utf8))
        }
    }

    @Test("Missing SRP6 URLs throws")
    func missingSRP6URLs() {
        let xml = """
        <jnlp><resources>
          <property name="jnlp.client.mode" value="DEMO"/>
        </resources></jnlp>
        """
        #expect(throws: JNLPError.missingProperty("jnlp.srp6.login.url")) {
            try JNLPClient.parse(data: Data(xml.utf8))
        }
    }

    @Test("Unknown client mode throws")
    func unknownClientMode() {
        let xml = """
        <jnlp><resources>
          <property name="jnlp.client.mode" value="WAT"/>
          <property name="jnlp.srp6.login.url" value="https://x/"/>
        </resources></jnlp>
        """
        #expect(throws: JNLPError.unknownClientMode("WAT")) {
            try JNLPClient.parse(data: Data(xml.utf8))
        }
    }

    @Test("Environment JNLP URLs are correct")
    func environmentURLs() {
        #expect(DukascopyEnvironment.demo.jnlpURL.absoluteString
            == "http://platform.dukascopy.com/demo/jforex.jnlp")
        #expect(DukascopyEnvironment.live.jnlpURL.absoluteString
            == "http://platform.dukascopy.com/live_3/jforex_3.jnlp")
    }
}
