import Foundation

enum DrawingKind: String, Codable, Equatable {
    case line
    case arrow
}

struct Drawing: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: DrawingKind
    var startTimeMs: Int64
    var startPrice: Double
    var endTimeMs: Int64
    var endPrice: Double
}
