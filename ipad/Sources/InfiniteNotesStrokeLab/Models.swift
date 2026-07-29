import CoreGraphics
import Foundation
import SwiftUI
import UIKit

enum NoteTool: String, CaseIterable, Identifiable, Codable {
    case pressurePen = "pen"
    /// Retained only so old saved preferences and legacy stroke routing decode.
    /// It is intentionally hidden from the toolbar; Pen pressure is now a toggle.
    case fixedPen = "fixed-pen"
    case highlighter = "highlighter"
    case eraser = "eraser"
    case selector = "selector"
    case shape = "shape"

    static var allCases: [NoteTool] {
        [.pressurePen, .eraser, .highlighter, .selector, .shape]
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pressurePen: return "Pen"
        case .fixedPen: return "Pen"
        case .highlighter: return "Highlight"
        case .eraser: return "Eraser"
        case .selector: return "Select"
        case .shape: return "Geometry"
        }
    }

    var symbolName: String {
        switch self {
        case .pressurePen: return "pencil.tip"
        case .fixedPen: return "pencil.line"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .selector: return "lasso"
        case .shape: return "square.on.circle"
        }
    }
}



enum GeometryShapeType: String, CaseIterable, Identifiable, Codable {
    case line, arrow, curve, rectangle, square, ellipse, circle, triangle, diamond
    case xyPlane = "xy-plane"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .curve: return "Curve"
        case .rectangle: return "Rectangle"
        case .square: return "Square"
        case .ellipse: return "Ellipse"
        case .circle: return "Circle"
        case .triangle: return "Triangle"
        case .diamond: return "Diamond"
        case .xyPlane: return "X–Y plane"
        }
    }

    var symbolName: String {
        switch self {
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .curve: return "point.topleft.down.curvedto.point.bottomright.up"
        case .rectangle: return "rectangle"
        case .square: return "square"
        case .ellipse: return "oval"
        case .circle: return "circle"
        case .triangle: return "triangle"
        case .diamond: return "diamond"
        case .xyPlane: return "chart.xyaxis.line"
        }
    }

    var usesBoxPoints: Bool {
        ![.line, .arrow, .curve].contains(self)
    }
}

enum GeometryLineStyle: String, CaseIterable, Identifiable, Codable {
    case solid, dashed, dotted
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum OffPageGridStyle: String, CaseIterable, Identifiable, Codable {
    case system
    case white
    case lightGray = "light-gray"
    case darkGray = "dark-gray"
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .white: return "White"
        case .lightGray: return "Light gray"
        case .darkGray: return "Dark gray"
        case .black: return "Black"
        }
    }
}

enum NotebookBackgroundStyle: String, CaseIterable, Identifiable, Codable {
    case system, lightGray = "light-gray", darkGray = "dark-gray", black
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .lightGray: return "Light gray"
        case .darkGray: return "Dark gray"
        case .black: return "Black"
        }
    }
}

struct NativeAppConfiguration: Codable, Equatable {
    // Display and page engine
    var backgroundStyle: NotebookBackgroundStyle = .system
    /// Optional so existing saved configurations continue decoding after this experimental feature is added.
    var offPageGridStyle: OffPageGridStyle?
    var offPageGridSpacing: Double?
    var showPageShadow = true
    var pageGap = 18.0
    var pageWorkingRadius = 2
    var maximumZoom = 12.0
    var showStatusBar = true
    /// Optional so existing saved settings continue decoding after diagnostics UI additions.
    var showFPSInStatusBar: Bool?
    var showPipelineDiagnosticsSidebar: Bool?

    // Geometry creation and snapping
    var geometryLineStyle: GeometryLineStyle = .solid
    var holdRecognitionEnabled = true
    var recognitionHoldMS = 700.0
    var lineRecognitionTolerance = 7.0
    var curveRecognitionTolerance = 13.0
    var endpointSnap = true
    var axisSnap = true
    var tangentSnap = true
    var normalSnap = true
    var geometrySnapDistance = 14.0
    var showSnapGuides = true
    var lockNewXYPlanes = true
    var xyPlaneGridDivisions = 10
    var xyPlaneWidthFraction = 0.70
    var xyPlaneHeightFraction = 0.55

