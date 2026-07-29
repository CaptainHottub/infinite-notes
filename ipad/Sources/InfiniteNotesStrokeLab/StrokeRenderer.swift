import CoreGraphics
import QuartzCore
import UIKit


struct LiveStrokeLayerDescriptor {
    var path: CGPath
    var fillColor: CGColor?
    var strokeColor: CGColor?
    var lineWidth: CGFloat
    var lineDashPattern: [NSNumber]?
    var lineCap: CAShapeLayerLineCap = .round
    var lineJoin: CAShapeLayerLineJoin = .round
}

enum StrokeRenderer {
    static func draw(
        stroke: NoteStroke,
        page: PageInfo,
        in context: CGContext,
        viewBounds: CGRect,
        configuration: StrokePipelineConfiguration = .default,
        appConfiguration: NativeAppConfiguration = .default,
        isLive: Bool = false
    ) {
        guard !stroke.points.isEmpty else { return }
        switch stroke.tool {
        case "text":
            drawText(stroke: stroke, page: page, in: context, viewBounds: viewBounds)
        case "shape":
            drawShape(stroke: stroke, page: page, in: context, viewBounds: viewBounds, appConfiguration: appConfiguration)
        default:
            drawInk(
                stroke: stroke,
                page: page,
                in: context,
                viewBounds: viewBounds,
                configuration: configuration,
                isLive: isLive
            )
        }
    }

    private static func viewPoint(_ point: NotePoint, page: PageInfo, bounds: CGRect) -> CGPoint {
        let scaleX = bounds.width / max(0.001, CGFloat(page.width))
        let scaleY = bounds.height / max(0.001, CGFloat(page.height))
        return CGPoint(
            x: CGFloat(point.x - page.x) * scaleX,
            y: CGFloat(point.y - page.y) * scaleY
        )
    }

    private static func viewWidth(_ width: Double, page: PageInfo, bounds: CGRect) -> CGFloat {
        let scaleX = bounds.width / max(0.001, CGFloat(page.width))
        let scaleY = bounds.height / max(0.001, CGFloat(page.height))
        return max(0.1, CGFloat(width) * (scaleX + scaleY) / 2)
    }

