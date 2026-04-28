import Foundation

final class NewsCoordinator: Sendable {
    private let host: String
    private let port: Int

    init(host: String = "localhost", port: Int = 8080) {
        self.host = host
        self.port = port
    }

    func streamNews() -> AsyncThrowingStream<[NewsItem], Error> {
        // News batches arrive infrequently (calendar releases, breaking news) but each item is
        // an upsert to the shared client-side table — dropping any would lose an event forever.
        // Unbounded is safe because throughput is bounded by human news cadence.
        let url = URL(string: "ws://\(host):\(port)/ws/news")!
        // News cadence is human-driven and bursty — disable the data-staleness watchdog;
        // pings still kill the stream if the peer goes dead.
        return WebSocketStreamDriver.stream(url: url, bufferingPolicy: .unbounded, stalenessTimeout: nil)
    }
}
