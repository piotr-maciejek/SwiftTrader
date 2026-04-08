import Foundation

final class TradingWebSocketService: Sendable {
    private let url: URL

    init(host: String = "localhost", port: Int = 8080) {
        self.url = URL(string: "ws://\(host):\(port)/ws/positions")!
    }

    func snapshots() -> AsyncThrowingStream<TradingSnapshot, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(100)) { continuation in
            let task = URLSession.shared.webSocketTask(with: url)

            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
            }

            task.resume()

            // Ping every 30s to detect stale connections
            let pingTask = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(30))
                    task.sendPing { error in
                        if let error {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }

            Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        switch message {
                        case .string(let text):
                            if let data = text.data(using: .utf8) {
                                let snapshot = try JSONDecoder().decode(TradingSnapshot.self, from: data)
                                continuation.yield(snapshot)
                            }
                        case .data(let data):
                            let snapshot = try JSONDecoder().decode(TradingSnapshot.self, from: data)
                            continuation.yield(snapshot)
                        @unknown default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                pingTask.cancel()
            }
        }
    }
}
