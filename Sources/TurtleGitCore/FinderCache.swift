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
/// Presentation preferences are independent of repository status and app menus.
public struct FinderMenuSettings: Codable, Equatable, Sendable {
    public var showIcons: Bool
    public init(showIcons: Bool = true) { self.showIcons = showIcons }
    public static var sharedURL: URL? { FinderIntegration.container?.appendingPathComponent("menu-settings.json") }
    public static func from(defaults: UserDefaults = .standard) -> Self {
        Self(showIcons: (defaults.object(forKey: "ShowContextMenuIcons") as? NSNumber)?.boolValue ?? true)
    }
    public static func read(from url: URL? = sharedURL) -> Self {
        guard let url, let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }
    @discardableResult public func write(to url: URL? = sharedURL) throws -> Bool {
        guard let url else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        return true
    }
}

/// MenuInfo's folder creation clauses, using cached status and metadata only.
public struct FinderCreationMenuContext: Sendable {
    public var directory: Bool
    public var versioned: Bool
    public var folderInGit: Bool
    public var bare: Bool
    public var ignored: Bool
    public var inaccessible: Bool
    public var extended: Bool
    public init(directory: Bool, versioned: Bool = false, folderInGit: Bool? = nil, bare: Bool = false,
                ignored: Bool = false, inaccessible: Bool = false, extended: Bool = false) {
        self.directory = directory; self.versioned = versioned
        self.folderInGit = folderInGit ?? versioned; self.bare = bare
        self.ignored = ignored; self.inaccessible = inaccessible; self.extended = extended
    }
    public var actions: [RepositoryAction] {
        guard directory else { return [] }
        let ordinary = !versioned && !folderInGit && !bare && !inaccessible
        var result: [RepositoryAction] = []
        if ordinary || ignored || extended { result.append(.clone) }
        if ordinary || ignored || (extended && !versioned) { result.append(.initialize) }
        return result
    }
    public static func read(directory url: URL, snapshot: FinderSnapshot?, extended: Bool) -> Self {
        guard url.isFileURL, !url.pathComponents.contains(".git") else { return Self(directory: false) }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let folder = values?.isDirectory ?? url.hasDirectoryPath
        let path = url.standardizedFileURL.path
        let known = snapshot?.roots.contains { path == $0 || path.hasPrefix($0 + "/") } == true
        let state = snapshot?.states[path]
        let versioned = known && state.map { [.normal, .modified, .added, .deleted, .conflicted].contains($0) } == true
        let ignored = snapshot?.states.contains { entry in entry.value == .ignored && (path == entry.key || path.hasPrefix(entry.key + "/")) } == true
        let fm = FileManager.default
        // Same loose-ref metadata checks as pinned GitAdminDir::IsBareRepo.
        func hasDirectory(_ name: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let bare = ["HEAD", "config"].allSatisfy {
            fm.fileExists(atPath: url.appendingPathComponent($0).path)
        } && ["objects", "refs", "refs/heads"].allSatisfy(hasDirectory)
        let inaccessible = values == nil || (fm.fileExists(atPath: url.appendingPathComponent(".git").path) && !known)
        return Self(directory: folder, versioned: versioned && !bare, folderInGit: known && !bare, bare: bare,
                    ignored: ignored, inaccessible: inaccessible, extended: extended)
    }
}

public struct FinderRepositoryMetadata: Codable, Equatable, Sendable {
    public var bare: Bool
    public var bisectActive: Bool
    public var mergeActive: Bool
    public var hasStash: Bool
    public var hasSubmoduleConfig: Bool
    public init(bare: Bool = false, bisectActive: Bool = false, mergeActive: Bool = false,
                hasStash: Bool = false, hasSubmoduleConfig: Bool = false) {
        self.bare = bare; self.bisectActive = bisectActive; self.mergeActive = mergeActive
        self.hasStash = hasStash; self.hasSubmoduleConfig = hasSubmoduleConfig
    }
    /// Repository-wide clauses only; path/status clauses remain separate.
    public func allows(_ action: RepositoryAction) -> Bool {
        if bare { return [.fetch, .push, .log, .reflog, .repositoryBrowser, .worktreeList].contains(action) }
        if [.pull, .merge, .rebase].contains(action) && (bisectActive || mergeActive) { return false }
        if action == .stash && mergeActive { return false }
        if [.stashApply, .stashPop, .stashList].contains(action) && !hasStash { return false }
        if action == .submoduleUpdate && !hasSubmoduleConfig { return false }
        return true
    }
}

extension GitRepository {
    /// Runs only in the containing app; linked-worktree markers use its own Git dir.
    public func finderMetadata(knownBare: Bool? = nil) throws -> FinderRepositoryMetadata {
        let bare = try knownBare ?? isBare()
        var bytes = try run(["rev-parse", "--absolute-git-dir"]).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let directory = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
        let fm = FileManager.default
        let stash = try run(["show-ref", "--verify", "--quiet", "refs/stash"], successfulExitCodes: 0...1).exitCode == 0
        return FinderRepositoryMetadata(bare: bare,
            bisectActive: fm.fileExists(atPath: directory.appendingPathComponent("BISECT_START").path),
            mergeActive: fm.fileExists(atPath: directory.appendingPathComponent("MERGE_HEAD").path),
            hasStash: stash, hasSubmoduleConfig: !bare && fm.fileExists(atPath: root.appendingPathComponent(".gitmodules").path))
    }
}

public struct FinderSnapshot: Codable, Sendable {
    public var roots: [String]
    public var states: [String: FileState]
    public var updated: Date
    public var repositories: [String: FinderRepositoryMetadata]
    public init(roots: [String], states: [String: FileState], updated: Date = Date(), repositories: [String: FinderRepositoryMetadata] = [:]) {
        self.roots = roots; self.states = states; self.updated = updated; self.repositories = repositories
    }
    private enum CodingKeys: String, CodingKey { case roots, states, updated, repositories }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roots = try values.decode([String].self, forKey: .roots)
        states = try values.decode([String: FileState].self, forKey: .states)
        updated = try values.decode(Date.self, forKey: .updated)
        repositories = try values.decodeIfPresent([String: FinderRepositoryMetadata].self, forKey: .repositories) ?? [:]
    }
    public func repositoryMetadata(for paths: [URL]) -> FinderRepositoryMetadata? {
        guard !paths.isEmpty else { return nil }
        return roots.sorted { $0.count > $1.count }.first { root in
            paths.allSatisfy { $0.path == root || $0.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        }.flatMap { repositories[$0] }
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
    case status, commit, revert, submoduleUpdate, log, repositoryBrowser, formatPatch, worktreeCreate, worktreeList, diff, diffLater, clearComparisonMark, pull, push, fetch, branch, tag, switchBranch, merge, rebase, stash, stashApply, stashPop, stashList, reflog, clone, initialize, rename, remove, removeKeep, ignore, ignoreMask, ignoreDelete, ignoreDeleteMask, resolve, resolveCurrent, resolveMine, resolveTheirs, reset, editConflict
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .status: return "Check for modifications"
        case .commit: return "Commit…"
        case .revert: return "Revert…"
        case .submoduleUpdate: return "Submodule Update…"
        case .log: return "Show log"
        case .repositoryBrowser: return "Repo-browser…"
        case .formatPatch: return "Create Patch Serial…"
        case .worktreeCreate: return "New Worktree…"
        case .worktreeList: return "Worktrees"
        case .diff: return "Diff"
        case .diffLater: return "Mark for comparison"
        case .clearComparisonMark: return "Clear comparison mark"
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

public struct FinderShellFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let folder = Self(rawValue: 1 << 0)
    public static let inGit = Self(rawValue: 1 << 1)
    public static let folderInGit = Self(rawValue: 1 << 2)
    public static let bare = Self(rawValue: 1 << 3)
    public static let inaccessible = Self(rawValue: 1 << 4)
    public static let ignored = Self(rawValue: 1 << 5)
    public static let extended = Self(rawValue: 1 << 6)
    public static let onlyOne = Self(rawValue: 1 << 7)
    public static let two = Self(rawValue: 1 << 8)
    public static let workingTreeRoot = Self(rawValue: 1 << 9)
    public static let bisect = Self(rawValue: 1 << 10)
    public static let merge = Self(rawValue: 1 << 11)
    public static let added = Self(rawValue: 1 << 12)
    public static let normal = Self(rawValue: 1 << 13)
    public static let conflicted = Self(rawValue: 1 << 14)
    public static let inVersionedFolder = Self(rawValue: 1 << 15)
    public static let submodule = Self(rawValue: 1 << 16)
    public static let stash = Self(rawValue: 1 << 17)
    public static let submoduleContainer = Self(rawValue: 1 << 18)
}
public struct FinderShellCondition: Sendable {
    public let required: FinderShellFlags
    public let excluded: FinderShellFlags
    public init(_ required: FinderShellFlags, _ excluded: FinderShellFlags) { self.required = required; self.excluded = excluded }
    public func matches(_ flags: FinderShellFlags) -> Bool {
        (!required.isEmpty || !excluded.isEmpty) && flags.isSuperset(of: required) && flags.intersection(excluded).isEmpty
    }
}
public enum FinderShellRules {
    public static let conditions: [RepositoryAction: [FinderShellCondition]] = [
        .clone: [.init([.folder], [.inGit, .folderInGit, .bare, .inaccessible]), .init([.folder, .ignored], []), .init([.folder, .extended], []), .init([], [])],
        .pull: [.init([.folderInGit, .onlyOne], [.bisect, .merge]), .init([.workingTreeRoot], [.bisect, .merge]), .init([], []), .init([], [])],
        .fetch: [.init([.folderInGit, .onlyOne], []), .init([.bare], []), .init([.workingTreeRoot], []), .init([], [])],
        .push: [.init([.folderInGit, .onlyOne], []), .init([.bare], []), .init([.workingTreeRoot], []), .init([], [])],
        .commit: [.init([.inGit], []), .init([.folderInGit], []), .init([], []), .init([], [])],
        .diff: [.init([.inGit, .onlyOne], []), .init([.two], [.folder]), .init([], []), .init([], [])],
        .diffLater: [.init([.onlyOne], [.folder]), .init([], []), .init([], []), .init([], [])],
        .log: [.init([.inGit, .onlyOne], [.added]), .init([.folder, .folderInGit, .onlyOne], [.added]), .init([.folderInGit, .onlyOne], [.added]), .init([.bare], [])],
        .reflog: [.init([.folderInGit, .onlyOne], []), .init([.bare], []), .init([], []), .init([], [])],
        .repositoryBrowser: [.init([.folderInGit, .onlyOne], []), .init([.bare, .onlyOne], []), .init([], []), .init([], [])],
        .status: [.init([.inGit], []), .init([.folder, .folderInGit], []), .init([], []), .init([], [])],
        .rebase: [.init([.folderInGit, .onlyOne], [.bisect, .merge]), .init([], []), .init([], []), .init([], [])],
        .stash: [.init([.inGit, .onlyOne], [.merge]), .init([], []), .init([], []), .init([], [])],
        .stashApply: [.init([.folderInGit, .onlyOne, .stash], []), .init([], []), .init([], []), .init([], [])],
        .stashPop: [.init([.folderInGit, .onlyOne, .stash], []), .init([], []), .init([], []), .init([], [])],
        .stashList: [.init([.folderInGit, .onlyOne, .stash], []), .init([], []), .init([], []), .init([], [])],
        .resolve: [.init([.inGit, .conflicted], []), .init([.inGit, .folder], []), .init([.folderInGit], []), .init([], [])],
        .rename: [.init([.inGit, .onlyOne, .inVersionedFolder], [.workingTreeRoot]), .init([.workingTreeRoot, .submodule], []), .init([], []), .init([], [])],
        .remove: [.init([.inGit, .inVersionedFolder], [.added, .workingTreeRoot]), .init([.folderInGit, .workingTreeRoot, .submodule], []), .init([], []), .init([], [])],
        .removeKeep: [.init([.inGit, .inVersionedFolder], [.added, .workingTreeRoot]), .init([], []), .init([], []), .init([], [])],
        .revert: [.init([.inGit], [.normal]), .init([.folderInGit], []), .init([], []), .init([], [])],
        .switchBranch: [.init([.folderInGit, .onlyOne], []), .init([], []), .init([], []), .init([], [])],
        .merge: [.init([.folderInGit, .onlyOne], [.bisect, .merge]), .init([], []), .init([], []), .init([], [])],
        .branch: [.init([.folderInGit, .onlyOne], []), .init([], []), .init([], []), .init([], [])],
        .tag: [.init([.folderInGit, .onlyOne], []), .init([], []), .init([], []), .init([], [])],
        .initialize: [.init([.folder], [.inGit, .folderInGit, .bare, .inaccessible]), .init([.folder, .ignored], []), .init([.folder, .extended], [.inGit]), .init([], [])],
        .ignore: [.init([.inVersionedFolder], [.ignored, .inGit, .workingTreeRoot]), .init([], []), .init([], []), .init([], [])],
        .ignoreDelete: [.init([.inVersionedFolder, .inGit], [.ignored, .workingTreeRoot]), .init([], []), .init([], []), .init([], [])],
        .worktreeList: [.init([.folderInGit, .onlyOne], []), .init([.bare], []), .init([], []), .init([], [])],
        .submoduleUpdate: [.init([.folderInGit, .submoduleContainer], []), .init([], []), .init([], []), .init([], [])],
        .formatPatch: [.init([.folderInGit, .onlyOne], []), .init([], []), .init([], []), .init([], [])],
    ]
    public static func allows(_ action: RepositoryAction, flags: FinderShellFlags) -> Bool {
        conditions[action]?.contains { $0.matches(flags) } ?? false
    }
    /// Cached status plus directory metadata; never executes Git in Finder.
    public static func flags(paths: [URL], snapshot: FinderSnapshot?, extended: Bool = false) -> FinderShellFlags {
        var flags: FinderShellFlags = extended ? [.extended] : []
        if paths.count == 1 { flags.insert(.onlyOne) }
        if paths.count == 2 { flags.insert(.two) }
        for path in paths {
            let directory = (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? path.hasDirectoryPath
            if directory { flags.insert(.folder) }
            let root = snapshot?.roots.sorted { $0.count > $1.count }.first { root in
                path.path == root || path.path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            let metadata = root.flatMap { snapshot?.repositories[$0] }
            let bare = metadata?.bare ?? root.map { FinderCreationMenuContext.read(directory: URL(fileURLWithPath: $0, isDirectory: true), snapshot: snapshot, extended: false).bare } ?? false
            if let root, !bare {
                flags.formUnion([.inGit, .inVersionedFolder])
                if directory { flags.insert(.folderInGit) }
                if path.path == root { flags.insert(.workingTreeRoot) }
                if metadata?.hasStash != false { flags.insert(.stash) }
                if metadata?.hasSubmoduleConfig != false { flags.insert(.submoduleContainer) }
                if metadata?.mergeActive == true { flags.insert(.merge) }
                if metadata?.bisectActive == true { flags.insert(.bisect) }
            } else if let root, bare && path.path == root { flags.insert(.bare) }
            switch snapshot?.states[path.path] {
            case .normal: flags.insert(.normal)
            case .modified: break
            case .added: flags.insert(.added)
            case .deleted: break
            case .conflicted: flags.insert(.conflicted)
            case .ignored: flags.remove(.inGit); flags.insert(.ignored)
            case .untracked, nil: flags.remove(.inGit)
            }
        }
        return flags
    }
}