    private static func drawInk(
        stroke: NoteStroke,
        page: PageInfo,
        in context: CGContext,
        viewBounds: CGRect,
        configuration: StrokePipelineConfiguration,
        isLive: Bool
    ) {
        let samples = StrokeGeometryBuilder.computedSamples(
            stroke: stroke,
            page: page,
            bounds: viewBounds,
            fallback: configuration
        )
        guard let first = samples.first else { return }
        let settings = stroke.pipeline ?? .legacy(smoothing: stroke.smoothing)
        let color = UIColor(noteHex: stroke.color, alpha: CGFloat(stroke.opacity)).cgColor
        let baseWidth = viewWidth(stroke.width, page: page, bounds: viewBounds)

        context.saveGState()
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if samples.count == 1 {
            let scale = stroke.tool == "pen" ? pressureScale(first.pressure, settings: settings) : 1
            let radius = max(0.05, baseWidth * scale / 2)
            context.fillEllipse(in: CGRect(
                x: first.point.x - radius,
                y: first.point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        } else {
            let lineStyle = stroke.lineStyle ?? "solid"
            if lineStyle != "solid" || stroke.tool != "pen" {
                let averageScale: CGFloat = stroke.tool == "pen"
                    ? samples.reduce(0) { $0 + pressureScale($1.pressure, settings: settings) } / CGFloat(samples.count)
                    : 1
                context.setLineWidth(baseWidth * averageScale)
                applyDash(lineStyle, width: baseWidth * averageScale, context: context)
                let path = CGMutablePath()
                path.move(to: first.point)
                for sample in samples.dropFirst() { path.addLine(to: sample.point) }
                context.addPath(path)
                context.strokePath()
            } else if settings.variableWidthRibbon {
                drawVariableWidthRibbon(
                    samples: samples,
                    baseWidth: baseWidth,
                    settings: settings,
                    context: context
                )
            } else {
                drawPressureSegments(
                    samples: samples,
                    baseWidth: baseWidth,
                    settings: settings,
                    context: context
                )
            }
        }
        context.restoreGState()

        if isLive || !configuration.debugLiveStrokeOnly {
            drawDiagnostics(
                stroke: stroke,
                page: page,
                context: context,
                bounds: viewBounds,
                configuration: configuration,
                computed: samples
            )
        }
    }

    /// Builds Core Animation vector layers for the live Pencil preview.
    /// Unlike the committed page cache, these paths do not allocate or repaint
    /// a zoom-sized whole-page bitmap on every Pencil sample.
    static func liveLayerDescriptors(
        stroke: NoteStroke,
        page: PageInfo,
        viewBounds: CGRect,
        configuration: StrokePipelineConfiguration
    ) -> [LiveStrokeLayerDescriptor] {
        vectorLayerDescriptors(
            stroke: stroke,
            page: page,
            viewBounds: viewBounds,
            configuration: configuration,
            includeDiagnostics: true
        )
    }

    /// Builds retained Core Animation vector paths for ink. Sample points become
    /// vertices in one path (or one filled pressure ribbon), not one layer per
    /// sample. Diagnostic dots are also combined into one compound path.
    static func vectorLayerDescriptors(
        stroke: NoteStroke,
        page: PageInfo,
        viewBounds: CGRect,
        configuration: StrokePipelineConfiguration,
        includeDiagnostics: Bool
    ) -> [LiveStrokeLayerDescriptor] {
        guard stroke.tool != "text", stroke.tool != "shape", !stroke.points.isEmpty else { return [] }

        let samples = StrokeGeometryBuilder.computedSamples(
            stroke: stroke,
            page: page,
            bounds: viewBounds,
            fallback: configuration
        )
        guard let first = samples.first else { return [] }
        let settings = stroke.pipeline ?? .legacy(smoothing: stroke.smoothing)
        let color = UIColor(noteHex: stroke.color, alpha: CGFloat(stroke.opacity)).cgColor
        let baseWidth = viewWidth(stroke.width, page: page, bounds: viewBounds)
        var result: [LiveStrokeLayerDescriptor] = []

        if samples.count == 1 {
            let scale = stroke.tool == "pen" ? pressureScale(first.pressure, settings: settings) : 1
            let radius = max(0.05, baseWidth * scale / 2)
            let path = CGPath(ellipseIn: CGRect(
                x: first.point.x - radius,
                y: first.point.y - radius,
                width: radius * 2,
                height: radius * 2
            ), transform: nil)
            result.append(LiveStrokeLayerDescriptor(
                path: path,
                fillColor: color,
                strokeColor: nil,
                lineWidth: 0,
                lineDashPattern: nil
            ))
        } else {
            let lineStyle = stroke.lineStyle ?? "solid"
            if lineStyle == "solid", stroke.tool == "pen", settings.variableWidthRibbon {
                result.append(LiveStrokeLayerDescriptor(
                    path: variableWidthRibbonPath(samples: samples, baseWidth: baseWidth, settings: settings),
                    fillColor: color,
                    strokeColor: nil,
                    lineWidth: 0,
                    lineDashPattern: nil
                ))
            } else {
                let path = polylinePath(samples)
                let averageScale: CGFloat = stroke.tool == "pen"
                    ? samples.reduce(0) { $0 + pressureScale($1.pressure, settings: settings) } / CGFloat(samples.count)
                    : 1
                let width = baseWidth * averageScale
                result.append(LiveStrokeLayerDescriptor(
                    path: path,
                    fillColor: nil,
                    strokeColor: color,
                    lineWidth: width,
                    lineDashPattern: dashPattern(lineStyle, width: width)
                ))
            }
        }

        if includeDiagnostics {
            result.append(contentsOf: liveDiagnosticDescriptors(
                stroke: stroke,
                page: page,
                bounds: viewBounds,
                configuration: configuration,
                computed: samples
            ))
        }
        return result
    }

    private static func liveDiagnosticDescriptors(
        stroke: NoteStroke,
        page: PageInfo,
        bounds: CGRect,
        configuration: StrokePipelineConfiguration,
        computed: [StrokeGeometrySample]
    ) -> [LiveStrokeLayerDescriptor] {
        var result: [LiveStrokeLayerDescriptor] = []

        func addLine(_ samples: [StrokeGeometrySample], color: UIColor, width: CGFloat, dash: [NSNumber]? = nil) {
            guard samples.count > 1 else { return }
            result.append(LiveStrokeLayerDescriptor(
                path: polylinePath(samples),
                fillColor: nil,
                strokeColor: color.cgColor,
                lineWidth: width,
                lineDashPattern: dash
            ))
        }

        func addDots(_ samples: [StrokeGeometrySample], color: UIColor, diameter value: Double) {
            guard !samples.isEmpty else { return }
            let diameter = CGFloat(max(0.1, value))
            let radius = diameter / 2
            let path = CGMutablePath()
            for sample in samples {
                path.addEllipse(in: CGRect(
                    x: sample.point.x - radius,
                    y: sample.point.y - radius,
                    width: diameter,
                    height: diameter
                ))
            }
            result.append(LiveStrokeLayerDescriptor(
                path: path,
                fillColor: color.cgColor,
                strokeColor: nil,
                lineWidth: 0,
                lineDashPattern: nil
            ))
        }

        if configuration.showRawConnections || configuration.showRawPoints {
            let raw = StrokeGeometryBuilder.rawSamples(stroke: stroke, page: page, bounds: bounds)
            if configuration.showRawConnections {
                addLine(raw, color: UIColor.lightGray.withAlphaComponent(0.85), width: 0.8)
            }
            if configuration.showRawPoints { addDots(raw, color: .systemRed, diameter: configuration.resolvedRawPointDiameter) }
        }

        if configuration.showFilteredConnections || configuration.showFilteredPoints {
            let filtered = StrokeGeometryBuilder.filteredSamples(stroke: stroke, page: page, bounds: bounds)
            if configuration.showFilteredConnections {
                addLine(filtered, color: UIColor.systemOrange.withAlphaComponent(0.65), width: 0.9)
            }
            if configuration.showFilteredPoints { addDots(filtered, color: .systemOrange, diameter: configuration.resolvedFilteredPointDiameter) }
        }

        if configuration.showComputedConnections {
            addLine(computed, color: UIColor.systemBlue.withAlphaComponent(0.55), width: 0.9)
        }
        if configuration.showComputedCenterline {
            addLine(computed, color: UIColor.systemPurple.withAlphaComponent(0.8), width: 1.2, dash: [4, 3])
        }
        if configuration.showComputedPoints { addDots(computed, color: .systemBlue, diameter: configuration.resolvedComputedPointDiameter) }
        return result
    }

    private static func polylinePath(_ samples: [StrokeGeometrySample]) -> CGPath {
        let path = CGMutablePath()
        guard let first = samples.first else { return path }
        path.move(to: first.point)
        for sample in samples.dropFirst() { path.addLine(to: sample.point) }
        return path
    }

    private static func dashPattern(_ style: String, width: CGFloat) -> [NSNumber]? {
        switch style {
        case "dashed": return [NSNumber(value: Double(max(5, width * 3.2))), NSNumber(value: Double(max(4, width * 2)))]
        case "dotted": return [NSNumber(value: Double(max(0.5, width * 0.18))), NSNumber(value: Double(max(4, width * 2.1)))]
        default: return nil
        }
    }

    private static func pressureScale(
        _ pressure: Double,
        settings: StrokePipelineSnapshot
    ) -> CGFloat {
        let normalized = max(0, min(1, pressure))
        let gamma = max(0.05, settings.pressureGamma)
        let curved = pow(normalized, gamma)
        let minimum = settings.minimumPressureScale
        let maximum = max(minimum, settings.maximumPressureScale)
        return CGFloat(minimum + (maximum - minimum) * curved)
    }

    private static func drawPressureSegments(
        samples: [StrokeGeometrySample],
        baseWidth: CGFloat,
        settings: StrokePipelineSnapshot,
        context: CGContext
    ) {
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            let width = baseWidth
                * (pressureScale(previous.pressure, settings: settings)
                   + pressureScale(current.pressure, settings: settings)) / 2
            context.setLineWidth(width)
            context.beginPath()
            context.move(to: previous.point)
            context.addLine(to: current.point)
            context.strokePath()
        }
    }

    /// Produces one closed, filled outline for the entire pressure stroke. This
    /// removes the overlapping round-cap "beads" created by segment rendering.
    private static func drawVariableWidthRibbon(
        samples: [StrokeGeometrySample],
        baseWidth: CGFloat,
        settings: StrokePipelineSnapshot,
        context: CGContext
    ) {
        guard samples.count >= 2 else { return }
        context.addPath(variableWidthRibbonPath(
            samples: samples,
            baseWidth: baseWidth,
            settings: settings
        ))
        context.fillPath()
    }

    private static func variableWidthRibbonPath(
        samples: [StrokeGeometrySample],
        baseWidth: CGFloat,
        settings: StrokePipelineSnapshot
    ) -> CGPath {
        guard samples.count >= 2 else { return CGMutablePath() }
        var cumulative = Array(repeating: CGFloat.zero, count: samples.count)
        for index in 1..<samples.count {
            cumulative[index] = cumulative[index - 1] + distance(samples[index - 1].point, samples[index].point)
        }
        let totalLength = max(0.001, cumulative.last ?? 0.001)
        let startTaper = CGFloat(max(0, settings.startTaperLength))
        let endTaper = CGFloat(max(0, settings.endTaperLength))
        let minimumTaper = CGFloat(max(0.01, min(1, settings.taperMinimumScale)))

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        var halfWidths: [CGFloat] = []
        left.reserveCapacity(samples.count)
        right.reserveCapacity(samples.count)
        halfWidths.reserveCapacity(samples.count)

        for index in samples.indices {
            let previous = samples[max(0, index - 1)].point
            let next = samples[min(samples.count - 1, index + 1)].point
            let tangent = normalized(CGPoint(x: next.x - previous.x, y: next.y - previous.y))
            let normal = CGPoint(x: -tangent.y, y: tangent.x)

            var taper: CGFloat = 1
            if startTaper > 0 {
                let progress = min(1, cumulative[index] / startTaper)
                taper *= minimumTaper + (1 - minimumTaper) * progress
            }
            if endTaper > 0 {
                let remaining = totalLength - cumulative[index]
                let progress = min(1, remaining / endTaper)
                taper *= minimumTaper + (1 - minimumTaper) * progress
            }

            let halfWidth = max(
                0.2,
                baseWidth * pressureScale(samples[index].pressure, settings: settings) * taper / 2
            )
            halfWidths.append(halfWidth)
            left.append(CGPoint(
                x: samples[index].point.x + normal.x * halfWidth,
                y: samples[index].point.y + normal.y * halfWidth
            ))
            right.append(CGPoint(
                x: samples[index].point.x - normal.x * halfWidth,
                y: samples[index].point.y - normal.y * halfWidth
            ))
        }

        let path = CGMutablePath()
        path.move(to: left[0])
        for point in left.dropFirst() { path.addLine(to: point) }

        let endTangent = normalized(CGPoint(
            x: samples[samples.count - 1].point.x - samples[samples.count - 2].point.x,
            y: samples[samples.count - 1].point.y - samples[samples.count - 2].point.y
        ))
        let endControl = CGPoint(
            x: samples.last!.point.x + endTangent.x * halfWidths.last!,
            y: samples.last!.point.y + endTangent.y * halfWidths.last!
        )
        path.addQuadCurve(to: right[right.count - 1], control: endControl)

        if right.count >= 2 {
            for index in stride(from: right.count - 2, through: 0, by: -1) {
                path.addLine(to: right[index])
            }
        }

        let startTangent = normalized(CGPoint(
            x: samples[1].point.x - samples[0].point.x,
            y: samples[1].point.y - samples[0].point.y
        ))
        let startControl = CGPoint(
            x: samples[0].point.x - startTangent.x * halfWidths[0],
            y: samples[0].point.y - startTangent.y * halfWidths[0]
        )
        path.addQuadCurve(to: left[0], control: startControl)
        path.closeSubpath()
        return path
    }

    private static func drawDiagnostics(
        stroke: NoteStroke,
        page: PageInfo,
        context: CGContext,
        bounds: CGRect,
        configuration: StrokePipelineConfiguration,
        computed: [StrokeGeometrySample]
    ) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if configuration.showRawConnections || configuration.showRawPoints {
            let raw = StrokeGeometryBuilder.rawSamples(stroke: stroke, page: page, bounds: bounds)
            if configuration.showRawConnections {
                drawDiagnosticPolyline(raw, color: UIColor.lightGray.withAlphaComponent(0.85), width: 0.8, context: context)
            }
            if configuration.showRawPoints {
                drawDiagnosticPoints(raw, color: .systemRed, diameter: configuration.resolvedRawPointDiameter, context: context)
            }
        }

        if configuration.showFilteredConnections || configuration.showFilteredPoints {
            let filtered = StrokeGeometryBuilder.filteredSamples(stroke: stroke, page: page, bounds: bounds)
            if configuration.showFilteredConnections {
                drawDiagnosticPolyline(filtered, color: UIColor.systemOrange.withAlphaComponent(0.65), width: 0.9, context: context)
            }
            if configuration.showFilteredPoints {
                drawDiagnosticPoints(filtered, color: .systemOrange, diameter: configuration.resolvedFilteredPointDiameter, context: context)
            }
        }

        if configuration.showComputedConnections || configuration.showComputedCenterline {
            let color = configuration.showComputedCenterline
                ? UIColor.systemPurple.withAlphaComponent(0.8)
                : UIColor.systemBlue.withAlphaComponent(0.55)
            if configuration.showComputedCenterline {
                context.setLineDash(phase: 0, lengths: [4, 3])
            }
            drawDiagnosticPolyline(computed, color: color, width: configuration.showComputedCenterline ? 1.2 : 0.9, context: context)
            context.setLineDash(phase: 0, lengths: [])
        }
        if configuration.showComputedPoints {
            drawDiagnosticPoints(computed, color: .systemBlue, diameter: configuration.resolvedComputedPointDiameter, context: context)
        }
        context.restoreGState()
    }

