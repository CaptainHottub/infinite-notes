import Foundation

/// Local Pencil input survives a transport loss; remote previews need recovery.
struct LiveStrokeTracker {
    private(set) var ids: Set<String> = []
    private var localIDs: Set<String> = []

    mutating func begin(_ id: String, local: Bool) {
        ids.insert(id)
        if local { localIDs.insert(id) }
    }

    mutating func end(_ id: String) {
        ids.remove(id)
        localIDs.remove(id)
    }

    mutating func reset(remoteIDs: Set<String> = []) {
        ids = remoteIDs
        localIDs.removeAll()
    }

    mutating func disconnect() -> Set<String> {
        let interrupted = ids.subtracting(localIDs)
        ids = localIDs
        return interrupted
    }
}
