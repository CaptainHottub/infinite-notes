import Foundation

/// Document-space sample. Time is in seconds, pressure is normalized to [0, 1].
/// seq is the source observation anchor; a modeled point is still derived ink.
struct GoogleInkSample {
    var point: CGPoint
    var pressure: Double
    var t: Double
    var seq: Int
}

/// The model uses the source PDF page as its origin. The drawing workspace
/// can start to its left and grow while the Pencil is down.
struct GoogleInkCoordinates {
    let sourceOrigin: CGPoint

    func pagePoint(fromWorld point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - sourceOrigin.x, y: point.y - sourceOrigin.y)
    }

    func worldPoint(fromPage point: CGPoint) -> CGPoint {
        CGPoint(x: sourceOrigin.x + point.x, y: sourceOrigin.y + point.y)
    }

    func viewPoint(fromPage point: CGPoint, workspace: CGRect, viewSize: CGSize) -> CGPoint {
        let world = worldPoint(fromPage: point)
        return CGPoint(x: (world.x - workspace.minX) / workspace.width * viewSize.width,
                       y: (world.y - workspace.minY) / workspace.height * viewSize.height)
    }
}
