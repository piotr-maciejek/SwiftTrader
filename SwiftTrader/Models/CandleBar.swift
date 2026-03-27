import Foundation

struct CandleBar: Codable, Identifiable, Equatable {
    let time: Int64
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
    let partial: Bool

    var id: Int64 { time }

    var date: Date {
        Date(timeIntervalSince1970: Double(time) / 1000.0)
    }

    var isBullish: Bool {
        close >= open
    }

    init(time: Int64, open: Double, high: Double, low: Double, close: Double, volume: Double, partial: Bool = false) {
        self.time = time
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.partial = partial
    }
}
