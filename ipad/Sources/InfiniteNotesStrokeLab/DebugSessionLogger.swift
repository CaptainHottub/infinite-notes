import Foundation
import OSLog

/// Best-effort diagnostics activated by the server's initial state_refresh.
/// Only bounded metadata is retained; document and annotation content is never logged.
final class DebugSessionLogger: @unchecked Sendable {
    static let shared = DebugSessionLogger()

    private struct PendingEvent {
        let date: Date
        let sessionID: String
        let sequence: UInt64
        let category: String
        let name: String
        let fields: [String: Any]
    }

    private let osLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "InfiniteNotesNative",
        category: "DebugSession"
    )
    private let writerQueue = DispatchQueue(
        label: "InfiniteNotesNative.DebugSession",
        qos: .utility
    )
    private let lock = NSLock()
    private let maximumPendingEvents = 1_024
    private let maximumBytes: UInt64 = 2 * 1024 * 1024
    private var activeSessionID: String?
    private var eventSequence: UInt64 = 0
    private var droppedEventCount: UInt64 = 0
    private var pendingEvents: [PendingEvent] = []
    private var drainScheduled = false
    private lazy var timestampFormatter = ISO8601DateFormatter()

    private init() {}

    func configure(enabled: Bool, sessionID: String?) {
        let normalized = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextSessionID = enabled && !normalized.isEmpty
            ? String(normalized.prefix(128))
            : nil

        lock.lock()
        let changed = activeSessionID != nextSessionID
        if changed {
            activeSessionID = nextSessionID
            eventSequence = 0
            droppedEventCount = 0
        }
        lock.unlock()

        if changed, let nextSessionID {
            event(
                "lifecycle",
                "server_session_received",
                fields: ["serverSessionId": nextSessionID]
            )
        }
    }

    func event(_ category: String, _ name: String, fields: [String: Any] = [:]) {
        guard isEnabled else { return }
        let safeFields = sanitized(fields)
        var shouldScheduleDrain = false

        lock.lock()
        guard let sessionID = activeSessionID else {
            lock.unlock()
            return
        }
        guard pendingEvents.count < maximumPendingEvents else {
            droppedEventCount &+= 1
            lock.unlock()
            return
        }

        eventSequence &+= 1
        var recordFields = safeFields
        if droppedEventCount > 0 {
            recordFields["droppedEventCount"] = droppedEventCount
        }
        pendingEvents.append(PendingEvent(
            date: Date(),
            sessionID: sessionID,
            sequence: eventSequence,
            category: String(category.prefix(64)),
            name: String(name.prefix(128)),
            fields: recordFields
        ))
        if !drainScheduled {
            drainScheduled = true
            shouldScheduleDrain = true
        }
        lock.unlock()

        if shouldScheduleDrain {
            writerQueue.async { [weak self] in
                self?.drainPendingEvents()
            }
        }
    }

    func protocolEvent(direction: String, object: [String: Any], byteCount: Int) {
        guard isEnabled else { return }
        var fields: [String: Any] = [
            "direction": direction,
            "byteCount": max(0, byteCount),
            "messageType": String((object["type"] as? String ?? "unknown").prefix(64)),
        ]
        if let id = object["id"] as? String { fields["strokeId"] = id }
        if let ids = object["ids"] as? [Any] { fields["idCount"] = ids.count }
        if let operationID = object["operationId"] as? String {
            fields["operationId"] = operationID
        }
        if let documentID = object["documentId"] as? String {
            fields["documentId"] = documentID
        }
        if let reason = object["reason"] as? String { fields["reason"] = reason }
        if let points = object["points"] as? [Any] { fields["pointCount"] = points.count }
        if let strokes = object["strokes"] as? [Any] { fields["strokeCount"] = strokes.count }
        if let stroke = object["stroke"] as? [String: Any] {
            fields["strokeCount"] = 1
            if fields["strokeId"] == nil, let id = stroke["id"] as? String {
                fields["strokeId"] = id
            }
        }
        event("protocol", "message", fields: fields)
    }

    func protocolEvent(direction: String, envelope: ServerEnvelope, byteCount: Int) {
        guard isEnabled else { return }
        var fields: [String: Any] = [
            "direction": direction,
            "byteCount": max(0, byteCount),
            "messageType": String(envelope.type.prefix(64)),
        ]
        if let id = envelope.id { fields["strokeId"] = id }
        if let ids = envelope.ids { fields["idCount"] = ids.count }
        if let operationID = envelope.operationId { fields["operationId"] = operationID }
        if let documentID = envelope.documentId { fields["documentId"] = documentID }
        if let revision = envelope.documentRevision { fields["documentRevision"] = revision }
        if let reason = envelope.reason { fields["reason"] = reason }
        if let pointCount = envelope.pointCount {
            fields["pointCount"] = pointCount
        } else if let points = envelope.points {
            fields["pointCount"] = points.count
        }
        if let strokes = envelope.strokes {
            fields["strokeCount"] = strokes.count
        } else if envelope.stroke != nil {
            fields["strokeCount"] = 1
        }
        if let state = envelope.state {
            fields["strokeCount"] = state.strokes.count
            fields["pageCount"] = state.document.pages.count
            if let documentID = state.documentId { fields["documentId"] = documentID }
            if let revision = state.documentRevision { fields["documentRevision"] = revision }
        }
        event("protocol", "message", fields: fields)
    }

    private var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeSessionID != nil
    }

    private func sanitized(_ fields: [String: Any]) -> [String: Any] {
        let forbidden = Set([
            "category", "content", "data", "document", "event", "eventsequence",
            "payload", "pdf", "points", "project", "sessionid", "state", "stroke",
            "strokes", "text", "timestamp",
        ])
        var result: [String: Any] = [:]
        for (key, value) in fields.prefix(50) {
            let safeKey = String(key.prefix(64))
            guard !forbidden.contains(safeKey.lowercased()) else { continue }
            switch value {
            case let string as String:
                result[safeKey] = String(string.prefix(512))
            case let number as NSNumber:
                result[safeKey] = number
            case let boolean as Bool:
                result[safeKey] = boolean
            case let integer as Int:
                result[safeKey] = integer
            case let unsigned as UInt64:
                result[safeKey] = unsigned
            case let double as Double:
                result[safeKey] = double
            case let float as Float:
                result[safeKey] = float
            default:
                result[safeKey] = "<redacted:container>"
            }
        }
        return result
    }

    private func drainPendingEvents() {
        while true {
            lock.lock()
            guard !pendingEvents.isEmpty else {
                drainScheduled = false
                lock.unlock()
                return
            }
            let pending = pendingEvents.removeFirst()
            lock.unlock()
            write(pending)
        }
    }

    private func write(_ pending: PendingEvent) {
        var record: [String: Any] = [
            "timestamp": timestampFormatter.string(from: pending.date),
            "sessionId": pending.sessionID,
            "eventSequence": pending.sequence,
            "category": pending.category,
            "event": pending.name,
        ]
        for (key, value) in pending.fields {
            record[key] = value
        }

        let details = pending.fields.keys.sorted().map { key in
            "\(key)=\(pending.fields[key]!)"
        }.joined(separator: " ")
        let suffix = details.isEmpty ? "" : " \(details)"
        let line = "session=\(pending.sessionID) [\(pending.category.uppercased())] "
            + "#\(pending.sequence) \(pending.name)\(suffix)"
        osLogger.debug("\(line, privacy: .public)")

        do {
            try append(record: record, sessionID: pending.sessionID)
        } catch {
            osLogger.error(
                "Debug file logging failed; app operation will continue: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func append(record: [String: Any], sessionID: String) throws {
        let manager = FileManager.default
        let documents = try manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents
            .appendingPathComponent("InfiniteNotes", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeID = String(sessionID.prefix(128)).replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )
        let fileURL = directory.appendingPathComponent("session-\(safeID).jsonl")
        let backupURL = directory.appendingPathComponent("session-\(safeID).jsonl.1")
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0A)

        let attributes = try? manager.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if size + UInt64(data.count) > maximumBytes {
            try? manager.removeItem(at: backupURL)
            if manager.fileExists(atPath: fileURL.path) {
                try manager.moveItem(at: fileURL, to: backupURL)
            }
        }
        if !manager.fileExists(atPath: fileURL.path) {
            _ = manager.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
