import Foundation

final class PendingOrdersWebSocketService: Sendable {
    private let url: URL

    init(host: String = "localhost", port: Int = 8080) {
        self.url = URL(string: "ws://\(host):\(port)/ws/pending-orders")!
    }

    func snapshots() -> AsyncThrowingStream<PendingOrdersSnapshot, Error> {
        WebSocketStreamDriver.stream(url: url, bufferingPolicy: .bufferingNewest(1))
    }
}
