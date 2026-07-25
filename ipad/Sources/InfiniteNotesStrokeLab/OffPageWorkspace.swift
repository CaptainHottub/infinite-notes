import CoreGraphics
import UIKit

struct PageWorkspaceState: Equatable {
    var leftPageWidths: Int = 1
    var rightPageWidths: Int = 1
    var hasOffPageContent = false

    func workspacePage(from source: PageInfo) -> PageInfo {
        let pageWidth = max(1, source.width)
        var result = source
        result.x = source.x - Double(leftPageWidths) * pageWidth
        result.width = Double(leftPageWidths + 1 + rightPageWidths) * pageWidth
        return result
    }

    func sourcePDFFrame(source: PageInfo, workspace: PageInfo) -> CGRect {
        CGRect(
            x: source.x - workspace.x,
            y: source.y - workspace.y,
            width: source.width,
            height: source.height
        )
    }
}

enum OffPageWorkspaceGeometry {
    static func state(sourcePage: PageInfo, strokes: [NoteStroke]) -> PageWorkspaceState {
        let sourceRect = sourcePage.worldRect
        let pageWidth = max(1, sourceRect.width)
        var contentBounds: CGRect?

        for stroke in strokes {
            guard let bounds = strokeWorldBounds(stroke) else { continue }
            contentBounds = contentBounds.map { $0.union(bounds) } ?? bounds
        }

        guard let bounds = contentBounds else { return PageWorkspaceState() }

        let leftOverflow = max(0, sourceRect.minX - bounds.minX)
        let rightOverflow = max(0, bounds.maxX - sourceRect.maxX)
        return PageWorkspaceState(
            leftPageWidths: max(1, Int(ceil(leftOverflow / pageWidth))),
            rightPageWidths: max(1, Int(ceil(rightOverflow / pageWidth))),
            hasOffPageContent: leftOverflow > 0.01 || rightOverflow > 0.01
        )
    }

    static func strokeWorldBounds(_ stroke: NoteStroke) -> CGRect? {
        let points: [CGPoint]
        if GeometryEngine.isGeometry(stroke) {
            let geometryPoints = GeometryEngine.polyline(for: stroke, segments: 72)
            points = geometryPoints.isEmpty ? stroke.points.map(\.cgPoint) : geometryPoints
        } else {
            points = stroke.points.map(\.cgPoint)
        }
        guard let first = points.first else { return nil }

        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        let widthScale: CGFloat = stroke.tool == "pen" ? 1.2 : 1
        let pad: CGFloat
        if stroke.tool == "text" {
            pad = max(0.75, CGFloat(stroke.width) * 0.08)
        } else {
            pad = max(0.75, CGFloat(stroke.width) * widthScale / 2 + 0.75)
        }
        return CGRect(
            x: minX - pad,
            y: minY - pad,
            width: max(0.001, maxX - minX + pad * 2),
            height: max(0.001, maxY - minY + pad * 2)
        )
    }
}

@MainActor
final class OffPageGridView: UIView {
    var sourcePDFFrame: CGRect = .zero {
        didSet { setNeedsDisplay() }
    }
    var isGridActive = false {
        didSet { setNeedsDisplay() }
    }
    var gridStyle: OffPageGridStyle = .system {
        didSet { setNeedsDisplay() }
    }
    var gridSpacing: CGFloat = 20 {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if gridStyle == .system { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard isGridActive,
              let context = UIGraphicsGetCurrentContext(),
              bounds.width > 0,
              bounds.height > 0 else { return }

        let palette = Self.palette(for: gridStyle, traits: traitCollection)
        let sideRects = [
            CGRect(x: bounds.minX, y: bounds.minY, width: max(0, sourcePDFFrame.minX - bounds.minX), height: bounds.height),
            CGRect(x: sourcePDFFrame.maxX, y: bounds.minY, width: max(0, bounds.maxX - sourcePDFFrame.maxX), height: bounds.height),
        ].filter { $0.width > 0.01 }

        context.saveGState()
        context.setFillColor(palette.background.cgColor)
        for side in sideRects { context.fill(side) }

        let spacing = max(4, gridSpacing)
        context.setStrokeColor(palette.line.cgColor)
        context.setLineWidth(0.55 / max(1, contentScaleFactor))

        for side in sideRects {
            context.saveGState()
            context.clip(to: side)
            let firstX = floor(side.minX / spacing) * spacing
            var x = firstX
            while x <= side.maxX + 0.01 {
                context.move(to: CGPoint(x: x, y: side.minY))
                context.addLine(to: CGPoint(x: x, y: side.maxY))
                x += spacing
            }
            let firstY = floor(side.minY / spacing) * spacing
            var y = firstY
            while y <= side.maxY + 0.01 {
                context.move(to: CGPoint(x: side.minX, y: y))
                context.addLine(to: CGPoint(x: side.maxX, y: y))
                y += spacing
            }
            context.strokePath()
            context.restoreGState()
        }
        context.restoreGState()
    }

    private static func palette(for style: OffPageGridStyle, traits: UITraitCollection) -> (background: UIColor, line: UIColor) {
        switch style {
        case .system:
            let background = UIColor.secondarySystemBackground.resolvedColor(with: traits)
            let line = UIColor.separator.resolvedColor(with: traits).withAlphaComponent(0.42)
            return (background, line)
        case .white:
            return (.white, UIColor(white: 0.72, alpha: 0.62))
        case .lightGray:
            return (UIColor(white: 0.86, alpha: 1), UIColor(white: 0.60, alpha: 0.64))
        case .darkGray:
            return (UIColor(white: 0.20, alpha: 1), UIColor(white: 0.48, alpha: 0.68))
        case .black:
            return (.black, UIColor(white: 0.38, alpha: 0.72))
        }
    }
}
