import CoreGraphics
import Foundation

struct GeometryBox {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
    var width: CGFloat
    var height: CGFloat
    var ux: CGPoint
    var uy: CGPoint

    func localToWorld(x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(
            x: topLeft.x + ux.x * x + uy.x * y,
            y: topLeft.y + ux.y * x + uy.y * y
        )
    }

    func worldToLocal(_ point: CGPoint) -> CGPoint {
        let dx = point.x - topLeft.x
        let dy = point.y - topLeft.y
        return CGPoint(x: dx * ux.x + dy * ux.y, y: dx * uy.x + dy * uy.y)
    }
}

struct GeometrySnapResult {
    var point: CGPoint
    var kind: String?
    var from: CGPoint?
}

enum SelectionTransformMode: Equatable {
    case lasso
    case move
    case scale(handle: String)
    case rotate
    case point(index: Int)
}

struct SelectionTransformGesture {
    var mode: SelectionTransformMode
    var startWorld: CGPoint
    var originals: [NoteStroke]
    var lassoPoints: [CGPoint] = []
    var startViewPoint: CGPoint = .zero
    var changed = false
    var center: CGPoint = .zero
    var anchor: CGPoint = .zero
    var startDistance: CGFloat = 1
    var startAngle: CGFloat = 0
}

enum GeometryEngine {
    static let geometryTypes: Set<String> = Set(GeometryShapeType.allCases.map(\.rawValue))

    static func isGeometry(_ stroke: NoteStroke) -> Bool {
        stroke.tool == "shape" && geometryTypes.contains(stroke.shapeType ?? "")
    }

    static func displayName(_ stroke: NoteStroke) -> String {
        guard let raw = stroke.shapeType, let type = GeometryShapeType(rawValue: raw) else { return "Item" }
        return type.title
    }

    static func makePoint(_ point: CGPoint, page: PageInfo, pressure: Double = 0.5) -> NotePoint {
        let localX = Double(point.x) - page.x
        let localY = Double(point.y) - page.y
        return NotePoint(
            x: Double(point.x),
            y: Double(point.y),
            p: pressure,
            t: ProcessInfo.processInfo.systemUptime * 1000,
            xRaw: Double(point.x),
            yRaw: Double(point.y),
            xLocal: localX,
            yLocal: localY,
            xRawLocal: localX,
            yRawLocal: localY
        )
    }

    static func replacingPoint(_ original: NotePoint, with point: CGPoint, page: PageInfo?) -> NotePoint {
        var result = original
        let dx = Double(point.x) - result.x
        let dy = Double(point.y) - result.y
        result.x = Double(point.x)
        result.y = Double(point.y)
        result.xRaw += dx
        result.yRaw += dy
        if let page {
            result.xLocal = result.x - page.x
            result.yLocal = result.y - page.y
            result.xRawLocal = result.xRaw - page.x
            result.yRawLocal = result.yRaw - page.y
        }
        result.t = ProcessInfo.processInfo.systemUptime * 1000
        return result
    }

    static func makeShapePoints(type: GeometryShapeType, start: CGPoint, end: CGPoint, page: PageInfo) -> [NotePoint] {
        var dx = end.x - start.x
        var dy = end.y - start.y
        if type == .square || type == .circle {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if type == .line || type == .arrow {
            return [makePoint(start, page: page), makePoint(CGPoint(x: start.x + dx, y: start.y + dy), page: page)]
        }
        if type == .curve {
            let length = max(0.001, hypot(dx, dy))
            let normal = CGPoint(x: -dy / length, y: dx / length)
            let bend = min(length * 0.24, 80)
            let control = CGPoint(
                x: (start.x + end.x) / 2 + normal.x * bend,
                y: (start.y + end.y) / 2 + normal.y * bend
            )
            return [makePoint(start, page: page), makePoint(control, page: page), makePoint(end, page: page)]
        }
        let points = [
            start,
            CGPoint(x: start.x + dx, y: start.y),
            CGPoint(x: start.x + dx, y: start.y + dy),
            CGPoint(x: start.x, y: start.y + dy),
        ]
        return points.map { makePoint($0, page: page) }
    }

    static func shapeBox(_ stroke: NoteStroke) -> GeometryBox? {
        guard stroke.points.count >= 4 else { return nil }
        let tl = stroke.points[0].cgPoint
        let tr = stroke.points[1].cgPoint
        let br = stroke.points[2].cgPoint
        let bl = stroke.points[3].cgPoint
        let width = hypot(tr.x - tl.x, tr.y - tl.y)
        let height = hypot(bl.x - tl.x, bl.y - tl.y)
        guard width > 0.001, height > 0.001 else { return nil }
        return GeometryBox(
            topLeft: tl,
            topRight: tr,
            bottomRight: br,
            bottomLeft: bl,
            width: width,
            height: height,
            ux: CGPoint(x: (tr.x - tl.x) / width, y: (tr.y - tl.y) / width),
            uy: CGPoint(x: (bl.x - tl.x) / height, y: (bl.y - tl.y) / height)
        )
    }

    static func quadratic(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
            y: u * u * a.y + 2 * u * t * c.y + t * t * b.y
        )
    }

