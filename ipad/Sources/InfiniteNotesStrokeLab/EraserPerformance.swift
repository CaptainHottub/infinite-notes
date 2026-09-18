import Foundation

/// One bounded diagnostic record per gesture; no ink coordinates or IDs.
struct EraserPerformance {
    private var batches = 0, samples = 0, candidates = 0, hits = 0
    private var querySeconds = 0.0, journalSeconds = 0.0, removalSeconds = 0.0, maxBatchSeconds = 0.0

    mutating func recordQuery(samples: Int, candidates: Int, hits: Int, seconds: Double) {
        batches += 1
        self.samples += samples; self.candidates += candidates; self.hits += hits
        querySeconds += seconds
        maxBatchSeconds = max(maxBatchSeconds, seconds)
    }

    mutating func recordMutation(journal: Double, removal: Double, total: Double) {
        journalSeconds += journal; removalSeconds += removal
        maxBatchSeconds = max(maxBatchSeconds, total)
    }

    func fields(workspaceSeconds: Double) -> [String: Any] {
        ["batches": batches, "samples": samples, "candidates": candidates, "hits": hits,
         "queryMs": querySeconds * 1000, "journalMs": journalSeconds * 1000,
         "removalMs": removalSeconds * 1000, "workspaceMs": workspaceSeconds * 1000,
         "maxBatchMs": maxBatchSeconds * 1000]
    }
}
