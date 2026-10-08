import Foundation

protocol PageLocalInkPoint {
    var x: Double { get set }
    var y: Double { get set }
    var xRaw: Double { get set }
    var yRaw: Double { get set }
    var xLocal: Double? { get set }
    var yLocal: Double? { get set }
    var xRawLocal: Double? { get set }
    var yRawLocal: Double? { get set }
}

protocol PageLocalInkStroke {
    associatedtype Point: PageLocalInkPoint
    var id: String { get }
    var pageId: String? { get set }
    var pageIndex: Int? { get set }
    var points: [Point] { get set }
}

/// Authoritative native ink uses fixed page-local points. World-coordinate
/// strokes are disposable projections for the existing renderer/protocol.
/// Only mounted pages retain projected arrays; moving pages never visits points.
final class PageLocalInkStore<Stroke: PageLocalInkStroke> {
    struct Page: Equatable {
        var id: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }
    private struct Entry {
        var stroke: Stroke
        var isLocal: Bool
    }
    private var entries: [String: Entry] = [:]
    private var pages: [Page] = []
    private var pageIndices: [String: Int] = [:]
    private var worldViews: [String: Stroke] = [:]
    private var cachedPageIDs: Set<String> = []
    private(set) var localizedPointCount = 0
    private(set) var projectedPointCount = 0

    var count: Int { entries.count }
    var ids: Set<String> { Set(entries.keys) }
    var ownership: [String: String] {
        entries.reduce(into: [:]) { result, pair in
            if pair.value.isLocal, let id = pair.value.stroke.pageId { result[pair.key] = id }
        }
    }
    var unowned: [Stroke] { entries.values.filter { !$0.isLocal }.map(\.stroke) }
    func contains(_ id: String) -> Bool { entries[id] != nil }
    func owner(of id: String) -> String? { entries[id]?.isLocal == true ? entries[id]?.stroke.pageId : nil }
    /// Also used by regression tests to inspect authoritative, unprojected ink.
    func localRecord(_ id: String) -> Stroke? { entries[id]?.isLocal == true ? entries[id]?.stroke : nil }

    func normalizedWorldStroke(_ original: Stroke) -> Stroke {
        guard let index = owningPage(original) else { return original }
        let page = pages[index]
        var result = original
        result.pageId = page.id
        result.pageIndex = index
        result.points = original.points.map { normalizedWorldPoint($0, page: page) }
        return result
    }

    func normalizedWorldPoints(_ points: [Stroke.Point], for id: String) -> [Stroke.Point] {
        guard let owner = owner(of: id), let index = pageIndices[owner] else { return points }
        return points.map { normalizedWorldPoint($0, page: pages[index]) }
    }

    subscript(id: String) -> Stroke? {
        get {
            if let cached = worldViews[id] { return cached }
            guard let entry = entries[id] else { return nil }
            guard entry.isLocal, let pageID = entry.stroke.pageId,
                  let index = pageIndices[pageID] else { return entry.isLocal ? nil : entry.stroke }
            var world = entry.stroke
            world.pageIndex = index
            world.points = world.points.map { worldPoint($0, page: pages[index]) }
            projectedPointCount += world.points.count
            if cachedPageIDs.contains(pageID) { worldViews[id] = world }
            return world
        }
        set {
            guard var world = newValue else { entries.removeValue(forKey: id); worldViews.removeValue(forKey: id); return }
            precondition(world.id == id)
            guard let index = owningPage(world) else {
                entries[id] = Entry(stroke: world, isLocal: false)
                worldViews.removeValue(forKey: id)
                return
            }
            let page = pages[index]
            world.pageId = page.id
            world.pageIndex = index
            var local = world
            local.pageIndex = nil
            local.points = world.points.map { localPoint($0, page: page) }
            localizedPointCount += local.points.count
            entries[id] = Entry(stroke: local, isLocal: true)
            // Re-project only on demand, so stale optional local metadata never
            // leaks back to the wire and nonmounted pages retain no world arrays.
            worldViews.removeValue(forKey: id)
        }
    }

