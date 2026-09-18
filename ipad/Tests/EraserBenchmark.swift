import Foundation

/// Run optimized on a host; this measures hit testing and journal writes, not iPad FPS.
@main
struct EraserBenchmark {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        values.sorted()[min(values.count - 1, Int(Double(values.count) * fraction))] * 1000
    }
    static func oldHit(_ points: [CGPoint], _ p: CGPoint, radius: CGFloat) -> Bool {
        var best = CGFloat.infinity
        for i in 1..<points.count {
            best = min(best, sqrt(EraserHitGeometry.pointDistanceSquared(p, points[i - 1], points[i])))
        }
        return best <= radius + 1
    }
    static func main() throws {
        for count in [2400, 6000] {
            var seed: UInt64 = 1337
            func random(_ scale: Double) -> Double {
                seed = seed &* 6364136223846793005 &+ 1
                return Double(seed >> 32) / Double(UInt32.max) * scale
            }
            var paths: [String: [CGPoint]] = [:]
            for n in 0..<count {
                let x = random(570), y = random(780)
                paths[String(n)] = (0..<192).map { i in
                    CGPoint(x: x + Double(i) / 8, y: y + sin(Double(i) / 12) * 8)
                }
            }
            var index = EraserSpatialIndex()
            let start = now()
            for (id, points) in paths {
                index.update(id: id, geometry: EraserHitGeometry(points: points, width: 2)!, pages: [0])
            }
            let build = (now() - start) * 1000
            var oldTimes: [Double] = [], newTimes: [Double] = []
            var candidateCount = 0, hits = 0
            for _ in 0..<300 {
                let p = CGPoint(x: random(600), y: random(800))
                let started = now()
                let expected = Set(paths.keys.filter { oldHit(paths[$0]!, p, radius: 4) })
                oldTimes.append(now() - started)
                let indexedStart = now()
                let candidates = index.candidates(sweep: [p], radius: 4, page: 0)
                let actual = Set(candidates.filter { index.geometry(for: $0)!.intersects(sweep: [p], radius: 4) })
                newTimes.append(now() - indexedStart)
                precondition(actual == expected, "Benchmark hit mismatch")
                candidateCount += candidates.count; hits += actual.count
            }
            print(String(format: "%d strokes x 192 points: build %.2f ms; old p50/p95 %.3f/%.3f ms; indexed %.3f/%.3f ms; mean candidates %.1f; hits %d (equal)", count, build,
                         percentile(oldTimes, 0.5), percentile(oldTimes, 0.95),
                         percentile(newTimes, 0.5), percentile(newTimes, 0.95), Double(candidateCount) / 300, hits))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eraser-benchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var queue = PendingEraseQueue(root: root)
        let documentID = UUID().uuidString
        var writes: [Double] = []
        for batch in 0..<100 {
            let ids = (0..<16).map { "stroke-\(batch)-\($0)-0123456789abcdef" }
            let start = now()
            try queue.append(ids, operationID: "gesture", documentID: documentID)
            writes.append(now() - start)
        }
        try queue.finish("gesture", documentID: documentID)
        var restored = PendingEraseQueue(root: root)
        try restored.load(documentID: documentID)
        precondition(restored.erasedIDs.count == 1600)
        print(String(format: "Journal 100 batches x 16 IDs: p50/p95 %.3f/%.3f ms; 1600 IDs restored", percentile(writes, 0.5), percentile(writes, 0.95)))
    }
}
