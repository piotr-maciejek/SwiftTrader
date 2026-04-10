import Foundation

struct NewsItem: Codable, Identifiable, Equatable {
    let id: String
    let type: String            // "NEWS" or "CALENDAR"
    let header: String?
    let publishDate: Int64
    let hot: Bool
    let currencies: Set<String>?
    // Calendar-specific
    let country: String?
    let eventCategory: String?
    let period: String?
    let details: [Detail]?

    struct Detail: Codable, Equatable {
        let description: String?
        let actual: String?
        let previous: String?
        let expected: String?
    }

    /// Best available display title
    var displayTitle: String {
        if let header, !header.isEmpty { return header }
        if let detail = details?.first, let desc = detail.description, !desc.isEmpty { return desc }
        return eventCategory ?? "Market Event"
    }

    var date: Date {
        Date(timeIntervalSince1970: Double(publishDate) / 1000.0)
    }

    var isCalendar: Bool { type == "CALENDAR" }
}