    // Selection
    var lassoSampleSpacing = 2.0
    var selectorHitRadius = 10.0
    var selectionHandleSize = 11.0
    var showSelectionBounds = true
    var selectLockedItemsOnlyByLasso = true
    var pasteOffset = 24.0

    // Interaction and performance
    var hapticsEnabled = true
    var reduceNeighbourInkQuality = true

    var resolvedOffPageGridStyle: OffPageGridStyle {
        offPageGridStyle ?? .system
    }

    var resolvedOffPageGridSpacing: Double {
        max(4, min(200, offPageGridSpacing ?? 20))
    }

    var resolvedShowFPSInStatusBar: Bool {
        showFPSInStatusBar ?? false
    }

    var resolvedShowPipelineDiagnosticsSidebar: Bool {
        showPipelineDiagnosticsSidebar ?? false
    }

    static let `default` = NativeAppConfiguration()
}

enum InputSmoothingAlgorithm: String, CaseIterable, Identifiable, Codable {
    case none
    case exponential
    case oneEuro = "one-euro"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .exponential: return "Adaptive exponential"
        case .oneEuro: return "One Euro"
        }
    }
}

enum SplineAlgorithm: String, CaseIterable, Identifiable, Codable {
    case polyline
    case quadraticMidpoint = "quadratic-midpoint"
    case catmullRomUniform = "catmull-rom-uniform"
    case catmullRomCentripetal = "catmull-rom-centripetal"
    case cubicBezier = "cubic-bezier"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .polyline: return "Polyline"
        case .quadraticMidpoint: return "Quadratic midpoint"
        case .catmullRomUniform: return "Catmull–Rom (uniform)"
        case .catmullRomCentripetal: return "Catmull–Rom (centripetal)"
        case .cubicBezier: return "Cubic Bézier"
        }
    }
}

struct StrokePipelineConfiguration: Codable, Equatable {
    // Capture
    var useCoalescedTouches = true
    var usePredictedTouches = true
    var pressureThreshold = 0.02
    var minimumSampleSpacing = 0.65
    var pressureDeltaThreshold = 0.015
    var networkBatchSize = 24
    var networkFlushIntervalMS = 8.0

    // Input filtering
    var inputSmoothingAlgorithm: InputSmoothingAlgorithm = .oneEuro
    var smoothingStrength = 0.52
    var adaptiveSmoothing = true
    var pressureSmoothing = 0.32
    var oneEuroMinCutoff = 1.15
    var oneEuroBeta = 0.028
    var oneEuroDerivativeCutoff = 1.0

    // Geometry
    var resamplingEnabled = true
    var resampleSpacing = 1.05
    var splineAlgorithm: SplineAlgorithm = .catmullRomCentripetal
    var splineSampleSpacing = 0.9
    var splineTension = 0.12
    var computedPressureSmoothing = 0.18

    // Width/ribbon
    var variableWidthRibbon = true
    var minimumPressureScale = 0.24
    var maximumPressureScale = 1.22
    var pressureGamma = 0.72
    var startTaperLength = 1.5
    var endTaperLength = 2.0
    var taperMinimumScale = 0.18

    // Legacy persisted values retained for compatibility with older settings.
    // Vector ink rendering no longer uses a page bitmap cache.
    var maximumInkCacheScale = 8.0
    var maximumInkCacheMegapixels = 28.0

    // Diagnostics
    var debugLiveStrokeOnly = true
    var showRawPoints = false
    var showRawConnections = false
    var showFilteredPoints = false
    var showFilteredConnections = false
    var showComputedPoints = false
    var showComputedConnections = false
    var showComputedCenterline = false
    /// Legacy shared diameter retained so older saved settings continue decoding.
    var debugPointDiameter = 4.0
    var rawPointDiameter: Double?
    var filteredPointDiameter: Double?
    var computedPointDiameter: Double?

    var resolvedRawPointDiameter: Double {
        max(0.1, min(32, rawPointDiameter ?? debugPointDiameter))
    }

