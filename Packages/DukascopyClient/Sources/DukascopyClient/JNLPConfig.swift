import Foundation

public enum DukascopyEnvironment: String, Sendable {
    case demo
    case live

    public var jnlpURL: URL {
        switch self {
        case .demo: URL(string: "http://platform.dukascopy.com/demo/jforex.jnlp")!
        case .live: URL(string: "http://platform.dukascopy.com/live_3/jforex_3.jnlp")!
        }
    }
}

public enum ClientMode: String, Sendable, CaseIterable {
    case live = "LIVE"
    case demo = "DEMO"
}

public struct JNLPConfig: Sendable, Equatable {
    public let clientMode: ClientMode
    public let srp6LoginURLs: [URL]
    public let legacyLoginURLs: [URL]

    public init(clientMode: ClientMode, srp6LoginURLs: [URL], legacyLoginURLs: [URL]) {
        self.clientMode = clientMode
        self.srp6LoginURLs = srp6LoginURLs
        self.legacyLoginURLs = legacyLoginURLs
    }
}

public enum JNLPError: Error, CustomStringConvertible, Equatable {
    case httpError(Int)
    case xmlParseFailed(String)
    case missingProperty(String)
    case unknownClientMode(String)

    public var description: String {
        switch self {
        case .httpError(let code): "HTTP \(code) fetching JNLP"
        case .xmlParseFailed(let msg): "JNLP XML parse failed: \(msg)"
        case .missingProperty(let name): "JNLP missing required property: \(name)"
        case .unknownClientMode(let v): "Unknown jnlp.client.mode value: \(v)"
        }
    }
}

public enum JNLPClient {
    public static func fetch(from url: URL, session: URLSession = .shared) async throws -> JNLPConfig {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw JNLPError.httpError(http.statusCode)
        }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> JNLPConfig {
        let collector = PropertyCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else {
            let msg = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw JNLPError.xmlParseFailed(msg)
        }

        guard let modeStr = collector.properties["jnlp.client.mode"] else {
            throw JNLPError.missingProperty("jnlp.client.mode")
        }
        guard let mode = ClientMode(rawValue: modeStr) else {
            throw JNLPError.unknownClientMode(modeStr)
        }
        guard let srp6Str = collector.properties["jnlp.srp6.login.url"] else {
            throw JNLPError.missingProperty("jnlp.srp6.login.url")
        }
        let legacyStr = collector.properties["jnlp.login.url"] ?? ""

        return JNLPConfig(
            clientMode: mode,
            srp6LoginURLs: splitCSVURLs(srp6Str),
            legacyLoginURLs: splitCSVURLs(legacyStr)
        )
    }

    private static func splitCSVURLs(_ csv: String) -> [URL] {
        csv.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
    }

    private final class PropertyCollector: NSObject, XMLParserDelegate {
        var properties: [String: String] = [:]

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            guard elementName == "property" else { return }
            guard let name = attributeDict["name"], let value = attributeDict["value"] else { return }
            properties[name] = value
        }
    }
}
