import Foundation

final class PendingOrdersWebSocketService: Sendable {
    private let url: URL

    init(host: String = "localhost", port: Int = 8080) {
        self.url = URL(string: "ws://\(host):\(port)/ws/pending-orders")!
    }

    func snapshots() -> AsyncThrowingStream<PendingOrdersSnapshot, Error> {
        // Pending-order changes are user-driven and can be silent for long stretches —
        // disable the data-staleness watchdog; pings still kill a dead peer.
        WebSocketStreamDriver.stream(url: url, bufferingPolicy: .bufferingNewest(1), stalenessTimeout: nil)
    }
}
