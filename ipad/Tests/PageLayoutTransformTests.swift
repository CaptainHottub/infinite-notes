import Foundation

@main
struct Tests {
    static func main() {
        let old: [PageLayoutTransform.Page] = [
            .init(id: "legacy-1", x: 0, y: 0),
            .init(id: "legacy-2", x: 0, y: 150),
            .init(id: "legacy-3", x: 0, y: 350)
        ]
        let new: [PageLayoutTransform.Page] = [
            .init(id: "a", x: 0, y: 0), .init(id: "inserted", x: 0, y: 150),
            .init(id: "b", x: 0, y: 330), .init(id: "c", x: 0, y: 530)
        ]
        let mapping = ["legacy-1": "a", "legacy-2": "b", "legacy-3": "c"]
        let insert = PageLayoutTransform(oldPages: old, newPages: new, idMap: mapping)!
        let last = insert.placement(pageID: nil, pageIndex: 2)!
        precondition(last.pageID == "c" && last.index == 3)
        precondition(370 - last.old.y + last.new.y == 550)
        // Stable IDs override stale positional indices.
        let delete = PageLayoutTransform(oldPages: new, newPages: [new[0], .init(id: "c", x: 0, y: 150)], idMap: [:])!
        let retained = delete.placement(pageID: "c", pageIndex: 0)!
        precondition(retained.index == 1 && 550 - retained.old.y + retained.new.y == 170)
        precondition(delete.placement(pageID: "b", pageIndex: 0) == nil)
        precondition(insert.placement(pageID: "unknown", pageIndex: 0) == nil)
        precondition(PageLayoutTransform(oldPages: old, newPages: [new[0], new[0]], idMap: mapping) == nil)
        print("PageLayoutTransform: stable ownership, migration, insertion/deletion and duplicate validation passed")
    }
}
