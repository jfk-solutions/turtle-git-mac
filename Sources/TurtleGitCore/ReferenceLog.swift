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
    public func referenceLogNames() throws -> [String] {
        ["HEAD"] + (try run(["for-each-ref", "--format=%(refname)"])).text.split(separator: "\n").map(String.init)
    }
    public func referenceLog(_ reference: String) throws -> [ReferenceLogEntry] {
        guard reference == "HEAD" || (reference.hasPrefix("refs/") && !reference.contains("\0") && !reference.contains("\n")) else { throw ReferenceLogFailure.reference }
        do { _ = try run(["rev-parse", "--verify", "--quiet", "--end-of-options", reference]) }
        catch let error as GitFailure where error.code == 1 { return [] }
        let bytes = try run(["reflog", "show", "--date=raw", "--format=%H%x00%gD%x00%gs%x00", reference, "--"]).stdout
        let fields = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\0")
        var entries: [ReferenceLogEntry] = [], offset = 0
        while offset + 2 < fields.count {
            let hash = fields[offset].trimmingCharacters(in: .newlines)
            let datedRef = fields[offset + 1], subject = fields[offset + 2]
            guard !hash.isEmpty else { break }
            let timestamp = datedRef.range(of: "@{", options: .backwards).map { String(datedRef[$0.upperBound...].dropLast()) } ?? ""
            entries.append(.init(hash: hash, selector: reference + "@{\(entries.count)}", timestamp: timestamp, subject: subject))
            offset += 3
        }
        return entries
    }
    /// Delete positional reflog entries without moving the ref. Stash deletion
    /// uses stash drop so its stack ref is updated by Git, matching upstream.
    public func deleteReferenceLogEntries(_ selected: Set<String>, reference: String, expected: [ReferenceLogEntry]) throws -> String {
        guard reference == "HEAD" || (reference.hasPrefix("refs/") && !reference.contains("\0") && !reference.contains("\n") && (try? run(["check-ref-format", reference])) != nil) else { throw ReferenceLogFailure.reference }
        if reference == "refs/stash" { return try deleteStashEntries(selected, expected: expected) }
        let current = try referenceLog(reference)
        guard current == expected else { throw ReferenceLogFailure.stale }
        guard !expected.isEmpty, !selected.isEmpty, selected.isSubset(of: Set(expected.map(\.selector))) else { throw ReferenceLogFailure.selection }
        var output = ""
        for entry in expected.reversed() where selected.contains(entry.selector) {
            output += try run(["reflog", "delete", "--", entry.selector]).text
        }
        return output
    }
    /// Verify every row before positional deletion, then delete from oldest to newest
    /// so removing a row does not shift a subsequent selection's stash index.
    public func deleteStashEntries(_ selected: Set<String>, expected: [ReferenceLogEntry], clear: Bool = false) throws -> String {
        let current = try referenceLog("refs/stash")
        guard current == expected else { throw ReferenceLogFailure.stale }
        guard !expected.isEmpty, clear || (!selected.isEmpty && selected.isSubset(of: Set(expected.map(\.selector)))) else { throw ReferenceLogFailure.selection }
        if clear { return try run(["stash", "clear"]).text }
        var output = ""
        for entry in expected.reversed() where selected.contains(entry.selector) {
            output += try run(["stash", "drop", "--", entry.selector]).text
        }
        return output
    }
}
