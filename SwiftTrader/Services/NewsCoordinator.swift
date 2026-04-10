import Foundation

final class NewsCoordinator: Sendable {
    private let host: String
    private let port: Int

    init(host: String = "localhost", port: Int = 8080) {
        self.host = host
        self.port = port
    }

    func streamNews() -> AsyncThrowingStream<[NewsItem], Error> {
        let url = URL(string: "ws://\(host):\(port)/ws/news")!
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(50)) { continuation in
            let task = URLSession.shared.webSocketTask(with: url)
            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
            }
            task.resume()

            let pingTask = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(30))
                    task.sendPing { error in
                        if let error { continuation.finish(throwing: error) }
                    }
                }
            }

            Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data? = switch message {
                        case .string(let text): text.data(using: .utf8)
                        case .data(let d): d
                        @unknown default: nil
                        }
                        if let data {
                            let items = try JSONDecoder().decode([NewsItem].self, from: data)
                            continuation.yield(items)
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
