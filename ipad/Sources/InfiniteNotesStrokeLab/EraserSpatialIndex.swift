import Foundation

/// Cached hit geometry and a bounded spatial grid. Bounds only select candidates;
/// a hit always requires intersection with the stroke path (or filled text box).
struct EraserHitGeometry {
    let points: [CGPoint]
    let halfWidth: CGFloat
    let filled: Bool
    let bounds: CGRect

    init?(points: [CGPoint], width: CGFloat, filled: Bool = false) {
        guard let first = points.first, width.isFinite,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        self.points = points
        self.halfWidth = max(0.05, width / 2)
        self.filled = filled
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        bounds = CGRect(x: minX - halfWidth, y: minY - halfWidth,
                        width: maxX - minX + 2 * halfWidth, height: maxY - minY + 2 * halfWidth)
    }

    func intersects(sweep: [CGPoint], radius: CGFloat) -> Bool {
        guard let first = sweep.first else { return false }
        let limit = max(0.1, radius) + halfWidth
        let squared = limit * limit
        if filled && sweep.contains(where: contains) { return true }
        var previous = first
        for current in sweep {
            if points.count == 1 {
                if Self.pointDistanceSquared(points[0], previous, current) <= squared { return true }
            } else {
                for index in 1..<points.count {
                    if Self.segmentDistanceSquared(previous, current, points[index - 1], points[index]) <= squared {
                        return true
                    }
                }
                if filled && Self.segmentDistanceSquared(previous, current, points.last!, points[0]) <= squared {
                    return true
                }
            }
            previous = current
        }
        return false
    }

    private func contains(_ point: CGPoint) -> Bool {
        var inside = false
        let corners = points.prefix(4)
        var previous = corners.last!
        for current in corners {
            if (current.y > point.y) != (previous.y > point.y),
               point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    static func pointDistanceSquared(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let vx = b.x - a.x, vy = b.y - a.y
        let wx = point.x - a.x, wy = point.y - a.y
        let length = vx * vx + vy * vy
        let t = length > 0.000_001 ? max(0, min(1, (wx * vx + wy * vy) / length)) : 0
        let dx = wx - t * vx, dy = wy - t * vy
        return dx * dx + dy * dy
    }

    static func segmentDistanceSquared(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat {
        if a == b { return pointDistanceSquared(a, c, d) }
        let ux = b.x - a.x, uy = b.y - a.y
        let vx = d.x - c.x, vy = d.y - c.y
        let denominator = ux * vy - uy * vx
        if denominator != 0 {
            let wx = c.x - a.x, wy = c.y - a.y
            let t = (wx * vy - wy * vx) / denominator
            let u = (wx * uy - wy * ux) / denominator
            if (0...1).contains(t) && (0...1).contains(u) { return 0 }
        }
        return min(pointDistanceSquared(a, c, d), pointDistanceSquared(b, c, d),
                   pointDistanceSquared(c, a, b), pointDistanceSquared(d, a, b))
    }
}

struct EraserSpatialIndex {
    private struct Cell: Hashable { let x: Int; let y: Int }
    private struct Entry {
        let geometry: EraserHitGeometry
        let pages: Set<Int>
        let cells: [Cell]?
    }
    private var entries: [String: Entry] = [:]
    private var cells: [Cell: Set<String>] = [:]
    private var largeEntries: Set<String> = []
    var count: Int { entries.count }

    mutating func update(id: String, geometry: EraserHitGeometry, pages: Set<Int>) {
        remove(id)
        let covered = cellKeys(geometry.bounds, limit: 256)
        entries[id] = Entry(geometry: geometry, pages: pages, cells: covered)
        if let covered {
            for cell in covered { cells[cell, default: []].insert(id) }
        } else { largeEntries.insert(id) }
    }

    mutating func remove(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let covered = entry.cells {
            for cell in covered {
                cells[cell]?.remove(id)
                if cells[cell]?.isEmpty == true { cells.removeValue(forKey: cell) }
            }
        } else { largeEntries.remove(id) }
    }

    func candidates(sweep: [CGPoint], radius: CGFloat, page: Int) -> Set<String> {
        guard let area = EraserHitGeometry(points: sweep, width: 2 * max(0.1, radius))?.bounds else { return [] }
        var found: Set<String>
        if let covered = cellKeys(area, limit: 4096) {
            found = largeEntries
            for cell in covered { found.formUnion(cells[cell] ?? []) }
        } else { found = Set(entries.keys) }
        return Set(found.filter {
            guard let entry = entries[$0] else { return false }
            // Inclusive edges preserve tangencies exactly on grid/bounds borders.
            let b = entry.geometry.bounds
            return entry.pages.contains(page) && b.minX <= area.maxX && b.maxX >= area.minX
                && b.minY <= area.maxY && b.maxY >= area.minY
        })
    }

    func geometry(for id: String) -> EraserHitGeometry? { entries[id]?.geometry }

    private func cellKeys(_ bounds: CGRect, limit: Int) -> [Cell]? {
        let values = [bounds.minX, bounds.maxX, bounds.minY, bounds.maxY].map { floor($0 / 128) }
        guard values.allSatisfy({ $0.isFinite && abs($0) < 1_000_000_000 }) else { return nil }
        let x0 = Int(values[0]), x1 = Int(values[1]), y0 = Int(values[2]), y1 = Int(values[3])
        let width = x1 - x0 + 1, height = y1 - y0 + 1
        guard width > 0, height > 0, width <= limit, height <= limit, width * height <= limit else { return nil }
        var result: [Cell] = []
        result.reserveCapacity(width * height)
        for x in x0...x1 { for y in y0...y1 { result.append(Cell(x: x, y: y)) } }
        return result
    }
}
