import Foundation

@main
struct Tests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-pdf-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Data("%PDF-test-a".utf8), b = Data("%PDF-test-b".utf8)
        let hashA = String(repeating: "a", count: 64), hashB = String(repeating: "b", count: 64)
        func hash(_ data: Data) -> String { data == a ? hashA : data == b ? hashB : "invalid" }
        let cache = PDFPageAssetCache(root: root, digest: hash)
        let first = PDFPageAsset(id: "page-a", width: 612, height: 792, pdfUrl: "/api/pdf/page/\(hashA)", pdfSha256: hashA, pdfBytes: a.count)
        let second = PDFPageAsset(id: "page-b", width: 612, height: 792, pdfUrl: "/api/pdf/page/\(hashB)", pdfSha256: hashB, pdfBytes: b.count)
        precondition(first.isValid && cache.cachedURL(for: first) == nil)
        let urlA = try cache.store(a, for: first)
        precondition(cache.cachedURL(for: first) == urlA)
        let modified = try urlA.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let reusedURL = try cache.store(a, for: first)
        let modifiedAfterReuse = try urlA.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        precondition(reusedURL == urlA && modifiedAfterReuse == modified)
        // A reordered/renamed page uses exactly the same bytes and file.
        var renamed = first
        renamed.id = "stable-page-a"
        precondition(cache.cachedURL(for: renamed) == urlA)
        let restarted = PDFPageAssetCache(root: root, digest: hash)
        precondition(restarted.cachedURL(for: first) == urlA)
        let urlB = try cache.store(b, for: second)
        for badData in [b, Data("bad prefix".utf8), Data()] {
            do { _ = try cache.store(badData, for: first); preconditionFailure("Accepted corrupt PDF") }
            catch PDFPageAssetCache.CacheError.invalidContent {}
        }
        for badHash in ["../escape", String(repeating: "A", count: 64), String(repeating: "a", count: 63)] {
            var invalid = first
            invalid.pdfSha256 = badHash
            precondition(!invalid.isValid && cache.cachedURL(for: invalid) == nil)
        }
        var crossOrigin = first
        crossOrigin.pdfUrl = "https://example.com/pdf"
        precondition(!crossOrigin.isValid)
        var badSize = first
        badSize.pdfBytes = -1
        precondition(!badSize.isValid)
        cache.prune(keeping: [renamed])
        precondition(FileManager.default.fileExists(atPath: urlA.path))
        precondition(!FileManager.default.fileExists(atPath: urlB.path))
        try b.write(to: urlA)
        let corrupted = PDFPageAssetCache(root: root, digest: hash)
        precondition(corrupted.cachedURL(for: first) == nil)
        _ = try corrupted.store(a, for: first)
        precondition(corrupted.cachedURL(for: first) != nil)
        print("PDFPageAssetCache: integrity, restart, reuse, identity remap, safe paths, corruption recovery and pruning passed")
    }
}
