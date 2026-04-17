import Foundation

enum BarAggregator {
    /// Groups completed 1H bars into target-period buckets using NY-close rules.
    /// `openPartial` is the most recent forming 1H bar (from the WS); merged into
    /// the currently-forming target bucket if present.
    /// Weekend fillers (Fri 17:00 ET → Sun 17:00 ET) are dropped.
    static func aggregate(
        hourly: [CandleBar],
        openPartial: CandleBar?,
        target: AggregatedPeriod
    ) -> [CandleBar] {
        var inputs = hourly.filter { !isWeekendFiller($0) }

        if let partial = openPartial, !isWeekendFiller(partial) {
            let hasCompleted = inputs.contains { $0.time == partial.time && !$0.partial }
            if !hasCompleted {
                inputs.removeAll { $0.time == partial.time }
                inputs.append(partial)
            }
        }

        let sorted = inputs.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }

        var buckets: [(start: Date, bars: [CandleBar])] = []
        for bar in sorted {
            let bStart = NYTradingCalendar.bucketStart(at: bar.date, period: target)
            if let lastIdx = buckets.indices.last, buckets[lastIdx].start == bStart {
                buckets[lastIdx].bars.append(bar)
            } else {
                buckets.append((bStart, [bar]))
            }
        }

        return buckets.map { bucket in
            let bars = bucket.bars
            let open = bars.first!.open
            let close = bars.last!.close
            let high = bars.map(\.high).max()!
            let low = bars.map(\.low).min()!
            let volume = bars.map(\.volume).reduce(0, +)
            let partial = bars.contains { $0.partial }
            let timeMs = Int64(bucket.start.timeIntervalSince1970 * 1000)
            return CandleBar(
                time: timeMs,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume,
                partial: partial
            )
        }
    }

    /// True when a 1H bar sits inside the Fri 17:00 ET → Sun 17:00 ET market closure.
    static func isWeekendFiller(_ bar: CandleBar) -> Bool {
        let cal = NYTradingCalendar.calendar
        let comps = cal.dateComponents([.weekday, .hour], from: bar.date)
        guard let weekday = comps.weekday, let hour = comps.hour else { return false }
        // Gregorian weekday: 1=Sun, 2=Mon, ..., 6=Fri, 7=Sat
        if weekday == 6 && hour >= 17 { return true }
        if weekday == 7 { return true }
        if weekday == 1 && hour < 17 { return true }
        return false
    }
}