    var resolvedFilteredPointDiameter: Double {
        max(0.1, min(32, filteredPointDiameter ?? debugPointDiameter))
    }

    var resolvedComputedPointDiameter: Double {
        max(0.1, min(32, computedPointDiameter ?? debugPointDiameter))
    }

    static let `default` = StrokePipelineConfiguration()
}

/// Appearance-affecting settings stored with each new stroke. This keeps old
/// strokes visually stable when the global pipeline settings are changed later.
struct StrokePipelineSnapshot: Codable, Equatable {
    var resamplingEnabled: Bool
    var resampleSpacing: Double
    var splineAlgorithm: SplineAlgorithm
    var splineSampleSpacing: Double
    var splineTension: Double
    var computedPressureSmoothing: Double
    var variableWidthRibbon: Bool
    var minimumPressureScale: Double
    var maximumPressureScale: Double
    var pressureGamma: Double
    var startTaperLength: Double
    var endTaperLength: Double
    var taperMinimumScale: Double

    init(configuration: StrokePipelineConfiguration) {
        resamplingEnabled = configuration.resamplingEnabled
        resampleSpacing = configuration.resampleSpacing
        splineAlgorithm = configuration.splineAlgorithm
        splineSampleSpacing = configuration.splineSampleSpacing
        splineTension = configuration.splineTension
        computedPressureSmoothing = configuration.computedPressureSmoothing
        variableWidthRibbon = configuration.variableWidthRibbon
        minimumPressureScale = configuration.minimumPressureScale
        maximumPressureScale = configuration.maximumPressureScale
        pressureGamma = configuration.pressureGamma
        startTaperLength = configuration.startTaperLength
        endTaperLength = configuration.endTaperLength
        taperMinimumScale = configuration.taperMinimumScale
    }

    static func legacy(smoothing: Double) -> StrokePipelineSnapshot {
        var configuration = StrokePipelineConfiguration.default
        configuration.smoothingStrength = max(0, min(1, smoothing / 100))
        return StrokePipelineSnapshot(configuration: configuration)
    }
}

struct NotePoint: Codable, Hashable {
    /// Filtered world/document coordinates retained for v24 compatibility.
    var x: Double
    var y: Double
    var p: Double
    var t: Double

    /// Unfiltered Pencil coordinates in the same world/document coordinate space.
    var xRaw: Double
    var yRaw: Double

    /// Optional coordinates relative to the originating PDF page. Native code
    /// prefers these when available; v24 continues using x/y.
    var xLocal: Double?
    var yLocal: Double?
    var xRawLocal: Double?
    var yRawLocal: Double?

    var altitude: Double?
    var azimuth: Double?

    init(
        x: Double,
        y: Double,
        p: Double,
        t: Double,
        xRaw: Double? = nil,
        yRaw: Double? = nil,
        xLocal: Double? = nil,
        yLocal: Double? = nil,
        xRawLocal: Double? = nil,
        yRawLocal: Double? = nil,
        altitude: Double? = nil,
        azimuth: Double? = nil
    ) {
        self.x = x
        self.y = y
        self.p = p
        self.t = t
        self.xRaw = xRaw ?? x
        self.yRaw = yRaw ?? y
        self.xLocal = xLocal
        self.yLocal = yLocal
        self.xRawLocal = xRawLocal
        self.yRawLocal = yRawLocal
        self.altitude = altitude
        self.azimuth = azimuth
    }

