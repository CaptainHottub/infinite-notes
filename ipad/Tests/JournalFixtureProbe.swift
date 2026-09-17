import Foundation

/// Validates a copied device journal without printing stroke data or modifying it.
@main
struct JournalFixtureProbe {
    private struct OpaqueValue: Codable {
        init(from decoder: Decoder) throws { }
        func encode(to encoder: Encoder) throws { }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: JournalFixtureProbe <PendingStrokes root> <document UUID>")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let documentID = CommandLine.arguments[2]
        let recovered = try PendingStrokeJournal<OpaqueValue>(root: root).load(documentID: documentID)
        print("Validated \(recovered.count) saved-stroke records; no files changed")
    }
}