    @discardableResult
    func setPages(_ next: [Page], idMap: [String: String] = [:], removeMissing: Bool = false) -> Bool {
        guard Set(next.map(\.id)).count == next.count else { return false }
        let indices = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($0.element.id, $0.offset) })
        if removeMissing || !idMap.isEmpty {
            for id in Array(entries.keys) {
                guard var entry = entries[id], entry.isLocal, let oldID = entry.stroke.pageId else { continue }
                let newID = idMap[oldID] ?? oldID
                if removeMissing && indices[newID] == nil { entries.removeValue(forKey: id) }
                else if oldID != newID {
                    entry.stroke.pageId = newID
                    entries[id] = entry
                }
            }
        }
        pages = next
        pageIndices = indices
        cachedPageIDs = Set(cachedPageIDs.map { idMap[$0] ?? $0 }).intersection(Set(indices.keys))
        worldViews.removeAll(keepingCapacity: true)
        return true
    }

    func cacheWorldViews(for pageIDs: Set<String>) {
        cachedPageIDs = pageIDs
        worldViews = worldViews.filter { pageIDs.contains($0.value.pageId ?? "") }
    }

    @discardableResult
    func replaceAll(_ records: [String: Stroke], pages next: [Page]) -> Bool {
        guard Set(next.map(\.id)).count == next.count else { return false }
        removeAll()
        _ = setPages(next)
        entries.reserveCapacity(records.count)
        for (id, record) in records { self[id] = record }
        return true
    }

    /// Pencil/network streaming converts only newly appended samples, not the
    /// already stored prefix on every update.
    @discardableResult
    func appendWorldPoints(_ points: [Stroke.Point], to id: String) -> Bool {
        guard var entry = entries[id] else { return false }
        if entry.isLocal, let pageID = entry.stroke.pageId, let index = pageIndices[pageID] {
            entry.stroke.points.append(contentsOf: points.map { localPoint($0, page: pages[index]) })
            localizedPointCount += points.count
            if var cached = worldViews[id] {
                cached.points.append(contentsOf: points.map { worldPoint(localPoint($0, page: pages[index]), page: pages[index]) })
                worldViews[id] = cached
                projectedPointCount += points.count
            }
        } else { entry.stroke.points.append(contentsOf: points); worldViews.removeValue(forKey: id) }
        entries[id] = entry
        return true
    }

    func removeValue(forKey id: String) {
        entries.removeValue(forKey: id)
        worldViews.removeValue(forKey: id)
    }
    func removeAll() { entries.removeAll(); worldViews.removeAll() }

    private func owningPage(_ stroke: Stroke) -> Int? {
        if let id = stroke.pageId { return pageIndices[id] }
        if let index = stroke.pageIndex, pages.indices.contains(index) { return index }
        guard let first = stroke.points.first, !pages.isEmpty else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in stroke.points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let x = (minX + maxX) / 2, y = (minY + maxY) / 2
        func distance(_ page: Page) -> Double {
            let dx = max(page.x - x, 0, x - page.x - page.width)
            let dy = max(page.y - y, 0, y - page.y - page.height)
            return dx * dx + dy * dy
        }
        return pages.indices.min { distance(pages[$0]) < distance(pages[$1]) }
    }

    private func localPoint(_ original: Stroke.Point, page: Page) -> Stroke.Point {
        var point = original
        point.x -= page.x; point.y -= page.y
        point.xRaw -= page.x; point.yRaw -= page.y
        point.xLocal = point.x; point.yLocal = point.y
        point.xRawLocal = point.xRaw; point.yRawLocal = point.yRaw
        return point
    }
    private func normalizedWorldPoint(_ original: Stroke.Point, page: Page) -> Stroke.Point {
        var point = original
        point.xLocal = point.x - page.x; point.yLocal = point.y - page.y
        point.xRawLocal = point.xRaw - page.x; point.yRawLocal = point.yRaw - page.y
        return point
    }
    private func worldPoint(_ original: Stroke.Point, page: Page) -> Stroke.Point {
        var point = original
        point.xLocal = point.x; point.yLocal = point.y
        point.xRawLocal = point.xRaw; point.yRawLocal = point.yRaw
        point.x += page.x; point.y += page.y
        point.xRaw += page.x; point.yRaw += page.y
        return point
    }
}