    private static func drawDiagnosticPolyline(
        _ samples: [StrokeGeometrySample],
        color: UIColor,
        width: CGFloat,
        context: CGContext
    ) {
        guard let first = samples.first, samples.count > 1 else { return }
        let path = CGMutablePath()
        path.move(to: first.point)
        for sample in samples.dropFirst() { path.addLine(to: sample.point) }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.addPath(path)
        context.strokePath()
    }

    private static func drawDiagnosticPoints(
        _ samples: [StrokeGeometrySample],
        color: UIColor,
        diameter: Double,
        context: CGContext
    ) {
        let size = CGFloat(max(0.1, diameter))
        let radius = size / 2
        context.setFillColor(color.cgColor)
        for sample in samples {
            context.fillEllipse(in: CGRect(
                x: sample.point.x - radius,
                y: sample.point.y - radius,
                width: size,
                height: size
            ))
        }
    }

    private static func normalized(_ vector: CGPoint) -> CGPoint {
        let length = hypot(vector.x, vector.y)
        guard length > 0.000_01 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: vector.x / length, y: vector.y / length)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func drawShape(stroke: NoteStroke, page: PageInfo, in context: CGContext, viewBounds: CGRect, appConfiguration: NativeAppConfiguration) {
        let points = stroke.points.map { viewPoint($0, page: page, bounds: viewBounds) }
        guard !points.isEmpty else { return }
        let width = viewWidth(stroke.width, page: page, bounds: viewBounds)
        context.saveGState()
        context.setStrokeColor(UIColor(noteHex: stroke.color, alpha: CGFloat(stroke.opacity)).cgColor)
        context.setFillColor(UIColor(noteHex: stroke.color, alpha: CGFloat(stroke.opacity)).cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        applyDash(stroke.lineStyle ?? "solid", width: width, context: context)

        switch stroke.shapeType ?? "" {
        case "line":
            drawPolyline(points.prefix(2), context: context)
        case "arrow":
            drawPolyline(points.prefix(2), context: context)
            if points.count >= 2 { drawArrowHead(from: points[0], to: points[1], width: width, context: context) }
        case "curve":
            if points.count >= 3 {
                context.beginPath()
                context.move(to: points[0])
                context.addQuadCurve(to: points[2], control: points[1])
                context.strokePath()
            }
        case "ellipse", "circle":
            drawRotatedEllipse(points: points, context: context)
        case "triangle":
            guard points.count >= 4 else { break }
            let box = boxGeometry(points)
            let triangle = [
                localPoint(x: box.width / 2, y: 0, box: box),
                localPoint(x: box.width, y: box.height, box: box),
                localPoint(x: 0, y: box.height, box: box),
                localPoint(x: box.width / 2, y: 0, box: box),
            ]
            drawPolyline(triangle, context: context)
        case "diamond":
            guard points.count >= 4 else { break }
            let box = boxGeometry(points)
            let diamond = [
                localPoint(x: box.width / 2, y: 0, box: box),
                localPoint(x: box.width, y: box.height / 2, box: box),
                localPoint(x: box.width / 2, y: box.height, box: box),
                localPoint(x: 0, y: box.height / 2, box: box),
                localPoint(x: box.width / 2, y: 0, box: box),
            ]
            drawPolyline(diamond, context: context)
        case "xy-plane":
            guard points.count >= 4 else { break }
            let box = boxGeometry(points)
            context.saveGState()
            context.setAlpha(min(0.45, CGFloat(stroke.opacity)))
            context.setStrokeColor(UIColor(noteHex: stroke.gridColor ?? "#7a7f89", alpha: 1).cgColor)
            context.setLineWidth(max(0.45, width * 0.34))
            context.setLineDash(phase: 0, lengths: [])
            let divisions = max(2, min(40, appConfiguration.xyPlaneGridDivisions))
            context.beginPath()
            for index in 1..<divisions {
                let x = box.width * CGFloat(index) / CGFloat(divisions)
                let y = box.height * CGFloat(index) / CGFloat(divisions)
                let verticalStart = localPoint(x: x, y: 0, box: box)
                let verticalEnd = localPoint(x: x, y: box.height, box: box)
                let horizontalStart = localPoint(x: 0, y: y, box: box)
                let horizontalEnd = localPoint(x: box.width, y: y, box: box)
                context.move(to: verticalStart)
                context.addLine(to: verticalEnd)
                context.move(to: horizontalStart)
                context.addLine(to: horizontalEnd)
            }
            context.strokePath()
            context.restoreGState()

            context.setAlpha(CGFloat(stroke.opacity))
            context.setStrokeColor(UIColor(noteHex: stroke.color, alpha: 1).cgColor)
            context.setFillColor(UIColor(noteHex: stroke.color, alpha: 1).cgColor)
            context.setLineWidth(max(1, width))
            context.setLineDash(phase: 0, lengths: [])
            let xStart = localPoint(x: 0, y: box.height / 2, box: box)
            let xEnd = localPoint(x: box.width, y: box.height / 2, box: box)
            let yStart = localPoint(x: box.width / 2, y: box.height, box: box)
            let yEnd = localPoint(x: box.width / 2, y: 0, box: box)
            drawPolyline([xStart, xEnd], context: context)
            drawPolyline([yStart, yEnd], context: context)
            drawArrowHead(from: localPoint(x: max(0, box.width - 20), y: box.height / 2, box: box), to: xEnd, width: width, context: context)
            drawArrowHead(from: localPoint(x: box.width / 2, y: min(box.height, 20), box: box), to: yEnd, width: width, context: context)

            let fontSize = max(10, width * 4)
            let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor(noteHex: stroke.color, alpha: 0.82),
            ]
            NSString(string: "x").draw(at: CGPoint(x: xEnd.x - fontSize * 1.1, y: xEnd.y - fontSize * 1.1), withAttributes: attributes)
            NSString(string: "y").draw(at: CGPoint(x: yEnd.x + fontSize * 0.35, y: yEnd.y + fontSize * 0.15), withAttributes: attributes)
        default:
            if points.count >= 4 {
                drawPolyline([points[0], points[1], points[2], points[3], points[0]], context: context)
            }
        }
        context.restoreGState()
    }

