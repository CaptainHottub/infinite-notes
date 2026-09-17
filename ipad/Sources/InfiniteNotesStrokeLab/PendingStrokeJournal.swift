import Foundation

/// One atomic file per completed stroke; ordinary commits never rewrite the queue.
/// Callers keep records until a server acknowledgement confirms persistence.
struct PendingStrokeJournal<Value: Codable> {
    let root: URL

    private struct Record: Codable {
        let version: Int
        let documentID: String
        let id: String
        let value: Value
    }

    enum JournalError: LocalizedError {
        case invalidIdentity
        case invalidRecord(file: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .invalidIdentity:
                return "Saved stroke has an invalid notebook or stroke identity"
            case let .invalidRecord(file, reason):
                return "Saved stroke record \(file) is inconsistent (\(reason)); the file was kept"
            }
        }
    }

    private func canonicalDocumentID(_ documentID: String) throws -> String {
        guard let uuid = UUID(uuidString: documentID) else { throw JournalError.invalidIdentity }
        return uuid.uuidString.lowercased()
    }

    private func directory(_ documentID: String) throws -> URL {
        root.appendingPathComponent(try canonicalDocumentID(documentID), isDirectory: true)
    }

    private func file(_ id: String, documentID: String) throws -> URL {
        guard !id.isEmpty, id.utf8.count <= 128 else { throw JournalError.invalidIdentity }
        let name = Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return try directory(documentID).appendingPathComponent(name + ".json")
    }

    func save(_ value: Value, id: String, documentID: String) throws {
        let destination = try file(id, documentID: documentID)
        let record = Record(version: 1, documentID: try canonicalDocumentID(documentID),
                            id: id, value: value)
        let data = try JSONEncoder().encode(record)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    func load(documentID: String) throws -> [String: Value] {
        let folder = try directory(documentID)
        let canonicalID = try canonicalDocumentID(documentID)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [:] }
        var result: [String: Value] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
            guard record.version == 1 else {
                throw JournalError.invalidRecord(file: url.lastPathComponent, reason: "unsupported version")
            }
            guard (try? canonicalDocumentID(record.documentID)) == canonicalID else {
                throw JournalError.invalidRecord(file: url.lastPathComponent, reason: "notebook identity differs")
            }
            guard let expected = try? file(record.id, documentID: canonicalID),
                  expected.lastPathComponent == url.lastPathComponent else {
                throw JournalError.invalidRecord(file: url.lastPathComponent, reason: "stroke ID does not match filename")
            }
            result[record.id] = record.value
        }
        return result
    }

    func acknowledge(_ id: String, documentID: String) throws {
        let url = try file(id, documentID: documentID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
