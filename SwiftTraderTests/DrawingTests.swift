import Testing
import Foundation
import CoreGraphics
@testable import SwiftTrader

@Suite("Drawing")
struct DrawingTests {

    @Test("Drawing line round-trips through JSON")
    func lineRoundTrip() throws {
        let original = Drawing(
            kind: .line,
            startTimeMs: 1_700_000_000_000,
            startPrice: 1.0950,
            endTimeMs: 1_700_003_600_000,
            endPrice: 1.0980
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Drawing.self, from: data)
        #expect(decoded == original)
    }

    @Test("Drawing arrow round-trips through JSON")
    func arrowRoundTrip() throws {
        let original = Drawing(
            kind: .arrow,
            startTimeMs: 1_700_000_000_000,
            startPrice: 1.10,
            endTimeMs: 1_700_010_000_000,
            endPrice: 1.12
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Drawing.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("DrawingMath")
struct DrawingMathTests {

    // MARK: - Distance from segment

    @Test("Perpendicular distance to mid-segment")
    func perpendicularDistance() {
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 10, y: 0)
        let p = CGPoint(x: 5, y: 4)
        let d = DrawingMath.distanceFromSegment(point: p, a: a, b: b)
        #expect(abs(d - 4) < 1e-6)
    }

    @Test("Distance to endpoint clamps")
    func endpointClamp() {
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 10, y: 0)
        // Point past `b` — should measure distance to `b`, not the (infinite) line.
        let p = CGPoint(x: 20, y: 0)
        let d = DrawingMath.distanceFromSegment(point: p, a: a, b: b)
        #expect(abs(d - 10) < 1e-6)
    }

    @Test("Zero-length segment returns endpoint distance")
    func zeroLengthSegment() {
        let a = CGPoint(x: 5, y: 5)
        let b = CGPoint(x: 5, y: 5)
        let p = CGPoint(x: 8, y: 9)
        let d = DrawingMath.distanceFromSegment(point: p, a: a, b: b)
        #expect(abs(d - 5) < 1e-6)
    }

    @Test("Threshold boundary — 5.99 hits, 6.01 misses")
    func thresholdBoundary() {
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 100, y: 0)
        let near = CGPoint(x: 50, y: 5.99)
        let far  = CGPoint(x: 50, y: 6.01)
        #expect(DrawingMath.distanceFromSegment(point: near, a: a, b: b) < 6)
        #expect(DrawingMath.distanceFromSegment(point: far,  a: a, b: b) > 6)
    }

    // MARK: - Arrowhead

    @Test("Horizontal arrowhead tips are symmetric and behind the tip")
    func horizontalArrowhead() {
        let p1 = CGPoint(x: 0, y: 0)
        let p2 = CGPoint(x: 100, y: 0)
        let (l, r) = DrawingMath.arrowHeadTips(from: p1, to: p2, length: 10)
        // Both tips should sit behind the head (x < p2.x).
        #expect(l.x < p2.x)
        #expect(r.x < p2.x)
        // Symmetric around the line (one above, one below).
        #expect(abs(l.x - r.x) < 1e-6)
        #expect(abs(l.y + r.y) < 1e-6)
        #expect(l.y != 0)
    }

    @Test("45° arrowhead tips are correctly rotated")
    func diagonalArrowhead() {
        let p1 = CGPoint(x: 0, y: 0)
        // 45° direction (atan2(100, 100) == π/4).
        let p2 = CGPoint(x: 100, y: 100)
        let (l, r) = DrawingMath.arrowHeadTips(from: p1, to: p2, length: 10)
        // Both tips should lie strictly behind the head in the line's direction:
        // their distance to p2 ≈ 10, and they should be closer to p1 than p2 is.
        let dlSq = (l.x - p2.x) * (l.x - p2.x) + (l.y - p2.y) * (l.y - p2.y)
        let drSq = (r.x - p2.x) * (r.x - p2.x) + (r.y - p2.y) * (r.y - p2.y)
        #expect(abs(dlSq.squareRoot() - 10) < 1e-6)
        #expect(abs(drSq.squareRoot() - 10) < 1e-6)
    }

