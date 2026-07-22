import CoreGraphics
import QuartzCore
import UIKit

enum InteractionOverlayRenderer {
    private static func viewPoint(_ world: CGPoint, page: PageInfo, bounds: CGRect) -> CGPoint {
        CGPoint(
            x: (world.x - CGFloat(page.x)) * bounds.width / max(0.001, CGFloat(page.width)),
            y: (world.y - CGFloat(page.y)) * bounds.height / max(0.001, CGFloat(page.height))
        )
    }

    private static func viewWidth(_ width: Double, page: PageInfo, bounds: CGRect) -> CGFloat {
        let x = bounds.width / max(0.001, CGFloat(page.width))
        let y = bounds.height / max(0.001, CGFloat(page.height))
        return max(0.5, CGFloat(width) * (x + y) / 2)
    }

    static func shapePreview(
        stroke: NoteStroke,
        page: PageInfo,
        bounds: CGRect
    ) -> [LiveStrokeLayerDescriptor] {
        guard GeometryEngine.isGeometry(stroke) else { return [] }
        let world = GeometryEngine.polyline(for: stroke, segments: 72)
        guard let first = world.first else { return [] }
        let path = CGMutablePath()
        path.move(to: viewPoint(first, page: page, bounds: bounds))
        for point in world.dropFirst() { path.addLine(to: viewPoint(point, page: page, bounds: bounds)) }
        let width = viewWidth(stroke.width, page: page, bounds: bounds)
        let dash: [NSNumber]?
        switch stroke.lineStyle {
        case "dashed": dash = [NSNumber(value: Double(max(5, width * 3.2))), NSNumber(value: Double(max(4, width * 2)))]
        case "dotted": dash = [NSNumber(value: Double(max(0.5, width * 0.18))), NSNumber(value: Double(max(4, width * 2.1)))]
        default: dash = nil
        }
        var result = [LiveStrokeLayerDescriptor(
            path: path,
            fillColor: nil,
            strokeColor: UIColor(noteHex: stroke.color, alpha: 0.82).cgColor,
            lineWidth: width,
            lineDashPattern: dash
        )]

        if stroke.shapeType == "arrow", world.count >= 2 {
            let start = viewPoint(world[0], page: page, bounds: bounds)
            let end = viewPoint(world[1], page: page, bounds: bounds)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let size = max(9, width * 4.5)
            let arrow = CGMutablePath()
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(x: end.x - cos(angle - .pi / 6) * size, y: end.y - sin(angle - .pi / 6) * size))
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(x: end.x - cos(angle + .pi / 6) * size, y: end.y - sin(angle + .pi / 6) * size))
            result.append(LiveStrokeLayerDescriptor(
                path: arrow,
                fillColor: nil,
                strokeColor: UIColor(noteHex: stroke.color, alpha: 0.82).cgColor,
                lineWidth: width,
                lineDashPattern: nil
            ))
        }
        return result
    }

    static func eraserCursor(
        center: CGPoint,
        diameter: Double,
        page: PageInfo,
        bounds: CGRect,
        zoomScale: CGFloat
    ) -> [LiveStrokeLayerDescriptor] {
        let viewCenter = viewPoint(center, page: page, bounds: bounds)
        let width = bounds.width / max(0.001, CGFloat(page.width))
        let height = bounds.height / max(0.001, CGFloat(page.height))
        let viewDiameter = max(4, CGFloat(diameter) * (width + height) / 2)
        let rect = CGRect(
            x: viewCenter.x - viewDiameter / 2,
            y: viewCenter.y - viewDiameter / 2,
            width: viewDiameter,
            height: viewDiameter
        )
        let path = CGPath(ellipseIn: rect, transform: nil)
        let inverseZoom = 1 / max(0.05, zoomScale)
        return [
            LiveStrokeLayerDescriptor(
                path: path,
                fillColor: UIColor.systemGray.withAlphaComponent(0.10).cgColor,
                strokeColor: nil,
                lineWidth: 0,
                lineDashPattern: nil
            ),
            LiveStrokeLayerDescriptor(
                path: path,
                fillColor: nil,
                strokeColor: UIColor.label.withAlphaComponent(0.92).cgColor,
                lineWidth: 2.0 * inverseZoom,
                lineDashPattern: nil
            ),
        ]
    }

    static func lasso(
        points: [CGPoint],
        page: PageInfo,
        bounds: CGRect,
        zoomScale: CGFloat
    ) -> [LiveStrokeLayerDescriptor] {
        guard let first = points.first else { return [] }
        let inverseZoom = 1 / max(0.05, zoomScale)
        let path = CGMutablePath()
        path.move(to: viewPoint(first, page: page, bounds: bounds))
        for point in points.dropFirst() { path.addLine(to: viewPoint(point, page: page, bounds: bounds)) }
        return [LiveStrokeLayerDescriptor(
            path: path,
            fillColor: nil,
            strokeColor: UIColor.systemBlue.cgColor,
            lineWidth: 1.5 * inverseZoom,
            lineDashPattern: [NSNumber(value: Double(6 * inverseZoom)), NSNumber(value: Double(4 * inverseZoom))]
        )]
    }

    static func selection(
        strokes: [NoteStroke],
        page: PageInfo,
        bounds: CGRect,
        settings: NativeAppConfiguration,
        zoomScale: CGFloat
    ) -> [LiveStrokeLayerDescriptor] {
        guard settings.showSelectionBounds,
              let worldBounds = GeometryEngine.selectionBounds(strokes) else { return [] }
        let topLeft = viewPoint(CGPoint(x: worldBounds.minX, y: worldBounds.minY), page: page, bounds: bounds)
        let bottomRight = viewPoint(CGPoint(x: worldBounds.maxX, y: worldBounds.maxY), page: page, bounds: bounds)
        let rect = CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: max(1, abs(bottomRight.x - topLeft.x)),
            height: max(1, abs(bottomRight.y - topLeft.y))
        )
        let inverseZoom = 1 / max(0.05, zoomScale)
        let blue = UIColor.systemBlue.cgColor
        var result: [LiveStrokeLayerDescriptor] = []
        result.append(LiveStrokeLayerDescriptor(
            path: CGPath(rect: rect, transform: nil),
            fillColor: UIColor.systemBlue.withAlphaComponent(0.04).cgColor,
            strokeColor: blue,
            lineWidth: 1.5 * inverseZoom,
            lineDashPattern: [NSNumber(value: Double(7 * inverseZoom)), NSNumber(value: Double(4 * inverseZoom))],
            lineCap: .butt,
            lineJoin: .miter
        ))

        let rotation = CGPoint(x: rect.midX, y: rect.minY - 30 * inverseZoom)
        let rotationLine = CGMutablePath()
        rotationLine.move(to: CGPoint(x: rect.midX, y: rect.minY))
        rotationLine.addLine(to: rotation)
        result.append(LiveStrokeLayerDescriptor(
            path: rotationLine,
            fillColor: nil,
            strokeColor: blue,
            lineWidth: 1.5 * inverseZoom,
            lineDashPattern: nil
        ))

        let size = CGFloat(max(7, settings.selectionHandleSize)) * inverseZoom
        let handlePath = CGMutablePath()
        for point in [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ] {
            handlePath.addRect(CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
        }
        handlePath.addEllipse(in: CGRect(x: rotation.x - size / 2, y: rotation.y - size / 2, width: size, height: size))
        result.append(LiveStrokeLayerDescriptor(
            path: handlePath,
            fillColor: UIColor.white.cgColor,
            strokeColor: blue,
            lineWidth: 2 * inverseZoom,
            lineDashPattern: nil,
            lineCap: .round,
            lineJoin: .round
        ))

        if strokes.count == 1, let stroke = strokes.first,
           GeometryEngine.isGeometry(stroke),
           ["line", "arrow", "curve"].contains(stroke.shapeType ?? "") {
            let pointPath = CGMutablePath()
            for (index, point) in stroke.points.enumerated() {
                let view = viewPoint(point.cgPoint, page: page, bounds: bounds)
                let diameter = CGFloat(index == 1 && stroke.shapeType == "curve" ? size * 0.9 : size * 1.2)
                pointPath.addEllipse(in: CGRect(x: view.x - diameter / 2, y: view.y - diameter / 2, width: diameter, height: diameter))
            }
            result.append(LiveStrokeLayerDescriptor(
                path: pointPath,
                fillColor: UIColor.white.cgColor,
                strokeColor: blue,
                lineWidth: 2 * inverseZoom,
                lineDashPattern: nil
            ))
        }
        return result
    }

    static func snapGuide(
        _ snap: GeometrySnapResult,
        page: PageInfo,
        bounds: CGRect,
        zoomScale: CGFloat
    ) -> [LiveStrokeLayerDescriptor] {
        let inverseZoom = 1 / max(0.05, zoomScale)
        let point = viewPoint(snap.point, page: page, bounds: bounds)
        var result: [LiveStrokeLayerDescriptor] = []
        if let from = snap.from {
            let path = CGMutablePath()
            path.move(to: viewPoint(from, page: page, bounds: bounds))
            path.addLine(to: point)
            result.append(LiveStrokeLayerDescriptor(
                path: path,
                fillColor: nil,
                strokeColor: UIColor.systemOrange.cgColor,
                lineWidth: 1.5 * inverseZoom,
                lineDashPattern: [NSNumber(value: Double(5 * inverseZoom)), NSNumber(value: Double(4 * inverseZoom))]
            ))
        }
        let markerRadius = 6 * inverseZoom
        result.append(LiveStrokeLayerDescriptor(
            path: CGPath(
                ellipseIn: CGRect(
                    x: point.x - markerRadius,
                    y: point.y - markerRadius,
                    width: markerRadius * 2,
                    height: markerRadius * 2
                ),
                transform: nil
            ),
            fillColor: nil,
            strokeColor: UIColor.systemOrange.cgColor,
            lineWidth: 1.5 * inverseZoom,
            lineDashPattern: nil
        ))
        return result
    }

    static func selectionScreenGeometry(
        strokes: [NoteStroke],
        page: PageInfo,
        bounds: CGRect,
        zoomScale: CGFloat
    ) -> (world: CGRect, view: CGRect, rotation: CGPoint, handles: [String: CGPoint])? {
        guard let world = GeometryEngine.selectionBounds(strokes) else { return nil }
        let tl = viewPoint(CGPoint(x: world.minX, y: world.minY), page: page, bounds: bounds)
        let br = viewPoint(CGPoint(x: world.maxX, y: world.maxY), page: page, bounds: bounds)
        let view = CGRect(x: min(tl.x, br.x), y: min(tl.y, br.y), width: max(1, abs(br.x - tl.x)), height: max(1, abs(br.y - tl.y)))
        let handles = [
            "nw": CGPoint(x: view.minX, y: view.minY),
            "ne": CGPoint(x: view.maxX, y: view.minY),
            "sw": CGPoint(x: view.minX, y: view.maxY),
            "se": CGPoint(x: view.maxX, y: view.maxY),
        ]
        let inverseZoom = 1 / max(0.05, zoomScale)
        return (world, view, CGPoint(x: view.midX, y: view.minY - 30 * inverseZoom), handles)
    }
}
