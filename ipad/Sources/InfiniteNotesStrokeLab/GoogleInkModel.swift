import Foundation

// Based on work copyright Google LLC, licensed under Apache-2.0.
/// Swift implementation of Google Ink Stroke Modeler (Apache-2.0, f2388813),
/// with the desktop adapter's smoothing and settling settings.
/// https://github.com/google/ink-stroke-modeler
enum GoogleInkModel {
    private typealias Vector = SIMD2<Float>
    static let maximumStrokePoints = 8_000

    private struct Tip {
        var position = Vector.zero
        var velocity = Vector.zero
        var time = 0.0

        mutating func update(anchor: Vector, time: Double) {
            let dt = Float(time - self.time)
            let acceleration = (anchor - position) / (11.0 / 32400.0) - velocity * 72
            velocity += acceleration * dt
            position += velocity * dt
            self.time = time
        }

        mutating func advance(from start: Vector, to end: Vector, startTime: Double, until time: Double,
                              emit: (Tip) -> Void) {
            let dt = time - startTime
            let steps = Int(ceil(Double(Float(dt)) * 240))
            guard steps > 0 else { return }
            for step in 1...steps {
                let fraction = Float(step) / Float(steps)
                update(anchor: start + (end - start) * fraction, time: startTime + dt * Double(fraction))
                emit(self)
            }
        }

        mutating func settle(at anchor: Vector, emit: (Tip) -> Void) {
            var step = 1.0 / 240.0
            for _ in 0..<48 {
                let prior = self
                update(anchor: anchor, time: prior.time + step)
                if length(position - prior.position) < 0.002 { break }
                if projection(prior.position, position, anchor) < 1 {
                    self = prior
                    step *= 0.5
                    continue
                }
                emit(self)
                if length(position - anchor) < 0.002 { break }
            }
        }
    }

    private struct WobbleSample {
        var time: Double
        var duration = 0.0
        var distance: Float = 0
        var weighted = Vector.zero
    }

    private struct Anchor {
        let position: Vector
        let pressure: Float
    }

    private struct PressureCursor {
        var segment = 0
        var ratio: Float = 0

        mutating func pressure(at position: Vector, anchors: [Anchor], pending: Anchor? = nil) -> Double {
            func anchor(at index: Int) -> Anchor {
                if index == anchors.count, let pending { return pending }
                return anchors[index]
            }
            let lastIndex = anchors.count - (pending == nil ? 1 : 0)
            var best = Float.infinity
            var nextSegment = segment
            var nextRatio = ratio
            for index in segment..<lastIndex {
                let a = anchor(at: index).position
                let b = anchor(at: index + 1).position
                let fraction = projection(a, b, position)
                if index == segment && fraction < ratio { continue }
                let distance = length(position - (a + (b - a) * fraction))
                if distance <= best {
                    best = distance
                    nextSegment = index
                    nextRatio = fraction
                }
            }
            segment = nextSegment
            ratio = nextRatio
            let a = anchor(at: segment).pressure
            let b = anchor(at: min(segment + 1, lastIndex)).pressure
            return Double(max(0, min(1, a + (b - a) * ratio)))
        }
    }

    /// Keep the last observation pending until we know whether it is a move
    /// or the final sample. The preview treats it as Pencil-up on a scratch
    /// tip and cursor, so new input can replace just that provisional tail.
    struct Stream {
        private let first: GoogleInkSample
        private let pointLimit: Int
        private var pending: GoogleInkSample?
        private var tip = Tip()
        private var cursor = PressureCursor()
        private var corrected = Vector.zero
        private var previous = Vector.zero
        private var processedTime = 0.0
        private var wobble = [WobbleSample(time: 0)]
        private var sum = Vector.zero
        private var distance: Float = 0
        private var duration = 0.0
        private var anchors: [Anchor]
        private(set) var stableSamples: [GoogleInkSample]
        private(set) var inputCount = 1

        init(first: GoogleInkSample, pointLimit: Int = GoogleInkModel.maximumStrokePoints) {
            self.first = first
            self.pointLimit = pointLimit
            anchors = [Anchor(position: .zero, pressure: Float(first.pressure))]
            stableSamples = [first]
        }

