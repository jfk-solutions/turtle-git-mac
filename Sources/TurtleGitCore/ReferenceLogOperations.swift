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

public struct ReferenceLogCombineCandidate: Sendable {
    public let entries: [LogEntry]
    public let offset: Int
    public let head: String
    public let selectors: Set<String>
}
public struct ReferenceLogBisectRequest: Sendable {
    public let good: String?
    public let bad: String?
    public let operation: BisectOperation?
    public let revisions: [String]
}
extension GitRepository {
    /// Match the source's RefLog row-to-HEAD endpoint checks. Actual history
    /// rewriting is still validated by the shared Combine workflow at execution.
    public func referenceLogCombineCandidate(snapshot: [ReferenceLogEntry], selected: Set<String>, expectedHead: String, cancellation: OperationCancellation? = nil) throws -> ReferenceLogCombineCandidate? {
        try cancellation?.check()
        guard try !isBare(cancellation: cancellation), try !logMergeActive(cancellation: cancellation) else { return nil }
        let rows = snapshot.indices.filter { selected.contains(snapshot[$0].id) }
        guard rows.count >= 2, rows.count == selected.count, rows.last! - rows.first! + 1 == rows.count,
              let headRow = snapshot.firstIndex(where: { $0.hash == expectedHead }), rows.first! >= headRow else { return nil }
        let head = try run(["rev-parse", "--verify", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        guard head == expectedHead else { return nil }
        let offset = rows.first! - headRow
        func ancestor(_ offset: Int) throws -> String? {
            let value = try run(["rev-parse", "--verify", "HEAD~" + String(offset)], successfulExitCodes: 0...128, cancellation: cancellation)
            return value.exitCode == 0 ? value.text.trimmingCharacters(in: .newlines) : nil
        }
        guard try ancestor(offset) == snapshot[rows.first!].hash,
              try ancestor(offset + rows.count - 1) == snapshot[rows.last!].hash else { return nil }
        let entries = try referenceLogOperationEntries(snapshot: snapshot, selected: selected, cancellation: cancellation)
        return ReferenceLogCombineCandidate(entries: entries, offset: offset, head: head, selectors: selected)
    }
    public func referenceLogBisectRequest(snapshot: [ReferenceLogEntry], selected: Set<String>, operation: BisectOperation?, references: [String: [String]], cancellation: OperationCancellation? = nil) throws -> ReferenceLogBisectRequest {
        try cancellation?.check()
        guard try !isBare(cancellation: cancellation) else { throw BisectFailure.workingTree }
        let entries = try referenceLogOperationEntries(snapshot: snapshot, selected: selected, cancellation: cancellation)
        let state = try bisectState(cancellation: cancellation)
        if let operation {
            guard operation != .reset, operation == .skip || entries.count == 1 else { throw BisectFailure.operation }
            guard state.active else { throw BisectFailure.inactive }
            let marks = try run(["for-each-ref", "--points-at", entries[0].hash, "--format=%(refname)", "refs/bisect/"], cancellation: cancellation)
            guard marks.stdout.isEmpty else { throw ReferenceLogBisectFailure.marked }
            return ReferenceLogBisectRequest(good: nil, bad: nil, operation: operation, revisions: entries.map(\.hash))
        }
        guard entries.count == 2 else { throw BisectFailure.operation }
        guard !state.active, try !logMergeActive(cancellation: cancellation) else { throw BisectFailure.active }
        func preset(_ entry: LogEntry) throws -> String {
            guard let name = references[entry.hash]?.first else { return entry.hash }
            let value = try run(["rev-parse", "--verify", "--end-of-options", name + "^{commit}"], successfulExitCodes: 0...128, cancellation: cancellation)
            return value.exitCode == 0 && value.text.trimmingCharacters(in: .newlines) == entry.hash ? name : entry.hash
        }
        return ReferenceLogBisectRequest(good: try preset(entries[1]), bad: try preset(entries[0]), operation: nil, revisions: [])
    }
}

public enum ReferenceLogBisectFailure: LocalizedError {
    case marked
    public var errorDescription: String? { "This revision is already marked in the active bisect session." }
}

/// RefLog transport menus use the selected event, while named Push presets
/// must still point at its commit when the dialog is opened.
public enum ReferenceLogTransportCommand: Sendable { case push, pull, svnDCommit }
public struct ReferenceLogTransportRequest: Sendable {
    public let command: ReferenceLogTransportCommand
    public let source: String?
}
extension GitRepository {
    public func referenceLogHasGitSVN(cancellation: OperationCancellation? = nil) throws -> Bool {
        var bytes = try run(["rev-parse", "--git-common-dir"], cancellation: cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let result = String(decoding: bytes, as: UTF8.self)
        let directory = result.hasPrefix("/") ? URL(fileURLWithPath: result) : root.appendingPathComponent(result)
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("svn/.metadata").path)
    }
    public func referenceLogTransportRequest(command: ReferenceLogTransportCommand, entry: ReferenceLogEntry, references: [String], cancellation: OperationCancellation? = nil) throws -> ReferenceLogTransportRequest {
        _ = try referenceLogOperationEntries(snapshot: [entry], selected: [entry.id], cancellation: cancellation)
        switch command {
        case .push:
            // Prefer local branches, then tags; an externally moved name must
            // never silently select another revision in the Push dialog.
            let names = references.filter { $0.hasPrefix("refs/heads/") } + references.filter { $0.hasPrefix("refs/tags/") }
            for name in names {
                let ref = GitReferenceName.removingSuffix("^{}", from: name) ?? name
                let value = try run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], successfulExitCodes: 0...128, cancellation: cancellation)
                if value.exitCode == 0, value.text.trimmingCharacters(in: .newlines) == entry.hash {
                    return ReferenceLogTransportRequest(command: command, source: ref)
                }
            }
            return ReferenceLogTransportRequest(command: command, source: entry.hash)
        case .pull:
            guard try !isBare(cancellation: cancellation), try !logMergeActive(cancellation: cancellation) else { throw ReferenceLogFailure.selection }
            let head = try run(["rev-parse", "--verify", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            guard head == entry.hash else { throw ReferenceLogFailure.selection }
        case .svnDCommit:
            guard try !isBare(cancellation: cancellation), try referenceLogHasGitSVN(cancellation: cancellation) else { throw ReferenceLogFailure.selection }
        }
        return ReferenceLogTransportRequest(command: command, source: nil)
    }
}
