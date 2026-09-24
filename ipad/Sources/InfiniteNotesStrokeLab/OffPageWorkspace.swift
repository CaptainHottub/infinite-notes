import CoreGraphics
import SwiftUI
import UIKit

struct WhiteboardSection: Hashable {
    let column: Int
    let row: Int
}

struct PageWorkspaceState: Equatable {
    var leftPageWidths: Int = 1
    var rightPageWidths: Int = 2
    var topPageHeights: Int = 0
    var bottomPageHeights: Int = 0
    var hasLeftContent = false
    var hasRightContent = false
    var occupiedSections: Set<WhiteboardSection> = []

    func workspacePage(from source: PageInfo) -> PageInfo {
        let pageWidth = max(1, source.width)
        var result = source
        result.x = source.x - Double(leftPageWidths) * pageWidth
        result.y = source.y - Double(topPageHeights) * max(1, source.height)
        result.width = Double(leftPageWidths + 1 + rightPageWidths) * pageWidth
        result.height = Double(topPageHeights + 1 + bottomPageHeights) * max(1, source.height)
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
    static func whiteboardState(sourcePage: PageInfo, strokes: [NoteStroke],
                                visibleLeft: Int, visibleRight: Int,
                                visibleTop: Int, visibleBottom: Int) -> PageWorkspaceState {
        let width = max(1, sourcePage.width)
        let height = max(1, sourcePage.height)
        var result = PageWorkspaceState(
            leftPageWidths: visibleLeft, rightPageWidths: visibleRight,
            topPageHeights: visibleTop, bottomPageHeights: visibleBottom
        )
        for stroke in strokes {
            guard let bounds = strokeWorldBounds(stroke) else { continue }
            let firstColumn = Int(floor((Double(bounds.minX) - sourcePage.x) / width))
            let lastColumn = Int(floor((Double(bounds.maxX) - sourcePage.x) / width))
            let firstRow = Int(floor((Double(bounds.minY) - sourcePage.y) / height))
            let lastRow = Int(floor((Double(bounds.maxY) - sourcePage.y) / height))
            result.leftPageWidths = max(result.leftPageWidths, -firstColumn + 2)
            result.rightPageWidths = max(result.rightPageWidths, lastColumn + 2)
            result.topPageHeights = max(result.topPageHeights, -firstRow + 2)
            result.bottomPageHeights = max(result.bottomPageHeights, lastRow + 2)
            result.occupiedSections.formUnion(
                occupiedWhiteboardSections(stroke, sourcePage: sourcePage)
            )
        }
        return result
    }

    static func occupiedWhiteboardSections(_ stroke: NoteStroke, sourcePage: PageInfo) -> Set<WhiteboardSection> {
        let width = max(1, sourcePage.width)
        let height = max(1, sourcePage.height)
        let geometryPoints = GeometryEngine.isGeometry(stroke)
            ? GeometryEngine.polyline(for: stroke, segments: 72) : []
        let points = geometryPoints.isEmpty ? stroke.points.map(\.cgPoint) : geometryPoints
        guard let first = points.first else { return [] }
        let radius = max(0.75, stroke.width * 0.6)
        var result: Set<WhiteboardSection> = []
        func include(_ point: CGPoint) {
            for x in [Double(point.x) - radius, Double(point.x) + radius] {
                for y in [Double(point.y) - radius, Double(point.y) + radius] {
                    result.insert(WhiteboardSection(
                        column: Int(floor((x - sourcePage.x) / width)),
                        row: Int(floor((y - sourcePage.y) / height))
                    ))
                }
            }
        }
        include(first)
        var previous = first
        for point in points.dropFirst() {
            let deltaX = abs(Double(point.x - previous.x)) / width
            let deltaY = abs(Double(point.y - previous.y)) / height
            let steps = max(1, min(8192, Int(ceil(max(deltaX, deltaY) * 4))))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                include(CGPoint(x: previous.x + (point.x - previous.x) * t,
                                y: previous.y + (point.y - previous.y) * t))
            }
            previous = point
        }
        return result
    }

