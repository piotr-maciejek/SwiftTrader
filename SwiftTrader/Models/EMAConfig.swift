import SwiftUI

struct EMALine: Identifiable, Equatable {
    let id = UUID()
    var period: Int
    var color: Color

    static let presetColors: [Color] = [
        .yellow,
        .orange,
        Color(red: 1.0, green: 0.4, blue: 0.7), // pink
        .cyan,
        .white,
    ]

    static let defaults: [EMALine] = [
        EMALine(period: 20, color: .yellow),
        EMALine(period: 50, color: .orange),
        EMALine(period: 200, color: Color(red: 1.0, green: 0.4, blue: 0.7)),
    ]
}
