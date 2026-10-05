import Foundation
import Security

public enum FinderIntegration {
    public static let group = "group.org.turtlegit.macos"
    public static let notification = "org.turtlegit.macos.statusChanged"
    public static var container: URL? {
        // Unsigned development builds cannot access the signed app's shared cache.
        // Merely constructing a group-container path can otherwise trigger protected
        // data access and stall startup on recent macOS versions.
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
              groups.contains(group) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
    public static var snapshotURL: URL? { container?.appendingPathComponent("status.json") }
}
public struct FinderSnapshot: Codable, Sendable {
    public var roots: [String]
    public var states: [String: FileState]
    public var updated: Date
    public init(roots: [String], states: [String: FileState], updated: Date = Date()) {
        self.roots = roots; self.states = states; self.updated = updated
    }
    @discardableResult public func write() throws -> Bool {
        guard let url = FinderIntegration.snapshotURL else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        return true
    }
    public static func read() -> FinderSnapshot? {
        guard let url = FinderIntegration.snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public static func build(root: URL, tracked: [String], changes: [StatusEntry]) -> FinderSnapshot {
        var states: [String: FileState] = [:]
        for path in tracked { states[root.appendingPathComponent(path).path] = .normal }
        let priority: [FileState: Int] = [.normal: 0, .ignored: 1, .untracked: 2, .added: 3, .deleted: 4, .modified: 5, .conflicted: 6]
        for change in changes { states[root.appendingPathComponent(change.path).path] = change.state }
        let files = states
        for (path, state) in files {
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            while parent.path == root.path || parent.path.hasPrefix(root.path + "/") {
                if priority[state, default: 0] >= priority[states[parent.path] ?? .normal, default: 0] { states[parent.path] = state }
                if parent.path == root.path { break }
                parent.deleteLastPathComponent()
            }
        }
        states[root.path] = states[root.path] ?? .normal
        return FinderSnapshot(roots: [root.path], states: states)
    }
    /// Cached eligibility only. The containing app revalidates tracked paths and
    /// the working tree before Git mutates anything.
    public func canRename(_ selection: [URL]) -> Bool {
        guard selection.count == 1, let path = selection.first?.standardizedFileURL.path,
              roots.contains(where: { path.hasPrefix($0 + "/") }) else { return false }
        let versioned: Set<FileState> = [.normal, .modified, .added, .conflicted]
        if let state = states[path], versioned.contains(state) { return true }
        return states.contains { $0.key.hasPrefix(path + "/") && versioned.contains($0.value) }
    }
    public func canRemove(_ selection: [URL]) -> Bool {
        guard !selection.isEmpty else { return false }
        let paths = selection.map { $0.standardizedFileURL.path }
        guard roots.contains(where: { root in paths.allSatisfy { $0.hasPrefix(root + "/") } }) else { return false }
        let versioned: Set<FileState> = [.normal, .modified, .conflicted]
        return paths.allSatisfy { path in
            if let state = states[path], versioned.contains(state) { return true }
            return states.contains { $0.key.hasPrefix(path + "/") && versioned.contains($0.value) }
        }
    }
    public func canRevert(_ selection: [URL]) -> Bool {
        guard !selection.isEmpty else { return false }
        let paths = selection.map { $0.standardizedFileURL.path }
        guard roots.contains(where: { root in paths.allSatisfy { $0 == root || $0.hasPrefix(root + "/") } }) else { return false }
        let changes: Set<FileState> = [.modified, .added, .deleted, .conflicted]
        return paths.allSatisfy { path in
            changes.contains(states[path] ?? .normal) || states.contains { $0.key.hasPrefix(path + "/") && changes.contains($0.value) }
        }
    }
    public func canResolve(_ selection: [URL]) -> Bool {
        guard !selection.isEmpty else { return false }
        let paths = selection.map { $0.standardizedFileURL.path }
        guard roots.contains(where: { root in paths.allSatisfy { $0 == root || $0.hasPrefix(root + "/") } }) else { return false }
        return paths.contains { path in states.contains { $0.value == .conflicted && ($0.key == path || $0.key.hasPrefix(path + "/")) } }
    }
    public func canIgnore(_ selection: [URL], deleting: Bool) -> Bool {
        guard !selection.isEmpty else { return false }
        let paths = selection.map { $0.standardizedFileURL.path }
        guard roots.contains(where: { root in paths.allSatisfy { $0.hasPrefix(root + "/") } }) else { return false }
        return paths.allSatisfy { path in
            guard let state = states[path] else { return false }
            return deleting ? [.normal, .modified, .added, .conflicted].contains(state) : [.untracked, .deleted].contains(state)
        }
    }
}

public enum RepositoryAction: String, CaseIterable, Identifiable, Sendable {
    case status, commit, revert, submoduleUpdate, log, diff, pull, push, fetch, branch, tag, switchBranch, merge, rebase, stash, stashApply, stashPop, stashList, reflog, clone, initialize, rename, remove, removeKeep, ignore, ignoreMask, ignoreDelete, ignoreDeleteMask, resolve, resolveCurrent, resolveMine, resolveTheirs, reset, editConflict
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .status: return "Check for modifications"
        case .commit: return "Commit…"
        case .revert: return "Revert…"
        case .submoduleUpdate: return "Submodule Update…"
        case .log: return "Show log"
        case .diff: return "Diff"
        case .pull: return "Pull…"
        case .push: return "Push…"
        case .fetch: return "Fetch…"
        case .branch: return "Create branch…"
        case .tag: return "Create tag…"
        case .switchBranch: return "Switch/Checkout…"
        case .merge: return "Merge…"
        case .rebase: return "Rebase…"
        case .stash: return "Stash save…"
        case .stashList: return "Stash list"
        case .reflog: return "RefLog"
        case .stashApply: return "Stash apply"
        case .stashPop: return "Stash pop"
        case .clone: return "Clone…"
        case .initialize: return "Create repository here…"
        case .rename: return "Rename…"
        case .remove: return "Delete"
        case .removeKeep: return "Delete (keep local)"
        case .ignore: return "Add to ignore list"
        case .ignoreMask: return "Ignore by extension"
        case .ignoreDelete: return "Delete and add to ignore list"
        case .ignoreDeleteMask: return "Delete and ignore by extension"
        case .editConflict: return "Edit conflict…"
        case .reset: return "Reset…"
        case .resolve: return "Resolve…"
        case .resolveCurrent: return "Resolved"
        case .resolveMine: return "Resolve conflict using ‘mine’"
        case .resolveTheirs: return "Resolve conflict using ‘theirs’"
        }
    }
    public var resolveChoice: ResolveChoice? {
        switch self { case .resolveCurrent: return .current; case .resolveMine: return .mine; case .resolveTheirs: return .theirs; default: return nil }
    }
    public var isResolve: Bool { self == .resolve || self == .editConflict || resolveChoice != nil }
    public var isIgnore: Bool { [.ignore, .ignoreMask, .ignoreDelete, .ignoreDeleteMask].contains(self) }
    public var ignoresByExtension: Bool { self == .ignoreMask || self == .ignoreDeleteMask }
    public var removesWhenIgnoring: Bool { self == .ignoreDelete || self == .ignoreDeleteMask }
    public var requiresValue: Bool { [.branch, .tag, .switchBranch, .merge, .rebase, .stash, .clone].contains(self) }
    public var requiresWorkingTree: Bool { [.status, .commit, .revert, .submoduleUpdate, .diff, .pull, .switchBranch, .merge, .rebase, .stash, .stashApply, .stashPop, .stashList, .rename, .remove, .removeKeep, .ignore, .ignoreMask, .ignoreDelete, .ignoreDeleteMask, .resolve, .resolveCurrent, .resolveMine, .resolveTheirs, .editConflict].contains(self) }
    public var prompt: String {
        switch self {
        case .clone: return "Repository URL"
        case .stash: return "Stash message"
        default: return "Branch, tag, or revision"
        }
    }
    public func arguments(value: String) -> [String]? {
        switch self {
        case .pull: return ["pull", "--ff-only"]
        case .push: return ["push"]
        case .fetch: return ["fetch", "--all"]
        case .branch: return ["branch", "--", value]
        case .tag: return ["tag", "--", value]
        case .switchBranch: return ["switch", "--", value]
        case .merge: return ["merge", "--", value]
        case .rebase: return ["rebase", "--", value]
        case .stash: return ["stash", "push", "-m", value]
        case .stashApply: return ["stash", "apply"]
        case .stashPop: return ["stash", "pop"]
        case .clone: return ["clone", "--", value, "."]
        case .initialize: return ["init"]
        default: return nil
        }
    }
}

/// Menu metadata only. This shared record intentionally has no bookmark or scope.
public struct WorkingComparisonMarkSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public var path: String
    public init(id: UUID, path: String) { self.id = id; self.path = path }
    public static var sharedURL: URL? { FinderIntegration.container?.appendingPathComponent("comparison-mark.json") }
    public static func read(from url: URL? = sharedURL) throws -> Self? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.path.hasPrefix("/"), !value.path.contains("\0") else { throw RevisionComparisonFailure.selection }
        return value
    }
    @discardableResult public static func publish(_ mark: Self?, to url: URL? = sharedURL) throws -> Bool {
        guard let url else { return false }
        if let mark {
            guard mark.path.hasPrefix("/"), !mark.path.contains("\0") else { throw RevisionComparisonFailure.selection }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(mark).write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        return true
    }
}
