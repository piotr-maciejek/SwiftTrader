import Foundation

final class TradingWebSocketService: Sendable {
    private let url: URL

    init(host: String = "localhost", port: Int = 8080) {
        self.url = URL(string: "ws://\(host):\(port)/ws/positions")!
    }

    func snapshots() -> AsyncThrowingStream<TradingSnapshot, Error> {
        // Positions snapshots are monotonic — only the latest matters. If we fall behind,
        // drop everything except the freshest so the UI never shows a stale P&L.
        WebSocketStreamDriver.stream(url: url, bufferingPolicy: .bufferingNewest(1))
    }
}
