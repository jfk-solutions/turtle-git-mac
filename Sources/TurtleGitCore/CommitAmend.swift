import Foundation

public enum CommitStagingState: Sendable, Equatable {
    case unstaged, partial, staged
}

extension GitRepository {
    public func commitComparisonBase(amendToParent: Bool, cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        guard amendToParent else { return "HEAD" }
        _ = try run(["rev-parse", "--verify", "HEAD"], cancellation: cancellation)
        if let parent = try? run(["rev-parse", "--verify", "HEAD^1^{commit}"], cancellation: cancellation).text {
            return parent.trimmingCharacters(in: .newlines)
        }
        // Compute the empty tree in the repository's object format (including SHA-256).
        return try run(["mktree"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
    }

    public func commitDialogStatus(amendToParent: Bool, cancellation: OperationCancellation? = nil) throws -> [StatusEntry] {
        try cancellation?.check()
        let current = try status(cancellation: cancellation)
        guard amendToParent else { return current }
        let base = try commitComparisonBase(amendToParent: true, cancellation: cancellation)
        let indexed = try stagingFiles(staged: true, base: base, cancellation: cancellation)
        let indexedByPath = GitPathMap(indexed.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        let currentByPath = GitPathMap(current.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        var result = current.filter { $0.state == .untracked || $0.state == .ignored || $0.state == .conflicted }
        for file in try workingTreeFiles(amendToParent: true, cancellation: cancellation) {
            if currentByPath[file.path]?.state == .conflicted { continue }
            let staged = indexedByPath[file.path]
            let old = staged?.oldPath ?? file.oldPath
            var entry = StatusEntry(path: file.path, originalPath: old,
                                      index: staged?.action.first ?? " ",
                                      worktree: currentByPath[file.path]?.worktree ?? " ")
            entry.hasUnversionedCopy = currentByPath[file.path]?.hasUnversionedCopy ?? false
            result.append(entry)
        }
        // Include an index-only change cancelled out by the working tree, so the
        // staging checkbox can still unstage or retain it.
        let paths = Set(result.map { GitReferenceName($0.path) })
        for file in indexed where !paths.contains(GitReferenceName(file.path)) {
            var entry = StatusEntry(path: file.path, originalPath: file.oldPath,
                                      index: file.action.first ?? "M",
                                      worktree: currentByPath[file.path]?.worktree ?? " ")
            entry.hasUnversionedCopy = currentByPath[file.path]?.hasUnversionedCopy ?? false
            result.append(entry)
        }
        return GitPathMap(result.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last }).values.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    /// Read the index independently of rename pairing. Git may choose a
    /// different identical source after staging a deletion; retained Commit rows
    /// must still show that original deletion as staged.
    public func commitStagingStates(for entries: [StatusEntry], base: String? = nil, cancellation: OperationCancellation? = nil) throws -> [String: CommitStagingState] {
        try cancellation?.check()
        let cached = try run(["diff", "--cached", "--no-renames", "--name-only", "-z"] + (base.map { [$0] } ?? []) + ["--"], cancellation: cancellation)
        let working = try run(["diff", "--no-renames", "--name-only", "-z", "--"], cancellation: cancellation)
        func paths(_ bytes: Data) -> Set<Data> { Set(bytes.split(separator: 0).map { Data($0) }) }
        let stagedPaths = paths(cached.stdout), workingPaths = paths(working.stdout)
        let unversioned = Set(try status(cancellation: cancellation).filter { $0.state == .untracked }.map { Data($0.path.utf8) })
        try cancellation?.check()
        return Dictionary(entries.map { entry in
            var targets = [Data(entry.path.utf8)]
            if (entry.index == "R" || entry.worktree == "R"), let old = entry.originalPath { targets.append(Data(old.utf8)) }
            let staged = targets.contains { stagedPaths.contains($0) }
            let unstaged = targets.contains { workingPaths.contains($0) || unversioned.contains($0) }
            return (entry.path, staged ? (unstaged ? CommitStagingState.partial : .staged) : .unstaged)
        }, uniquingKeysWith: { _, new in new })
    }

    /// Whole-file Commit checkboxes operate on both sides of a retained rename.
    /// Copies retain their source in the index; staging a copy must not stage
    /// unrelated changes in that source file.
    public func setCommitFilesStaged(_ entries: [StatusEntry], staged: Bool, amendToParent: Bool = false, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        var paths: [String] = []
        for entry in entries where entry.state != .conflicted {
            paths.append(entry.path)
            if (entry.index == "R" || entry.worktree == "R"), let old = entry.originalPath { paths.append(old) }
        }
        if staged { try stage(paths, cancellation: cancellation) }
        else { try unstageCommitPaths(paths, amendToParent: amendToParent, cancellation: cancellation) }
    }

    public func unstageCommitPaths(_ paths: [String], amendToParent: Bool, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard amendToParent else { try unstage(paths, cancellation: cancellation); return }
        guard !paths.isEmpty else { return }
        let base = try commitComparisonBase(amendToParent: true, cancellation: cancellation)
        _ = try run(["restore", "--source=" + base, "--staged", "--"] + paths, cancellation: cancellation)
    }

    func commitParentSelection(message: String, checked: [StatusEntry], options: CommitOptions, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try cancellation?.check()
        let base = try commitComparisonBase(amendToParent: true)
        return try commitSeparateSelection(message: message, checked: checked, options: options, base: base, fileModes: selectedStagedFileModes(checked), cancellation: cancellation, onOutput: onOutput)
    }
    private func populateCommitSelectionIndex(checked: [StatusEntry], base: String, fileModes: [String: String], environment: [String: String], cancellation: OperationCancellation? = nil) throws -> [String] {
        try cancellation?.check()
        let tracked = Set(try trackedPaths())
        let retainedDeletes = Set(checked.filter { $0.index == "D" && $0.hasUnversionedCopy }.map(\.path))
        var paths = checked.filter { !retainedDeletes.contains($0.path) }.map(\.path)
        var realStage = checked.filter { !retainedDeletes.contains($0.path) && ($0.state != .deleted || tracked.contains($0.path) || FileManager.default.fileExists(atPath: root.appendingPathComponent($0.path).path)) }.map(\.path)
        for entry in checked {
            if let old = entry.originalPath, entry.index == "R" || entry.worktree == "R" {
                paths.append(old)
                if tracked.contains(old) { realStage.append(old) }
            }
        }
        _ = try run(["read-tree", base], environmentOverrides: environment, cancellation: cancellation)
        if !paths.isEmpty {
            _ = try run(["add", "--all", "--"] + Array(Set(paths)).sorted(), environmentOverrides: environment, cancellation: cancellation)
        }
        if !retainedDeletes.isEmpty {
            _ = try run(["update-index", "--force-remove", "--"] + retainedDeletes.sorted(), environmentOverrides: environment, cancellation: cancellation)
        }
        try applySelectedFileModes(fileModes, environment: environment, cancellation: cancellation)
        return realStage
    }
    func commitSelectionIsEmpty(checked: [StatusEntry], base: String, fileModes: [String: String]) throws -> Bool {
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-selection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["GIT_INDEX_FILE": directory.appendingPathComponent("index").path]
        _ = try populateCommitSelectionIndex(checked: checked, base: base, fileModes: fileModes, environment: environment)
        let tree = try run(["write-tree"], environmentOverrides: environment).text
        return tree == (try run(["rev-parse", base + "^{tree}"]).text)
    }
    func commitSeparateSelection(message: String, checked: [StatusEntry], options: CommitOptions, base: String, fileModes: [String: String] = [:], preservedAuthorDate: String? = nil, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try cancellation?.check()
        let messageFile = try makeCommitMessageFile(message); defer { messageFile.remove() }
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-amend-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = ["GIT_INDEX_FILE": directory.appendingPathComponent("index").path]
        if let preservedAuthorDate { environment["GIT_AUTHOR_DATE"] = preservedAuthorDate }
        let realStage = try populateCommitSelectionIndex(checked: checked, base: base, fileModes: fileModes, environment: environment, cancellation: cancellation)
        try prepareCommitBranch(options.newBranch, cancellation: cancellation)
        try stage(realStage, cancellation: cancellation)
        try applySelectedFileModes(fileModes, cancellation: cancellation)
        var args = ["commit", "-F", messageFile.url.path]
        if options.amend { args.append("--amend") }
        if options.messageOnly { args.append("--allow-empty") }
        if options.signOff { args.append("--signoff") }
        if let author = options.author, !author.isEmpty { args.append("--author=" + author) }
        if options.resetAuthorDate { args.append("--date=now") }
        else if let date = options.authorDate { args.append("--date=" + ISO8601DateFormatter().string(from: date)) }
        return try run(args, environmentOverrides: environment, cancellation: cancellation, onOutput: onOutput).text
    }
}
