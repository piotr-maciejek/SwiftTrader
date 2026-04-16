import Foundation

/// Errors surfaced by WebSocketStreamDriver on top of the underlying URLSession failure modes.
enum WebSocketStreamError: Error, LocalizedError, Equatable {
    /// The driver hasn't observed any server-side activity (message or pong) for this many seconds.
    /// Caller should treat the connection as dead and reconnect.
    case stale(secondsSilent: Int)

    /// A payload arrived but could not be decoded into the expected type.
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .stale(let s):
            return "No message received in \(s)s — connection appears dead"
        case .decode(let m):
            return "Failed to decode WebSocket message: \(m)"
        }
    }
}
