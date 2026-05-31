import Foundation

enum DrawingKind: String, Codable, Equatable {
    case line
    case arrow
    case freehand
}

/// A single (time, price) vertex of a freehand polyline. A struct (not a tuple)
/// so it round-trips through `Codable` with the rest of `Drawing`.
struct DrawingPoint: Codable, Equatable {
    var timeMs: Int64
    var price: Double
}

struct Drawing: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: DrawingKind
    var startTimeMs: Int64
    var startPrice: Double
    var endTimeMs: Int64
    var endPrice: Double
    /// Full polyline for `.freehand` drawings; `nil` for line/arrow. When set,
    /// `start*`/`end*` mirror the first/last point so existing readers and
    /// off-screen culling keep working. Optional + synthesized `Codable` keeps
    /// workspaces saved before freehand existed decoding fine.
    var points: [DrawingPoint]? = nil
}
