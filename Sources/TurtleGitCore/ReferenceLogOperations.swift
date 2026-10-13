import Foundation

extension GitRepository {
    /// Read immutable commit metadata for the captured reflog events. Query each
    /// object once, then restore event order and duplicates: selectors identify
    /// events, and two selected events can point at the same commit.
    public func referenceLogOperationEntries(snapshot: [ReferenceLogEntry], selected: Set<String>, cancellation: OperationCancellation? = nil) throws -> [LogEntry] {
        try cancellation?.check()
        let chosen = snapshot.filter { selected.contains($0.id) }
        guard !chosen.isEmpty, chosen.count == selected.count else { throw ReferenceLogFailure.selection }
        var seen = Set<String>(), hashes: [String] = []
        for entry in chosen {
            guard [40,64].contains(entry.hash.utf8.count), entry.hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ReferenceLogFailure.selection }
            if seen.insert(entry.hash).inserted { hashes.append(entry.hash) }
        }
        var records: [String: LogEntry] = [:]
        let format = "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%B%x00"
        for start in stride(from: 0, to: hashes.count, by: 128) {
            try cancellation?.check()
            let batch = Array(hashes[start..<min(start + 128, hashes.count)])
            let output = try run(["log", "--no-walk=unsorted", "--no-show-signature", "--encoding=UTF-8", "--no-notes", format] + batch + ["--"], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout
            let parsed = LogEntry.parseHistory(output)
            guard parsed.count == batch.count, Set(parsed.map(\.hash)) == Set(batch) else { throw ReferenceLogFailure.selection }
            for entry in parsed { records[entry.hash] = entry }
        }
        try cancellation?.check()
        return try chosen.map { guard let entry = records[$0.hash] else { throw ReferenceLogFailure.selection }; return entry }
    }
}
