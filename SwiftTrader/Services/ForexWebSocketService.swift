import Foundation

final class ForexWebSocketService: Sendable {
    private let url: URL

    init(instrument: String = "EURUSD", period: String = "ONE_MIN", host: String = "localhost", port: Int = 8080) {
        self.url = URL(string: "ws://\(host):\(port)/ws/bars?instrument=\(instrument)&period=\(period)")!
    }

    func bars() -> AsyncThrowingStream<CandleBar, Error> {
        // Bars arrive frequently during active hours; a small buffer keeps the chart current
        // without dropping ticks on a transient render stall.
        WebSocketStreamDriver.stream(url: url, bufferingPolicy: .bufferingNewest(8))
    }
}
