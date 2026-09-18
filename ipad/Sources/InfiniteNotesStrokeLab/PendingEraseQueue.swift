import Foundation

/// Durable erase gestures. An interrupted gesture becomes complete on reload.
struct PendingEraseQueue {
    struct Operation: Codable {
        var ids: Set<String>
        let created: Double
        var finished: Bool
    }

    struct Batch: Equatable {
        let operationID: String
        let ids: [String]
        let final: Bool
    }

    let root: URL
    private(set) var operations: [String: Operation] = [:]
    private(set) var erasedIDs: Set<String> = []
    var isEmpty: Bool { operations.isEmpty }
    private var journal: PendingStrokeJournal<Operation> { PendingStrokeJournal(root: root) }

    mutating func load(documentID: String, activeOperationIDs: Set<String> = []) throws {
        var loaded = try journal.load(documentID: documentID)
        for id in loaded.keys where !activeOperationIDs.contains(id) {
            loaded[id]?.finished = true
        }
        operations = loaded
        updateIDs()
    }

    mutating func append(_ ids: [String], operationID: String, documentID: String) throws {
        var operation = operations[operationID] ?? Operation(
            ids: [], created: Date().timeIntervalSince1970, finished: false)
        operation.ids.formUnion(ids)
        try journal.save(operation, id: operationID, documentID: documentID)
        operations[operationID] = operation
        updateIDs()
    }

    mutating func finish(_ operationID: String, documentID: String) throws {
        guard var operation = operations[operationID] else { return }
        operation.finished = true
        try journal.save(operation, id: operationID, documentID: documentID)
        operations[operationID] = operation
    }

    func nextBatch() -> Batch? {
        let ordered = operations.keys.sorted {
            let left = operations[$0]!.created
            let right = operations[$1]!.created
            return left == right ? $0 < $1 : left < right
        }
        guard let id = ordered.first, let operation = operations[id], operation.finished else { return nil }
        // Bound reconnect frames even for large erase gestures.
        let ids = Array(operation.ids.sorted().prefix(256))
        return Batch(operationID: id, ids: ids, final: ids.count == operation.ids.count)
    }

    mutating func acknowledge(_ batch: Batch, documentID: String) throws {
        guard var operation = operations[batch.operationID] else { return }
        operation.ids.subtract(batch.ids)
        if batch.final && operation.ids.isEmpty {
            try journal.acknowledge(batch.operationID, documentID: documentID)
            operations.removeValue(forKey: batch.operationID)
        } else {
            try journal.save(operation, id: batch.operationID, documentID: documentID)
            operations[batch.operationID] = operation
        }
        updateIDs()
    }

    mutating func reset() {
        // Leave the previous notebook's records on disk for later recovery.
        operations.removeAll()
        erasedIDs.removeAll()
    }

    private mutating func updateIDs() {
        erasedIDs = operations.values.reduce(into: Set<String>()) { $0.formUnion($1.ids) }
    }
}