    private static func drawText(stroke: NoteStroke, page: PageInfo, in context: CGContext, viewBounds: CGRect) {
        let points = stroke.points.map { viewPoint($0, page: page, bounds: viewBounds) }
        guard points.count >= 4, let text = stroke.text, !text.isEmpty else { return }
        let box = boxGeometry(points)
        let fontSize = max(1, viewWidth(stroke.width, page: page, bounds: viewBounds))
        let paragraph = NSMutableParagraphStyle()
        switch stroke.textAlign {
        case "center": paragraph.alignment = .center
        case "right": paragraph.alignment = .right
        default: paragraph.alignment = .left
        }
        let family: String
        switch stroke.fontFamily {
        case "serif": family = "Times New Roman"
        case "monospace": family = "Menlo"
        default: family = ".AppleSystemUIFont"
        }
        let font = UIFont(name: family, size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(noteHex: stroke.color, alpha: CGFloat(stroke.opacity)),
            .paragraphStyle: paragraph,
        ]

        context.saveGState()
        context.translateBy(x: box.topLeft.x, y: box.topLeft.y)
        context.rotate(by: box.angle)
        context.clip(to: CGRect(x: 0, y: 0, width: box.width, height: box.height))
        let rect = CGRect(x: max(2, fontSize * 0.16), y: max(2, fontSize * 0.16), width: max(1, box.width - fontSize * 0.32), height: max(1, box.height - fontSize * 0.32))
        NSString(string: text).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        context.restoreGState()
    }

