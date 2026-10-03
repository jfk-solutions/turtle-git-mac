import Foundation

public struct CommitOptions: Sendable {
    public var amend = false
    public var signOff = false
    public var author: String?
    public init() {}
}

extension GitRepository {
    /// TortoiseGit's default checkbox mode commits the current whole-file contents
    /// of checked paths. Git --only preserves unrelated staged changes in the index.
    public func commitSelected(message: String, paths: Set<String>, options: CommitOptions = CommitOptions()) throws -> String {
        func failure(_ message: String) -> GitFailure { GitFailure(arguments: ["commit"], code: 1, message: message) }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("Enter a commit message.") }
        guard !paths.isEmpty || options.amend else { throw failure("Check at least one file to commit.") }
        let changes = try status()
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
        let tracked = Set(try trackedPaths())
        var stagePaths = checked.filter { $0.state != .deleted || tracked.contains($0.path) }.map(\.path)
        var commitPaths = checked.map(\.path)
        for entry in checked {
            if let source = entry.originalPath, entry.index == "R" || entry.worktree == "R" {
                commitPaths.append(source)
                if tracked.contains(source) { stagePaths.append(source) }
            }
        }
        try stage(stagePaths)
        var args = ["commit", "--only", "-m", message]
        if options.amend { args.append("--amend") }
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
        var args = ["commit", "-m", message]
        if options.amend { args.append("--amend") }
        if options.signOff { args.append("--signoff") }
        if let author = options.author, !author.isEmpty { args.append("--author=" + author) }
        return try run(args).text
    }
    public func stagingFiles(staged: Bool) throws -> [CommitFile] {
        let args = ["diff", "--no-ext-diff", "--no-color", "-M"] + (staged ? ["--cached"] : [])
        return CommitFile.parse(names: try run(args + ["--name-status", "-z", "--"]).stdout,
                                statistics: try run(args + ["--numstat", "-z", "--"]).stdout)
    }

    public func workingTreeFiles() throws -> [CommitFile] {
        let head = (try? run(["rev-parse", "--verify", "HEAD"])) != nil
        let base = head ? ["HEAD"] : ["--cached"]
        let args = ["diff", "--no-ext-diff", "--no-color", "-M"] + base
        return CommitFile.parse(names: try run(args + ["--name-status", "-z", "--"]).stdout,
                                statistics: try run(args + ["--numstat", "-z", "--"]).stdout)
    }
}
