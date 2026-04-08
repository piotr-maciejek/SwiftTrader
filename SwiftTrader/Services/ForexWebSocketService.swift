import Foundation

final class ForexWebSocketService: Sendable {
    private let url: URL

    init(instrument: String = "EURUSD", period: String = "ONE_MIN", host: String = "localhost", port: Int = 8080) {
        self.url = URL(string: "ws://\(host):\(port)/ws/bars?instrument=\(instrument)&period=\(period)")!
    }

    func bars() -> AsyncThrowingStream<CandleBar, Error> {
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
                                let bar = try JSONDecoder().decode(CandleBar.self, from: data)
                                continuation.yield(bar)
                            }
                        case .data(let data):
                            let bar = try JSONDecoder().decode(CandleBar.self, from: data)
                            continuation.yield(bar)
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
