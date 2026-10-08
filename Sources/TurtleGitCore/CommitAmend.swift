import Foundation

extension GitRepository {
    public func commitComparisonBase(amendToParent: Bool) throws -> String {
        guard amendToParent else { return "HEAD" }
        _ = try run(["rev-parse", "--verify", "HEAD"])
        if let parent = try? run(["rev-parse", "--verify", "HEAD^1^{commit}"]).text {
            return parent.trimmingCharacters(in: .newlines)
        }
        // Compute the empty tree in the repository's object format (including SHA-256).
        return try run(["mktree"]).text.trimmingCharacters(in: .newlines)
    }

    public func commitDialogStatus(amendToParent: Bool) throws -> [StatusEntry] {
        let current = try status()
        guard amendToParent else { return current }
        let base = try commitComparisonBase(amendToParent: true)
        let indexed = try stagingFiles(staged: true, base: base)
        let indexedByPath = Dictionary(indexed.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        let currentByPath = Dictionary(current.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        var result = current.filter { $0.state == .untracked || $0.state == .ignored || $0.state == .conflicted }
        for file in try workingTreeFiles(amendToParent: true) {
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
        let paths = Set(result.map(\.path))
        for file in indexed where !paths.contains(file.path) {
            var entry = StatusEntry(path: file.path, originalPath: file.oldPath,
                                      index: file.action.first ?? "M",
                                      worktree: currentByPath[file.path]?.worktree ?? " ")
            entry.hasUnversionedCopy = currentByPath[file.path]?.hasUnversionedCopy ?? false
            result.append(entry)
        }
        return Dictionary(result.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last }).values.sorted { $0.path < $1.path }
    }

    public func unstageCommitPaths(_ paths: [String], amendToParent: Bool) throws {
        guard amendToParent else { try unstage(paths); return }
        guard !paths.isEmpty else { return }
        let base = try commitComparisonBase(amendToParent: true)
        _ = try run(["restore", "--source=" + base, "--staged", "--"] + paths)
    }

    func commitParentSelection(message: String, checked: [StatusEntry], options: CommitOptions, cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        let base = try commitComparisonBase(amendToParent: true)
        return try commitSeparateSelection(message: message, checked: checked, options: options, base: base, fileModes: selectedStagedFileModes(checked), cancellation: cancellation)
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-selection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["GIT_INDEX_FILE": directory.appendingPathComponent("index").path]
        _ = try populateCommitSelectionIndex(checked: checked, base: base, fileModes: fileModes, environment: environment)
        let tree = try run(["write-tree"], environmentOverrides: environment).text
        return tree == (try run(["rev-parse", base + "^{tree}"]).text)
    }
    func commitSeparateSelection(message: String, checked: [StatusEntry], options: CommitOptions, base: String, fileModes: [String: String] = [:], preservedAuthorDate: String? = nil, cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        let messageFile = try makeCommitMessageFile(message); defer { messageFile.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-amend-" + UUID().uuidString)
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
        return try run(args, environmentOverrides: environment, cancellation: cancellation).text
    }
}
