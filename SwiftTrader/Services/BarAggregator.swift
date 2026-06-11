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

    /// Aggregates source bars onto a fixed epoch grid of `granularityMs` (e.g. 5m/15m/30m
    /// from 1m — used in native mode where the datafeed only stores 1m/1H/Daily). Like the
    /// 3m path: pure epoch grid, no weekend-filler dropping, since the grid divides an hour
    /// evenly and the source already excludes weekends.
    static func aggregateFixedGrid(
        _ source: [CandleBar], granularityMs: Int64, openPartial: CandleBar?
    ) -> [CandleBar] {
        var inputs = source
        if let partial = openPartial {
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
            let bStart = fixedGridBucketStartMs(bar.time, granularityMs)
            if let lastIdx = buckets.indices.last, buckets[lastIdx].startMs == bStart {
                buckets[lastIdx].bars.append(bar)
            } else {
                buckets.append((bStart, [bar]))
            }
        }

        return buckets.map { bucket in
            let bars = bucket.bars
            return CandleBar(
                time: bucket.startMs,
                open: bars.first!.open,
                high: bars.map(\.high).max()!,
                low: bars.map(\.low).min()!,
                close: bars.last!.close,
                volume: bars.map(\.volume).reduce(0, +),
                partial: bars.contains { $0.partial }
            )
        }
    }

    /// Calendar used to group DAILY bars into weeks: Sunday-first, NY timezone, so
    /// the FX trading week (Sun 17:00 ET open → Fri close) lands in one bucket and
    /// matches the NY-session daily chart. Sunday's candle is intentionally kept.
    private static let weekGroupingCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = NYTradingCalendar.nyTZ
        c.firstWeekday = 1            // Sunday
        c.minimumDaysInFirstWeek = 1
        return c
    }()

    /// Epoch ms of the start (Sunday 00:00 ET) of the Sunday-first NY week containing
    /// `date`. Used both to label weekly bars and to bucket live ticks so the forming
    /// weekly bar shares the historical bar's timestamp.
    static func weekStartMs(_ date: Date) -> Int64 {
        let cal = weekGroupingCalendar
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let start = cal.date(from: comps) ?? cal.startOfDay(for: date)
        return Int64((start.timeIntervalSince1970 * 1000).rounded())
    }

    /// Groups source bars (weekend-stripped 1H — the same series the daily chart uses)
    /// into weekly candles on FX-week boundaries (Sunday-first, NY-aligned). Weekly is
    /// canonical — there's only one sensible grouping. Built from 1H rather than DAILY
    /// because Dukascopy serves no weekly history and its deep daily .bi5 files 503;
    /// 1H is deep and reliable, and a weekly candle then spans exactly that week's daily
    /// candles. `openPartial` is the most recent forming source bar, merged into the
    /// current week.
    static func aggregateWeekly(_ daily: [CandleBar], openPartial: CandleBar?) -> [CandleBar] {
        var inputs = daily
        if let partial = openPartial {
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
            let bStart = weekStartMs(bar.date)
            if let lastIdx = buckets.indices.last, buckets[lastIdx].startMs == bStart {
                buckets[lastIdx].bars.append(bar)
            } else {
                buckets.append((bStart, [bar]))
            }
        }

        return buckets.map { bucket in
            let bars = bucket.bars
            return CandleBar(
                time: bucket.startMs,
                open: bars.first!.open,
                high: bars.map(\.high).max()!,
                low: bars.map(\.low).min()!,
                close: bars.last!.close,
                volume: bars.map(\.volume).reduce(0, +),
                partial: bars.contains { $0.partial }
            )
        }
    }

    /// Start (epoch ms) of the bucket containing `now` for a derived target — any
    /// aggregated bar at/after this is still FORMING. Used to force `partial` on the
    /// open bucket when the source series alone can't reveal it (a cache rebuild sees
    /// only completed source bars, so the forming bucket would aggregate as complete
    /// and get persisted with a frozen close).
    static func formingBucketStartMs(target: AggregatedPeriod, now: Date) -> Int64 {
        if target.isSessionAligned {
            let start = NYTradingCalendar.bucketStart(at: now, period: target)
            return Int64((start.timeIntervalSince1970 * 1000).rounded())
        }
        return fixedGridBucketStartMs(Int64(now.timeIntervalSince1970 * 1000), 180_000)
    }

    /// Re-flag every bar at/after `formingStartMs` as `partial` (already-partial bars
    /// pass through). Bars before the forming bucket are returned untouched.
    static func markForming(_ bars: [CandleBar], formingStartMs: Int64) -> [CandleBar] {
        bars.map { bar in
            guard bar.time >= formingStartMs, !bar.partial else { return bar }
            return CandleBar(time: bar.time, open: bar.open, high: bar.high, low: bar.low,
                             close: bar.close, volume: bar.volume, partial: true)
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
