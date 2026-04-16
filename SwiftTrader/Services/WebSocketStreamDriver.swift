import Foundation

/// Generic WebSocket → AsyncThrowingStream<T> driver shared by bars, positions, and news.
///
/// Responsibilities:
/// - Connect, receive messages, JSON-decode each frame into `T`, yield to the continuation.
/// - Send periodic client-side pings so the server notices a dead peer promptly.
/// - Run a watchdog that fails the stream with `WebSocketStreamError.stale` when no server
///   activity has been observed for `stalenessTimeout` — protects against paths that silently
///   black-hole packets where `receive()` would otherwise hang forever.
///
/// Caller picks `bufferingPolicy` based on how it consumes the stream:
/// - Positions: `.bufferingNewest(1)` — only the latest snapshot matters; drop stale ones.
/// - Bars: `.bufferingNewest(8)` — small headroom for a momentary consumer stall on a burst.
/// - News: `.unbounded` — each item is an edit to the client-side table; losing any is wrong.
enum WebSocketStreamDriver {

    static func stream<T: Decodable & Sendable>(
        url: URL,
        bufferingPolicy: AsyncThrowingStream<T, Error>.Continuation.BufferingPolicy,
        pingInterval: Duration = .seconds(30),
        stalenessTimeout: Duration = .seconds(90)
    ) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let task = URLSession.shared.webSocketTask(with: url)
            let activity = LastActivity()

            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
            }

            task.resume()
            activity.touch()

            let pingTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: pingInterval)
                    if Task.isCancelled { break }
                    task.sendPing { error in
                        if let error {
                            continuation.finish(throwing: error)
                        } else {
                            activity.touch()
                        }
                    }
                }
            }

            let watchdog = Task {
                // Poll every 5s rather than sleeping the full timeout — keeps shutdown snappy
                // and lets us surface a precise elapsed-seconds number in the error.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    if Task.isCancelled { break }
                    let silent = activity.elapsedSeconds
                    let timeoutSeconds = Int(stalenessTimeout.components.seconds)
                    if silent >= timeoutSeconds {
                        continuation.finish(throwing: WebSocketStreamError.stale(secondsSilent: silent))
                        return
                    }
                }
            }

            Task {
                defer {
                    pingTask.cancel()
                    watchdog.cancel()
                }
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        activity.touch()
                        let payload: Data? = switch message {
                        case .string(let text): text.data(using: .utf8)
                        case .data(let data): data
                        @unknown default: nil
                        }
                        guard let data = payload else { continue }
                        switch decode(data, as: T.self) {
                        case .success(let value):
                            continuation.yield(value)
                        case .failure(let error):
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Exposed for tests — decodes a single frame or returns a `.decode` error with a
    /// human-readable description.
    static func decode<T: Decodable>(_ data: Data, as type: T.Type) -> Result<T, WebSocketStreamError> {
        do {
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch {
            return .failure(.decode(String(describing: error)))
        }
    }
}

/// Thread-safe, monotonic "last server activity seen" timestamp shared between the receive
/// loop and the staleness watchdog. Uses `ContinuousClock` so it isn't perturbed by wall-clock
/// adjustments (NTP, sleep/wake).
private final class LastActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last: ContinuousClock.Instant

    init() { self.last = .now }

    func touch() {
        lock.lock()
        last = .now
        lock.unlock()
    }

    var elapsedSeconds: Int {
        lock.lock()
        let snapshot = last
        lock.unlock()
        return Int(snapshot.duration(to: .now).components.seconds)
    }
}