    private static func applyDash(_ style: String, width: CGFloat, context: CGContext) {
        switch style {
        case "dashed": context.setLineDash(phase: 0, lengths: [max(5, width * 3.2), max(4, width * 2)])
        case "dotted": context.setLineDash(phase: 0, lengths: [max(0.5, width * 0.18), max(4, width * 2.1)])
        default: context.setLineDash(phase: 0, lengths: [])
        }
    }

    private static func drawPolyline<S: Sequence>(_ points: S, context: CGContext) where S.Element == CGPoint {
        var iterator = points.makeIterator()
        guard let first = iterator.next() else { return }
        context.beginPath()
        context.move(to: first)
        while let point = iterator.next() { context.addLine(to: point) }
        context.strokePath()
    }

    private static func drawArrowHead(from start: CGPoint, to end: CGPoint, width: CGFloat, context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let size = max(9, width * 4.5)
        context.setLineDash(phase: 0, lengths: [])
        context.beginPath()
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - cos(angle - .pi / 6) * size, y: end.y - sin(angle - .pi / 6) * size))
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - cos(angle + .pi / 6) * size, y: end.y - sin(angle + .pi / 6) * size))
        context.strokePath()
    }

    private struct BoxGeometry {
        var topLeft: CGPoint
        var width: CGFloat
        var height: CGFloat
        var ux: CGVector
        var uy: CGVector
        var angle: CGFloat
    }

    private static func boxGeometry(_ points: [CGPoint]) -> BoxGeometry {
        let topLeft = points[0]
        let topRight = points.count > 1 ? points[1] : points[0]
        let bottomLeft = points.count > 3 ? points[3] : points[0]
        let width = max(0.001, hypot(topRight.x - topLeft.x, topRight.y - topLeft.y))
        let height = max(0.001, hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y))
        return BoxGeometry(
            topLeft: topLeft,
            width: width,
            height: height,
            ux: CGVector(dx: (topRight.x - topLeft.x) / width, dy: (topRight.y - topLeft.y) / width),
            uy: CGVector(dx: (bottomLeft.x - topLeft.x) / height, dy: (bottomLeft.y - topLeft.y) / height),
            angle: atan2(topRight.y - topLeft.y, topRight.x - topLeft.x)
        )
    }

    private static func localPoint(x: CGFloat, y: CGFloat, box: BoxGeometry) -> CGPoint {
        CGPoint(
            x: box.topLeft.x + box.ux.dx * x + box.uy.dx * y,
            y: box.topLeft.y + box.ux.dy * x + box.uy.dy * y
        )
    }

    private static func drawRotatedEllipse(points: [CGPoint], context: CGContext) {
        guard points.count >= 4 else { return }
        let box = boxGeometry(points)
        context.saveGState()
        context.translateBy(x: box.topLeft.x, y: box.topLeft.y)
        context.rotate(by: box.angle)
        context.strokeEllipse(in: CGRect(x: 0, y: 0, width: box.width, height: box.height))
        context.restoreGState()
    }
}
