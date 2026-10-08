import Foundation

private struct Point: PageLocalInkPoint, Equatable {
    var x: Double
    var y: Double
    var xRaw: Double
    var yRaw: Double
    var xLocal: Double? = nil
    var yLocal: Double? = nil
    var xRawLocal: Double? = nil
    var yRawLocal: Double? = nil
    var pressure: Double = 0.7
    var time: Double = 123
}
private struct Stroke: PageLocalInkStroke {
    var id: String
    var pageId: String?
    var pageIndex: Int?
    var points: [Point]
    var shapeType: String = "ellipse"
}

@main
struct Tests {
    static func main() {
        typealias Store = PageLocalInkStore<Stroke>
        let a = Store.Page(id: "a", x: 10, y: 0, width: 100, height: 120)
        let b = Store.Page(id: "b", x: 20, y: 150, width: 100, height: 120)
        let c = Store.Page(id: "c", x: 30, y: 300, width: 100, height: 120)
        let store = Store()
        precondition(store.setPages([a, b, c]))
        store.cacheWorldViews(for: ["b"])
        let point = Point(x: -15, y: 160, xRaw: -14, yRaw: 161, xLocal: 999, yLocal: 999)
        let original = Stroke(id: "s", pageId: "b", pageIndex: 0, points: [point])
        store["s"] = original
        let canonical = store.localRecord("s")!
        precondition(canonical.pageIndex == nil && canonical.pageId == "b")
        precondition(canonical.points[0].x == -35 && canonical.points[0].y == 10)
        precondition(canonical.points[0].xRaw == -34 && canonical.points[0].yRaw == 11)
        precondition(canonical.points[0].pressure == point.pressure && canonical.points[0].time == point.time)
        let world = store["s"]!
        precondition(world.points[0].x == point.x && world.points[0].y == point.y)
        precondition(world.points[0].xLocal == -35 && world.points[0].yLocal == 10)
        precondition(world.pageIndex == 1 && world.shapeType == original.shapeType)
        let normalized = store.normalizedWorldStroke(original)
        precondition(normalized.pageIndex == 1 && normalized.points == world.points)

        let localBefore = store.localizedPointCount
        let projectedBefore = store.projectedPointCount
        let inserted = Store.Page(id: "inserted", x: 10, y: 150, width: 100, height: 120)
        let movedB = Store.Page(id: "b", x: 50, y: 300, width: 100, height: 120)
        let movedC = Store.Page(id: "c", x: 30, y: 450, width: 100, height: 120)
        precondition(store.setPages([a, inserted, movedB, movedC], removeMissing: true))
        precondition(store.localRecord("s")!.points == canonical.points)
        precondition(store.localizedPointCount == localBefore && store.projectedPointCount == projectedBefore)
        precondition(store.ownership == ["s": "b"])
        let movedWorld = store["s"]!
        precondition(movedWorld.pageIndex == 2 && movedWorld.points[0].x == 15 && movedWorld.points[0].y == 310)

        // Streaming samples convert only the new suffix. The mounted world view
        // is updated incrementally, without projecting the stored prefix again.
        let beforeAppend = store.projectedPointCount
        let next = Point(x: 17, y: 315, xRaw: 18, yRaw: 316)
        let normalizedBatch = store.normalizedWorldPoints([next], for: "s")
        precondition(normalizedBatch[0].x == 17 && normalizedBatch[0].y == 315)
        precondition(normalizedBatch[0].xLocal == -33 && normalizedBatch[0].yLocal == 15)
        precondition(store.normalizedWorldPoints([next], for: "missing") == [next])
        precondition(store.appendWorldPoints([next], to: "s"))
        precondition(store.localizedPointCount == localBefore + 1)
        precondition(store.projectedPointCount == beforeAppend + 1)
        precondition(store["s"]!.points.count == 2 && store.projectedPointCount == beforeAppend + 1)
        precondition(store.localRecord("s")!.points.last!.y == 15)
        precondition(!store.appendWorldPoints([next], to: "missing"))

        // Replacement/undo input is world-space at the current page placement.
        store["s"] = movedWorld
        precondition(store.localRecord("s")!.points == canonical.points)
        store["delete"] = Stroke(id: "delete", pageId: "c", pageIndex: nil, points: [next])
        let reboundB = Store.Page(id: "stable-b", x: 20, y: 150, width: 100, height: 120)
        let counters = (store.localizedPointCount, store.projectedPointCount)
        precondition(store.setPages([a, reboundB], idMap: ["b": "stable-b"], removeMissing: true))
        precondition(!store.contains("delete") && store.count == 1)
        precondition(store.owner(of: "s") == "stable-b")
        precondition(store.localRecord("s")!.points == canonical.points)
        precondition(store.localizedPointCount == counters.0 && store.projectedPointCount == counters.1)
        precondition(store["s"]!.points[0].y == 160)
        precondition(!store.setPages([a, a], removeMissing: true))
        precondition(store.owner(of: "s") == "stable-b" && store["s"]!.pageIndex == 1)

        // Unmounted projections are disposable; neither they nor a cached view
        // can retain an old page offset after a layout update.
        store.cacheWorldViews(for: [])
        let evicted = store.projectedPointCount
        _ = store["s"]; _ = store["s"]
        precondition(store.projectedPointCount == evicted + 2)
        store.cacheWorldViews(for: ["stable-b"])
        _ = store["s"]
        let cached = store.projectedPointCount
        _ = store["s"]
        precondition(store.projectedPointCount == cached)

        let legacy = Stroke(id: "legacy", pageId: nil, pageIndex: 1, points: [point])
        let nearest = Stroke(id: "nearest", pageId: nil, pageIndex: nil, points: [point])
        let unknown = Stroke(id: "unknown", pageId: "deleted-page", pageIndex: 0, points: [point])
        let empty = Stroke(id: "empty", pageId: nil, pageIndex: nil, points: [])
        precondition(store.replaceAll(["legacy": legacy, "nearest": nearest, "unknown": unknown, "empty": empty], pages: [a, b]))
        precondition(store.owner(of: "legacy") == "b" && store.owner(of: "nearest") == "b")
        precondition(store.owner(of: "unknown") == nil && store["unknown"]!.pageId == "deleted-page")
        precondition(store.contains("empty") && store.unowned.count == 2)
        precondition(!store.replaceAll([:], pages: [a, a]) && store.count == 4)
        store.removeValue(forKey: "empty")
        precondition(!store.contains("empty"))
        store.removeAll()
        precondition(store.count == 0)

        // Regression: inserting/deleting above a dense notebook must not walk
        // any canonical point buffer, including one-time legacy ID migration.
        let dense = Store()
        let pages = (0..<20).map { Store.Page(id: "old-\($0)", x: 0, y: Double($0 * 150), width: 100, height: 120) }
        dense.setPages(pages)
        for i in 0..<2400 {
            let page = i % pages.count
            let points = (0..<80).map { Point(x: Double($0), y: pages[page].y + Double($0), xRaw: Double($0), yRaw: pages[page].y + Double($0)) }
            dense["s-\(i)"] = Stroke(id: "s-\(i)", pageId: nil, pageIndex: page, points: points)
        }
        let buffers = Dictionary(uniqueKeysWithValues: dense.ids.map { ($0, dense.localRecord($0)!.points) })
        let before = (dense.localizedPointCount, dense.projectedPointCount)
        let remapped = pages.enumerated().map { Store.Page(id: "new-\($0.offset)", x: $0.element.x, y: $0.element.y + 150, width: 100, height: 120) }
        let mapping = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.element.id, "new-\($0.offset)") })
        let start = ProcessInfo.processInfo.systemUptime
        dense.setPages([inserted] + remapped, idMap: mapping, removeMissing: true)
        precondition(dense.localizedPointCount == before.0 && dense.projectedPointCount == before.1)
        precondition(dense.count == 2400 && dense.ownership.count == 2400)
        for (id, points) in buffers { precondition(dense.localRecord(id)!.points == points) }
        dense.setPages(Array(remapped.dropFirst()), removeMissing: true)
        precondition(dense.count == 2280)
        for id in dense.ids { precondition(dense.localRecord(id)!.points == buffers[id]!) }
        precondition(dense.localizedPointCount == before.0 && dense.projectedPointCount == before.1)
        precondition(buffers.count == 2400) // Keep canonical buffers alive during the regression.
        print("PageLocalInkStore: conversion, ownership, streaming, cache, migration and deletion passed")
        print("PageLocalInkStore: 2,400 strokes / 192,000 points: insert + delete processed zero points in \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms")
    }
}
