import Foundation
import CoreGraphics

/// Pure helpers shared between rendering and hit-testing for chart drawings.
/// Kept free of view types so tests can exercise the math directly.
enum DrawingMath {
    /// Pixel X for a bar at `index`, matching `ChartView.xForBar`.
    static func xForBar(index: Int, xOffset: CGFloat, slotWidth: CGFloat) -> CGFloat {
        CGFloat(index) * slotWidth - xOffset + slotWidth / 2
    }

    /// Map a bar-time-in-ms to its pixel X by binary-searching `barTimes` and
    /// linearly interpolating within the slot. Outside the loaded range the
    /// function extrapolates using the nearest pair's interval, so drawings
    /// can extend beyond the first/last loaded bar (e.g. trend lines into the
    /// "future" area to the right of the most recent candle).
    static func xForTimeMs(_ ms: Int64,
                           barTimes: [Int64],
                           xOffset: CGFloat,
                           slotWidth: CGFloat) -> CGFloat {
        guard !barTimes.isEmpty, slotWidth > 0 else { return 0 }
        let n = barTimes.count
        if ms >= barTimes.last! {
            let lastX = xForBar(index: n - 1, xOffset: xOffset, slotWidth: slotWidth)
            guard n >= 2, barTimes[n - 1] > barTimes[n - 2] else { return lastX }
            let dt = barTimes[n - 1] - barTimes[n - 2]
            let extraSlots = Double(ms - barTimes[n - 1]) / Double(dt)
            return lastX + CGFloat(extraSlots) * slotWidth
        }
        if ms <= barTimes.first! {
            let firstX = xForBar(index: 0, xOffset: xOffset, slotWidth: slotWidth)
            guard n >= 2, barTimes[1] > barTimes[0] else { return firstX }
            let dt = barTimes[1] - barTimes[0]
            let extraSlots = Double(ms - barTimes[0]) / Double(dt)   // negative
            return firstX + CGFloat(extraSlots) * slotWidth
        }
        // Largest index with barTimes[i] <= ms.
        var lo = 0, hi = n - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if barTimes[mid] <= ms { lo = mid } else { hi = mid - 1 }
        }
        let t0 = barTimes[lo]
        let t1 = barTimes[lo + 1]
        let frac = Double(ms - t0) / Double(t1 - t0)
        return xForBar(index: lo, xOffset: xOffset, slotWidth: slotWidth)
            + CGFloat(frac) * slotWidth
    }

    /// Inverse of `xForTimeMs`. Outside the loaded range, extrapolates using
    /// the nearest pair's interval so a click in the empty "future" area to
    /// the right of the last bar yields a sensible (future) time.
    static func timeMsForX(_ x: CGFloat,
                           barTimes: [Int64],
                           xOffset: CGFloat,
                           slotWidth: CGFloat) -> Int64 {
        guard !barTimes.isEmpty, slotWidth > 0 else { return 0 }
        let rawIndex = (x + xOffset) / slotWidth - 0.5
        let n = barTimes.count
        if rawIndex >= CGFloat(n - 1) {
            guard n >= 2 else { return barTimes.last! }
            let dt = barTimes[n - 1] - barTimes[n - 2]
            let extraSlots = Double(rawIndex - CGFloat(n - 1))
            let interpolated = Double(barTimes[n - 1]) + extraSlots * Double(dt)
            return Int64(interpolated.rounded())
        }
        if rawIndex <= 0 {
            guard n >= 2 else { return barTimes.first! }
            let dt = barTimes[1] - barTimes[0]
            let interpolated = Double(barTimes[0]) + Double(rawIndex) * Double(dt)
            return Int64(interpolated.rounded())
        }
        let i0 = Int(floor(rawIndex))
        let i1 = min(n - 1, i0 + 1)
        if i0 == i1 { return barTimes[i0] }
        let frac = Double(rawIndex - CGFloat(i0))
        let interpolated = Double(barTimes[i0]) + frac * Double(barTimes[i1] - barTimes[i0])
        return Int64(interpolated.rounded())
    }

    /// The `xOffset` that horizontally centers bar-time `ms` in a viewport of width `chartWidth`.
    /// `xForTimeMs` is linear in `-xOffset` (the time→pixel position is offset-independent), so
    /// centering reduces to `pixelPos(ms, xOffset: 0) - chartWidth/2`. Clamped to `[0, maxOffset]`,
    /// where `maxOffset` lets the newest bar sit anywhere up to the left edge — deliberately NOT the
    /// live-edge resting offset, so a near-live anchor keeps its empty right-hand "future" room
    /// instead of snapping back to the live edge. Pure, so it's unit-testable.
    static func xOffsetCenteringTime(_ ms: Int64,
                                     barTimes: [Int64],
                                     slotWidth: CGFloat,
                                     chartWidth: CGFloat) -> CGFloat {
        guard !barTimes.isEmpty, slotWidth > 0, chartWidth > 0 else { return 0 }
        let raw = xForTimeMs(ms, barTimes: barTimes, xOffset: 0, slotWidth: slotWidth) - chartWidth / 2
        let maxOffset = max(0, CGFloat(barTimes.count) * slotWidth - slotWidth)   // last bar at left edge
        return min(max(0, raw), maxOffset)
    }

    /// Shortest distance from `p` to the line segment `a`–`b`, in pixel space.
    /// Clamped so points past either endpoint return the endpoint distance.
    static func distanceFromSegment(point p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else {
            let ex = p.x - a.x
            let ey = p.y - a.y
            return (ex * ex + ey * ey).squareRoot()
        }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let cx = a.x + t * dx
        let cy = a.y + t * dy
        let ex = p.x - cx
        let ey = p.y - cy
        return (ex * ex + ey * ey).squareRoot()
    }

    /// Shortest distance from `p` to a polyline (the connected segments through
    /// `points`), in pixel space. Returns `.infinity` for an empty polyline and
    /// the point distance for a single vertex. Used to hit-test freehand drawings.
    static func distanceFromPolyline(point p: CGPoint, points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else {
            let ex = p.x - first.x
            let ey = p.y - first.y
            return (ex * ex + ey * ey).squareRoot()
        }
        var best = CGFloat.infinity
        for i in 0..<(points.count - 1) {
            best = min(best, distanceFromSegment(point: p, a: points[i], b: points[i + 1]))
        }
        return best
    }

    /// Arrowhead tip points for an arrow from `p1` to `p2`. Two short strokes
    /// from `p2` back toward `p1`, splayed ±30° around the line direction.
    static func arrowHeadTips(from p1: CGPoint,
                              to p2: CGPoint,
                              length: CGFloat = 10) -> (CGPoint, CGPoint) {
        let angle = atan2(p2.y - p1.y, p2.x - p1.x)
        let leftAngle = angle - .pi / 6
        let rightAngle = angle + .pi / 6
        let tipL = CGPoint(x: p2.x - length * cos(leftAngle),
                           y: p2.y - length * sin(leftAngle))
        let tipR = CGPoint(x: p2.x - length * cos(rightAngle),
                           y: p2.y - length * sin(rightAngle))
        return (tipL, tipR)
    }
}
