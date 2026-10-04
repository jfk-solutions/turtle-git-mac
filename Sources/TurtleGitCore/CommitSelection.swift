import Foundation

public struct CommitOptions: Sendable {
    public var amend = false
    public var amendDiffToLastCommit = true
    public var signOff = false
    public var author: String?
    public var authorDate: Date?
    public var resetAuthorDate = false
    public var messageOnly = false
    public var newBranch: String?
    public init() {}
}

extension GitRepository {
    /// TortoiseGit's default checkbox mode commits the current whole-file contents
    /// of checked paths. HEAD-based commits use --only; parent-based amendments
    /// use a separate index so unrelated staged changes remain intact.
    public func commitSelected(message: String, paths: Set<String>, options: CommitOptions = CommitOptions()) throws -> String {
        func failure(_ message: String) -> GitFailure { GitFailure(arguments: ["commit"], code: 1, message: message) }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("Enter a commit message.") }
        let paths = options.messageOnly ? Set<String>() : paths
        guard !paths.isEmpty || options.amend || options.messageOnly else { throw failure("Check at least one file to commit.") }
        let parentMode = options.amend && !options.amendDiffToLastCommit
        let changes = try commitDialogStatus(amendToParent: parentMode)
        guard !changes.contains(where: { $0.state == .conflicted }) else { throw failure("Resolve the conflicted files before committing.") }
        let checked = changes.filter { paths.contains($0.path) }
        guard checked.count == paths.count, checked.allSatisfy({ $0.state != .ignored }) else {
            throw failure("The checked files have changed since the dialog was loaded. Refresh the file list before committing.")
        }
        let mergePath = try run(["rev-parse", "--git-path", "MERGE_HEAD"]).text.trimmingCharacters(in: .newlines)
        let mergeURL = mergePath.hasPrefix("/") ? URL(fileURLWithPath: mergePath) : root.appendingPathComponent(mergePath)
        guard !FileManager.default.fileExists(atPath: mergeURL.path) else {
            throw failure("A merge is in progress. Committing a merge requires the complete resolved index; the checked-file commit dialog does not support that yet.")
        }
        if options.amend { _ = try run(["rev-parse", "--verify", "HEAD"]) }
        if parentMode { return try commitParentSelection(message: message, checked: checked, options: options) }
        if checked.contains(where: { $0.index == "D" && $0.hasUnversionedCopy }) {
            // --only would read the retained working copy and silently re-add it.
            // Build the selected tree separately while leaving that copy on disk.
            return try commitSeparateSelection(message: message, checked: checked, options: options, base: "HEAD")
        }
        let tracked = Set(try trackedPaths())
        var stagePaths = checked.filter { $0.state != .deleted || tracked.contains($0.path) }.map(\.path)
        var commitPaths = checked.map(\.path)
        for entry in checked {
            if let source = entry.originalPath, entry.index == "R" || entry.worktree == "R" {
                commitPaths.append(source)
                if tracked.contains(source) { stagePaths.append(source) }
            }
        }
        try prepareCommitBranch(options.newBranch)
        try stage(stagePaths)
        var args = ["commit", "--only", "-m", message]
        if options.amend { args.append("--amend") }
        if options.messageOnly { args.append("--allow-empty") }
        if options.resetAuthorDate { args.append("--date=now") }
        else if let date = options.authorDate { args.append("--date=" + ISO8601DateFormatter().string(from: date)) }
        if options.signOff { args.append("--signoff") }
        if let author = options.author, !author.isEmpty { args.append("--author=" + author) }
        if commitPaths.isEmpty { return try run(args).text }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-commit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data(Set(commitPaths).sorted().flatMap { Array($0.utf8) + [0] })
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw failure("Could not prepare the checked file list.")
        }
        args += ["--pathspec-from-file=" + file.path, "--pathspec-file-nul"]
        return try run(args).text
    }

    /// Staging mode commits the index exactly as it is, including partial files.
    public func commitIndex(message: String, options: CommitOptions = CommitOptions()) throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitFailure(arguments: ["commit"], code: 1, message: "Enter a commit message.")
        }
        try prepareCommitBranch(options.newBranch)
        var args = ["commit", "-m", message]
        if options.amend { args.append("--amend") }
        if options.messageOnly { args.append("--allow-empty") }
        if options.resetAuthorDate { args.append("--date=now") }
        else if let date = options.authorDate { args.append("--date=" + ISO8601DateFormatter().string(from: date)) }
        if options.signOff { args.append("--signoff") }
        if let author = options.author, !author.isEmpty { args.append("--author=" + author) }
        return try run(args).text
    }
    func prepareCommitBranch(_ name: String?) throws {
        guard let name else { return }
        guard !name.isEmpty, !name.contains("\0"), !name.hasPrefix("-") else { throw GitFailure(arguments: ["branch"], code: 1, message: "Enter a valid new branch name.") }
        _ = try run(["check-ref-format", "refs/heads/" + name])
        _ = try run(["checkout", "-b", name])
    }
    public func submodulePaths() throws -> Set<String> {
        Set(try run(["ls-files", "--stage", "-z"]).stdout.split(separator: 0).compactMap { record in
            let fields = record.split(separator: 9, maxSplits: 1)
            guard fields.count == 2, fields[0].starts(with: Array("160000 ".utf8)) else { return nil }
            return String(decoding: fields[1], as: UTF8.self)
        })
    }
    public func stagingFiles(staged: Bool, base: String? = nil) throws -> [CommitFile] {
        let args = ["diff", "--no-ext-diff", "--no-color", "-M"] + (staged ? ["--cached"] + (base.map { [$0] } ?? []) : [])
        return CommitFile.parse(names: try run(args + ["--name-status", "-z", "--"]).stdout,
                                statistics: try run(args + ["--numstat", "-z", "--"]).stdout)
    }

    public func workingTreeFiles(amendToParent: Bool = false) throws -> [CommitFile] {
        let head = (try? run(["rev-parse", "--verify", "HEAD"])) != nil
        let base = amendToParent ? [try commitComparisonBase(amendToParent: true)] : head ? ["HEAD"] : ["--cached"]
        let args = ["diff", "--no-ext-diff", "--no-color", "-M"] + base
        return CommitFile.parse(names: try run(args + ["--name-status", "-z", "--"]).stdout,
                                statistics: try run(args + ["--numstat", "-z", "--"]).stdout)
    }
}
