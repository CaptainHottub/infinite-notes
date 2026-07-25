import Combine
import CoreGraphics
import Foundation

@MainActor
final class StrokeSettingsStore: ObservableObject {
    @Published var configuration: StrokePipelineConfiguration {
        didSet { persist() }
    }

    private let defaultsKey = "native.strokePipeline.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(StrokePipelineConfiguration.self, from: data) {
            configuration = decoded
        } else {
            configuration = .default
        }
    }

    func resetToDefaults() {
        configuration = .default
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

struct PencilInputSample {
    var viewPoint: CGPoint
    var rawWorldPoint: CGPoint
    var rawPagePoint: CGPoint
    var pressure: Double
    var timestampMS: Double
    var altitude: Double?
    var azimuth: Double?
}

private struct ScalarLowPassFilter {
    var value: Double?

    mutating func filter(_ next: Double, alpha: Double) -> Double {
        guard let value else {
            self.value = next
            return next
        }
        let result = value + alpha * (next - value)
        self.value = result
        return result
    }
}

private struct ScalarOneEuroFilter {
    var signal = ScalarLowPassFilter()
    var derivative = ScalarLowPassFilter()
    var previousRaw: Double?
    var previousTimeMS: Double?

    mutating func filter(
        _ value: Double,
        timestampMS: Double,
        minCutoff: Double,
        beta: Double,
        derivativeCutoff: Double
    ) -> Double {
        guard let previousRaw, let previousTimeMS else {
            self.previousRaw = value
            self.previousTimeMS = timestampMS
            signal.value = value
            derivative.value = 0
            return value
        }

        let dt = max(1.0 / 240.0, min(0.1, (timestampMS - previousTimeMS) / 1000.0))
        let rawDerivative = (value - previousRaw) / dt
        let derivativeAlpha = Self.alpha(cutoff: max(0.01, derivativeCutoff), dt: dt)
        let filteredDerivative = derivative.filter(rawDerivative, alpha: derivativeAlpha)
        let cutoff = max(0.01, minCutoff + beta * abs(filteredDerivative))
        let signalAlpha = Self.alpha(cutoff: cutoff, dt: dt)
        let result = signal.filter(value, alpha: signalAlpha)

        self.previousRaw = value
        self.previousTimeMS = timestampMS
        return result
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}

/// Mutable state for one Pencil contact. Predicted touches use a copied state so
/// they never affect the persisted centreline.
struct StrokePipelineState {
    private var previousFilteredViewPoint: CGPoint?
    private var previousFilteredPressure: Double?
    private var previousTimestampMS: Double?
    private var lastAcceptedViewPoint: CGPoint?
    private var lastAcceptedPressure: Double?
    private var xOneEuro = ScalarOneEuroFilter()
    private var yOneEuro = ScalarOneEuroFilter()

    mutating func reset() {
        self = StrokePipelineState()
    }

    mutating func process(
        _ sample: PencilInputSample,
        page: PageInfo,
        viewBounds: CGRect,
        configuration: StrokePipelineConfiguration,
        forceAccept: Bool = false
    ) -> NotePoint? {
        guard viewBounds.width > 0, viewBounds.height > 0 else { return nil }

        let filteredViewPoint = filterPosition(sample, configuration: configuration)
        let filteredPressure = filterPressure(sample.pressure, configuration: configuration)

        defer {
            previousFilteredViewPoint = filteredViewPoint
            previousFilteredPressure = filteredPressure
            previousTimestampMS = sample.timestampMS
        }

        if !forceAccept, let lastAcceptedViewPoint, let lastAcceptedPressure {
            let distance = hypot(
                filteredViewPoint.x - lastAcceptedViewPoint.x,
                filteredViewPoint.y - lastAcceptedViewPoint.y
            )
            let pressureDelta = abs(filteredPressure - lastAcceptedPressure)
            if distance < CGFloat(max(0.01, configuration.minimumSampleSpacing)),
               pressureDelta < max(0, configuration.pressureDeltaThreshold) {
                return nil
            }
        }

        self.lastAcceptedViewPoint = filteredViewPoint
        self.lastAcceptedPressure = filteredPressure

        let filteredPage = CGPoint(
            x: filteredViewPoint.x / viewBounds.width * CGFloat(page.width),
            y: filteredViewPoint.y / viewBounds.height * CGFloat(page.height)
        )
        let filteredWorld = CGPoint(
            x: CGFloat(page.x) + filteredPage.x,
            y: CGFloat(page.y) + filteredPage.y
        )

        return NotePoint(
            x: Double(filteredWorld.x),
            y: Double(filteredWorld.y),
            p: max(0, min(1, filteredPressure)),
            t: sample.timestampMS,
            xRaw: Double(sample.rawWorldPoint.x),
            yRaw: Double(sample.rawWorldPoint.y),
            xLocal: Double(filteredPage.x),
            yLocal: Double(filteredPage.y),
            xRawLocal: Double(sample.rawPagePoint.x),
            yRawLocal: Double(sample.rawPagePoint.y),
            altitude: sample.altitude,
            azimuth: sample.azimuth
        )
    }

    private mutating func filterPosition(
        _ sample: PencilInputSample,
        configuration: StrokePipelineConfiguration
    ) -> CGPoint {
        let raw = sample.viewPoint
        let strength = max(0, min(1, configuration.smoothingStrength))
        guard strength > 0 else { return raw }

        switch configuration.inputSmoothingAlgorithm {
        case .none:
            return raw

        case .exponential:
            guard let previousFilteredViewPoint else { return raw }
            let dt = max(1.0 / 240.0, min(0.1, (sample.timestampMS - (previousTimestampMS ?? sample.timestampMS)) / 1000.0))
            let distance = hypot(raw.x - previousFilteredViewPoint.x, raw.y - previousFilteredViewPoint.y)
            let speed = distance / CGFloat(dt)
            var alpha = 1.0 - strength * 0.88
            if configuration.adaptiveSmoothing {
                alpha += min(1, Double(speed) / 1200.0) * strength * 0.72
            }
            alpha = max(0.035, min(1, alpha))
            return CGPoint(
                x: previousFilteredViewPoint.x + (raw.x - previousFilteredViewPoint.x) * CGFloat(alpha),
                y: previousFilteredViewPoint.y + (raw.y - previousFilteredViewPoint.y) * CGFloat(alpha)
            )

        case .oneEuro:
            let filteredX = xOneEuro.filter(
                Double(raw.x),
                timestampMS: sample.timestampMS,
                minCutoff: configuration.oneEuroMinCutoff,
                beta: configuration.adaptiveSmoothing ? configuration.oneEuroBeta : 0,
                derivativeCutoff: configuration.oneEuroDerivativeCutoff
            )
            let filteredY = yOneEuro.filter(
                Double(raw.y),
                timestampMS: sample.timestampMS,
                minCutoff: configuration.oneEuroMinCutoff,
                beta: configuration.adaptiveSmoothing ? configuration.oneEuroBeta : 0,
                derivativeCutoff: configuration.oneEuroDerivativeCutoff
            )
            return CGPoint(
                x: raw.x + (CGFloat(filteredX) - raw.x) * CGFloat(strength),
                y: raw.y + (CGFloat(filteredY) - raw.y) * CGFloat(strength)
            )
        }
    }

    private func filterPressure(
        _ pressure: Double,
        configuration: StrokePipelineConfiguration
    ) -> Double {
        guard let previousFilteredPressure else { return pressure }
        let amount = max(0, min(1, configuration.pressureSmoothing))
        let alpha = max(0.08, 1.0 - amount * 0.9)
        return previousFilteredPressure + (pressure - previousFilteredPressure) * alpha
    }
}

struct StrokeGeometrySample: Equatable {
    var point: CGPoint
    var pressure: Double
}

enum StrokeCoordinates {
    /// World coordinates are authoritative. Page-local coordinates from older
    /// notebooks are relative to the source PDF, while the experimental native
    /// workspace can be several page widths wide. Using world coordinates keeps
    /// both legacy and off-page strokes aligned as the workspace grows.
    static func filteredViewPoint(
        _ point: NotePoint,
        stroke: NoteStroke,
        page: PageInfo,
        bounds: CGRect
    ) -> CGPoint {
        CGPoint(
            x: CGFloat((point.x - page.x) / page.width) * bounds.width,
            y: CGFloat((point.y - page.y) / page.height) * bounds.height
        )
    }

    static func rawViewPoint(
        _ point: NotePoint,
        stroke: NoteStroke,
        page: PageInfo,
        bounds: CGRect
    ) -> CGPoint {
        CGPoint(
            x: CGFloat((point.xRaw - page.x) / page.width) * bounds.width,
            y: CGFloat((point.yRaw - page.y) / page.height) * bounds.height
        )
    }
}

enum StrokeGeometryBuilder {
    static func computedSamples(
        stroke: NoteStroke,
        page: PageInfo,
        bounds: CGRect,
        fallback: StrokePipelineConfiguration
    ) -> [StrokeGeometrySample] {
        let source = stroke.points.map {
            StrokeGeometrySample(
                point: StrokeCoordinates.filteredViewPoint($0, stroke: stroke, page: page, bounds: bounds),
                pressure: $0.p
            )
        }
        guard source.count > 1 else { return source }
        let settings = stroke.pipeline ?? .legacy(smoothing: stroke.smoothing)

        let resampled = settings.resamplingEnabled
            ? resample(source, spacing: max(0.15, settings.resampleSpacing))
            : source

        let fitted: [StrokeGeometrySample]
        switch settings.splineAlgorithm {
        case .polyline:
            fitted = resampled
        case .quadraticMidpoint:
            fitted = quadraticMidpoint(resampled, spacing: max(0.15, settings.splineSampleSpacing))
        case .catmullRomUniform:
            fitted = catmullRom(resampled, alpha: 0, spacing: max(0.15, settings.splineSampleSpacing))
        case .catmullRomCentripetal:
            fitted = catmullRom(resampled, alpha: 0.5, spacing: max(0.15, settings.splineSampleSpacing))
        case .cubicBezier:
            fitted = cubicBezier(
                resampled,
                tension: max(0, min(1, settings.splineTension)),
                spacing: max(0.15, settings.splineSampleSpacing)
            )
        }

        let uniformlySpaced = resample(fitted, spacing: max(0.15, settings.splineSampleSpacing))
        return smoothPressure(uniformlySpaced, amount: settings.computedPressureSmoothing)
    }

    static func rawSamples(
        stroke: NoteStroke,
        page: PageInfo,
        bounds: CGRect
    ) -> [StrokeGeometrySample] {
        stroke.points.map {
            StrokeGeometrySample(
                point: StrokeCoordinates.rawViewPoint($0, stroke: stroke, page: page, bounds: bounds),
                pressure: $0.p
            )
        }
    }

    static func filteredSamples(
        stroke: NoteStroke,
        page: PageInfo,
        bounds: CGRect
    ) -> [StrokeGeometrySample] {
        stroke.points.map {
            StrokeGeometrySample(
                point: StrokeCoordinates.filteredViewPoint($0, stroke: stroke, page: page, bounds: bounds),
                pressure: $0.p
            )
        }
    }

    private static func resample(_ input: [StrokeGeometrySample], spacing: Double) -> [StrokeGeometrySample] {
        guard input.count > 1, spacing > 0 else { return input }
        var output = [input[0]]
        var previous = input[0]
        var carried = 0.0

        for target in input.dropFirst() {
            var start = previous
            var segmentLength = distance(start.point, target.point)
            if segmentLength < 0.000_001 {
                previous = target
                continue
            }

            while carried + segmentLength >= spacing {
                let remaining = spacing - carried
                let ratio = remaining / segmentLength
                let next = interpolate(start, target, ratio)
                output.append(next)
                start = next
                segmentLength = distance(start.point, target.point)
                carried = 0
                if segmentLength < 0.000_001 { break }
            }
            carried += segmentLength
            previous = target
        }

        if let last = input.last,
           let outputLast = output.last,
           distance(outputLast.point, last.point) > spacing * 0.25 {
            output.append(last)
        }
        return output
    }

    private static func quadraticMidpoint(
        _ input: [StrokeGeometrySample],
        spacing: Double
    ) -> [StrokeGeometrySample] {
        guard input.count >= 3 else { return input }
        var output = [input[0]]
        var start = input[0]

        for index in 1..<(input.count - 1) {
            let control = input[index]
            let next = input[index + 1]
            let end = midpoint(control, next)
            appendQuadratic(from: start, control: control, to: end, spacing: spacing, output: &output)
            start = end
        }
        appendQuadratic(from: start, control: input[input.count - 2], to: input[input.count - 1], spacing: spacing, output: &output)
        return output
    }

    private static func appendQuadratic(
        from start: StrokeGeometrySample,
        control: StrokeGeometrySample,
        to end: StrokeGeometrySample,
        spacing: Double,
        output: inout [StrokeGeometrySample]
    ) {
        let estimate = distance(start.point, control.point) + distance(control.point, end.point)
        let steps = max(2, min(128, Int(ceil(estimate / spacing))))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let inverse = 1 - t
            let point = CGPoint(
                x: CGFloat(inverse * inverse) * start.point.x + CGFloat(2 * inverse * t) * control.point.x + CGFloat(t * t) * end.point.x,
                y: CGFloat(inverse * inverse) * start.point.y + CGFloat(2 * inverse * t) * control.point.y + CGFloat(t * t) * end.point.y
            )
            let pressure = inverse * inverse * start.pressure + 2 * inverse * t * control.pressure + t * t * end.pressure
            output.append(StrokeGeometrySample(point: point, pressure: pressure))
        }
    }

    private static func catmullRom(
        _ input: [StrokeGeometrySample],
        alpha: Double,
        spacing: Double
    ) -> [StrokeGeometrySample] {
        guard input.count >= 2 else { return input }
        var output: [StrokeGeometrySample] = []
        output.reserveCapacity(input.count * 3)

        for index in 0..<(input.count - 1) {
            let p0 = input[max(0, index - 1)]
            let p1 = input[index]
            let p2 = input[index + 1]
            let p3 = input[min(input.count - 1, index + 2)]
            let estimate = max(spacing, distance(p1.point, p2.point))
            let steps = max(1, min(128, Int(ceil(estimate / spacing))))
            for step in 0..<steps {
                let t = Double(step) / Double(steps)
                output.append(parameterizedCatmull(p0, p1, p2, p3, t: t, alpha: alpha))
            }
        }
        if let last = input.last { output.append(last) }
        return output
    }

    private static func parameterizedCatmull(
        _ p0: StrokeGeometrySample,
        _ p1: StrokeGeometrySample,
        _ p2: StrokeGeometrySample,
        _ p3: StrokeGeometrySample,
        t: Double,
        alpha: Double
    ) -> StrokeGeometrySample {
        if alpha == 0 {
            let t2 = t * t
            let t3 = t2 * t
            func cubic(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
            }
            return StrokeGeometrySample(
                point: CGPoint(
                    x: CGFloat(cubic(Double(p0.point.x), Double(p1.point.x), Double(p2.point.x), Double(p3.point.x))),
                    y: CGFloat(cubic(Double(p0.point.y), Double(p1.point.y), Double(p2.point.y), Double(p3.point.y)))
                ),
                pressure: cubic(p0.pressure, p1.pressure, p2.pressure, p3.pressure)
            )
        }

        let t0 = 0.0
        let t1 = t0 + pow(max(0.000_1, distance(p0.point, p1.point)), alpha)
        let t2 = t1 + pow(max(0.000_1, distance(p1.point, p2.point)), alpha)
        let t3 = t2 + pow(max(0.000_1, distance(p2.point, p3.point)), alpha)
        let u = t1 + (t2 - t1) * t

        let a1 = interpolateParameterized(p0, p1, u: u, low: t0, high: t1)
        let a2 = interpolateParameterized(p1, p2, u: u, low: t1, high: t2)
        let a3 = interpolateParameterized(p2, p3, u: u, low: t2, high: t3)
        let b1 = interpolateParameterized(a1, a2, u: u, low: t0, high: t2)
        let b2 = interpolateParameterized(a2, a3, u: u, low: t1, high: t3)
        return interpolateParameterized(b1, b2, u: u, low: t1, high: t2)
    }

    private static func interpolateParameterized(
        _ a: StrokeGeometrySample,
        _ b: StrokeGeometrySample,
        u: Double,
        low: Double,
        high: Double
    ) -> StrokeGeometrySample {
        let span = max(0.000_001, high - low)
        return interpolate(a, b, (u - low) / span)
    }

    private static func cubicBezier(
        _ input: [StrokeGeometrySample],
        tension: Double,
        spacing: Double
    ) -> [StrokeGeometrySample] {
        guard input.count >= 2 else { return input }
        var output: [StrokeGeometrySample] = []
        let tangentScale = (1 - tension) / 6

        for index in 0..<(input.count - 1) {
            let p0 = input[max(0, index - 1)]
            let p1 = input[index]
            let p2 = input[index + 1]
            let p3 = input[min(input.count - 1, index + 2)]
            let c1 = StrokeGeometrySample(
                point: CGPoint(
                    x: p1.point.x + (p2.point.x - p0.point.x) * CGFloat(tangentScale),
                    y: p1.point.y + (p2.point.y - p0.point.y) * CGFloat(tangentScale)
                ),
                pressure: p1.pressure + (p2.pressure - p0.pressure) * tangentScale
            )
            let c2 = StrokeGeometrySample(
                point: CGPoint(
                    x: p2.point.x - (p3.point.x - p1.point.x) * CGFloat(tangentScale),
                    y: p2.point.y - (p3.point.y - p1.point.y) * CGFloat(tangentScale)
                ),
                pressure: p2.pressure - (p3.pressure - p1.pressure) * tangentScale
            )
            let estimate = distance(p1.point, c1.point) + distance(c1.point, c2.point) + distance(c2.point, p2.point)
            let steps = max(1, min(128, Int(ceil(estimate / spacing))))
            for step in 0..<steps {
                let t = Double(step) / Double(steps)
                output.append(bezier(p1, c1, c2, p2, t: t))
            }
        }
        if let last = input.last { output.append(last) }
        return output
    }

    private static func bezier(
        _ p0: StrokeGeometrySample,
        _ p1: StrokeGeometrySample,
        _ p2: StrokeGeometrySample,
        _ p3: StrokeGeometrySample,
        t: Double
    ) -> StrokeGeometrySample {
        let inverse = 1 - t
        let a = inverse * inverse * inverse
        let b = 3 * inverse * inverse * t
        let c = 3 * inverse * t * t
        let d = t * t * t
        return StrokeGeometrySample(
            point: CGPoint(
                x: CGFloat(a) * p0.point.x + CGFloat(b) * p1.point.x + CGFloat(c) * p2.point.x + CGFloat(d) * p3.point.x,
                y: CGFloat(a) * p0.point.y + CGFloat(b) * p1.point.y + CGFloat(c) * p2.point.y + CGFloat(d) * p3.point.y
            ),
            pressure: a * p0.pressure + b * p1.pressure + c * p2.pressure + d * p3.pressure
        )
    }

    private static func smoothPressure(
        _ input: [StrokeGeometrySample],
        amount: Double
    ) -> [StrokeGeometrySample] {
        guard input.count > 1 else { return input }
        let strength = max(0, min(1, amount))
        guard strength > 0 else { return input }
        let alpha = max(0.04, 1 - strength * 0.92)
        var output = input
        for index in 1..<output.count {
            output[index].pressure = output[index - 1].pressure
                + (output[index].pressure - output[index - 1].pressure) * alpha
        }
        if output.count > 2 {
            for index in stride(from: output.count - 2, through: 0, by: -1) {
                output[index].pressure = output[index + 1].pressure
                    + (output[index].pressure - output[index + 1].pressure) * alpha
            }
        }
        return output
    }

    private static func midpoint(_ a: StrokeGeometrySample, _ b: StrokeGeometrySample) -> StrokeGeometrySample {
        interpolate(a, b, 0.5)
    }

    private static func interpolate(
        _ a: StrokeGeometrySample,
        _ b: StrokeGeometrySample,
        _ ratio: Double
    ) -> StrokeGeometrySample {
        let t = max(0, min(1, ratio))
        return StrokeGeometrySample(
            point: CGPoint(
                x: a.point.x + (b.point.x - a.point.x) * CGFloat(t),
                y: a.point.y + (b.point.y - a.point.y) * CGFloat(t)
            ),
            pressure: a.pressure + (b.pressure - a.pressure) * t
        )
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }
}
