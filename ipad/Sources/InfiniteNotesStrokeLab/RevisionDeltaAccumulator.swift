import Foundation

enum RevisionDeltaSafety {
    static func sameServerInstance(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right,
              let leftID = left.split(separator: ":", maxSplits: 1).first,
              let rightID = right.split(separator: ":", maxSplits: 1).first,
              leftID.count == 32, rightID.count == 32,
              leftID.allSatisfy(\.isHexDigit), rightID.allSatisfy(\.isHexDigit) else {
            return false
        }
        return leftID == rightID
    }
}

/// Merges paged stroke deltas without letting an earlier page resurrect a later deletion.
struct RevisionDeltaAccumulator<Value: Identifiable> where Value.ID == String {
    private(set) var upserts: [String: Value] = [:]
    private(set) var deletes: Set<String> = []

    mutating func append(upserts nextUpserts: [String: Value], deletes nextDeletes: [String]) -> Bool {
        guard nextUpserts.allSatisfy({ $0.key == $0.value.id }),
              Set(nextDeletes).count == nextDeletes.count,
              Set(nextUpserts.keys).isDisjoint(with: nextDeletes) else { return false }
        for id in nextDeletes {
            upserts.removeValue(forKey: id)
            deletes.insert(id)
        }
        for (id, value) in nextUpserts {
            deletes.remove(id)
            upserts[id] = value
        }
        return true
    }
}
