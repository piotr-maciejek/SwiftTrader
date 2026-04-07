import SwiftUI

struct EMALineState: Codable, Equatable {
    var period: Int
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

extension EMALineState {
    init(from line: EMALine) {
        self.period = line.period
        let nsColor = NSColor(line.color).usingColorSpace(.sRGB) ?? NSColor(line.color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.alpha = Double(a)
    }

    func toEMALine() -> EMALine {
        EMALine(period: period, color: Color(red: red, green: green, blue: blue, opacity: alpha))
    }
}

struct ChartTabState: Codable, Equatable {
    var instrument: String
    var period: String
    var showSessions: Bool
    var showVolume: Bool
    var showEMA: Bool
    var emaConfigs: [EMALineState]
}

struct CorrelationTabState: Codable, Equatable {
    var currency: String
    var period: String
    var showSessions: Bool
    var showVolume: Bool
    var showEMA: Bool
    var emaConfigs: [EMALineState]
}

enum TabContentState: Codable, Equatable {
    case chart(ChartTabState)
    case correlation(CorrelationTabState)
}

struct TabState: Codable, Equatable, Identifiable {
    var id: UUID
    var content: TabContentState
}

struct WorkspaceState: Codable, Equatable {
    var tabs: [TabState]
    var selectedTabIndex: Int?
    var showBottomPanel: Bool
    var showRightPanel: Bool
}
