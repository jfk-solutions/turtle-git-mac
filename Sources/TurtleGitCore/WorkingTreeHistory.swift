import Foundation

/// The synthetic Log row has no commit hash and points at the actual HEAD,
/// independently of the range displayed below it. Unversioned paths are kept
/// separate for the Log's Show Unversioned Files option.
public struct WorkingTreeHistory: Sendable {
    public let entry: LogEntry
    public let files: [CommitFile]
    public let unversioned: [CommitFile]
}

extension GitRepository {
    /// Upstream concatenates the selected versioned files' patches in list order.
    /// The working-tree row compares current HEAD with both index/worktree changes.
    public func workingTreeFileDiffData(files: [CommitFile], cancellation: OperationCancellation? = nil) throws -> Data {
        guard !files.isEmpty, files.allSatisfy({ $0.action != "?" }) else { throw RevisionComparisonFailure.selection }
        func read(_ args: [String], successfulExitCodes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(args, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], successfulExitCodes: successfulExitCodes, cancellation: cancellation)
        }
        guard try read(["rev-parse", "--is-bare-repository"]).text.trimmingCharacters(in: .newlines) != "true" else { throw RevisionComparisonFailure.range }
        let head = try read(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], successfulExitCodes: 0...1)
        guard head.exitCode == 0 else { throw RevisionComparisonFailure.range }
        let base = head.text.trimmingCharacters(in: .newlines)
        func valid(_ path: String) -> Bool { !path.isEmpty && !path.contains("\0") && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") }
        var seen = Set<String>(), patch = Data()
        for file in files where seen.insert(file.path).inserted {
            guard valid(file.path), file.oldPath.map(valid) != false else { throw RevisionComparisonFailure.selection }
            let paths = file.oldPath.map { [$0, file.path] } ?? [file.path]
            patch.append(try read(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "-M", base, "--"] + paths).stdout)
        }
        return patch
    }
    public func workingTreeHistory(cancellation: OperationCancellation? = nil) throws -> WorkingTreeHistory? {
        try cancellation?.check()
        func read(_ args: [String], successfulExitCodes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(args, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], successfulExitCodes: successfulExitCodes, cancellation: cancellation)
        }
        guard try read(["rev-parse", "--is-bare-repository"]).text.trimmingCharacters(in: .newlines) != "true" else { return nil }
        let head = try read(["rev-parse", "--verify", "--quiet", "HEAD"], successfulExitCodes: 0...1)
        let parents = head.exitCode == 0 ? [head.text.trimmingCharacters(in: .newlines)] : []
        let status = StatusEntry.parse(try read(["status", "--porcelain=v1", "-z", "--untracked-files=all"]).stdout)
        // Net HEAD diff can be empty even though the index has a different
        // gitlink. Keep that row typed as a submodule rather than a text file.
        let indexRecords = try read(["ls-files", "--stage", "-z"]).stdout.split(separator: 0)
        var gitlinks = Set<String>()
        for record in indexRecords {
            guard let tab = record.firstIndex(of: 9), record.prefix(upTo: tab).starts(with: Data("160000 ".utf8)) else { continue }
            gitlinks.insert(String(decoding: record.suffix(from: record.index(after: tab)), as: UTF8.self))
        }
        var differences: [String: CommitFile] = [:]
        if let parent = parents.first {
            let args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "-M", parent, "--"]
            func data(_ format: String) throws -> Data { try read([args[0], format, "-z"] + args.dropFirst()).stdout }
            let parsed = try CommitFile.parse(names: data("--name-status"), statistics: data("--numstat"), raw: data("--raw"))
            for file in parsed { differences[file.path] = file }
        }
        var files: [CommitFile] = [], unversioned: [CommitFile] = []
        for row in status where row.state != .ignored {
            try cancellation?.check()
            let diff = differences[row.path]
            let action: String
            if row.state == .conflicted { action = "U" }
            else if row.state == .untracked { action = "?" }
            else if let diff { action = diff.action }
            else if row.state == .deleted { action = "D" }
            else if row.originalPath != nil { action = row.index == "C" || row.worktree == "C" ? "C" : "R" }
            else if row.state == .added { action = "A" }
            else if row.index == "T" || row.worktree == "T" { action = "T" }
            else { action = "M" }
            let file = CommitFile(path: row.path, oldPath: row.originalPath ?? diff?.oldPath, action: action,
                                  added: diff?.added, removed: diff?.removed, hasStatistics: diff?.hasStatistics ?? false,
                                  isSubmodule: diff?.isSubmodule == true || gitlinks.contains(row.path))
            if row.state == .untracked { unversioned.append(file) } else { files.append(file) }
            if row.hasUnversionedCopy {
                unversioned.append(CommitFile(path: row.path, oldPath: nil, action: "?", added: nil, removed: nil, hasStatistics: false, isSubmodule: false))
            }
        }
        try cancellation?.check()
        let entry = LogEntry(hash: "", author: "", date: "", subject: "Working tree changes", parents: parents,
                             message: "\(files.count) changed files")
        return WorkingTreeHistory(entry: entry, files: files, unversioned: unversioned)
    }
}