    static func lineFitError(_ points: [CGPoint]) -> Double {
        guard let first = points.first, let last = points.last, points.count >= 2 else { return .infinity }
        let chord = hypot(last.x - first.x, last.y - first.y)
        guard chord > 0.000_001 else { return .infinity }
        var maximum = CGFloat.zero
        for point in points {
            maximum = max(maximum, sqrt(segmentDistanceSquared(point, first, last)))
        }
        return Double(maximum / chord * 100)
    }

    static func quadraticFit(_ source: [NotePoint], page: PageInfo) -> (points: [NotePoint], error: Double)? {
        guard source.count >= 3 else { return nil }
        let raw = source.map { CGPoint(x: $0.xRaw, y: $0.yRaw) }
        guard let first = raw.first, let last = raw.last else { return nil }
        var total = CGFloat.zero
        var distances: [CGFloat] = [0]
        distances.reserveCapacity(raw.count)
        for index in 1..<raw.count {
            total += hypot(raw[index].x - raw[index - 1].x, raw[index].y - raw[index - 1].y)
            distances.append(total)
        }
        guard total > 0.000_001 else { return nil }

        var sumX = CGFloat.zero
        var sumY = CGFloat.zero
        var weight = CGFloat.zero
        if raw.count > 2 {
            for index in 1..<(raw.count - 1) {
                let t = distances[index] / total
                let u = 1 - t
                let denominator = 2 * u * t
                guard denominator >= 0.05 else { continue }
                sumX += (raw[index].x - u * u * first.x - t * t * last.x) / denominator
                sumY += (raw[index].y - u * u * first.y - t * t * last.y) / denominator
                weight += 1
            }
        }
        let control = weight > 0
            ? CGPoint(x: sumX / weight, y: sumY / weight)
            : CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)

