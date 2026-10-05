import Foundation

/// The three mutually exclusive Version choices in TortoiseGit's Format Patch dialog.
public enum FormatPatchSelection: Equatable, Sendable {
    case since(String)
    case number(Int)
    case range(from: String, to: String)
}

/// FormatPatchCommand startrev/endrev and GitLogListAction ID_CREATE_PATCH.
/// A single selected revision means Since (export commits after that revision).
/// Multiple selections include the oldest selected revision via its first parent.
public struct FormatPatchPreset: Equatable, Sendable {
    public let selection: FormatPatchSelection
    public let from: String
    public let to: String
    public init?(startRevision: String?, endRevision: String? = nil) {
        guard let start = startRevision, !start.isEmpty else { return nil }
        if let end = endRevision, !end.isEmpty {
            selection = .range(from: start, to: end); from = start; to = end
        } else {
            selection = .since(start); from = start + "~1"; to = start
        }
    }
    public static func logSelection(orderedHashes: [String], selected: Set<String>, oldestFirst: Bool = false, hasHiddenRows: Bool = false) -> FormatPatchPreset? {
        let rows = orderedHashes.indices.filter { selected.contains(orderedHashes[$0]) }
        guard !rows.isEmpty, rows.count == selected.count else { return nil }
        if rows.count == 1 { return FormatPatchPreset(startRevision: orderedHashes[rows[0]]) }
        guard rows.count <= 2 || (!hasHiddenRows && rows.last! - rows.first! + 1 == rows.count) else { return nil }
        let oldest = orderedHashes[oldestFirst ? rows.first! : rows.last!]
        let newest = orderedHashes[oldestFirst ? rows.last! : rows.first!]
        return FormatPatchPreset(startRevision: oldest + "~1", endRevision: newest)
    }
}

public enum FormatPatchFailure: LocalizedError {
    case selection, outputDirectory
    public var errorDescription: String? {
        switch self {
        case .selection: return "Choose a revision or a commit count between 1 and 2147483647."
        case .outputDirectory: return "Choose an output directory outside Git metadata."
        }
    }
}

extension GitRepository {
    /// Adapted from FormatPatchCommand.cpp, GPL-2.0-or-later. Preserve Git's
    /// numbering, naming, configuration, binary patches and empty-range behavior.
    /// Existing patch files can be replaced, just as in the upstream command.
    public func formatPatch(selection: FormatPatchSelection, to folder: URL, noPrefix: Bool = false, cancellation: OperationCancellation? = nil) throws -> GitResult {
        try cancellation?.check()
        func valid(_ revision: String) -> Bool { !revision.isEmpty && !revision.contains("\0") }
        let version: [String]
        switch selection {
        case .since(let revision):
            guard valid(revision) else { throw FormatPatchFailure.selection }
            // FixBranchName upstream chooses the sole for-merge FETCH_HEAD
            // record, rather than Git's first record (which can be not-for-merge).
            let since: String
            if revision == "FETCH_HEAD" {
                var data = try run(["rev-parse", "--git-path", "FETCH_HEAD"], cancellation: cancellation).stdout
                if data.last == 10 { data.removeLast() }
                let path = String(decoding: data, as: UTF8.self)
                let location = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
                let records = try Data(contentsOf: location).split(separator: 10).compactMap { record -> String? in
                    let fields = record.split(separator: 9, omittingEmptySubsequences: false)
                    guard fields.count >= 3, fields[1].isEmpty else { return nil }
                    return String(decoding: fields[0], as: UTF8.self)
                }
                guard records.count == 1, valid(records[0]) else { throw FormatPatchFailure.selection }
                since = records[0]
            } else { since = revision }
            version = ["--end-of-options", since]
        case .number(let count):
            guard count >= 1, count <= Int(Int32.max) else { throw FormatPatchFailure.selection }
            version = ["-\(count)"]
        case .range(let from, let to):
            guard valid(from), valid(to) else { throw FormatPatchFailure.selection }
            version = ["--end-of-options", from + ".." + to]
        }
        let destination = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard folder.isFileURL,
              !destination.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw FormatPatchFailure.outputDirectory }
        // Bare repositories and linked worktrees can store metadata outside a
        // directory named .git. Never allow an export into either admin root.
        for option in ["--absolute-git-dir", "--git-common-dir"] {
            var data = try run(["rev-parse", option], cancellation: cancellation).stdout
            if data.last == 10 { data.removeLast() }
            let path = String(decoding: data, as: UTF8.self)
            let metadata = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
            guard !RepositoryAccessLease.pathIsContained(destination, by: metadata) else { throw FormatPatchFailure.outputDirectory }
        }
        return try run(["format-patch"] + (noPrefix ? ["--no-prefix"] : []) + ["-o", destination.path] + version + ["--"], cancellation: cancellation)
    }
}
