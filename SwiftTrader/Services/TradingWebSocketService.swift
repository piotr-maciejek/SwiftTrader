import Foundation

final class TradingWebSocketService: Sendable {
    private let url: URL

    init(host: String = "localhost", port: Int = 8080) {
        self.url = URL(string: "ws://\(host):\(port)/ws/positions")!
    }

    func positions() -> AsyncThrowingStream<[Position], Error> {
        AsyncThrowingStream { continuation in
            let task = URLSession.shared.webSocketTask(with: url)

            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
            }

            task.resume()

            Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        switch message {
                        case .string(let text):
                            if let data = text.data(using: .utf8) {
                                let positions = try JSONDecoder().decode([Position].self, from: data)
                                continuation.yield(positions)
                            }
                        case .data(let data):
                            let positions = try JSONDecoder().decode([Position].self, from: data)
                            continuation.yield(positions)
                        @unknown default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
