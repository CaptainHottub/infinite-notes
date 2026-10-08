import Foundation

struct PDFPageAsset: Codable, Equatable {
    var id: String
    var width: Double
    var height: Double
    var pdfUrl: String
    var pdfSha256: String
    var pdfBytes: Int

    var isValid: Bool {
        pdfSha256.count == 64 && pdfSha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && pdfUrl == "/api/pdf/page/\(pdfSha256)"
            && pdfBytes > 0 && pdfBytes <= 100 * 1024 * 1024
            && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}

struct PDFPageManifest: Decodable {
    var documentId: String
    var pages: [PDFPageAsset]
}

/// A cache of independent vector PDFs. No combined notebook PDF is written.
/// The digest function is injected so cache integrity can be tested on Linux
/// without importing the iOS CryptoKit implementation.
final class PDFPageAssetCache {
    enum CacheError: Error { case invalidAsset, invalidContent }
    private let root: URL
    private let digest: (Data) -> String
    private var verified: Set<String> = []

    init(root: URL, digest: @escaping (Data) -> String) {
        self.root = root
        self.digest = digest
    }

    func cachedURL(for asset: PDFPageAsset) -> URL? {
        guard asset.isValid else { return nil }
        let url = root.appendingPathComponent("\(asset.pdfSha256).pdf")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == asset.pdfBytes else {
            verified.remove(asset.pdfSha256)
            return nil
        }
        if !verified.contains(asset.pdfSha256) {
            guard let data = try? Data(contentsOf: url), valid(data, asset: asset) else { return nil }
            verified.insert(asset.pdfSha256)
        }
        return url
    }

    func store(_ data: Data, for asset: PDFPageAsset) throws -> URL {
        guard asset.isValid else { throw CacheError.invalidAsset }
        guard valid(data, asset: asset) else { throw CacheError.invalidContent }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("\(asset.pdfSha256).pdf")
        if cachedURL(for: asset) == nil { try data.write(to: url, options: .atomic) }
        verified.insert(asset.pdfSha256)
        return url
    }

    /// Only prune after the new renderer has its own CGPDFDocument references.
    func prune(keeping assets: [PDFPageAsset]) {
        let keep = Set(assets.map { "\($0.pdfSha256).pdf" })
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "pdf" && !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        verified.formIntersection(Set(assets.map(\.pdfSha256)))
    }

    private func valid(_ data: Data, asset: PDFPageAsset) -> Bool {
        data.count == asset.pdfBytes && data.starts(with: Data("%PDF-".utf8)) && digest(data) == asset.pdfSha256
    }
}
