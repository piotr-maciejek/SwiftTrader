import SwiftUI

struct RightPanel: View {
    var newsItems: [NewsItem]
    @State private var showHeadlines = false
    @State private var expandedRowIDs: Set<String> = []

    private var rows: [(id: String, time: String, country: String, hot: Bool, event: String, previous: String, expected: String, actual: String, actualColor: Color)] {
        let calendar = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"

        return newsItems
            .filter { (showHeadlines || $0.isCalendar) && calendar.isDateInToday($0.date) }
            .sorted { $0.publishDate < $1.publishDate }
            .flatMap { item -> [(id: String, time: String, country: String, hot: Bool, event: String, previous: String, expected: String, actual: String, actualColor: Color)] in
                let time = fmt.string(from: item.date)
                let country = item.country ?? ""
                guard let details = item.details, !details.isEmpty else {
                    return [(id: item.id, time: time, country: country, hot: item.hot, event: item.displayTitle, previous: "", expected: "", actual: "", actualColor: .primary)]
                }
                return details.enumerated().map { i, d in
                    let act = d.actual ?? ""
                    let exp = d.expected ?? ""
                    let color = colorForActual(act, expected: exp)
                    return (id: "\(item.id)_\(i)", time: i == 0 ? time : "", country: i == 0 ? country : "", hot: i == 0 && item.hot, event: d.description ?? "", previous: d.previous ?? "", expected: exp, actual: act, actualColor: color)
                }
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            headerRow
            Divider()

            if rows.isEmpty {
                Text("No events today")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.id) { row in
                            dataRow(row)
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
        .frame(width: 620)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $showHeadlines) {
                Label("Headlines", systemImage: "newspaper")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(showHeadlines ? "Hide general headlines" : "Show general headlines")

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Time").frame(width: 44, alignment: .leading)
            Text("").frame(width: 26)
            Text("Event").frame(maxWidth: .infinity, alignment: .leading)
            Text("Prev").frame(width: 64, alignment: .trailing)
            Text("Exp").frame(width: 64, alignment: .trailing)
            Text("Act").frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func dataRow(_ row: (id: String, time: String, country: String, hot: Bool, event: String, previous: String, expected: String, actual: String, actualColor: Color)) -> some View {
        let expanded = expandedRowIDs.contains(row.id)
        return HStack(alignment: .top, spacing: 0) {
            Text(row.time)
                .frame(width: 44, alignment: .leading)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text(countryFlag(row.country))
                if row.hot {
                    Circle().fill(.red).frame(width: 5, height: 5)
                }
            }
            .frame(width: 26)
            Text(row.event)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(expanded ? nil : 1)
                .foregroundStyle(.primary)
            Text(row.previous)
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(row.expected)
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(row.actual)
                .frame(width: 64, alignment: .trailing)
                .fontWeight(.semibold)
                .foregroundStyle(row.actualColor)
        }
        .background(expanded ? Color.secondary.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { toggleExpanded(row.id) }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private func toggleExpanded(_ id: String) {
        if expandedRowIDs.contains(id) {
            expandedRowIDs.remove(id)
        } else {
            expandedRowIDs.insert(id)
        }
    }

    private func colorForActual(_ actual: String, expected: String) -> Color {
        guard let a = parseNumber(actual), let e = parseNumber(expected) else { return .primary }
        if a > e { return .green }
        if a < e { return .red }
        return .primary
    }

    private func parseNumber(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: "%", with: "")
                       .replacingOccurrences(of: "+", with: "")
                       .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    private static let iso3to2: [String: String] = [
        "BRA": "BR", "MEX": "MX", "TW": "TW", "KR": "KR", "TH": "TH",
        "MY": "MY", "IN": "IN", "CN": "CN", "CZ": "CZ", "DK": "DK",
        "NO": "NO", "TR": "TR", "DE": "DE", "CA": "CA", "US": "US",
        "JP": "JP", "GB": "GB", "AU": "AU", "NZ": "NZ", "CH": "CH",
        "SE": "SE", "ZA": "ZA", "SG": "SG", "HK": "HK", "PL": "PL",
        "HU": "HU", "RO": "RO", "CL": "CL", "CO": "CO", "PH": "PH",
        "ID": "ID", "IL": "IL", "RU": "RU", "AR": "AR", "PE": "PE",
    ]

    private func countryFlag(_ country: String) -> String {
        guard !country.isEmpty else { return "" }
        let code = Self.iso3to2[country.uppercased()] ?? (country.count == 2 ? country.uppercased() : "")
        guard code.count == 2 else { return country }
        let base: UInt32 = 127397
        return String(code.unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value)
        }.map { Character($0) })
    }
}