        var maximum = CGFloat.zero
        for index in raw.indices {
            let fitted = quadratic(first, control, last, t: distances[index] / total)
            maximum = max(maximum, hypot(fitted.x - raw[index].x, fitted.y - raw[index].y))
        }
        let chord = hypot(last.x - first.x, last.y - first.y)
        guard chord > 0.000_001 else { return nil }
        return (
            [makePoint(first, page: page), makePoint(control, page: page), makePoint(last, page: page)],
            Double(maximum / chord * 100)
        )
    }

    static func polyline(for stroke: NoteStroke, segments: Int = 64) -> [CGPoint] {
        let points = stroke.points.map(\.cgPoint)
        guard let type = stroke.shapeType else { return points }
        if (type == "line" || type == "arrow"), points.count >= 2 { return Array(points.prefix(2)) }
        if type == "curve", points.count >= 3 {
            return (0...max(2, segments)).map { index in
                quadratic(points[0], points[1], points[2], t: CGFloat(index) / CGFloat(max(2, segments)))
            }
        }
        guard let box = shapeBox(stroke) else { return points }
        switch type {
        case "ellipse", "circle":
            return (0...max(8, segments)).map { index in
                let angle = CGFloat(index) / CGFloat(max(8, segments)) * .pi * 2
                return box.localToWorld(
                    x: box.width / 2 + cos(angle) * box.width / 2,
                    y: box.height / 2 + sin(angle) * box.height / 2
                )
            }
        case "triangle":
            return [
                box.localToWorld(x: box.width / 2, y: 0),
                box.localToWorld(x: box.width, y: box.height),
                box.localToWorld(x: 0, y: box.height),
                box.localToWorld(x: box.width / 2, y: 0),
            ]
        case "diamond":
            return [
                box.localToWorld(x: box.width / 2, y: 0),
                box.localToWorld(x: box.width, y: box.height / 2),
                box.localToWorld(x: box.width / 2, y: box.height),
                box.localToWorld(x: 0, y: box.height / 2),
                box.localToWorld(x: box.width / 2, y: 0),
            ]
        case "xy-plane":
            return [
                box.topLeft, box.topRight, box.bottomRight, box.bottomLeft, box.topLeft,
                box.localToWorld(x: 0, y: box.height / 2),
                box.localToWorld(x: box.width, y: box.height / 2),
                box.localToWorld(x: box.width / 2, y: 0),
                box.localToWorld(x: box.width / 2, y: box.height),
            ]
        default:
            return [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft, box.topLeft]
        }
    }

    static func bounds(of stroke: NoteStroke) -> CGRect? {
        let source = isGeometry(stroke) ? polyline(for: stroke, segments: 72) : stroke.points.map(\.cgPoint)
        guard let first = source.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in source.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let pad = max(1, CGFloat(stroke.width) / 2)
        return CGRect(x: minX - pad, y: minY - pad, width: max(0.1, maxX - minX + pad * 2), height: max(0.1, maxY - minY + pad * 2))
    }

    static func selectionBounds(_ strokes: [NoteStroke]) -> CGRect? {
        var result: CGRect?
        for stroke in strokes {
            guard let next = bounds(of: stroke) else { continue }
            result = result.map { $0.union(next) } ?? next
        }
        return result
    }

    static func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            let denominator = (b.y - a.y == 0) ? 0.000_000_1 : b.y - a.y
            let intersects = ((a.y > point.y) != (b.y > point.y))
                && point.x < (b.x - a.x) * (point.y - a.y) / denominator + a.x
            if intersects { inside.toggle() }
            j = i
        }
        return inside
    }

    static func selectedByLasso(_ stroke: NoteStroke, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3, let bounds = bounds(of: stroke) else { return false }
        if pointInPolygon(bounds.center, polygon: polygon) { return true }
        let source = isGeometry(stroke) ? polyline(for: stroke, segments: 80) : stroke.points.map(\.cgPoint)
        guard !source.isEmpty else { return false }
        let sampleStride = max(1, source.count / 160)
        var sampled = 0
        var inside = 0
        for index in Swift.stride(from: 0, to: source.count, by: sampleStride) {
            sampled += 1
            if pointInPolygon(source[index], polygon: polygon) { inside += 1 }
        }
        return sampled > 0 && Double(inside) / Double(sampled) >= 0.5
    }

    static func hitTest(_ stroke: NoteStroke, point: CGPoint, threshold: CGFloat) -> CGFloat? {
        if stroke.tool == "text", stroke.points.count >= 4,
           pointInPolygon(point, polygon: Array(stroke.points.prefix(4).map(\.cgPoint))) {
            return 0
        }
        if isGeometry(stroke) {
            if let box = shapeBox(stroke), let type = stroke.shapeType,
               !["line", "arrow", "curve", "xy-plane"].contains(type) {
                let local = box.worldToLocal(point)
                switch type {
                case "rectangle", "square":
                    if local.x >= -threshold, local.y >= -threshold,
                       local.x <= box.width + threshold, local.y <= box.height + threshold { return 0 }
                case "ellipse", "circle":
                    let rx = max(0.001, box.width / 2)
                    let ry = max(0.001, box.height / 2)
                    let nx = (local.x - rx) / (rx + threshold)
                    let ny = (local.y - ry) / (ry + threshold)
                    if nx * nx + ny * ny <= 1 { return 0 }
                case "triangle", "diamond":
                    if pointInPolygon(point, polygon: Array(polyline(for: stroke, segments: 12).dropLast())) { return 0 }
                default: break
                }
            }
            var best = CGFloat.greatestFiniteMagnitude
            let line = polyline(for: stroke, segments: 72)
            for index in 1..<line.count {
                best = min(best, sqrt(segmentDistanceSquared(point, line[index - 1], line[index])))
            }
            return best <= threshold ? best : nil
        }

        let points = stroke.points.map(\.cgPoint)
        guard let first = points.first else { return nil }
        let limit = max(threshold, CGFloat(stroke.width) / 2)
        if points.count == 1 {
            let distance = hypot(point.x - first.x, point.y - first.y)
            return distance <= limit ? distance : nil
        }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<points.count {
            best = min(best, sqrt(segmentDistanceSquared(point, points[index - 1], points[index])))
        }
        return best <= limit ? best : nil
    }

    static func segmentDistanceSquared(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let vx = b.x - a.x
        let vy = b.y - a.y
        let wx = point.x - a.x
        let wy = point.y - a.y
        let lengthSquared = vx * vx + vy * vy
        guard lengthSquared > 0.000_001 else { return wx * wx + wy * wy }
        let t = max(0, min(1, (wx * vx + wy * vy) / lengthSquared))
        let dx = point.x - (a.x + t * vx)
        let dy = point.y - (a.y + t * vy)
        return dx * dx + dy * dy
    }

    static func translated(_ stroke: NoteStroke, dx: CGFloat, dy: CGFloat, page: PageInfo?) -> NoteStroke {
        var result = stroke
        result.points = stroke.points.map { point in
            replacingPoint(point, with: CGPoint(x: CGFloat(point.x) + dx, y: CGFloat(point.y) + dy), page: page)
        }
        return result
    }

    static func rotated(_ stroke: NoteStroke, around center: CGPoint, angle: CGFloat, page: PageInfo?) -> NoteStroke {
        let cosine = cos(angle)
        let sine = sin(angle)
        var result = stroke
        result.points = stroke.points.map { point in
            let dx = CGFloat(point.x) - center.x
            let dy = CGFloat(point.y) - center.y
            return replacingPoint(point, with: CGPoint(
                x: center.x + dx * cosine - dy * sine,
                y: center.y + dx * sine + dy * cosine
            ), page: page)
        }
        return result
    }

    static func scaled(_ stroke: NoteStroke, around anchor: CGPoint, factor: CGFloat, page: PageInfo?) -> NoteStroke {
        let clamped = max(0.05, min(20, factor))
        var result = stroke
        result.points = stroke.points.map { point in
            replacingPoint(point, with: CGPoint(
                x: anchor.x + (CGFloat(point.x) - anchor.x) * clamped,
                y: anchor.y + (CGFloat(point.y) - anchor.y) * clamped
            ), page: page)
        }
        result.width = max(0.25, min(100, stroke.width * Double(clamped)))
        return result
    }

    static func withPoint(_ stroke: NoteStroke, index: Int, point: CGPoint, page: PageInfo?) -> NoteStroke {
        guard stroke.points.indices.contains(index) else { return stroke }
        var result = stroke
        result.points[index] = replacingPoint(result.points[index], with: point, page: page)
        return result
    }

    static func endpoints(of stroke: NoteStroke) -> [CGPoint] {
        guard isGeometry(stroke) else { return [] }
        switch stroke.shapeType {
        case "line", "arrow": return Array(stroke.points.prefix(2).map(\.cgPoint))
        case "curve":
            guard stroke.points.count >= 3 else { return [] }
            return [stroke.points[0].cgPoint, stroke.points[2].cgPoint]
        default:
            guard let box = shapeBox(stroke) else { return [] }
            return [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft,
                    box.localToWorld(x: box.width / 2, y: 0),
                    box.localToWorld(x: box.width, y: box.height / 2),
                    box.localToWorld(x: box.width / 2, y: box.height),
                    box.localToWorld(x: 0, y: box.height / 2)]
        }
    }
}
