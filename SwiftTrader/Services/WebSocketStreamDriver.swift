import Foundation

/// Generic WebSocket → AsyncThrowingStream<T> driver shared by bars, positions, and news.
///
/// Responsibilities:
/// - Connect, receive messages, JSON-decode each frame into `T`, yield to the continuation.
/// - Send periodic client-side pings as a liveness probe — a ping that errors fails the stream.
/// - Run a watchdog that fails the stream with `WebSocketStreamError.stale` when no *data*
///   frame has arrived for `stalenessTimeout`. Pings deliberately do NOT count as activity:
///   a server that ack's pings while silently dropping the data subscription would otherwise
///   leave `receive()` parked forever and the chart frozen.
///
/// Pass `stalenessTimeout: nil` for streams whose data cadence is genuinely sparse (news,
/// pending orders) — pings still detect a dead peer.
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
        stalenessTimeout: Duration? = .seconds(90)
    ) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let task = URLSession.shared.webSocketTask(with: url)
            let dataActivity = LastActivity()

            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
            }

            task.resume()
            dataActivity.touch()

            let pingTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: pingInterval)
                    if Task.isCancelled { break }
                    task.sendPing { error in
                        if let error {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }

            let watchdog: Task<Void, Never>?
            if let timeout = stalenessTimeout {
                watchdog = Task {
                    // Poll every 5s rather than sleeping the full timeout — keeps shutdown snappy
                    // and lets us surface a precise elapsed-seconds number in the error.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                        if Task.isCancelled { break }
                        let silent = dataActivity.elapsedSeconds
                        let timeoutSeconds = Int(timeout.components.seconds)
                        if silent >= timeoutSeconds {
                            continuation.finish(throwing: WebSocketStreamError.stale(secondsSilent: silent))
                            return
                        }
                    }
                }
            } else {
                watchdog = nil
            }

            Task {
                defer {
                    pingTask.cancel()
                    watchdog?.cancel()
                }
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        dataActivity.touch()
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
