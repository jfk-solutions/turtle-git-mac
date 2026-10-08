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

public enum CommitOperation: String, Sendable {
    case merge, cherryPick, revert
    public var title: String {
        switch self {
        case .merge: return "You are about to commit a merge."
        case .cherryPick: return "You are about to commit a cherry-pick."
        case .revert: return "You are about to commit a revert."
        }
    }
}

extension GitRepository {
    public func commitOperation() throws -> CommitOperation? {
        for (name, operation) in [("MERGE_HEAD", CommitOperation.merge), ("CHERRY_PICK_HEAD", .cherryPick), ("REVERT_HEAD", .revert)] {
            let path = try run(["rev-parse", "--git-path", name]).text.trimmingCharacters(in: .newlines)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { return operation }
        }
        return nil
    }
    /// TortoiseGit's default checkbox mode commits the current whole-file contents
    /// of checked paths. HEAD-based commits use --only; parent-based amendments
    /// use a separate index so unrelated staged changes remain intact.
    public func commitSelected(message: String, paths: Set<String>, options: CommitOptions = CommitOptions(), cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        func failure(_ message: String) -> GitFailure { GitFailure(arguments: ["commit"], code: 1, message: message) }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("Enter a commit message.") }
        let operation = try commitOperation()
        if operation != nil, options.amend || options.newBranch != nil {
            throw failure("Finish the pending operation before amending or creating a new branch.")
        }
        let paths = options.messageOnly ? Set<String>() : paths
        guard !paths.isEmpty || options.amend || options.messageOnly || operation == .merge else { throw failure("Check at least one file to commit.") }
        let parentMode = options.amend && !options.amendDiffToLastCommit
        let changes = try commitDialogStatus(amendToParent: parentMode)
        guard !changes.contains(where: { $0.state == .conflicted }) else { throw failure("Resolve the conflicted files before committing.") }
        let checked = changes.filter { paths.contains($0.path) }
        guard checked.count == paths.count, checked.allSatisfy({ $0.state != .ignored }) else {
            throw failure("The checked files have changed since the dialog was loaded. Refresh the file list before committing.")
        }
        if operation != nil {
            // A normal commit against a selected temporary index preserves the
            // operation's parents/author/state. --only is forbidden by Git for
            // merges and cherry-picks. The real index retains unchecked entries.
            return try commitSeparateSelection(message: message, checked: checked, options: options, base: "HEAD", fileModes: selectedStagedFileModes(checked), cancellation: cancellation)
        }
        if options.amend { _ = try run(["rev-parse", "--verify", "HEAD"]) }
        if parentMode { return try commitParentSelection(message: message, checked: checked, options: options, cancellation: cancellation) }
        let modes = try selectedStagedFileModes(checked)
        if !modes.isEmpty {
            let base = try (try? run(["rev-parse", "--verify", "HEAD^{commit}"]).text.trimmingCharacters(in: .newlines))
                ?? (try run(["mktree"]).text.trimmingCharacters(in: .newlines))
            return try commitSeparateSelection(message: message, checked: checked, options: options, base: base, fileModes: modes, cancellation: cancellation)
        }
        if checked.contains(where: { $0.index == "D" && $0.hasUnversionedCopy }) {
            // --only would read the retained working copy and silently re-add it.
            // Build the selected tree separately while leaving that copy on disk.
            return try commitSeparateSelection(message: message, checked: checked, options: options, base: "HEAD", cancellation: cancellation)
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
        let messageFile = try makeCommitMessageFile(message); defer { messageFile.remove() }
        try prepareCommitBranch(options.newBranch, cancellation: cancellation)
        try stage(stagePaths, cancellation: cancellation)
        var args = ["commit", "--only", "-F", messageFile.url.path]
        if options.amend { args.append("--amend") }
        if options.messageOnly { args.append("--allow-empty") }
        if options.resetAuthorDate { args.append("--date=now") }
        else if let date = options.authorDate { args.append("--date=" + ISO8601DateFormatter().string(from: date)) }
        if options.signOff { args.append("--signoff") }
        if let author = options.author, !author.isEmpty { args.append("--author=" + author) }
        if commitPaths.isEmpty { return try run(args, cancellation: cancellation).text }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-commit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data(Set(commitPaths).sorted().flatMap { Array($0.utf8) + [0] })
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw failure("Could not prepare the checked file list.")
        }
        args += ["--pathspec-from-file=" + file.path, "--pathspec-file-nul"]
        return try run(args, cancellation: cancellation).text
    }

    /// Preserve staged modes that differ from disk. Ordinary matching entries
    /// can keep using --only without additional per-file Git processes.
    func selectedStagedFileModes(_ checked: [StatusEntry]) throws -> [String: String] {
        let paths = checked.filter { $0.index != " " && $0.index != "D" && $0.state != .deleted }.map(\.path)
        var result: [String: String] = [:]
        for offset in stride(from: 0, to: paths.count, by: 64) {
            let batch = Array(paths[offset..<min(offset + 64, paths.count)])
            for record in try run(["ls-files", "--stage", "-z", "--"] + batch).stdout.split(separator: 0) {
                guard let tab = record.firstIndex(of: 9) else { continue }
                let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                guard fields.count == 3, fields[2] == "0", ["100644", "100755", "120000"].contains(String(fields[0])) else { continue }
                let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
                let attributes = try FileManager.default.attributesOfItem(atPath: restoreLocation(path).path)
                let diskMode: String
                switch attributes[.type] as? FileAttributeType {
                case .typeSymbolicLink: diskMode = "120000"
                case .typeRegular:
                    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                    // Git's executable mode is determined by the owner bit.
                    diskMode = permissions & 0o100 == 0 ? "100644" : "100755"
                default: continue
                }
                if fields[0] != diskMode { result[path] = String(fields[0]) }
            }
        }
        return result
    }
    func applySelectedFileModes(_ modes: [String: String], environment: [String: String] = [:], cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        for path in modes.keys.sorted() {
            let records = try run(["ls-files", "--stage", "-z", "--", path], environmentOverrides: environment).stdout.split(separator: 0)
            guard records.count == 1, let record = records.first, let tab = record.firstIndex(of: 9) else {
                throw GitFailure(arguments: ["commit"], code: 1, message: "Could not preserve the staged file mode for " + path)
            }
            let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            guard fields.count == 3, fields[2] == "0" else { throw GitFailure(arguments: ["commit"], code: 1, message: "The selected file has unresolved index entries: " + path) }
            _ = try run(["update-index", "--cacheinfo", modes[path]!, String(fields[1]), path], environmentOverrides: environment, cancellation: cancellation)
        }
    }

    /// Staging mode commits the index exactly as it is, including partial files.
    public func commitIndex(message: String, options: CommitOptions = CommitOptions(), cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitFailure(arguments: ["commit"], code: 1, message: "Enter a commit message.")
        }
        if try commitOperation() != nil, options.amend || options.newBranch != nil {
            throw GitFailure(arguments: ["commit"], code: 1, message: "Finish the pending operation before amending or creating a new branch.")
        }
        let messageFile = try makeCommitMessageFile(message); defer { messageFile.remove() }
        try prepareCommitBranch(options.newBranch, cancellation: cancellation)
        var args = ["commit", "-F", messageFile.url.path]
        if options.amend { args.append("--amend") }
        if options.messageOnly { args.append("--allow-empty") }
        if options.resetAuthorDate { args.append("--date=now") }
        else if let date = options.authorDate { args.append("--date=" + ISO8601DateFormatter().string(from: date)) }
        if options.signOff { args.append("--signoff") }
        if let author = options.author, !author.isEmpty { args.append("--author=" + author) }
        return try run(args, cancellation: cancellation).text
    }
    func prepareCommitBranch(_ name: String?, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard let name else { return }
        guard !name.isEmpty, !name.contains("\0"), !name.hasPrefix("-") else { throw GitFailure(arguments: ["branch"], code: 1, message: "Enter a valid new branch name.") }
        _ = try run(["check-ref-format", "refs/heads/" + name], cancellation: cancellation)
        _ = try run(["checkout", "-b", name], cancellation: cancellation)
    }
    public func submodulePaths(cancellation: OperationCancellation? = nil) throws -> Set<String> {
        Set(try run(["ls-files", "--stage", "-z"], cancellation: cancellation).stdout.split(separator: 0).compactMap { record in
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

public struct CommitDirtySubmodule: Sendable {
    public let path: String
    public let checkout: URL
}

extension GitRepository {
    /// CommitDlg warns only for checked directories. Tracked gitlinks use the
    /// working/index diff's -dirty marker; newly added nested repos use status.
    /// This read does not stage either repository or initialize missing children.
    public func commitDirtySubmodules(paths: [String]) throws -> [CommitDirtySubmodule] {
        var result: [CommitDirtySubmodule] = [], seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            let location = try restoreLocation(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  (try FileManager.default.attributesOfItem(atPath: location.path))[.type] as? FileAttributeType == .typeDirectory,
                  FileManager.default.fileExists(atPath: location.appendingPathComponent(".git").path) else { continue }
            let discovered = try run(["-C", location.path, "rev-parse", "--show-toplevel"], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"]).stdout
            var bytes = discovered
            if bytes.last == 10 { bytes.removeLast() }
            guard URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath().standardizedFileURL == location.resolvingSymlinksInPath().standardizedFileURL else { throw SubmoduleComparisonFailure.unsafeCheckout }
            let tracked = try !run(["ls-files", "--stage", "-z", "--", path], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"]).stdout.isEmpty
            let dirty: Bool
            if tracked {
                dirty = try run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--", path], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"]).text.hasSuffix("-dirty\n")
            } else {
                dirty = try !run(["-C", location.path, "status", "--porcelain=v1", "-z"], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"]).stdout.isEmpty
            }
            if dirty { result.append(CommitDirtySubmodule(path: path, checkout: location)) }
        }
        return result
    }
}
