import Foundation

/// Layout-only changes preserve ink in its owning page's local coordinate space.
struct PageLayoutTransform {
    struct Page: Equatable {
        var id: String
        var x: Double
        var y: Double
    }
    struct Placement {
        var pageID: String
        var index: Int
        var old: Page
        var new: Page
    }
    private let oldPages: [Page]
    private let placements: [String: Placement]

    init?(oldPages: [Page], newPages: [Page], idMap: [String: String]) {
        guard Set(oldPages.map(\.id)).count == oldPages.count,
              Set(newPages.map(\.id)).count == newPages.count else { return nil }
        self.oldPages = oldPages
        let next = Dictionary(uniqueKeysWithValues: newPages.enumerated().map { ($0.element.id, $0.offset) })
        placements = Dictionary(uniqueKeysWithValues: oldPages.compactMap { old in
            let id = idMap[old.id] ?? old.id
            guard let index = next[id] else { return nil }
            return (old.id, Placement(pageID: id, index: index, old: old, new: newPages[index]))
        })
    }

    func placement(pageID: String?, pageIndex: Int?) -> Placement? {
        if let pageID { return placements[pageID] }
        guard let index = pageIndex, oldPages.indices.contains(index) else { return nil }
        return placements[oldPages[index].id]
    }
}
