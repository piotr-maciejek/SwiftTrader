import Foundation
import DukascopyClient

/// Standalone `NewsProviding` backed by a native `DukascopySession`. Subscribes to
/// Dukascopy's news/calendar feed (the same source server mode uses via JForex) and maps
/// each `NewsEvent` to the app's `NewsItem`, so the right panel works without jforex-server.
final class NativeNewsCoordinator: NewsProviding, Sendable {
    private let session: DukascopySession?

    init(session: DukascopySession?) {
        self.session = session
    }

    func streamNews() -> AsyncThrowingStream<[NewsItem], Error> {
        guard let session else {
            return AsyncThrowingStream { $0.finish() }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Calendar via DJ_LIVE_CALENDAR over a window around today (the panel shows
                    // today's events); headlines via FXSPIDER_NEWS (its window is open-ended,
                    // matching the desktop client's Long.MIN_VALUE sentinel). A subscribe
                    // failure finishes the stream with the error so the consumer can surface
                    // it (and retry) instead of leaving a silently-empty panel.
                    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                    let dayMs: Int64 = 24 * 60 * 60 * 1000
                    try await session.subscribeNews(
                        sources: ["DJ_LIVE_CALENDAR"], from: nowMs - 2 * dayMs, to: nowMs + 3 * dayMs,
                        calendarType: "ICC")
                    try await session.subscribeNews(
                        sources: ["FXSPIDER_NEWS"], from: Int64.min, to: Int64.min, calendarType: nil)

                    for await event in await session.newsEvents() {
                        if Task.isCancelled { break }
                        if let item = Self.map(event) {
                            continuation.yield([item])
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Map a wire `NewsEvent` to a `NewsItem`. Calendar events carry the embedded
    /// `CalendarEventMsg` plus the wrapping story's metadata; plain stories are news.
    static func map(_ event: NewsEvent) -> NewsItem? {
        switch event {
        case .calendar(let cal, let story):
            guard let id = story.newsId ?? cal.eventId else { return nil }
            let details = cal.details.map {
                NewsItem.Detail(description: $0.description, actual: $0.actual,
                                previous: $0.previous, expected: $0.expected)
            }
            // Unset times arrive as Long.MIN_VALUE — take the first positive of the
            // story's publish time, the scheduled timestamp, or the calendar day.
            let times: [Int64] = [story.publishDate, cal.eventTimestamp, cal.eventDate].compactMap { $0 }
            let publish: Int64 = times.first { $0 > 0 } ?? 0
            // Flag high-importance releases as "hot" so the panel marks them.
            let hot = story.hot || cal.details.contains { $0.importance?.uppercased() == "H" }
            return NewsItem(
                id: id, type: "CALENDAR",
                header: story.header.flatMap { $0.isEmpty ? nil : $0 } ?? cal.description,
                publishDate: publish, hot: hot,
                currencies: story.currencies.isEmpty ? nil : story.currencies,
                country: cal.country, eventCategory: cal.eventCategory, period: cal.period,
                details: details.isEmpty ? nil : details)
        case .story(let s):
            guard let id = s.newsId else { return nil }
            return NewsItem(
                id: id, type: "NEWS", header: s.header,
                publishDate: (s.publishDate ?? 0) > 0 ? s.publishDate! : 0,
                hot: s.hot,
                currencies: s.currencies.isEmpty ? nil : s.currencies,
                country: nil, eventCategory: nil, period: nil, details: nil)
        }
    }
}
