import Foundation
import CoreGraphics

/// Pointer angles use the same clockwise, twelve-o'clock origin as the
/// drawn needle. Each step takes the shortest signed angular difference,
/// so the bottom seam and Shift changes never reinterpret previous travel.
struct EditorKnobDragState {
    static let sweepAngle = 270.0
    static let startAngle = -135.0
    private let center: CGPoint
    private var previousAngle: Double?
    private(set) var fraction: Double

    init(fraction: Double, point: CGPoint, center: CGPoint) {
        self.fraction = Self.clamp(fraction)
        self.center = center
        previousAngle = Self.angle(point, center: center)
    }

    mutating func update(point: CGPoint, fine: Bool) -> Double {
        guard let angle = Self.angle(point, center: center) else {
            // Crossing the center has no meaningful angular direction. Anchor
            // again after leaving it instead of jumping half a revolution.
            previousAngle = nil
            return fraction
        }
        defer { previousAngle = angle }
        guard let previousAngle else { return fraction }
        var delta = angle - previousAngle
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        fraction = Self.clamp(fraction + delta / Self.sweepAngle * (fine ? 0.2 : 1))
        return fraction
    }

    static func wheelDelta(vertical: Double, horizontal: Double,
                           precise: Bool, inverted: Bool, fine: Bool) -> Double? {
        guard vertical.isFinite, horizontal.isFinite,
              abs(vertical) > 0.0001, abs(vertical) >= abs(horizontal) else { return nil }
        let physicalDelta = inverted ? -vertical : vertical
        let delta = min(max(physicalDelta / (precise ? 600 : 50), -0.08), 0.08)
        return delta * (fine ? 0.2 : 1)
    }

    static func clamp(_ fraction: Double) -> Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }

    private static func angle(_ point: CGPoint, center: CGPoint) -> Double? {
        let x = point.x - center.x
        let y = point.y - center.y
        guard x.isFinite, y.isFinite, hypot(x, y) >= 6 else { return nil }
        return atan2(Double(x), Double(-y)) * 180 / .pi
    }
}
