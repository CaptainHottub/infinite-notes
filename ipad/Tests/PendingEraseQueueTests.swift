import Foundation

@main
struct PendingEraseQueueTests {
    static func check(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = UUID().uuidString
        let other = UUID().uuidString
        var queue = PendingEraseQueue(root: root)
        let ids = (0..<600).map { "stroke-\($0)" }
        try queue.append(ids, operationID: "gesture", documentID: document)
        check(queue.erasedIDs == Set(ids))
        check(queue.nextBatch() == nil) // Keep the gesture together until lift.
        try queue.load(documentID: document, activeOperationIDs: ["gesture"])
        check(queue.nextBatch() == nil) // Reconnect during a live gesture.
        var restarted = PendingEraseQueue(root: root)
        try restarted.load(documentID: document)
        let first = restarted.nextBatch()!
        check(first.ids.count == 256 && !first.final)
        // A lost ACK replays exactly the same batch after process restart.
        try queue.load(documentID: document)
        check(queue.nextBatch() == first)
        try queue.acknowledge(first, documentID: document)
        try restarted.load(documentID: document)
        let second = restarted.nextBatch()!
        check(second.ids.count == 256 && !second.final)
        check(Set(first.ids).isDisjoint(with: second.ids))
        try restarted.acknowledge(second, documentID: document)
        let last = restarted.nextBatch()!
        check(last.ids.count == 88 && last.final)
        try restarted.acknowledge(last, documentID: document)
        check(restarted.isEmpty && restarted.erasedIDs.isEmpty)
        try queue.load(documentID: document)
        check(queue.isEmpty)

        try queue.append(["offline-add"], operationID: "erase-add", documentID: document)
        try queue.finish("erase-add", documentID: document)
        // Model a crash after saving the erase but before removing the add record.
        let adds = PendingStrokeJournal<[Int]>(root: root.appendingPathComponent("adds"))
        try adds.save([1], id: "offline-add", documentID: document)
        try restarted.load(documentID: document)
        for id in restarted.erasedIDs { try adds.acknowledge(id, documentID: document) }
        check(try adds.load(documentID: document).isEmpty)
        check(restarted.nextBatch()!.ids == ["offline-add"])
        restarted.reset()
        try restarted.load(documentID: other)
        check(restarted.isEmpty)
        try restarted.load(documentID: document)
        check(!restarted.isEmpty) // Switching notebooks must preserve the journal.

        let invalidRoot = root.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: invalidRoot)
        var failing = PendingEraseQueue(root: invalidRoot)
        do {
            try failing.append(["preserve"], operationID: "failed", documentID: document)
            fatalError("Write failure silently accepted")
        } catch { }
        check(failing.isEmpty && failing.erasedIDs.isEmpty)
        print("PendingEraseQueue: offline replay, interrupted gestures, batching, lost ACK, notebook isolation and write failure passed")
    }
}
