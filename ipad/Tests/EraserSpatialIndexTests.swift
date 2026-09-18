import Foundation

@main
struct EraserSpatialIndexTests {
    static func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
    static func geometry(_ points: [CGPoint], width: CGFloat = 2, filled: Bool = false) -> EraserHitGeometry {
        EraserHitGeometry(points: points, width: width, filled: filled)!
    }

    // Independent reference for the previous nearest-segment, single-position test.
    static func reference(_ points: [CGPoint], _ p: CGPoint, radius: CGFloat, width: CGFloat) -> Bool {
        var best = CGFloat.infinity
        for i in points.indices {
            let a = points[max(0, i - 1)], b = points[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let norm = dx * dx + dy * dy
            let t = norm <= 0.000_001 ? 0 : min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / norm))
            best = min(best, hypot(p.x - a.x - t * dx, p.y - a.y - t * dy))
        }
        return best <= max(0.1, radius) + max(0.05, width / 2)
    }

    static func main() {
        let diagonal = geometry([point(0, 0), point(100, 100)])
        precondition(!diagonal.intersects(sweep: [point(5, 95)], radius: 2))
        precondition(diagonal.intersects(sweep: [point(0, 100), point(100, 0)], radius: 1))
        let square = [point(0, 0), point(100, 0), point(100, 100), point(0, 100), point(0, 0)]
        precondition(!geometry(square).intersects(sweep: [point(50, 50)], radius: 1))
        precondition(geometry(square, filled: true).intersects(sweep: [point(50, 50)], radius: 1))
        precondition(geometry(square).intersects(sweep: [point(-10, 50), point(110, 50)], radius: 1))
        precondition(geometry([point(0, 0)]).intersects(sweep: [point(-10, 0), point(10, 0)], radius: 1))
        precondition(geometry([point(0, 0), point(0, 0)]).intersects(sweep: [point(0, 0)], radius: 1))
        let horizontal = geometry([point(0, 0), point(10, 0)])
        precondition(horizontal.intersects(sweep: [point(-5, 2), point(15, 2)], radius: 1))
        precondition(!horizontal.intersects(sweep: [point(-5, 2.001), point(15, 2.001)], radius: 1))
        precondition(horizontal.intersects(sweep: [point(-5, 0), point(15, 0)], radius: 0.5))
        precondition(!horizontal.intersects(sweep: [point(-5, 0), point(-2, 0)], radius: 0.5))
        precondition(!diagonal.intersects(sweep: [], radius: 1))
        precondition(EraserHitGeometry(points: [], width: 1) == nil)
        precondition(EraserHitGeometry(points: [point(.infinity, 0)], width: 1) == nil)

        var index = EraserSpatialIndex()
        index.update(id: "diagonal", geometry: diagonal, pages: [0])
        precondition(index.candidates(sweep: [point(50, 50)], radius: 1, page: 0) == ["diagonal"])
        precondition(index.candidates(sweep: [point(50, 50)], radius: 1, page: 1).isEmpty)
        index.update(id: "diagonal", geometry: geometry([point(-500, -500)]), pages: [1])
        precondition(index.candidates(sweep: [point(50, 50)], radius: 1, page: 0).isEmpty)
        precondition(index.candidates(sweep: [point(-500, -500)], radius: 1, page: 1) == ["diagonal"])
        index.remove("diagonal")
        index.remove("diagonal")
        precondition(index.count == 0)
        // Reinsert after erase (undo/redo and state replacement) and shared page membership.
        index.update(id: "diagonal", geometry: diagonal, pages: [0, 1])
        for page in [0, 1] {
            precondition(index.candidates(sweep: [point(50, 50)], radius: 0.5, page: page) == ["diagonal"])
        }
        index.remove("diagonal")

        // Tangency on a grid boundary, a huge stroke, and a huge query must not be omitted.
        index.update(id: "tangent", geometry: geometry([point(126, 0)]), pages: [0])
        precondition(index.candidates(sweep: [point(128, 0)], radius: 1, page: 0).contains("tangent"))
        index.update(id: "large", geometry: geometry([point(-1e12, 0), point(1e12, 0)]), pages: [0])
        precondition(index.candidates(sweep: [point(0, 0)], radius: 1, page: 0).contains("large"))
        precondition(index.candidates(sweep: [point(-1e12, 0), point(1e12, 0)], radius: 1, page: 0).contains("tangent"))
        index.remove("large")
        precondition(!index.candidates(sweep: [point(0, 0)], radius: 1, page: 0).contains("large"))

        var seed: UInt64 = 12345
        func random(_ range: Double) -> Double {
            seed = seed &* 6364136223846793005 &+ 1
            return Double(seed >> 32) / Double(UInt32.max) * range
        }
        var paths: [String: [CGPoint]] = [:]
        index = EraserSpatialIndex()
        for n in 0..<500 {
            let x = random(1000) - 500, y = random(1000) - 500
            let path = (0..<20).map { _ in point(x + random(40), y + random(40)) }
            paths[String(n)] = path
            index.update(id: String(n), geometry: geometry(path), pages: [0])
        }
        for _ in 0..<300 {
            let p = point(random(1000) - 500, random(1000) - 500)
            let radius = CGFloat(random(60) + 0.5)
            let expected = Set(paths.keys.filter { reference(paths[$0]!, p, radius: radius, width: 2) })
            let found = Set(index.candidates(sweep: [p], radius: radius, page: 0).filter {
                index.geometry(for: $0)!.intersects(sweep: [p], radius: radius)
            })
            precondition(found == expected, "Spatial index changed single-position hit results")
            let sweep = [p, point(p.x + random(100), p.y + random(100))]
            let allHits = Set(paths.keys.filter { index.geometry(for: $0)!.intersects(sweep: sweep, radius: radius) })
            let indexedHits = Set(index.candidates(sweep: sweep, radius: radius, page: 0).filter {
                index.geometry(for: $0)!.intersects(sweep: sweep, radius: radius)
            })
            precondition(indexedHits == allHits, "Spatial query omitted a swept hit")
        }
        print("EraserSpatialIndex: reference equivalence, swept hits, tangencies, hollow shapes, text, replacement, removal and bounded fallback passed")
    }
}