        /// False means the caller should retain the admitted input.
        mutating func append(_ input: GoogleInkSample) -> Bool {
            let gap = input.t - (pending?.t ?? first.t)
            let elapsed = input.t - first.t
            guard gap.isFinite, gap >= 0, gap <= 1024.0 / 240,
                  inputCount < pointLimit, elapsed <= Double(pointLimit) / 240 else { return false }
            if let pending {
                appendMove(pending)
                guard stableSamples.count < pointLimit else { return false }
            }
            pending = input
            inputCount += 1
            return true
        }

        /// A fresh prediction replaces the previous tail. Scratch state keeps
        /// these samples out of the stream, the journal, and the wire.
        func previewTail(settle: Bool) -> [GoogleInkSample] {
            guard let pending else { return [] }
            let anchor = Anchor(position: relativePoint(pending), pressure: Float(pending.pressure))
            var previewTip = tip
            var previewCursor = cursor
            var tail: [GoogleInkSample] = []
            let emit: (Tip) -> Void = { tip in
                let pressure = previewCursor.pressure(at: tip.position, anchors: anchors, pending: anchor)
                tail.append(sample(at: tip, pressure: pressure, seq: pending.seq))
            }
            previewTip.advance(from: corrected, to: anchor.position, startTime: processedTime,
                               until: pending.t - first.t, emit: emit)
            if settle { previewTip.settle(at: anchor.position, emit: emit) }
            return tail
        }

        func finishedSamples() -> [GoogleInkSample]? {
            let tail = previewTail(settle: true)
            guard stableSamples.count + tail.count <= pointLimit else { return nil }
            return stableSamples + tail
        }

        private mutating func appendMove(_ input: GoogleInkSample) {
            let time = input.t - first.t
            let dt = time - processedTime
            let raw = relativePoint(input)
            let sample = WobbleSample(time: time, duration: dt, distance: length(raw - previous),
                                      weighted: raw * Float(dt))
            wobble.append(sample)
            sum += sample.weighted
            distance += sample.distance
            duration += dt
            while let oldest = wobble.first, oldest.time < time - 0.012 {
                sum -= oldest.weighted
                distance -= oldest.distance
                duration -= oldest.duration
                wobble.removeFirst()
            }
            var anchor = raw
            if duration > 0 {
                let average = sum / Float(duration)
                let blend = max(0, min(1, (distance / Float(duration) - 1) / 2))
                anchor = average + (raw - average) * blend
            }
            anchors.append(Anchor(position: anchor, pressure: Float(input.pressure)))

            var nextTip = tip
            let start = corrected
            nextTip.advance(from: start, to: anchor, startTime: processedTime, until: time) { tip in
                let pressure = cursor.pressure(at: tip.position, anchors: anchors)
                stableSamples.append(self.sample(at: tip, pressure: pressure, seq: input.seq))
            }
            tip = nextTip
            processedTime = time
            corrected = anchor
            previous = raw
        }

        private func relativePoint(_ sample: GoogleInkSample) -> Vector {
            Vector(Float(sample.point.x - first.point.x), Float(sample.point.y - first.point.y))
        }

        private func sample(at tip: Tip, pressure: Double, seq: Int) -> GoogleInkSample {
            GoogleInkSample(point: CGPoint(x: first.point.x + CGFloat(tip.position.x),
                                           y: first.point.y + CGFloat(tip.position.y)),
                            pressure: pressure, t: first.t + tip.time, seq: seq)
        }
    }

    static func geometry(_ input: [GoogleInkSample]) -> [GoogleInkSample] {
        model(input) ?? input
    }

    static func model(_ input: [GoogleInkSample]) -> [GoogleInkSample]? {
        guard let first = input.first else { return [] }
        var stream = Stream(first: first, pointLimit: 200_000)
        for sample in input.dropFirst() {
            guard stream.append(sample) else { return nil }
        }
        return stream.finishedSamples()
    }

    private static func length(_ vector: Vector) -> Float { hypot(vector.x, vector.y) }

    private static func projection(_ a: Vector, _ b: Vector, _ point: Vector) -> Float {
        let delta = b - a
        guard delta != .zero else { return 0 }
        let relative = point - a
        return max(0, min(1, (relative.x * delta.x + relative.y * delta.y) /
                          (delta.x * delta.x + delta.y * delta.y)))
    }
}
