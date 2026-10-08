import Foundation

public struct ReferenceLogEntry: Identifiable, Hashable, Sendable {
    public let hash: String
    public let selector: String
    public let timestamp: String
    public let subject: String
    public var id: String { selector }
    public var action: String { subject.components(separatedBy: ": ").first ?? subject }
    public var message: String { subject.range(of: ": ").map { String(subject[$0.upperBound...]) } ?? "" }
    public var date: Date? { timestamp.split(separator: " ").first.flatMap { TimeInterval($0) }.map(Date.init(timeIntervalSince1970:)) }
}
public struct ReferenceLogDeleteIssue: Sendable {
    public let selector: String
    public let details: String
}
public struct ReferenceLogDeleteBatchFailure: LocalizedError, Sendable {
    public let completed: [String]
    public let failures: [ReferenceLogDeleteIssue]
    public let output: String
    public var errorDescription: String? {
        "Deleted entries: \(completed.count). Failed entries: \(failures.count).\n" +
        failures.map { $0.selector + ": " + $0.details }.joined(separator: "\n")
    }
}
public enum ReferenceLogFailure: LocalizedError {
    case reference, stale, selection
    public var errorDescription: String? {
        switch self {
        case .reference: return "Choose HEAD or a full reference name."
        case .stale: return "The current view is out of date. Refresh and recheck the selection."
        case .selection: return "Select entries from the current reference log."
        }
    }
}
extension GitRepository {
    /// Upstream's hash-to-friendly-name map, including peeled annotated tags.
    /// RefLog has no clicked ref label, so Switch guesses the first remote name.
    public func referenceLogReferenceNamesByHash() throws -> [String: [String]] {
        let result = try run(["show-ref", "-d"], successfulExitCodes: 0...1)
        var names: [String: [String]] = [:]
        for line in result.text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { continue }
            names[String(fields[0]), default: []].append(String(fields[1]))
        }
        return names.mapValues { $0.sorted() }
    }
    public func referenceLogNames() throws -> [String] {
        ["HEAD"] + (try run(["for-each-ref", "--format=%(refname)"])).text.split(separator: "\n").map(String.init)
    }
    public func referenceLog(_ reference: String) throws -> [ReferenceLogEntry] {
        guard reference == "HEAD" || (reference.hasPrefix("refs/") && !reference.contains("\0") && !reference.contains("\n") && (try? run(["check-ref-format", reference])) != nil) else { throw ReferenceLogFailure.reference }
        // Read the exact log, as the upstream libgit2/gitdll paths do. Git's
        // reflog-show walk can fall back from an empty HEAD log to the branch
        // log, making deleted HEAD entries appear again with wrong selectors.
        var pathBytes = try run(["rev-parse", "--git-path", "logs/" + reference]).stdout
        if pathBytes.last == 10 { pathBytes.removeLast() }
        let path = String(decoding: pathBytes, as: UTF8.self)
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        var entries: [ReferenceLogEntry] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let header = parts[0].split(separator: " ")
            guard header.count >= 5, let hash = header.dropFirst().first,
                  (hash.count == 40 || hash.count == 64), hash.allSatisfy({ $0.isHexDigit }),
                  Int64(header[header.count - 2]) != nil else { continue }
            let timestamp = String(header[header.count - 2]) + " " + header[header.count - 1]
            entries.append(.init(hash: String(hash), selector: reference + "@{\(entries.count)}", timestamp: timestamp, subject: parts.count > 1 ? String(parts[1]) : ""))
        }
        return entries
    }
    /// Delete positional reflog entries without moving the ref. Stash deletion
    /// uses stash drop so its stack ref is updated by Git, matching upstream.
    public func deleteReferenceLogEntries(_ selected: Set<String>, reference: String, expected: [ReferenceLogEntry], onFailure: (@Sendable (ReferenceLogDeleteIssue) async -> Void)? = nil) async throws -> String {
        guard reference == "HEAD" || (reference.hasPrefix("refs/") && !reference.contains("\0") && !reference.contains("\n") && (try? run(["check-ref-format", reference])) != nil) else { throw ReferenceLogFailure.reference }
        if reference == "refs/stash" { return try await deleteStashEntries(selected, expected: expected, onFailure: onFailure) }
        let current = try referenceLog(reference)
        guard current == expected else { throw ReferenceLogFailure.stale }
        guard !expected.isEmpty, !selected.isEmpty, selected.isSubset(of: Set(expected.map(\.selector))) else { throw ReferenceLogFailure.selection }
        return try await deleteReferenceLogBatch(selected, expected: expected, stash: false, onFailure: onFailure)
    }
    /// Verify every row before positional deletion, then delete from oldest to newest
    /// so removing a row does not shift a subsequent selection's stash index.
    public func deleteStashEntries(_ selected: Set<String>, expected: [ReferenceLogEntry], clear: Bool = false, onFailure: (@Sendable (ReferenceLogDeleteIssue) async -> Void)? = nil) async throws -> String {
        let current = try referenceLog("refs/stash")
        guard current == expected else { throw ReferenceLogFailure.stale }
        guard !expected.isEmpty, clear || (!selected.isEmpty && selected.isSubset(of: Set(expected.map(\.selector)))) else { throw ReferenceLogFailure.selection }
        if clear { return try run(["stash", "clear"]).text }
        return try await deleteReferenceLogBatch(selected, expected: expected, stash: true, onFailure: onFailure)
    }
    private func deleteReferenceLogBatch(_ selected: Set<String>, expected: [ReferenceLogEntry], stash: Bool, onFailure: (@Sendable (ReferenceLogDeleteIssue) async -> Void)?) async throws -> String {
        var output = "", completed: [String] = [], failures: [ReferenceLogDeleteIssue] = []
        for entry in expected.reversed() where selected.contains(entry.selector) {
            do {
                output += try run((stash ? ["stash", "drop"] : ["reflog", "delete"]) + ["--", entry.selector]).text
                completed.append(entry.selector)
            } catch {
                let issue = ReferenceLogDeleteIssue(selector: entry.selector, details: (error as? GitFailure)?.message ?? error.localizedDescription)
                failures.append(issue)
                await onFailure?(issue)
            }
        }
        if !failures.isEmpty { throw ReferenceLogDeleteBatchFailure(completed: completed, failures: failures, output: output) }
        return output
    }
}
