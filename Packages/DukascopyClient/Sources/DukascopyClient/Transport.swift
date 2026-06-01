import Foundation
import Network

public struct ServerAddress: Sendable, Equatable, CustomStringConvertible {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Parses `"host:port"` strings as returned in the `authApiURLs[]` list.
    /// Defaults to port 443 if no `:port` suffix is present.
    public static func parse(_ s: String) -> ServerAddress? {
        guard let colon = s.lastIndex(of: ":") else {
            return ServerAddress(host: s, port: 443)
        }
        let host = String(s[..<colon])
        let portStr = s[s.index(after: colon)...]
        guard let port = UInt16(portStr) else { return nil }
        return ServerAddress(host: host, port: port)
    }

    public var description: String { "\(host):\(port)" }
}

public enum TransportError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case closed
    case timedOut
    case badHelloMagic(received: String)
    case badHelloBodyLength(Int)
    case versionRejected(Int)
    case versionNotSupported(Int)

    public var description: String {
        switch self {
        case .connectionFailed(let msg): "transport connect failed: \(msg)"
        case .readFailed(let msg):       "transport read failed: \(msg)"
        case .writeFailed(let msg):      "transport write failed: \(msg)"
        case .closed:                    "transport closed by peer"
        case .timedOut:                  "transport operation timed out"
        case .badHelloMagic(let r):      "version negotiation: bad magic, got \"\(r)\""
        case .badHelloBodyLength(let n): "version negotiation: bad body length \(n), expected 4"
        case .versionRejected(let v):    "server rejected version negotiation (error code \(v))"
        case .versionNotSupported(let v):"server picked version \(v) which we do not support"
        }
    }
}

