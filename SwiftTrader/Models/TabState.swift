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
    var showATR: Bool
    var atrPeriod: Int

    init(instrument: String, period: String, showSessions: Bool, showVolume: Bool,
         showEMA: Bool, emaConfigs: [EMALineState], showATR: Bool = true, atrPeriod: Int = 14) {
        self.instrument = instrument; self.period = period
        self.showSessions = showSessions; self.showVolume = showVolume
        self.showEMA = showEMA; self.emaConfigs = emaConfigs
        self.showATR = showATR; self.atrPeriod = atrPeriod
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instrument = try c.decode(String.self, forKey: .instrument)
        period = try c.decode(String.self, forKey: .period)
        showSessions = try c.decode(Bool.self, forKey: .showSessions)
        showVolume = try c.decode(Bool.self, forKey: .showVolume)
        showEMA = try c.decode(Bool.self, forKey: .showEMA)
        emaConfigs = try c.decode([EMALineState].self, forKey: .emaConfigs)
        showATR = try c.decodeIfPresent(Bool.self, forKey: .showATR) ?? true
        atrPeriod = try c.decodeIfPresent(Int.self, forKey: .atrPeriod) ?? 14
    }
}

struct CorrelationTabState: Codable, Equatable {
    var currency: String
    var period: String
    var showSessions: Bool
    var showVolume: Bool
    var showEMA: Bool
    var emaConfigs: [EMALineState]
    var showATR: Bool
    var atrPeriod: Int

    init(currency: String, period: String, showSessions: Bool, showVolume: Bool,
         showEMA: Bool, emaConfigs: [EMALineState], showATR: Bool = true, atrPeriod: Int = 14) {
        self.currency = currency; self.period = period
        self.showSessions = showSessions; self.showVolume = showVolume
        self.showEMA = showEMA; self.emaConfigs = emaConfigs
        self.showATR = showATR; self.atrPeriod = atrPeriod
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currency = try c.decode(String.self, forKey: .currency)
        period = try c.decode(String.self, forKey: .period)
        showSessions = try c.decode(Bool.self, forKey: .showSessions)
        showVolume = try c.decode(Bool.self, forKey: .showVolume)
        showEMA = try c.decode(Bool.self, forKey: .showEMA)
        emaConfigs = try c.decode([EMALineState].self, forKey: .emaConfigs)
        showATR = try c.decodeIfPresent(Bool.self, forKey: .showATR) ?? true
        atrPeriod = try c.decodeIfPresent(Int.self, forKey: .atrPeriod) ?? 14
    }
}

enum TFZoom: String, Codable, Equatable, CaseIterable {
    case standard
    case intraday

    /// Periods rendered in the 2x2 grid, top-left → bottom-right.
    var periods: [String] {
        switch self {
        case .standard: return ["DAILY", "FOUR_HOURS", "ONE_HOUR", "FIFTEEN_MINS"]
        case .intraday: return ["FOUR_HOURS", "ONE_HOUR", "FIFTEEN_MINS", "FIVE_MINS"]
        }
    }
}

struct MultiTimeframeTabState: Codable, Equatable {
    var instrument: String
    var zoom: TFZoom
    var showSessions: Bool
    var showVolume: Bool
    var showEMA: Bool
    var emaConfigs: [EMALineState]
    var showATR: Bool
    var atrPeriod: Int

    init(instrument: String, zoom: TFZoom = .standard, showSessions: Bool = true,
         showVolume: Bool = true, showEMA: Bool = true,
         emaConfigs: [EMALineState] = [], showATR: Bool = true, atrPeriod: Int = 14) {
        self.instrument = instrument
        self.zoom = zoom
        self.showSessions = showSessions
        self.showVolume = showVolume
        self.showEMA = showEMA
        self.emaConfigs = emaConfigs
        self.showATR = showATR
        self.atrPeriod = atrPeriod
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instrument = try c.decode(String.self, forKey: .instrument)
        zoom = try c.decodeIfPresent(TFZoom.self, forKey: .zoom) ?? .standard
        showSessions = try c.decodeIfPresent(Bool.self, forKey: .showSessions) ?? true
        showVolume = try c.decodeIfPresent(Bool.self, forKey: .showVolume) ?? true
        showEMA = try c.decodeIfPresent(Bool.self, forKey: .showEMA) ?? true
        emaConfigs = try c.decodeIfPresent([EMALineState].self, forKey: .emaConfigs) ?? []
        showATR = try c.decodeIfPresent(Bool.self, forKey: .showATR) ?? true
        atrPeriod = try c.decodeIfPresent(Int.self, forKey: .atrPeriod) ?? 14
    }
}

enum TabContentState: Codable, Equatable {
    case chart(ChartTabState)
    case correlation(CorrelationTabState)
    case multiTimeframe(MultiTimeframeTabState)
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
    var showLeftPanel: Bool

    init(tabs: [TabState], selectedTabIndex: Int?, showBottomPanel: Bool,
         showRightPanel: Bool, showLeftPanel: Bool = true) {
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
        self.showBottomPanel = showBottomPanel
        self.showRightPanel = showRightPanel
        self.showLeftPanel = showLeftPanel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try c.decode([TabState].self, forKey: .tabs)
        selectedTabIndex = try c.decodeIfPresent(Int.self, forKey: .selectedTabIndex)
        showBottomPanel = try c.decode(Bool.self, forKey: .showBottomPanel)
        showRightPanel = try c.decode(Bool.self, forKey: .showRightPanel)
        showLeftPanel = try c.decodeIfPresent(Bool.self, forKey: .showLeftPanel) ?? true
    }
}
