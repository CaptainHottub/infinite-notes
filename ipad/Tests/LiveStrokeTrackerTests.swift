import Foundation

@main
enum LiveStrokeTrackerTests {
    static func main() {
        var tracker = LiveStrokeTracker()
        tracker.begin("pencil", local: true)
        tracker.begin("remote-preview", local: false)
        precondition(tracker.disconnect() == ["remote-preview"])
        precondition(tracker.ids == ["pencil"], "disconnect must retain local Pencil input")
        tracker.end("pencil")
        precondition(tracker.ids.isEmpty, "missing remote end must not block a reconnect refresh")
        precondition(tracker.disconnect().isEmpty, "disconnect recovery is idempotent")
        tracker.begin("finished", local: false)
        tracker.end("finished")
        precondition(tracker.disconnect().isEmpty)
        tracker.reset(remoteIDs: ["legacy-preview"])
        precondition(tracker.disconnect() == ["legacy-preview"])
        print("LiveStrokeTracker: interrupted remote recovery and local ink preservation passed")
    }
}