/// Length-prefix framed binary transport. Negotiates the version handshake on connect.
public actor Transport {
    public static let supportedVersions: [Int32] = [1, 2, 3, 4, 5, 6, 7]
    public static let helloMagic = "DDS4TRANSPORT"
    public static let maxMessageSize = 10 * 1024 * 1024

    public let address: ServerAddress
    public private(set) var negotiatedVersion: Int32?

    private var connection: NWConnection?
    private var readBuffer = Data()

    public init(address: ServerAddress) {
        self.address = address
    }

    /// Opens the TLS connection and performs the version handshake. After this
    /// returns, `negotiatedVersion` is set and the connection is ready for
    /// length-prefix framed messages.
    public func connect(timeout: TimeInterval = 15) async throws {
        try await openTLS(timeout: timeout)
        try await negotiateVersion()
    }

    public func close() async {
        connection?.cancel()
        connection = nil
        readBuffer.removeAll()
    }

    /// Sends a single framed message (`uint32 length + payload`).
    public func sendFrame(_ payload: Data) async throws {
        guard negotiatedVersion != nil else {
            throw TransportError.writeFailed("send before version negotiation")
        }
        guard payload.count <= Self.maxMessageSize else {
            throw TransportError.writeFailed("payload \(payload.count) > \(Self.maxMessageSize)")
        }
        var frame = Data(capacity: 4 + payload.count)
        frame.appendUInt32BE(UInt32(payload.count))
        frame.append(payload)
        try await sendRaw(frame)
    }

    /// Reads the next framed payload. Blocks until the full frame arrives or the
    /// connection drops.
    public func receiveFrame() async throws -> Data {
        let lengthBytes = try await readExact(4)
        let length = lengthBytes.readUInt32BE(at: 0)
        guard Int(length) <= Self.maxMessageSize else {
            throw TransportError.readFailed("frame length \(length) > \(Self.maxMessageSize)")
        }
        return try await readExact(Int(length))
    }

    // MARK: - TLS connection

    private func openTLS(timeout: TimeInterval) async throws {
        let tlsOptions = NWProtocolTLS.Options()
        // Network.framework picks TLS 1.2/1.3 by default; SNI uses the host below.
        let parameters = NWParameters(tls: tlsOptions)
        let endpoint = NWEndpoint.hostPort(
            host: .init(address.host),
            port: .init(integerLiteral: address.port)
        )
        let conn = NWConnection(to: endpoint, using: parameters)
        self.connection = conn

        // Race `.ready` against a timeout so an unreachable host fails into `.failed`
        // with a timeout instead of hanging forever. The latch makes the first of
        // {ready, connection-failure, timeout} win; the loser's resume is a no-op.
        let latch = VoidContinuationLatch()
        var timeoutTask: Task<Void, Never>?
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    latch.tryResumeFailure(cont, TransportError.timedOut)
                }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        latch.tryResumeSuccess(cont)
                    case .failed(let err):
                        latch.tryResumeFailure(cont, TransportError.connectionFailed(err.debugDescription))
                    case .cancelled:
                        latch.tryResumeFailure(cont, TransportError.closed)
                    default:
                        break
                    }
                }
                conn.start(queue: .global(qos: .userInitiated))
            }
        } catch {
            // Tear down the dangling NWConnection on timeout/failure so it can't linger.
            timeoutTask?.cancel()
            conn.cancel()
            self.connection = nil
            throw error
        }
        timeoutTask?.cancel()
    }

    // MARK: - Version negotiation

    private func negotiateVersion() async throws {
        // Send: "DDS4TRANSPORT" + uint16(N*4) + N x int32 versions.
        var hello = Data(capacity: 13 + 2 + Self.supportedVersions.count * 4)
        hello.append(Self.helloMagic.data(using: .ascii)!)
        hello.appendUInt16BE(UInt16(Self.supportedVersions.count * 4))
        for v in Self.supportedVersions {
            hello.appendInt32BE(v)
        }
        try await sendRaw(hello)

        // Receive: 13 + 2 + 4 bytes total.
        let expectedSize = Self.helloMagic.count + 2 + 4
        let response = try await readExact(expectedSize)
        let magicBytes = response.prefix(Self.helloMagic.count)
        let magic = String(data: magicBytes, encoding: .ascii) ?? ""
        guard magic == Self.helloMagic else {
            throw TransportError.badHelloMagic(received: magic)
        }
        let bodyLen = response.readUInt16BE(at: Self.helloMagic.count)
        guard bodyLen == 4 else {
            throw TransportError.badHelloBodyLength(Int(bodyLen))
        }
        let version = response.readInt32BE(at: Self.helloMagic.count + 2)
        guard version > 0 else {
            throw TransportError.versionRejected(Int(version))
        }
        guard Self.supportedVersions.contains(version) else {
            throw TransportError.versionNotSupported(Int(version))
        }
        self.negotiatedVersion = version
    }

    // MARK: - Raw I/O helpers

    private func sendRaw(_ data: Data) async throws {
        guard let conn = connection else { throw TransportError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: TransportError.writeFailed(error.debugDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func readExact(_ n: Int) async throws -> Data {
        while readBuffer.count < n {
            try await readMore()
        }
        let chunk = readBuffer.prefix(n)
        readBuffer.removeFirst(n)
        return Data(chunk)
    }

    private func readMore() async throws {
        guard let conn = connection else { throw TransportError.closed }
        let chunk: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: TransportError.readFailed(error.debugDescription))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: TransportError.closed)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
        readBuffer.append(chunk)
    }
}

// MARK: - One-shot continuation latch (Void-returning only)

private final class VoidContinuationLatch: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()

    func tryResumeSuccess(_ cont: CheckedContinuation<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        cont.resume()
    }

    func tryResumeFailure(_ cont: CheckedContinuation<Void, Error>, _ error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        cont.resume(throwing: error)
    }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendInt32BE(_ value: Int32) {
        appendUInt32BE(UInt32(bitPattern: value))
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return (UInt16(self[i]) << 8) | UInt16(self[i + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return (UInt32(self[i]) << 24)
            | (UInt32(self[i + 1]) << 16)
            | (UInt32(self[i + 2]) << 8)
            |  UInt32(self[i + 3])
    }

    func readInt32BE(at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32BE(at: offset))
    }
}
