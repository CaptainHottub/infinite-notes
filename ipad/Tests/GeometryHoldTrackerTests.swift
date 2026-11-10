import Foundation

@main
struct GeometryHoldTrackerTests {
    static func main() {
        var hold = GeometryHoldTracker()
        let tolerance: CGFloat = 3
        let end = CGPoint(x: 150, y: 220)
        precondition(hold.shouldRestart(at: end, movementTolerance: tolerance))

        // More than one hold duration of stationary Pencil observations.
        // Previously each of these observations restarted the timer.
        for index in 0..<120 {
            let jitter = CGFloat(index % 3 - 1) * 0.25
            let point = CGPoint(x: end.x + jitter, y: end.y - jitter)
            precondition(!hold.shouldRestart(at: point, movementTolerance: tolerance))
        }

        // Slow movement accumulates relative to the last anchor, even when
        // adjacent observations are only one point apart.
        for distance in 1...3 {
            let point = CGPoint(x: end.x + CGFloat(distance), y: end.y)
            precondition(hold.shouldRestart(at: point, movementTolerance: tolerance) == (distance == 3))
        }
        let moved = CGPoint(x: end.x + 3, y: end.y)
        precondition(!hold.shouldRestart(at: moved, movementTolerance: tolerance))
        hold = GeometryHoldTracker()
        precondition(hold.shouldRestart(at: moved, movementTolerance: tolerance))
        print("GeometryHoldTracker: stationary jitter, cumulative movement and new contacts passed")
    }
}
