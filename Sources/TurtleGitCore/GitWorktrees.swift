import Foundation

/// A record from `git worktree list --porcelain -z`. The main repository is first,
/// including when the command is run from a linked checkout or a bare repository.
public struct GitWorktree: Equatable, Sendable, Identifiable {
    public var path: URL
    public var head: String?
    public var branch: String?
    public var isBare = false
    public var isDetached = false
    public var isMain = false
    /// nil means unlocked; an empty string means locked without a reason.
    public var lockReason: String?
    public var pruneReason: String?
    // Foundation can change /var to /private/var when a checkout disappears.
    // Keep Git's registered path as row identity across that filesystem change.
    private var registeredPath: String?
    public var id: String { registeredPath ?? path.path }

    public static func parse(_ data: Data) -> [GitWorktree] {
        var records: [GitWorktree] = []
        var current: GitWorktree?
        for bytes in data.split(separator: 0, omittingEmptySubsequences: false) {
            let field = String(decoding: bytes, as: UTF8.self)
            if field.isEmpty {
                if let current { records.append(current) }
                current = nil
                continue
            }
            let parts = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let value = parts.count == 2 ? String(parts[1]) : ""
            if key == "worktree" {
                if let current { records.append(current) }
                current = GitWorktree(path: URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL)
                current?.registeredPath = value
            } else {
                switch key {
                case "HEAD": current?.head = value
                case "branch": current?.branch = value
                case "bare": current?.isBare = true
                case "detached": current?.isDetached = true
                case "locked": current?.lockReason = value
                case "prunable": current?.pruneReason = value
                default: break // Git may add attributes to this stable format.
                }
            }
        }
        if let current { records.append(current) }
        if !records.isEmpty { records[0].isMain = true }
        return records
    }
}

public struct WorktreeCreationOptions: Sendable {
    public var checkout = true
    public var force = false
    public var detach = false
    public var newBranch: String?
    public var revision = "HEAD"
    public init() {}
}

public enum WorktreeFailure: LocalizedError {
    case invalidPath, invalidBranch, invalidRevision, conflictingOptions, notLinkedWorktree
    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "Choose a worktree directory."
        case .invalidBranch: return "Enter a valid new branch name."
        case .invalidRevision: return "Choose an existing revision."
        case .conflictingOptions: return "Detach and Create New Branch cannot be enabled together."
        case .notLinkedWorktree: return "Choose a linked worktree belonging to this repository. The main repository cannot be locked or removed."
        }
    }
}

extension GitRepository {
    public func worktrees() throws -> [GitWorktree] {
        GitWorktree.parse(try run(["worktree", "list", "--porcelain", "-z"]).stdout)
    }

    /// Matches CreateWorktreeDlg / CAppUtils::CreateWorktree: Force is --force,
    /// never -B; HEAD is omitted so Git uses its directory-name branch behavior.
    public func createWorktree(at path: URL, options: WorktreeCreationOptions = .init(), cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        guard path.isFileURL, !path.path.isEmpty, !path.path.contains("\0") else { throw WorktreeFailure.invalidPath }
        guard !(options.detach && options.newBranch != nil) else { throw WorktreeFailure.conflictingOptions }
        if let name = options.newBranch {
            guard !name.isEmpty else { throw WorktreeFailure.invalidBranch }
            do {
                _ = try run(["check-ref-format", "refs/heads/" + name])
                _ = try run(["check-ref-format", "--branch", name])
            } catch { throw WorktreeFailure.invalidBranch }
        }
        guard !options.revision.isEmpty, !options.revision.contains("\0") else { throw WorktreeFailure.invalidRevision }
        if options.revision != "HEAD" {
            do { _ = try run(["rev-parse", "--verify", "--end-of-options", options.revision + "^{commit}"]) }
            catch { throw WorktreeFailure.invalidRevision }
        }
        var args = ["worktree", "add"]
        if !options.checkout { args.append("--no-checkout") }
        if options.force { args.append("--force") }
        if options.detach { args.append("--detach") }
        if let name = options.newBranch { args += ["-b", name] }
        args += ["--", path.standardizedFileURL.path]
        if options.revision != "HEAD" { args.append(options.revision) }
        return try run(args, cancellation: cancellation).text
    }

    private func linkedWorktreePath(_ path: URL) throws -> String {
        let normalized = canonicalWorktreePath(path)
        guard path.isFileURL, let record = try worktrees().first(where: {
            canonicalWorktreePath($0.path).path == normalized.path
        }), !record.isMain else { throw WorktreeFailure.notLinkedWorktree }
        return record.path.path
    }

    /// Resolve the existing ancestor too: Foundation leaves /var aliases intact
    /// for a missing checkout, while Git reports its /private/var spelling.
    private func canonicalWorktreePath(_ path: URL) -> URL {
        var ancestor = path.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in suffix.reversed() { resolved.appendPathComponent(component, isDirectory: true) }
        return resolved.standardizedFileURL
    }

    public func lockWorktree(at path: URL, reason: String? = nil, cancellation: OperationCancellation? = nil) throws -> String {
        let registered = try linkedWorktreePath(path)
        var args = ["worktree", "lock"]
        if let reason { args += ["--reason", reason] }
        return try run(args + ["--", registered], cancellation: cancellation).text
    }

    public func unlockWorktree(at path: URL, cancellation: OperationCancellation? = nil) throws -> String {
        try run(["worktree", "unlock", "--", linkedWorktreePath(path)], cancellation: cancellation).text
    }

    public func removeWorktree(at path: URL, force: Bool = false, cancellation: OperationCancellation? = nil) throws -> String {
        let registered = try linkedWorktreePath(path)
        return try run(["worktree", "remove"] + (force ? ["--force"] : []) + ["--", registered], cancellation: cancellation).text
    }

    public func pruneWorktrees(cancellation: OperationCancellation? = nil) throws -> String {
        // Use exactly Git's default prune command, as TortoiseGit does.
        try run(["worktree", "prune"], cancellation: cancellation).text
    }
}
