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
        // Weekend-filler dropping only applies to NY-session-aligned periods
        // (4H/Daily from 1H). Fixed-grid intraday periods (3m from 1m) must NOT
        // run it: the server already strips weekends from ONE_MIN via
        // Filter.WEEKENDS, and isWeekendFiller's Fri≥17 / Sun<17 hour windows
        // would wrongly drop legitimate session-edge minute bars.
        var inputs = target.isSessionAligned
            ? hourly.filter { !isWeekendFiller($0) }
            : hourly

        if let partial = openPartial,
           !target.isSessionAligned || !isWeekendFiller(partial) {
            let hasCompleted = inputs.contains { $0.time == partial.time && !$0.partial }
            if !hasCompleted {
                inputs.removeAll { $0.time == partial.time }
                inputs.append(partial)
            }
        }

        let sorted = inputs.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }

        var buckets: [(startMs: Int64, bars: [CandleBar])] = []
        for bar in sorted {
            let bStart = bucketStartMs(for: bar, target: target)
            if let lastIdx = buckets.indices.last, buckets[lastIdx].startMs == bStart {
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
            return CandleBar(
                time: bucket.startMs,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume,
                partial: partial
            )
        }
    }

    /// Bucket-start epoch ms for `bar` under `target`. Session-aligned periods
    /// (4H/Daily) defer to `NYTradingCalendar`; fixed-grid periods (3m) use a
    /// pure epoch grid that needs no timezone/DST/session logic.
    private static func bucketStartMs(for bar: CandleBar, target: AggregatedPeriod) -> Int64 {
        if target.isSessionAligned {
            let start = NYTradingCalendar.bucketStart(at: bar.date, period: target)
            return Int64((start.timeIntervalSince1970 * 1000).rounded())
        }
        return fixedGridBucketStartMs(bar.time, 180_000)
    }

    /// Floor `timeMs` to the start of its fixed `granularityMs` grid cell.
    /// Because 180 000 ms (3 min) divides an hour evenly, the grid is identical
    /// regardless of epoch/hour anchoring — no timezone or DST handling needed.
    static func fixedGridBucketStartMs(_ timeMs: Int64, _ granularityMs: Int64) -> Int64 {
        (timeMs / granularityMs) * granularityMs
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