    enum CodingKeys: String, CodingKey {
        case x, y, p, t
        case xRaw = "x_raw"
        case yRaw = "y_raw"
        case xLocal = "x_local"
        case yLocal = "y_local"
        case xRawLocal = "x_raw_local"
        case yRawLocal = "y_raw_local"
        case altitude, azimuth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        p = try container.decodeIfPresent(Double.self, forKey: .p) ?? 0.5
        t = try container.decodeIfPresent(Double.self, forKey: .t) ?? 0
        xRaw = try container.decodeIfPresent(Double.self, forKey: .xRaw) ?? x
        yRaw = try container.decodeIfPresent(Double.self, forKey: .yRaw) ?? y
        xLocal = try container.decodeIfPresent(Double.self, forKey: .xLocal)
        yLocal = try container.decodeIfPresent(Double.self, forKey: .yLocal)
        xRawLocal = try container.decodeIfPresent(Double.self, forKey: .xRawLocal)
        yRawLocal = try container.decodeIfPresent(Double.self, forKey: .yRawLocal)
        altitude = try container.decodeIfPresent(Double.self, forKey: .altitude)
        azimuth = try container.decodeIfPresent(Double.self, forKey: .azimuth)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(p, forKey: .p)
        try container.encode(t, forKey: .t)
        try container.encode(xRaw, forKey: .xRaw)
        try container.encode(yRaw, forKey: .yRaw)
        try container.encodeIfPresent(xLocal, forKey: .xLocal)
        try container.encodeIfPresent(yLocal, forKey: .yLocal)
        try container.encodeIfPresent(xRawLocal, forKey: .xRawLocal)
        try container.encodeIfPresent(yRawLocal, forKey: .yRawLocal)
        try container.encodeIfPresent(altitude, forKey: .altitude)
        try container.encodeIfPresent(azimuth, forKey: .azimuth)
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct NoteStroke: Codable, Identifiable, Equatable {
    var id: String
    var tool: String
    var color: String
    var width: Double
    var opacity: Double
    var smoothing: Double
    var strokeDetail: Double?
    var lineStyle: String?
    var points: [NotePoint]
    var owner: String
    var locked: Bool?

    /// Zero-based originating page. Optional for legacy v24 strokes.
    var pageIndex: Int?
    var pipeline: StrokePipelineSnapshot?

    var shapeType: String?
    var gridColor: String?
    var recognitionSource: String?
    var recognitionError: Double?
    var snapKind: String?

    var text: String?
    var textAlign: String?
    var fontFamily: String?

    var isLocked: Bool { locked ?? false }
    var isInk: Bool { tool == "pen" || tool == "fixed-pen" || tool == "highlighter" }
}

struct PageInfo: Codable, Equatable, Identifiable {
    var id: String
    var pageNumber: Int
    var imageUrl: String?
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var worldRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct DocumentInfo: Codable, Equatable {
    var filename: String?
    var pages: [PageInfo]

    static let empty = DocumentInfo(filename: nil, pages: [])
}

struct NotebookState: Codable {
    var version: Int?
    var document: DocumentInfo
    var strokes: [String: NoteStroke]
}

struct ServerEnvelope: Decodable {
    var type: String
    var state: NotebookState?
    var liveStrokeIds: [String]?
    var reason: String?
    var clientRole: String?

    var document: DocumentInfo?
    var clearStrokes: Bool?
    var focusPageNumber: Int?
    var notice: String?

    var stroke: NoteStroke?
    var strokes: [NoteStroke]?
    var points: [NotePoint]?
    var id: String?
    var ids: [String]?

    var canUndo: Bool?
    var canRedo: Bool?
    var message: String?
    var operationId: String?
    var final: Bool?
}

struct PageMembership {
    var pageIndices: Set<Int>
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        switch cleaned.count {
        case 8:
            red = Double((value >> 24) & 0xff) / 255
            green = Double((value >> 16) & 0xff) / 255
            blue = Double((value >> 8) & 0xff) / 255
            alpha = Double(value & 0xff) / 255
        case 6:
            red = Double((value >> 16) & 0xff) / 255
            green = Double((value >> 8) & 0xff) / 255
            blue = Double(value & 0xff) / 255
            alpha = 1
        default:
            red = 0.07
            green = 0.07
            blue = 0.07
            alpha = 1
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension Color {
    var noteHex: String? {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }
}

extension UIColor {
    convenience init(noteHex: String, alpha: CGFloat = 1) {
        let cleaned = noteHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        if cleaned.count >= 6 {
            red = CGFloat((value >> 16) & 0xff) / 255
            green = CGFloat((value >> 8) & 0xff) / 255
            blue = CGFloat(value & 0xff) / 255
        } else {
            red = 0.07
            green = 0.07
            blue = 0.07
        }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
