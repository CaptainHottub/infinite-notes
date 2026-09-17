import Foundation

private struct Stroke: Identifiable, Equatable {
    let id: String
    let version: Int
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

@main
enum RevisionDeltaAccumulatorTests {
    static func main() {
        let firstServer = String(repeating: "a", count: 32)
        let secondServer = String(repeating: "b", count: 32)
        check(RevisionDeltaSafety.sameServerInstance("\(firstServer):1", "\(firstServer):52"), "same process")
        check(!RevisionDeltaSafety.sameServerInstance("\(firstServer):1", "\(secondServer):52"), "restart or fork")
        check(!RevisionDeltaSafety.sameServerInstance(nil, "\(firstServer):1"), "missing token")
        check(!RevisionDeltaSafety.sameServerInstance("invalid:1", "invalid:2"), "malformed token")
        var delta = RevisionDeltaAccumulator<Stroke>()
        check(delta.append(upserts: ["a": Stroke(id: "a", version: 1)], deletes: []), "initial add")
        check(delta.append(upserts: [:], deletes: ["a"]), "later delete")
        check(delta.upserts.isEmpty && delta.deletes == ["a"], "delete must win")
        check(delta.append(upserts: ["a": Stroke(id: "a", version: 2)], deletes: []), "later restore")
        check(delta.upserts["a"] == Stroke(id: "a", version: 2), "latest restore must win")
        check(delta.deletes.isEmpty, "restored stroke is not deleted")
        check(!delta.append(upserts: ["wrong": Stroke(id: "a", version: 3)], deletes: []), "reject wrong ID")
        check(!delta.append(upserts: ["a": Stroke(id: "a", version: 3)], deletes: ["a"]), "reject conflicting page")
        check(delta.upserts["a"] == Stroke(id: "a", version: 2), "invalid page must not mutate")
        print("revision delta page merge and validation passed")
    }
}
