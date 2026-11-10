import Foundation

@main
struct GoogleInkStreamTests {
    static func main() {
        func observation(_ index: Int) -> GoogleInkSample {
            let angle = Double(index) / 9
            return GoogleInkSample(point: CGPoint(x: 60 + 30 * cos(angle), y: 50 + 30 * sin(angle)),
                                   pressure: 0.5 + 0.3 * sin(angle), t: 100 + Double(index) / 120,
                                   seq: index)
        }
        func matches(_ lhs: [GoogleInkSample], _ rhs: [GoogleInkSample]) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { lhs, rhs in
                lhs.point == rhs.point && lhs.pressure == rhs.pressure && lhs.t == rhs.t && lhs.seq == rhs.seq
            }
        }

        let input = (0..<180).map(observation)
        var stream = GoogleInkModel.Stream(first: input[0])
        precondition(matches(stream.finishedSamples()!, [input[0]]))
        for sample in input.dropFirst() {
            let previous = stream.stableSamples
            precondition(stream.append(sample))
            precondition(matches(previous, Array(stream.stableSamples.prefix(previous.count))))
            let stable = stream.stableSamples
            let preview = stream.previewTail(settle: true)
            let measuredTail = stream.previewTail(settle: false)
            precondition(measuredTail.allSatisfy { $0.t <= sample.t })
            precondition(matches(measuredTail, Array(preview.prefix(measuredTail.count))))
            precondition(matches(preview, stream.previewTail(settle: true)))
            precondition(matches(stable, stream.stableSamples))
            precondition(matches(stable + preview, stream.finishedSamples()!))
        }

        let final = stream.finishedSamples()!
        precondition(final.last!.t > input.last!.t)
        precondition(matches(final, GoogleInkModel.model(input)!))
        var invalidTime = input.last!
        invalidTime.t -= 1
        precondition(!stream.append(invalidTime))
        precondition(matches(final, stream.finishedSamples()!))

        var shortBudget = GoogleInkModel.Stream(first: input[0], pointLimit: 4)
        precondition(shortBudget.append(input[1]))
        precondition(shortBudget.finishedSamples() == nil)
        verifyWorkspaceCoordinates()
        print("GoogleInkStream: stable prefix, replaceable prediction, final settling, workspace coordinates and safety limits passed")
    }

    private static func verifyWorkspaceCoordinates() {
        let source = CGRect(x: 75, y: 1_800, width: 600, height: 800)
        let coordinates = GoogleInkCoordinates(sourceOrigin: source.origin)
        let workspace = CGRect(x: source.minX - source.width, y: source.minY,
                               width: 3 * source.width, height: source.height)
        let expanded = CGRect(x: workspace.minX - source.width, y: workspace.minY,
                              width: workspace.width + source.width, height: workspace.height)
        let worldPoints = [CGPoint(x: 63, y: 1_920), CGPoint(x: 76, y: 1_931), CGPoint(x: 90, y: 1_940)]
        let samples = worldPoints.enumerated().map { index, world in
            GoogleInkSample(point: coordinates.pagePoint(fromWorld: world),
                            pressure: 0.5, t: Double(index) / 120, seq: index)
        }
        precondition(samples[0].point == CGPoint(x: -12, y: 120))
        var stream = GoogleInkModel.Stream(first: samples[0])
        precondition(stream.append(samples[1]))
        precondition(stream.append(samples[2]))
        let finished = stream.finishedSamples()!
        let preview = stream.stableSamples + stream.previewTail(settle: true)

        // The Pencil starts left of the PDF, then crosses onto it. Expanding
        // the workspace changes the view origin but never the saved points.
        for frame in [workspace, expanded] {
            let viewSize = CGSize(width: frame.width / 2, height: frame.height / 2)
            let live = preview.map { coordinates.viewPoint(fromPage: $0.point, workspace: frame, viewSize: viewSize) }
            let savedWorld = [worldPoints[0]] + finished.dropFirst().map {
                coordinates.worldPoint(fromPage: $0.point)
            }
            let committed = savedWorld.map {
                CGPoint(x: ($0.x - frame.minX) / 2, y: ($0.y - frame.minY) / 2)
            }
            precondition(live.count == committed.count)
            precondition(zip(live, committed).allSatisfy { live, committed in
                hypot(live.x - committed.x, live.y - committed.y) < 0.000_001
            })
            precondition(savedWorld.allSatisfy { abs($0.x - worldPoints[0].x) < 30 })
            precondition(abs(savedWorld.last!.x - worldPoints.last!.x) < 2)
        }
    }
}
