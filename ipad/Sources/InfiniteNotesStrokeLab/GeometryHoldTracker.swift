import Foundation

struct GeometryHoldTracker {
    private var anchor: CGPoint?

    /// Measure from the last timer restart so small movements that add up
    /// still count as drawing.
    mutating func shouldRestart(at point: CGPoint, movementTolerance: CGFloat) -> Bool {
        if let anchor, hypot(point.x - anchor.x, point.y - anchor.y) < movementTolerance {
            return false
        }
        anchor = point
        return true
    }
}
