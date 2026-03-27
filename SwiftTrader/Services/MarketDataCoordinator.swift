import Foundation

final class MarketDataCoordinator: Sendable {
    private let apiService: ForexAPIService
    private let host: String
    private let port: Int

    init(host: String = "localhost", port: Int = 8080) {
        self.apiService = ForexAPIService(baseURL: URL(string: "http://\(host):\(port)")!)
        self.host = host
        self.port = port
    }

    func fetchInstruments() async throws -> [String] {
        try await apiService.fetchInstruments()
    }

    func fetchCandles(
        instrument: String = "EURUSD",
        period: String = "ONE_MIN",
        count: Int = 200
    ) async throws -> [CandleBar] {
        try await apiService.fetchHistory(instrument: instrument, period: period, count: count)
    }

    func streamCandles(
        instrument: String = "EURUSD",
        period: String = "ONE_MIN"
    ) -> AsyncThrowingStream<CandleBar, Error> {
        ForexWebSocketService(instrument: instrument, period: period, host: host, port: port).bars()
    }
}
