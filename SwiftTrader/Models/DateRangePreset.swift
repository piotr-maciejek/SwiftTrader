import Foundation

enum DateRangePreset: String, CaseIterable, Identifiable {
    case today
    case yesterday
    case thisWeek
    case previousWeek
    case thisMonth
    case previousMonth
    case thisYear
    case previousYear
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This Week"
        case .previousWeek: return "Previous Week"
        case .thisMonth: return "This Month"
        case .previousMonth: return "Previous Month"
        case .thisYear: return "This Year"
        case .previousYear: return "Previous Year"
        case .custom: return "Custom"
        }
    }

    /// Translate a preset into a ClosedRange<Date>. `.custom` is a pass-through of the
    /// caller-supplied range; every other preset ignores `custom` and computes from
    /// calendar boundaries honoring `calendar.firstWeekday` and `calendar.timeZone`.
    func range(now: Date = .now,
               calendar: Calendar = .current,
               custom: ClosedRange<Date>? = nil) -> ClosedRange<Date> {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
            return start...end

        case .yesterday:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -1, to: today)!
            let end = today.addingTimeInterval(-1)
            return start...end

        case .thisWeek:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)!.start
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!.addingTimeInterval(-1)
            return start...end

        case .previousWeek:
            let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
            let start = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart)!
            let end = thisWeekStart.addingTimeInterval(-1)
            return start...end

        case .thisMonth:
            let start = calendar.dateInterval(of: .month, for: now)!.start
            let end = calendar.date(byAdding: .month, value: 1, to: start)!.addingTimeInterval(-1)
            return start...end

        case .previousMonth:
            let thisMonthStart = calendar.dateInterval(of: .month, for: now)!.start
            let start = calendar.date(byAdding: .month, value: -1, to: thisMonthStart)!
            let end = thisMonthStart.addingTimeInterval(-1)
            return start...end

        case .thisYear:
            let start = calendar.dateInterval(of: .year, for: now)!.start
            let end = calendar.date(byAdding: .year, value: 1, to: start)!.addingTimeInterval(-1)
            return start...end

        case .previousYear:
            let thisYearStart = calendar.dateInterval(of: .year, for: now)!.start
            let start = calendar.date(byAdding: .year, value: -1, to: thisYearStart)!
            let end = thisYearStart.addingTimeInterval(-1)
            return start...end

        case .custom:
            if let custom { return custom }
            let start = calendar.startOfDay(for: now)
            return start...now
        }
    }
}