    // MARK: - Time ↔ X round-trip

    /// Synthetic bars at 60-second spacing.
    private static let synthBarTimes: [Int64] = (0..<10).map { Int64($0) * 60_000 }

    @Test("xForTimeMs at exact bar time matches xForBar")
    func xForTimeMsExact() {
        let xOffset: CGFloat = 0
        let slot: CGFloat = 8
        let times = Self.synthBarTimes
        for (i, t) in times.enumerated() {
            let x = DrawingMath.xForTimeMs(t, barTimes: times, xOffset: xOffset, slotWidth: slot)
            let expected = DrawingMath.xForBar(index: i, xOffset: xOffset, slotWidth: slot)
            #expect(abs(x - expected) < 1e-6)
        }
    }

    @Test("ms halfway between two bars maps to xForBar(i) + slot/2")
    func xForTimeMsHalfway() {
        let xOffset: CGFloat = 12
        let slot: CGFloat = 6
        let times = Self.synthBarTimes
        let mid = (times[3] + times[4]) / 2
        let x = DrawingMath.xForTimeMs(mid, barTimes: times, xOffset: xOffset, slotWidth: slot)
        let expected = DrawingMath.xForBar(index: 3, xOffset: xOffset, slotWidth: slot) + slot / 2
        #expect(abs(x - expected) < 1e-6)
    }

    @Test("Time-to-x and back round-trips within loaded range")
    func roundTrip() {
        let xOffset: CGFloat = 40
        let slot: CGFloat = 10
        let times = Self.synthBarTimes
        for t in [times[1], times[5], (times[2] + times[3]) / 2, times.last! - 1] {
            let x = DrawingMath.xForTimeMs(t, barTimes: times, xOffset: xOffset, slotWidth: slot)
            let back = DrawingMath.timeMsForX(x, barTimes: times, xOffset: xOffset, slotWidth: slot)
            // Linear interpolation should be exact to within 1ms (rounding).
            #expect(abs(back - t) <= 1)
        }
    }

    @Test("Past-the-last-bar times extrapolate one slot per period")
    func extrapolatesPastLastBar() {
        let times = Self.synthBarTimes                       // 60 000 ms spacing
        let xOffset: CGFloat = 0
        let slot: CGFloat = 8
        let lastX = DrawingMath.xForBar(index: times.count - 1, xOffset: xOffset, slotWidth: slot)
        // One full period past the last bar → exactly one slot to the right.
        let oneSlotPast = times.last! + 60_000
        let x1 = DrawingMath.xForTimeMs(oneSlotPast, barTimes: times, xOffset: xOffset, slotWidth: slot)
        #expect(abs(x1 - (lastX + slot)) < 1e-6)
        // 2.5 periods past → 2.5 slots.
        let xHalf = DrawingMath.xForTimeMs(times.last! + 150_000, barTimes: times, xOffset: xOffset, slotWidth: slot)
        #expect(abs(xHalf - (lastX + slot * 2.5)) < 1e-6)
    }

    @Test("Click past the last bar yields a future time")
    func timeMsForXExtrapolatesForward() {
        let times = Self.synthBarTimes
        let xOffset: CGFloat = 0
        let slot: CGFloat = 8
        let lastX = DrawingMath.xForBar(index: times.count - 1, xOffset: xOffset, slotWidth: slot)
        let oneSlotPast = lastX + slot
        let t = DrawingMath.timeMsForX(oneSlotPast, barTimes: times, xOffset: xOffset, slotWidth: slot)
        // Period is 60 000 ms; one slot past the last bar should sit ~60 000ms in the future.
        #expect(abs(t - (times.last! + 60_000)) <= 1)
    }
}
