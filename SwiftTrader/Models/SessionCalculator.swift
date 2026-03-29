import Foundation

enum SessionCalculator {
    static func sessions(
        for bars: [CandleBar],
        visibleRange: Range<Int>,
        definitions: [MarketSession] = MarketSession.all
    ) -> [SessionRect] {
        guard !visibleRange.isEmpty else { return [] }

        var results: [SessionRect] = []

        for session in definitions {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = session.timeZone

            let firstDate = bars[visibleRange.lowerBound].date
            let lastDate = bars[visibleRange.upperBound - 1].date

            let startDay = calendar.startOfDay(for: firstDate)
            let endDay = calendar.startOfDay(for: lastDate)

            var day = calendar.date(byAdding: .day, value: -1, to: startDay)!
            let limit = calendar.date(byAdding: .day, value: 2, to: endDay)!

            while day <= limit {
                let baseComponents = calendar.dateComponents([.year, .month, .day], from: day)

                // Forex session boundaries (rectangle)
                var openComponents = baseComponents
                openComponents.hour = session.sessionOpenHour
                openComponents.minute = session.sessionOpenMinute
                openComponents.second = 0

                var closeComponents = baseComponents
                closeComponents.hour = session.sessionCloseHour
                closeComponents.minute = session.sessionCloseMinute
                closeComponents.second = 0

                // Exchange boundaries (inner lines)
                var exchOpenComponents = baseComponents
                exchOpenComponents.hour = session.exchangeOpenHour
                exchOpenComponents.minute = session.exchangeOpenMinute
                exchOpenComponents.second = 0

                var exchCloseComponents = baseComponents
                exchCloseComponents.hour = session.exchangeCloseHour
                exchCloseComponents.minute = session.exchangeCloseMinute
                exchCloseComponents.second = 0

                guard let sessionOpen = calendar.date(from: openComponents),
                      let sessionClose = calendar.date(from: closeComponents),
                      let exchOpen = calendar.date(from: exchOpenComponents),
                      let exchClose = calendar.date(from: exchCloseComponents),
                      sessionClose > sessionOpen
                else {
                    day = calendar.date(byAdding: .day, value: 1, to: day)!
                    continue
                }

                let searchStart = max(0, visibleRange.lowerBound - 500)
                let searchEnd = min(bars.count, visibleRange.upperBound + 500)

                var firstIdx: Int?
                var lastIdx: Int?
                var hi = -Double.greatestFiniteMagnitude
                var lo = Double.greatestFiniteMagnitude
                var exchOpenIdx: Int?
                var exchCloseIdx: Int?

                for i in searchStart..<searchEnd {
                    let barDate = bars[i].date
                    if barDate >= sessionOpen && barDate < sessionClose {
                        if firstIdx == nil { firstIdx = i }
                        lastIdx = i
                        hi = max(hi, bars[i].high)
                        lo = min(lo, bars[i].low)

                        // First bar at or after exchange open
                        if exchOpenIdx == nil && barDate >= exchOpen {
                            exchOpenIdx = i
                        }
                        // Last bar before exchange close
                        if barDate < exchClose {
                            exchCloseIdx = i
                        }
                    }
                }

                if let first = firstIdx, let last = lastIdx {
                    results.append(SessionRect(
                        session: session,
                        startBarIndex: first,
                        endBarIndex: last,
                        highPrice: hi,
                        lowPrice: lo,
                        exchangeOpenBarIndex: exchOpenIdx,
                        exchangeCloseBarIndex: exchCloseIdx
                    ))
                }

                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
        }

        return results
    }
}