    static func state(sourcePage: PageInfo, strokes: [NoteStroke],
                      initialLeft: Int, initialRight: Int, extra: Int) -> PageWorkspaceState {
        let sourceRect = sourcePage.worldRect
        let pageWidth = max(1, sourceRect.width)
        var contentBounds: CGRect?

        for stroke in strokes {
            guard let bounds = strokeWorldBounds(stroke) else { continue }
            contentBounds = contentBounds.map { $0.union(bounds) } ?? bounds
        }

        guard let bounds = contentBounds else {
            return PageWorkspaceState(leftPageWidths: initialLeft, rightPageWidths: initialRight)
        }

        let leftOverflow = max(0, sourceRect.minX - bounds.minX)
        let rightOverflow = max(0, bounds.maxX - sourceRect.maxX)
        let hasLeft = leftOverflow > 0.01
        let hasRight = rightOverflow > 0.01
        return PageWorkspaceState(
            leftPageWidths: max(initialLeft, hasLeft ? Int(ceil(leftOverflow / pageWidth)) + extra : 0),
            rightPageWidths: max(initialRight, hasRight ? Int(ceil(rightOverflow / pageWidth)) + extra : 0),
            hasLeftContent: hasLeft,
            hasRightContent: hasRight
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
    var whiteboard: WhiteboardInfo? { didSet { setNeedsDisplay() } }
    var occupiedSections: Set<WhiteboardSection> = [] { didSet { setNeedsDisplay() } }
    var sourcePDFFrame: CGRect = .zero {
        didSet { setNeedsDisplay() }
    }
    var hasLeftContent = false { didSet { setNeedsDisplay() } }
    var hasRightContent = false { didSet { setNeedsDisplay() } }
    var emptyOutlineColor = UIColor(red: 0.33, green: 0.53, blue: 0.80, alpha: 1) { didSet { setNeedsDisplay() } }
    var inkedOutlineColor = UIColor(red: 0.43, green: 0.67, blue: 0.47, alpha: 1) { didSet { setNeedsDisplay() } }
    var outlineWidth: CGFloat = 1 { didSet { setNeedsDisplay() } }
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
        if gridStyle == .system || whiteboard?.useSystemColors == true { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              bounds.width > 0,
              bounds.height > 0 else { return }
        if let whiteboard {
            drawWhiteboard(rect, context: context, settings: whiteboard)
            return
        }

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
        for side in sideRects {
            let isLeft = side.maxX <= sourcePDFFrame.minX + 0.01
            let colour = (isLeft ? hasLeftContent : hasRightContent)
                ? inkedOutlineColor : emptyOutlineColor
            context.setStrokeColor(colour.cgColor)
            context.setLineWidth(max(0.25, outlineWidth))
            context.stroke(side.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2))
        }
        context.restoreGState()
    }

    private func drawWhiteboard(_ rect: CGRect, context: CGContext, settings: WhiteboardInfo) {
        context.saveGState()
        context.clip(to: rect)
        let background = settings.useSystemColors
            ? UIColor.secondarySystemBackground.resolvedColor(with: traitCollection)
            : UIColor(Color(hex: settings.backgroundColor))
        let grid = settings.useSystemColors
            ? UIColor.separator.resolvedColor(with: traitCollection).withAlphaComponent(0.42)
            : UIColor(Color(hex: settings.gridColor))
        context.setFillColor(background.cgColor)
        context.fill(rect)
        let origin = sourcePDFFrame.origin
        let spacing = CGFloat(settings.gridSpacing)
        context.setStrokeColor(grid.cgColor)
        context.setLineWidth(CGFloat(settings.gridThickness))
        var x = origin.x + floor((rect.minX - origin.x) / spacing) * spacing
        while x <= rect.maxX {
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }
        var y = origin.y + floor((rect.minY - origin.y) / spacing) * spacing
        while y <= rect.maxY {
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }
        context.strokePath()

        if settings.showOutlines {
            let width = CGFloat(settings.sectionWidth)
            let height = CGFloat(settings.sectionHeight)
            let leftColumn = Int(floor((rect.minX - origin.x) / width))
            let rightColumn = Int(ceil((rect.maxX - origin.x) / width))
            let topRow = Int(floor((rect.minY - origin.y) / height))
            let bottomRow = Int(ceil((rect.maxY - origin.y) / height))
            let empty = UIColor(Color(hex: settings.emptyOutlineColor)).cgColor
            let vertical = UIColor(Color(hex: settings.verticalInkedOutlineColor)).cgColor
            let horizontal = UIColor(Color(hex: settings.horizontalInkedOutlineColor)).cgColor
            context.setLineWidth(1)
            for column in leftColumn...rightColumn {
                let boundaryX = origin.x + CGFloat(column) * width
                for row in topRow..<bottomRow {
                    let both = occupiedSections.contains(WhiteboardSection(column: column - 1, row: row))
                        && occupiedSections.contains(WhiteboardSection(column: column, row: row))
                    context.setStrokeColor(both ? vertical : empty)
                    context.move(to: CGPoint(x: boundaryX, y: origin.y + CGFloat(row) * height))
                    context.addLine(to: CGPoint(x: boundaryX, y: origin.y + CGFloat(row + 1) * height))
                    context.strokePath()
                }
            }
            for row in topRow...bottomRow {
                let boundaryY = origin.y + CGFloat(row) * height
                for column in leftColumn..<rightColumn {
                    let both = occupiedSections.contains(WhiteboardSection(column: column, row: row - 1))
                        && occupiedSections.contains(WhiteboardSection(column: column, row: row))
                    context.setStrokeColor(both ? horizontal : empty)
                    context.move(to: CGPoint(x: origin.x + CGFloat(column) * width, y: boundaryY))
                    context.addLine(to: CGPoint(x: origin.x + CGFloat(column + 1) * width, y: boundaryY))
                    context.strokePath()
                }
            }
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
