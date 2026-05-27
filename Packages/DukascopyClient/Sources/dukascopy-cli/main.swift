import ArgumentParser
import DukascopyClient
import Foundation

@main
struct DukascopyCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dukascopy-cli",
        abstract: "Dukascopy native protocol prototyping CLI.",
        subcommands: [JNLPCommand.self, AuthCommand.self]
    )
}

struct JNLPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jnlp",
        abstract: "Fetch and parse the JNLP config for a Dukascopy environment."
    )

    @Option(name: .long, help: "Target environment: demo or live")
    var env: String = "demo"

    @Option(name: .long, help: "Override JNLP URL (takes precedence over --env)")
    var url: String?

    func run() async throws {
        let jnlpURL: URL
        if let raw = url, let parsed = URL(string: raw) {
            jnlpURL = parsed
        } else {
            guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
                throw ValidationError("env must be 'demo' or 'live'")
            }
            jnlpURL = target.jnlpURL
        }

        let config = try await JNLPClient.fetch(from: jnlpURL)
        print("Source:  \(jnlpURL.absoluteString)")
        print("Mode:    \(config.clientMode.rawValue)")
        print("SRP6 servers (\(config.srp6LoginURLs.count)):")
        for url in config.srp6LoginURLs { print("  \(url.absoluteString)") }
        if !config.legacyLoginURLs.isEmpty {
            print("Legacy servers (\(config.legacyLoginURLs.count)):")
            for url in config.legacyLoginURLs { print("  \(url.absoluteString)") }
        }
    }
}

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Run the full SRP6 handshake against an environment and print the result."
    )

    @Option(name: .long, help: "Target environment: demo or live")
    var env: String = "demo"

    @Option(name: .long, help: "Dukascopy login (account number / username)")
    var user: String

    @Option(name: .long, help: "Password")
    var pass: String

    @Option(name: .long, help: "Override the SRP6 base URL (skip JNLP lookup)")
    var url: String?

    @Flag(name: .long, help: "Skip requesting the occasus settings blob")
    var noSettings: Bool = false

    func run() async throws {
        let srp6URLs: [URL]
        if let raw = url, let u = URL(string: raw) {
            srp6URLs = [u]
        } else {
            guard let target = DukascopyEnvironment(rawValue: env.lowercased()) else {
                throw ValidationError("env must be 'demo' or 'live'")
            }
            let config = try await JNLPClient.fetch(from: target.jnlpURL)
            guard !config.srp6LoginURLs.isEmpty else {
                throw ValidationError("JNLP returned no SRP6 servers")
            }
            srp6URLs = config.srp6LoginURLs
        }

        let creds = AuthCredentials(login: user, password: pass)
        let client = AuthClient(requestSettings: !noSettings)

        var lastError: Error?
        for serverURL in srp6URLs {
            do {
                print("Trying \(serverURL.absoluteString) …")
                let result = try await client.authenticate(baseURL: serverURL, credentials: creds)
                printSuccess(result)
                return
            } catch {
                FileHandle.standardError.write(Data("  failed: \(error)\n".utf8))
                lastError = error
                continue
            }
        }
        throw lastError ?? ValidationError("authentication failed against all SRP6 servers")
    }

    private func printSuccess(_ r: AuthSuccess) {
        print("")
        print("Authenticated.")
        print("authApiURLs (\(r.authApiURLs.count)):")
        for u in r.authApiURLs { print("  \(u)") }
        print("ticket:      \(r.ticket)")
        print("packed:      \(r.packedTicket)")
        if let blob = r.settingsBlob {
            print("settings:    \(blob.count) bytes (parsing deferred)")
        }
    }
}
