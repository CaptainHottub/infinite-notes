import Foundation

@main
struct PendingStrokeJournalTests {
    static func check(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinite-notes-journal-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = UUID().uuidString.lowercased()
        let other = UUID().uuidString.lowercased()
        let journal = PendingStrokeJournal<[Int]>(root: root)
        check(try journal.load(documentID: document).isEmpty)
        try journal.save([1, 2, 3], id: "stroke/one", documentID: document)
        try journal.save([4, 5], id: "stroke-two", documentID: document)
        // A new instance models process restart, with no retained in-memory queue.
        let restarted = PendingStrokeJournal<[Int]>(root: root)
        check(try restarted.load(documentID: document) == ["stroke/one": [1, 2, 3], "stroke-two": [4, 5]])
        check(try restarted.load(documentID: other).isEmpty)
        try restarted.save([6], id: "stroke/one", documentID: document)
        try restarted.acknowledge("stroke-two", documentID: other)
        check(try journal.load(documentID: document).count == 2)
        try restarted.acknowledge("stroke-two", documentID: document)
        try restarted.acknowledge("stroke-two", documentID: document)
        check(try journal.load(documentID: document) == ["stroke/one": [6]])
        // Older records may spell the same UUID with uppercase letters.
        let folder = root.appendingPathComponent(document)
        let file = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)[0]
        var record = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        record["documentID"] = document.uppercased()
        try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
        check(try journal.load(documentID: document) == ["stroke/one": [6]])

        record["documentID"] = other
        try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
        do {
            _ = try journal.load(documentID: document)
            fatalError("Record from another notebook was accepted")
        } catch PendingStrokeJournal<[Int]>.JournalError.invalidRecord(let name, let reason) {
            check(name == file.lastPathComponent && reason == "notebook identity differs")
        }
        check(FileManager.default.fileExists(atPath: file.path))

        record["documentID"] = document
        record["version"] = 2
        try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
        do {
            _ = try journal.load(documentID: document)
            fatalError("Unsupported journal version was accepted")
        } catch PendingStrokeJournal<[Int]>.JournalError.invalidRecord(let name, let reason) {
            check(name == file.lastPathComponent && reason == "unsupported version")
        }
        check(FileManager.default.fileExists(atPath: file.path))

        record["version"] = 1
        try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
        let renamed = folder.appendingPathComponent("wrong-filename.json")
        try FileManager.default.moveItem(at: file, to: renamed)
        do {
            _ = try journal.load(documentID: document)
            fatalError("Record with wrong filename was accepted")
        } catch PendingStrokeJournal<[Int]>.JournalError.invalidRecord(let name, let reason) {
            check(name == renamed.lastPathComponent && reason == "stroke ID does not match filename")
        }
        check(FileManager.default.fileExists(atPath: renamed.path))
        do {
            try journal.save([], id: "x", documentID: "../escape")
            fatalError("Invalid document identity accepted")
        } catch PendingStrokeJournal<[Int]>.JournalError.invalidIdentity { }
        try Data("broken record".utf8).write(to: renamed)
        do {
            _ = try restarted.load(documentID: document)
            fatalError("Corruption was silently ignored")
        } catch is DecodingError { }
        assert(FileManager.default.fileExists(atPath: renamed.path))
        print("PendingStrokeJournal: restart, UUID normalization, record diagnostics, preservation passed")
    }
}
