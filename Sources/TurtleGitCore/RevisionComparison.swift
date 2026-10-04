import Foundation

public enum ComparisonRevision: Hashable, Sendable {
    case revision(String), workingTree, emptyTree
    public var label: String {
        switch self { case .revision(let value): return value; case .workingTree: return "Working tree"; case .emptyTree: return "Empty tree" }
    }
}
public struct RevisionDiffOptions: Equatable, Sendable {
    public var ignoreSpaceAtEnd = false, ignoreSpaceChange = false, ignoreAllSpace = false, ignoreBlankLines = false, commonAncestor = false
    public init() {}
    var arguments: [String] {
        (ignoreSpaceAtEnd ? ["--ignore-space-at-eol"] : []) + (ignoreSpaceChange ? ["-b"] : []) + (ignoreAllSpace ? ["-w"] : []) + (ignoreBlankLines ? ["--ignore-blank-lines"] : [])
    }
}
public struct ComparisonRevisionDetails: Sendable {
    public let shortHash: String
    public let subject: String
    public let author: String
    public let authorDate: Date?
    public let committerDate: Date?
}
public struct RevisionComparisonSnapshot: Sendable {
    public let root: URL
    public let from: ComparisonRevision
    public let to: ComparisonRevision
    public let fromDetails: ComparisonRevisionDetails?
    public let toDetails: ComparisonRevisionDetails?
    public let files: [CommitFile]
    public let options: RevisionDiffOptions
}
public enum RevisionComparisonFailure: LocalizedError {
    case range, selection
    public var errorDescription: String? {
        switch self { case .range: return "At least one comparison side must be a revision or the empty tree."; case .selection: return "Choose files from this comparison and repository." }
    }
}
extension GitRepository {
    /// Ordinary file Diff uses HEAD-to-working content, including staged edits.
    /// Explicit untracked selections use an empty base without staging them.
    public func workingFileComparison(paths: [String]) throws -> RevisionComparisonSnapshot {
        guard !paths.isEmpty else { throw RevisionComparisonFailure.selection }
        for path in paths { _ = try restoreLocation(path) }
        let head = try run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], successfulExitCodes: 0...1)
        let from: ComparisonRevision
        if head.exitCode == 0 { from = .revision(String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)) }
        else {
            let ref = try run(["symbolic-ref", "--quiet", "HEAD"]).text.trimmingCharacters(in: .newlines)
            guard try run(["show-ref", "--verify", "--quiet", ref], successfulExitCodes: 0...1).exitCode == 1 else { throw RevisionComparisonFailure.range }
            from = .emptyTree
        }
        let snapshot = try revisionComparison(from: from, to: .workingTree)
        var files = snapshot.files.filter { paths.contains($0.path) || $0.oldPath.map(paths.contains) == true }
        let changes = try status(refreshIndex: false)
        for path in Set(paths).sorted() where !files.contains(where: { $0.path == path }) {
            if changes.contains(where: { $0.path == path && $0.state == .untracked }) {
                files.append(CommitFile(path: path, oldPath: nil, action: "A", added: nil, removed: nil, hasStatistics: false, isSubmodule: false))
            }
        }
        return RevisionComparisonSnapshot(root: root, from: snapshot.from, to: snapshot.to, fromDetails: snapshot.fromDetails, toDetails: snapshot.toDetails, files: files, options: snapshot.options)
    }
    public func revisionComparison(from: ComparisonRevision, to: ComparisonRevision, options: RevisionDiffOptions = RevisionDiffOptions()) throws -> RevisionComparisonSnapshot {
        func resolve(_ side: ComparisonRevision) throws -> ComparisonRevision {
            if case .revision(let name) = side { return .revision(try run(["rev-parse", "--verify", "--end-of-options", name + "^{commit}"]).text.trimmingCharacters(in: .newlines)) }
            return side
        }
        var old = try resolve(from), new = try resolve(to)
        // Match FileDiffDlg: replace the base only when its IsFastForward
        // check succeeds; divergent or working-tree pairs keep the direct range.
        if options.commonAncestor, case .revision(let a) = old, case .revision(let b) = new,
           (try? run(["merge-base", "--is-ancestor", a, b])) != nil {
            old = .revision(try run(["merge-base", a, b]).text.trimmingCharacters(in: .newlines))
        }
        let args = try comparisonArguments(from: old, to: new, options: options)
        let files = CommitFile.parse(names: try run(args + ["--name-status", "-z", "--"]).stdout, statistics: try run(args + ["--numstat", "-z", "--"]).stdout, raw: try run(args + ["--raw", "-z", "--"]).stdout).filter { $0.hasStatistics || $0.isSubmodule }
        return RevisionComparisonSnapshot(root: root, from: old, to: new, fromDetails: try comparisonDetails(old), toDetails: try comparisonDetails(new), files: files, options: options)
    }
    public func revisionComparisonPatch(_ snapshot: RevisionComparisonSnapshot, paths: [String] = []) throws -> String {
        guard snapshot.root == root, paths.allSatisfy({ path in snapshot.files.contains { $0.path == path } }) else { throw RevisionComparisonFailure.selection }
        let selected = paths.isEmpty ? [] : snapshot.files.filter { paths.contains($0.path) }.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
        for path in selected { _ = try restoreLocation(path) }
        return try run(comparisonArguments(from: snapshot.from, to: snapshot.to, options: snapshot.options) + ["--"] + Set(selected).sorted()).text
    }
    private func comparisonDetails(_ side: ComparisonRevision) throws -> ComparisonRevisionDetails? {
        guard case .revision(let hash) = side else { return nil }
        let fields = try run(["show", "--no-patch", "--no-notes", "--format=%h%x00%s%x00%aN%x00%at%x00%ct", hash, "--"]).text.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
        guard fields.count == 5 else { throw RevisionComparisonFailure.range }
        return ComparisonRevisionDetails(shortHash: fields[0], subject: fields[1], author: fields[2], authorDate: TimeInterval(fields[3]).map(Date.init(timeIntervalSince1970:)), committerDate: TimeInterval(fields[4]).map(Date.init(timeIntervalSince1970:)))
    }
    private func comparisonArguments(from: ComparisonRevision, to: ComparisonRevision, options: RevisionDiffOptions) throws -> [String] {
        guard from != .workingTree || to != .workingTree else { throw RevisionComparisonFailure.range }
        func hash(_ side: ComparisonRevision) throws -> String {
            switch side { case .revision(let value): return value; case .emptyTree: return try run(["mktree"]).text.trimmingCharacters(in: .newlines); case .workingTree: throw RevisionComparisonFailure.range }
        }
        var args = ["diff", "--no-ext-diff", "--no-color", "-M"] + options.arguments
        if from == .workingTree { args += ["-R", try hash(to)] }
        else if to == .workingTree { args += [try hash(from)] }
        else { args += [try hash(from), try hash(to)] }
        return args
    }
}
