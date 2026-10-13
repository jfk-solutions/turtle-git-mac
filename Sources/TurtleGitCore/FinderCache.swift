import Foundation
import Darwin
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
    public var topLevelMask = FinderMenuEntry.defaultTopMask
    public var extendedOnlyMask = FinderMenuEntry.defaultExtendedMask
    public var hideForUnversioned = false
    public var excludedPaths = ""
    public init(showIcons: Bool = true) { self.showIcons = showIcons }
    private enum CodingKeys: String, CodingKey { case showIcons, topLevelMask, extendedOnlyMask, hideForUnversioned, excludedPaths }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(showIcons: try values.decodeIfPresent(Bool.self, forKey: .showIcons) ?? true)
        topLevelMask = try values.decodeIfPresent(UInt64.self, forKey: .topLevelMask) ?? FinderMenuEntry.defaultTopMask
        extendedOnlyMask = try values.decodeIfPresent(UInt64.self, forKey: .extendedOnlyMask) ?? FinderMenuEntry.defaultExtendedMask
        hideForUnversioned = try values.decodeIfPresent(Bool.self, forKey: .hideForUnversioned) ?? false
        excludedPaths = try values.decodeIfPresent(String.self, forKey: .excludedPaths) ?? ""
    }
    public static var sharedURL: URL? { FinderIntegration.container?.appendingPathComponent("menu-settings.json") }
    public static func from(defaults: UserDefaults = .standard) -> Self {
        var settings = defaults.data(forKey: "TurtleGit.FinderMenuSettings").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        settings.showIcons = (defaults.object(forKey: "ShowContextMenuIcons") as? NSNumber)?.boolValue ?? true
        return settings
    }
    public static func read(from url: URL? = sharedURL) -> Self {
        guard let url, let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }
    @discardableResult public func write(to url: URL? = sharedURL) throws -> Bool {
        guard valid else { throw GitConfigurationFailure.invalidValue }
        guard let url else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        return true
    }
    public var valid: Bool {
        !excludedPaths.contains("\0") && excludedPaths.replacingOccurrences(of: "\r", with: "").split(separator: "\n").allSatisfy {
            $0.hasPrefix("/") || $0 == "~" || $0.hasPrefix("~/") || $0 == "~*" || $0 == "$HOME" || $0.hasPrefix("$HOME/") || $0 == "$HOME*"
        }
    }
    public func save(to defaults: UserDefaults = .standard) throws {
        guard valid else { throw GitConfigurationFailure.invalidValue }
        defaults.set(try JSONEncoder().encode(self), forKey: "TurtleGit.FinderMenuSettings")
    }
    public func visible(_ entry: FinderMenuEntry, extended: Bool) -> Bool { extended || extendedOnlyMask & entry.mask == 0 }
    public func firstLevel(_ entry: FinderMenuEntry) -> Bool { topLevelMask & entry.mask != 0 }
    public mutating func set(_ entry: FinderMenuEntry, checked: Bool, extendedOnly: Bool) {
        if extendedOnly { extendedOnlyMask = checked ? extendedOnlyMask | entry.mask : extendedOnlyMask & ~entry.mask }
        else { topLevelMask = checked ? topLevelMask | entry.mask : topLevelMask & ~entry.mask }
    }
    public func allowsPath(_ path: String, caseSensitive: Bool = true) -> Bool {
        for line in excludedPaths.replacingOccurrences(of: "\r", with: "").split(separator: "\n") {
            var pattern = String(line)
            let prefix = pattern.hasSuffix("*"), descendants = pattern.hasSuffix("/")
            if prefix { pattern.removeLast() }
            if pattern == "~" || pattern.hasPrefix("~/") { pattern = FileManager.default.homeDirectoryForCurrentUser.path + pattern.dropFirst() }
            if pattern == "$HOME" || pattern.hasPrefix("$HOME/") { pattern = FileManager.default.homeDirectoryForCurrentUser.path + pattern.dropFirst(5) }
            // Unlike overlay rules, a bare path excludes only that exact path.
            // A terminal '*' is a spelling prefix; '/' includes directory children.
            let candidate = caseSensitive ? path : path.lowercased(), filter = caseSensitive ? pattern : pattern.lowercased()
            if prefix && candidate.hasPrefix(filter) { return false }
            if descendants && (candidate.hasPrefix(filter) || candidate == String(filter.dropLast())) { return false }
            if !prefix && !descendants && candidate == filter { return false }
        }
        return true
    }
    public func allowsMenu(flags: FinderShellFlags, extended: Bool) -> Bool {
        extended || !hideForUnversioned || !flags.intersection([.inGit, .inVersionedFolder, .folderInGit, .bare, .inaccessible]).isEmpty
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
        let knownRoot = snapshot?.roots.contains(path) == true
        let state = snapshot?.states[path]
        let versioned = knownRoot || known && state.map { [.normal, .modified, .added, .deleted, .conflicted].contains($0) } == true
        let ignored = !knownRoot && snapshot?.states.contains { entry in entry.value == .ignored && (path == entry.key || path.hasPrefix(entry.key + "/")) } == true
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
    public var hasLFS: Bool
    public var hasGitSVN: Bool
    public var submoduleParentRoot: String?
    public init(bare: Bool = false, bisectActive: Bool = false, mergeActive: Bool = false,
                hasStash: Bool = false, hasSubmoduleConfig: Bool = false, submoduleParentRoot: String? = nil, hasLFS: Bool = false, hasGitSVN: Bool = false) {
        self.bare = bare; self.bisectActive = bisectActive; self.mergeActive = mergeActive
        self.hasStash = hasStash; self.hasSubmoduleConfig = hasSubmoduleConfig; self.submoduleParentRoot = submoduleParentRoot
        self.hasLFS = hasLFS; self.hasGitSVN = hasGitSVN
    }
    private enum CodingKeys: String, CodingKey { case bare, bisectActive, mergeActive, hasStash, hasSubmoduleConfig, submoduleParentRoot, hasLFS, hasGitSVN }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bare = try values.decode(Bool.self, forKey: .bare)
        bisectActive = try values.decode(Bool.self, forKey: .bisectActive)
        mergeActive = try values.decode(Bool.self, forKey: .mergeActive)
        hasStash = try values.decode(Bool.self, forKey: .hasStash)
        hasSubmoduleConfig = try values.decode(Bool.self, forKey: .hasSubmoduleConfig)
        submoduleParentRoot = try values.decodeIfPresent(String.self, forKey: .submoduleParentRoot)
        hasGitSVN = try values.decodeIfPresent(Bool.self, forKey: .hasGitSVN) ?? false
        hasLFS = try values.decodeIfPresent(Bool.self, forKey: .hasLFS) ?? false
    }
    /// Repository-wide clauses only; path/status clauses remain separate.
    public func allows(_ action: RepositoryAction) -> Bool {
        if action.isApplicationUtility || [.sendMail, .reviewPatch].contains(action) { return true }
        if bare { return [.fetch, .push, .log, .daemon, .revisionGraph, .reflog, .referenceBrowser, .repositoryBrowser, .export, .worktreeList].contains(action) }
        if action.svnOperation != nil && !hasGitSVN { return false }
        if [.svnDCommit, .svnRebase, .pull, .merge, .rebase, .synchronize].contains(action) && (bisectActive || mergeActive) { return false }
        if action == .bisectStart && (bisectActive || mergeActive) { return false }
        if action.bisectOperation != nil && !bisectActive { return false }
        if action == .mergeAbort && !mergeActive { return false }
        if action == .stash && mergeActive { return false }
        if [.stashApply, .stashPop, .stashList].contains(action) && !hasStash { return false }
        if (action == .submoduleUpdate || action == .submoduleSync) && !hasSubmoduleConfig { return false }
        return true
    }
}

extension GitRepository {
    /// Runs only in the containing app; linked-worktree markers use its own Git dir.
    public func finderMetadata(knownBare: Bool? = nil,cancellation:OperationCancellation? = nil) throws -> FinderRepositoryMetadata {
        try cancellation?.check()
        let bare = try knownBare ?? isBare(cancellation:cancellation)
        var bytes = try run(["rev-parse", "--absolute-git-dir"],cancellation:cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let directory = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
        let fm = FileManager.default
        let stash = try run(["show-ref", "--verify", "--quiet", "refs/stash"], successfulExitCodes: 0...1,cancellation:cancellation).exitCode == 0
        let lfs = bare ? false : try hasLFS(cancellation:cancellation)
        var commonBytes = try run(["rev-parse", "--git-common-dir"],cancellation:cancellation).stdout
        if commonBytes.last == 10 { commonBytes.removeLast() }
        let commonPath = String(decoding: commonBytes, as: UTF8.self)
        let common = commonPath.hasPrefix("/") ? URL(fileURLWithPath: commonPath) : root.appendingPathComponent(commonPath)
        let svn = !bare && fm.fileExists(atPath: common.appendingPathComponent("svn/.metadata").path)
        return FinderRepositoryMetadata(bare: bare,
            bisectActive: fm.fileExists(atPath: directory.appendingPathComponent("BISECT_START").path),
            mergeActive: fm.fileExists(atPath: directory.appendingPathComponent("MERGE_HEAD").path),
            hasStash: stash, hasSubmoduleConfig: !bare && fm.fileExists(atPath: root.appendingPathComponent(".gitmodules").path),
            submoduleParentRoot: bare ? nil : try registeredSubmoduleParent(cancellation:cancellation)?.path, hasLFS: lfs, hasGitSVN: svn)
    }
}

public struct FinderSnapshot: Codable, Sendable {
    public var roots: [String]
    public var states: [String: FileState]
    public var updated: Date
    public var repositories: [String: FinderRepositoryMetadata]
    public var overlayEntries: [String: FileState]?
    public var indexFlags: [String: FinderIndexFlags]?
    public init(roots: [String], states: [String: FileState], updated: Date = Date(), repositories: [String: FinderRepositoryMetadata] = [:], overlayEntries: [String: FileState]? = nil, indexFlags: [String: FinderIndexFlags]? = nil) {
        self.roots = roots; self.states = states; self.updated = updated; self.repositories = repositories
        self.overlayEntries = overlayEntries
        self.indexFlags = indexFlags
    }
    private enum CodingKeys: String, CodingKey { case roots, states, updated, repositories, overlayEntries, indexFlags }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roots = try values.decode([String].self, forKey: .roots)
        states = try values.decode([String: FileState].self, forKey: .states)
        updated = try values.decode(Date.self, forKey: .updated)
        repositories = try values.decodeIfPresent([String: FinderRepositoryMetadata].self, forKey: .repositories) ?? [:]
        overlayEntries = try values.decodeIfPresent([String: FileState].self, forKey: .overlayEntries)
        indexFlags = try values.decodeIfPresent([String: FinderIndexFlags].self, forKey: .indexFlags)
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
        return FinderSnapshot(roots: [root.path], states: states, overlayEntries: files)
    }
    /// Cached eligibility only. The containing app revalidates tracked paths and
    /// the working tree before Git mutates anything.
    public func canRename(_ selection: [URL]) -> Bool {
        guard selection.count == 1, let path = selection.first?.standardizedFileURL.path,
              roots.contains(where: { path.hasPrefix($0 + "/") || path == $0 && repositories[$0]?.submoduleParentRoot != nil }) else { return false }
        let versioned: Set<FileState> = [.normal, .modified, .added, .conflicted]
        if let state = states[path], versioned.contains(state) { return true }
        return states.contains { $0.key.hasPrefix(path + "/") && versioned.contains($0.value) }
    }
    public func canRemove(_ selection: [URL]) -> Bool {
        guard !selection.isEmpty else { return false }
        let paths = selection.map { $0.standardizedFileURL.path }
        guard roots.contains(where: { root in paths.allSatisfy { $0.hasPrefix(root + "/") || $0 == root && repositories[root]?.submoduleParentRoot != nil } }) else { return false }
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
    case svnDCommit, svnRebase, svnFetch, svnIgnore
    case reviewPatch, daemon, lfs, lfsLocks, lfsLock, lfsUnlock, sendMail
    case synchronize, blame, previousDiff, logSubmodule, properties, settings, help, about
    case status, commit, add, revert, clean, submoduleAdd, submoduleUpdate, submoduleSync, log, revisionGraph, referenceBrowser, repositoryBrowser, export, bisect, bisectStart, bisectGood, bisectBad, bisectSkip, bisectReset, formatPatch, importPatch, requestPull, worktreeCreate, worktreeList, diff, diffLater, clearComparisonMark, pull, push, fetch, branch, tag, switchBranch, merge, mergeAbort, rebase, stash, stashApply, stashPop, stashList, reflog, clone, initialize, rename, remove, removeKeep, ignore, ignoreMask, ignoreDelete, ignoreDeleteMask, resolve, resolveCurrent, resolveMine, resolveTheirs, reset, editConflict
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .svnDCommit: return "SVN DCommit…"
        case .svnRebase: return "SVN Rebase"
        case .svnFetch: return "SVN Fetch"
        case .svnIgnore: return "Import SVN Ignore…"
        case .reviewPatch: return "Review/apply single patch…"
        case .daemon: return "Daemon"
        case .lfs: return "LFS"
        case .lfsLocks: return "Show locked files"
        case .lfsLock: return "Lock"
        case .lfsUnlock: return "Unlock"
        case .sendMail: return "Send Mail…"
        case .synchronize: return "Sync…"
        case .blame: return "Blame"
        case .previousDiff: return "Diff with previous version"
        case .logSubmodule: return "Show log of this folder"
        case .properties: return "Git Properties…"
        case .settings: return "Settings"
        case .help: return "Help"
        case .about: return "About"
        case .status: return "Check for modifications"
        case .commit: return "Commit…"
        case .add: return "Add…"
        case .revert: return "Revert…"
        case .clean: return "Clean up…"
        case .submoduleAdd: return "Submodule Add…"
        case .submoduleSync: return "Submodule Sync"
        case .submoduleUpdate: return "Submodule Update…"
        case .log: return "Show log"
        case .revisionGraph: return "Revision Graph"
        case .referenceBrowser: return "Browse References"
        case .repositoryBrowser: return "Repo-browser…"
        case .bisect: return "Bisect…"
        case .bisectStart: return "Bisect start…"
        case .bisectGood: return "Bisect good"
        case .bisectBad: return "Bisect bad"
        case .bisectSkip: return "Bisect skip"
        case .bisectReset: return "Bisect reset"
        case .export: return "Export…"
        case .formatPatch: return "Create Patch Serial…"
        case .importPatch: return "Apply Patch Serial…"
        case .requestPull: return "Create pull request…"
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
        case .mergeAbort: return "Abort Merge"
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
    public var bisectOperation: BisectOperation? {
        switch self { case .bisectGood: return .good; case .bisectBad: return .bad; case .bisectSkip: return .skip; case .bisectReset: return .reset; default: return nil }
    }
    public var resolveChoice: ResolveChoice? {
        switch self { case .resolveCurrent: return .current; case .resolveMine: return .mine; case .resolveTheirs: return .theirs; default: return nil }
    }
    public var svnOperation: GitSVNOperation? {
        switch self { case .svnDCommit: return .dcommit; case .svnRebase: return .rebase; case .svnFetch: return .fetch; case .svnIgnore: return .ignore; default: return nil }
    }
    public var isResolve: Bool { self == .resolve || self == .editConflict || resolveChoice != nil }
    public var isApplicationUtility: Bool { [.settings, .help, .about].contains(self) }
    public var allowsEmptySelection: Bool { isApplicationUtility || self == .clone || self == .initialize }
    public var isMenuHeader: Bool { self == .lfs }
    public var isLFS: Bool { [.lfs, .lfsLocks, .lfsLock, .lfsUnlock].contains(self) }
    public var isIgnore: Bool { [.ignore, .ignoreMask, .ignoreDelete, .ignoreDeleteMask].contains(self) }
    public var ignoresByExtension: Bool { self == .ignoreMask || self == .ignoreDeleteMask }
    public var removesWhenIgnoring: Bool { self == .ignoreDelete || self == .ignoreDeleteMask }
    public var requiresValue: Bool { [.branch, .tag, .switchBranch, .merge, .rebase, .stash, .clone].contains(self) }
    public var requiresWorkingTree: Bool { [.svnDCommit, .svnRebase, .svnFetch, .svnIgnore, .lfs, .lfsLocks, .lfsLock, .lfsUnlock, .synchronize, .blame, .previousDiff, .logSubmodule, .status, .commit, .importPatch, .add, .revert, .clean, .submoduleAdd, .submoduleUpdate, .submoduleSync, .diff, .bisect, .bisectStart, .bisectGood, .bisectBad, .bisectSkip, .bisectReset, .pull, .switchBranch, .merge, .mergeAbort, .rebase, .stash, .stashApply, .stashPop, .stashList, .rename, .remove, .removeKeep, .ignore, .ignoreMask, .ignoreDelete, .ignoreDeleteMask, .resolve, .resolveCurrent, .resolveMine, .resolveTheirs, .editConflict].contains(self) }
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
    public static let deleted = Self(rawValue: 1 << 19)
    public static let gitSVN = Self(rawValue: 1 << 21)
    public static let patchFile = Self(rawValue: 1 << 20)
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
        .svnDCommit: [.init([.inGit, .gitSVN], [.bisect, .merge]), .init([.folderInGit, .gitSVN], [.bisect, .merge]), .init([], []), .init([], [])],
        .svnRebase: [.init([.folderInGit, .gitSVN, .onlyOne], [.bisect, .merge]), .init([], []), .init([], []), .init([], [])],
        .svnFetch: [.init([.folderInGit, .gitSVN, .onlyOne], []), .init([], []), .init([], []), .init([], [])],
        .svnIgnore: [.init([.folderInGit, .gitSVN, .onlyOne], []), .init([], []), .init([], []), .init([], [])],
        .lfs: [.init([.inVersionedFolder, .inGit], []), .init([], []), .init([], []), .init([], [])],
        .lfsLocks: [.init([.folderInGit, .onlyOne], []), .init([], []), .init([], []), .init([], [])],
        .lfsLock: [.init([.inGit, .inVersionedFolder], [.folder]), .init([], []), .init([], []), .init([], [])],
        .lfsUnlock: [.init([.inGit, .inVersionedFolder], [.folder]), .init([], []), .init([], []), .init([], [])],
        .reviewPatch: [.init([.patchFile, .onlyOne], []), .init([.extended, .onlyOne], [.folder]), .init([], []), .init([], [])],
        .sendMail: [.init([.patchFile], []), .init([.extended], [.folder]), .init([], []), .init([], [])],
        .synchronize: [.init([.folderInGit, .onlyOne], [.bisect, .merge]), .init([], []), .init([], []), .init([], [])],
        .previousDiff: [.init([.inGit, .onlyOne], [.added]), .init([], []), .init([], []), .init([], [])],
        .blame: [.init([.inGit, .onlyOne], [.folder, .added]), .init([], []), .init([], []), .init([], [])],
        .logSubmodule: [.init([.folderInGit, .onlyOne, .workingTreeRoot, .submodule], []), .init([], []), .init([], []), .init([], [])],
        .editConflict: [.init([.inGit, .conflicted], [.folder]), .init([], []), .init([], []), .init([], [])],
        .properties: [.init([.inVersionedFolder], []), .init([.folderInGit], []), .init([.inGit], []), .init([.bare], [])],
        .settings: [.init([.folder], []), .init([], [.folder]), .init([], []), .init([], [])],
        .help: [.init([.folder], []), .init([], [.folder]), .init([], []), .init([], [])],
        .about: [.init([.folder], []), .init([], [.folder]), .init([], []), .init([], [])],
        .add: [.init([.inVersionedFolder], [.inGit]), .init([.inGit, .folder], []), .init([.ignored], []), .init([.deleted], [.folder, .onlyOne])],
        .clone: [.init([.folder], [.inGit, .folderInGit, .bare, .inaccessible]), .init([.folder, .ignored], []), .init([.folder, .extended], []), .init([], [])],
        .pull: [.init([.folderInGit, .onlyOne], [.bisect, .merge]), .init([.workingTreeRoot], [.bisect, .merge]), .init([], []), .init([], [])],
        .fetch: [.init([.folderInGit, .onlyOne], []), .init([.bare], []), .init([.workingTreeRoot], []), .init([], [])],
        .push: [.init([.folderInGit, .onlyOne], []), .init([.bare], []), .init([.workingTreeRoot], []), .init([], [])],
        .commit: [.init([.inGit], []), .init([.folderInGit], []), .init([], []), .init([], [])],
        .diff: [.init([.inGit, .onlyOne], []), .init([.two], [.folder]), .init([], []), .init([], [])],
        .diffLater: [.init([.onlyOne], [.folder]), .init([], []), .init([], []), .init([], [])],
        .log: [.init([.inGit, .onlyOne], [.added]), .init([.folder, .folderInGit, .onlyOne], [.added]), .init([.folderInGit, .onlyOne], [.added]), .init([.bare], [])],
        .daemon: [.init([.inGit, .onlyOne], [.added]), .init([.folder, .folderInGit, .onlyOne], [.added]), .init([.folderInGit, .onlyOne], [.added]), .init([.bare], [])],
        .revisionGraph: [.init([.inGit, .onlyOne], [.added]), .init([.folder, .folderInGit, .onlyOne], [.added]), .init([.folderInGit, .onlyOne], [.added]), .init([.bare], [])],
        .reflog: [.init([.folderInGit, .onlyOne], []), .init([.bare], []), .init([], []), .init([], [])],
        .referenceBrowser: [.init([.folderInGit, .onlyOne], []), .init([.bare], []), .init([], []), .init([], [])],
        .repositoryBrowser: [.init([.folderInGit, .onlyOne], []), .init([.bare, .onlyOne], []), .init([], []), .init([], [])],
        .status: [.init([.inGit], []), .init([.folder, .folderInGit], []), .init([], []), .init([], [])],
        .rebase: [.init([.folderInGit, .onlyOne], [.bisect, .merge]), .init([], []), .init([], []), .init([], [])],
        .stash: [.init([.inGit, .onlyOne], [.merge]), .init([], []), .init([], []), .init([], [])],
        .stashApply: [.init([.folderInGit, .onlyOne, .stash], []), .init([], []), .init([], []), .init([], [])],
        .stashPop: [.init([.folderInGit, .onlyOne, .stash], []), .init([], []), .init([], []), .init([], [])],
        .stashList: [.init([.folderInGit, .onlyOne, .stash], []), .init([], []), .init([], []), .init([], [])],
        .bisectStart: [.init([.folderInGit, .onlyOne], [.bisect, .merge]), .init([], []), .init([], []), .init([], [])],
        .bisectGood: [.init([.folderInGit, .onlyOne, .bisect], []), .init([], []), .init([], []), .init([], [])],
        .bisectBad: [.init([.folderInGit, .onlyOne, .bisect], []), .init([], []), .init([], []), .init([], [])],
        .bisectSkip: [.init([.folderInGit, .onlyOne, .bisect], []), .init([], []), .init([], []), .init([], [])],
        .bisectReset: [.init([.folderInGit, .onlyOne, .bisect], []), .init([], []), .init([], []), .init([], [])],
        .resolve: [.init([.inGit, .conflicted], []), .init([.inGit, .folder], []), .init([.folderInGit], []), .init([], [])],
        .mergeAbort: [.init([.inGit, .merge], []), .init([.folderInGit, .merge], []), .init([], []), .init([], [])],
        .rename: [.init([.inGit, .onlyOne, .inVersionedFolder], [.workingTreeRoot]), .init([.workingTreeRoot, .submodule], []), .init([], []), .init([], [])],
        .remove: [.init([.inGit, .inVersionedFolder], [.added, .workingTreeRoot]), .init([.folderInGit, .workingTreeRoot, .submodule], []), .init([], []), .init([], [])],
        .removeKeep: [.init([.inGit, .inVersionedFolder], [.added, .workingTreeRoot]), .init([], []), .init([], []), .init([], [])],
        .clean: [.init([.folderInGit, .folder], []), .init([], []), .init([], []), .init([], [])],
        .revert: [.init([.inGit], [.normal]), .init([.folderInGit], []), .init([], []), .init([], [])],
        .switchBranch: [.init([.folderInGit, .onlyOne], []), .init([], []), .init([], []), .init([], [])],
        .merge: [.init([.folderInGit, .onlyOne], [.bisect, .merge]), .init([], []), .init([], []), .init([], [])],
        .branch: [.init([.folderInGit, .onlyOne], []), .init([], []), .init([], []), .init([], [])],
        .tag: [.init([.folderInGit, .onlyOne], []), .init([], []), .init([], []), .init([], [])],
        .export: [.init([.folderInGit, .onlyOne], []), .init([.bare], []), .init([], []), .init([], [])],
        .initialize: [.init([.folder], [.inGit, .folderInGit, .bare, .inaccessible]), .init([.folder, .ignored], []), .init([.folder, .extended], [.inGit]), .init([], [])],
        .ignore: [.init([.inVersionedFolder], [.ignored, .inGit, .workingTreeRoot]), .init([], []), .init([], []), .init([], [])],
        .ignoreDelete: [.init([.inVersionedFolder, .inGit], [.ignored, .workingTreeRoot]), .init([], []), .init([], []), .init([], [])],
        .worktreeList: [.init([.folderInGit, .onlyOne], []), .init([.bare], []), .init([], []), .init([], [])],
        .submoduleAdd: [.init([.folderInGit, .onlyOne], []), .init([], []), .init([], []), .init([], [])],
        .submoduleSync: [.init([.folderInGit, .submoduleContainer], []), .init([], []), .init([], []), .init([], [])],
        .submoduleUpdate: [.init([.folderInGit, .submoduleContainer], []), .init([], []), .init([], []), .init([], [])],
        .importPatch: [.init([.patchFile], []), .init([.folderInGit, .onlyOne], []), .init([], []), .init([], [])],
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
            else if ["patch", "diff"].contains(path.pathExtension.lowercased()) { flags.insert(.patchFile) }
            let root = snapshot?.roots.sorted { $0.count > $1.count }.first { root in
                path.path == root || path.path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            if root == nil, directory, FinderCreationMenuContext.read(directory: path, snapshot: snapshot, extended: extended).inaccessible { flags.insert(.inaccessible) }
            let metadata = root.flatMap { snapshot?.repositories[$0] }
            let bare = metadata?.bare ?? root.map { FinderCreationMenuContext.read(directory: URL(fileURLWithPath: $0, isDirectory: true), snapshot: snapshot, extended: false).bare } ?? false
            if let root, !bare {
                flags.formUnion([.inGit, .inVersionedFolder])
                if directory { flags.insert(.folderInGit) }
                if path.path == root {
                    flags.insert(.workingTreeRoot)
                    if directory && metadata?.submoduleParentRoot != nil { flags.insert(.submodule) }
                }
                if metadata?.hasGitSVN == true { flags.insert(.gitSVN) }
                if metadata?.hasStash != false { flags.insert(.stash) }
                if metadata?.hasSubmoduleConfig != false { flags.insert(.submoduleContainer) }
                if metadata?.mergeActive == true { flags.insert(.merge) }
                if metadata?.bisectActive == true { flags.insert(.bisect) }
            } else if let root, bare && path.path == root { flags.insert(.bare) }
            switch snapshot?.states[path.path] {
            case .normal: flags.insert(.normal)
            case .modified: break
            case .added: flags.insert(.added)
            case .deleted: flags.insert(.deleted)
            case .conflicted: flags.insert(.conflicted)
            case .ignored: flags.remove(.inGit); flags.insert(.ignored)
            case .untracked, nil: flags.remove(.inGit)
            }
            // A repository root is versioned independently of aggregated child
            // status, including an unborn root containing only untracked files.
            if directory, root == path.path, !bare { flags.insert(.inGit); flags.remove(.ignored) }
        }
        return flags
    }
}

extension GitRepository {
    /// Source registration rule: nearest parent worktree's .gitmodules path match.
    /// Missing/inaccessible parent metadata leaves this optional fact unavailable.
    public func registeredSubmoduleParent(cancellation: OperationCancellation? = nil) throws -> URL? {
        try cancellation?.check()
        guard root.path != "/" else { return nil }
        let result: GitResult
        do { result = try run(["-C", root.deletingLastPathComponent().path, "rev-parse", "--show-toplevel"], cancellation: cancellation) }
        catch { try cancellation?.check(); return nil }
        var bytes = result.stdout; if bytes.last == 10 { bytes.removeLast() }
        let parent = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true).standardizedFileURL
        guard parent != root, RepositoryAccessLease.pathIsContained(root, by: parent) else { return nil }
        let modules = parent.appendingPathComponent(".gitmodules")
        guard (try? FileManager.default.attributesOfItem(atPath: modules.path)[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let relative = String(root.path.dropFirst(parent.path.count + 1))
        let names: [Data.SubSequence]
        do { names = try run(["config", "--no-includes", "--null", "--file", modules.path, "--name-only", "--get-regexp", "^submodule\\..*\\.path$"], successfulExitCodes: 0...1, cancellation: cancellation).stdout.split(separator: 0) }
        catch { try cancellation?.check(); return nil }
        for name in names {
            let values = try run(["config", "--no-includes", "--null", "--file", modules.path, "--get-all", String(decoding: name, as: UTF8.self)], successfulExitCodes: 0...1, cancellation: cancellation).stdout.split(separator: 0)
            if values.contains(where: { String(decoding: $0, as: UTF8.self) == relative }) { return parent }
        }
        return nil
    }
}

public struct FinderSubmoduleScan: Sendable {
    public var snapshots: [FinderSnapshot] = []
    public var failures: [String: String] = [:]
    public init() {}
}

extension GitRepository {
    /// Foreground app refresh only. Finder consumes the resulting cache without Git.
    public func finderSubmoduleSnapshots(authorizedRoot: URL,cancellation:OperationCancellation? = nil) async throws -> FinderSubmoduleScan {
        try cancellation?.check()
        guard RepositoryAccessLease.pathIsContained(root, by: authorizedRoot) else {
            throw RepositoryAccessFailure.securityScopeUnavailable
        }
        return try await scanFinderSubmodules(authorizedRoot:authorizedRoot,ancestors:[],cancellation:cancellation)
    }
    private func configuredFinderSubmodulePaths(cancellation:OperationCancellation?) throws -> Set<String> {
        let modules = root.appendingPathComponent(".gitmodules")
        guard FileManager.default.fileExists(atPath: modules.path) else { return [] }
        guard (try FileManager.default.attributesOfItem(atPath: modules.path)[.type] as? FileAttributeType) == .typeRegular else {
            throw SubmoduleComparisonFailure.unsafeCheckout
        }
        let names = try run(["config", "--no-includes", "--null", "--file", modules.path, "--name-only", "--get-regexp", "^submodule\\..*\\.path$"], successfulExitCodes:0...1,cancellation:cancellation).stdout.split(separator: 0)
        var paths = Set<String>()
        for name in names {
            let values = try run(["config", "--no-includes", "--null", "--file", modules.path, "--get-all", String(decoding: name, as: UTF8.self)], successfulExitCodes:0...1,cancellation:cancellation).stdout.split(separator: 0)
            paths.formUnion(values.map { String(decoding: $0, as: UTF8.self) })
        }
        return paths
    }
    private func scanFinderSubmodules(authorizedRoot: URL, ancestors:Set<String>,cancellation:OperationCancellation?) async throws -> FinderSubmoduleScan {
        try cancellation?.check()
        var result = FinderSubmoduleScan()
        let canonical = root.resolvingSymlinksInPath().path
        guard !ancestors.contains(canonical) else { return result }
        let visited = ancestors.union([canonical])
        let paths: Set<String>
        do { paths = try configuredFinderSubmodulePaths(cancellation:cancellation) }
        catch { try cancellation?.check();result.failures[root.path] = error.localizedDescription; return result }
        for path in paths.sorted() {
            try cancellation?.check()
            var failurePath = root.appendingPathComponent(path).path
            do {
                let location = try restoreLocation(path)
                failurePath = location.path
                guard RepositoryAccessLease.pathIsContained(location, by: authorizedRoot) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) else { continue }
                guard directory.boolValue else { throw SubmoduleComparisonFailure.unsafeCheckout }
                let child = GitRepository(root: location, executable: executable)
                let discovered = try await child.discoverRoot(cancellation:cancellation)
                // An uninitialized directory inherits its parent's root; it is not a child repository.
                guard discovered.path == location.path, try await !child.isBare(cancellation:cancellation) else { continue }
                let metadata = try await child.finderMetadata(knownBare:false,cancellation:cancellation)
                guard metadata.submoduleParentRoot == root.path else { continue }
                let tracked = try await child.trackedPaths(cancellation:cancellation), changes = try await child.status(refreshIndex:false,cancellation:cancellation)
                var snapshot = FinderSnapshot.build(root: location, tracked: tracked, changes: changes)
                snapshot.indexFlags = try await child.finderIndexFlags(cancellation:cancellation)
                snapshot.repositories[location.path] = metadata
                result.snapshots.append(snapshot)
                let nested = try await child.scanFinderSubmodules(authorizedRoot:authorizedRoot,ancestors:visited,cancellation:cancellation)
                result.snapshots.append(contentsOf: nested.snapshots)
                result.failures.merge(nested.failures) { _, latest in latest }
            } catch { try cancellation?.check();result.failures[failurePath] = error.localizedDescription }
        }
        return result
    }
}

extension FinderSnapshot {
    /// Replace one refreshed tree, dropping stale removed/deinitialized child roots.
    /// Other opened repositories survive. Parent gitlink dirtiness contributes to a child-root badge.
    public mutating func replaceSubtree(root: URL, snapshots: [FinderSnapshot]) {
        let path = root.standardizedFileURL.path
        func contains(_ candidate: String) -> Bool { candidate == path || candidate.hasPrefix(path.hasSuffix("/") ? path : path + "/") }
        let incoming = Set(snapshots.flatMap(\.roots))
        let independent = roots.filter { $0 != path && contains($0) && repositories[$0]?.submoduleParentRoot == nil && !incoming.contains($0) }
        let preserved = independent.map { candidate -> FinderSnapshot in
            func belongs(_ value: String) -> Bool { value == candidate || value.hasPrefix(candidate + "/") }
            return FinderSnapshot(roots: roots.filter(belongs), states: states.filter { belongs($0.key) },
                repositories: repositories.filter { belongs($0.key) }, overlayEntries: overlayEntries?.filter { belongs($0.key) }, indexFlags: indexFlags?.filter { belongs($0.key) })
        }
        roots.removeAll(where: contains)
        states = states.filter { !contains($0.key) }
        repositories = repositories.filter { !contains($0.key) }
        overlayEntries = (overlayEntries ?? states).filter { !contains($0.key) }
        indexFlags = indexFlags?.filter { !contains($0.key) }
        let priority: [FileState: Int] = [.normal: 0, .ignored: 1, .untracked: 2, .added: 3, .deleted: 4, .modified: 5, .conflicted: 6]
        for snapshot in (snapshots + preserved).sorted(by: { ($0.roots.first?.count ?? 0) < ($1.roots.first?.count ?? 0) }) {
            let accepted = snapshot.roots.filter(contains)
            guard !accepted.isEmpty else { continue }
            for candidate in accepted where !roots.contains(candidate) { roots.append(candidate) }
            let rootStates = Dictionary(uniqueKeysWithValues: accepted.compactMap { candidate in states[candidate].map { (candidate, $0) } })
            states.merge(snapshot.states.filter { contains($0.key) }) { _, latest in latest }
            overlayEntries?.merge((snapshot.overlayEntries ?? snapshot.states).filter { contains($0.key) }) { _, latest in latest }
            if let flags = snapshot.indexFlags {
                if indexFlags == nil { indexFlags = [:] }; indexFlags?.merge(flags.filter { contains($0.key) }) { _, latest in latest }
            }
            for (candidate, state) in rootStates where snapshot.repositories[candidate]?.submoduleParentRoot != nil && priority[state, default: 0] > priority[states[candidate] ?? .normal, default: 0] { states[candidate] = state }
            repositories.merge(snapshot.repositories.filter { contains($0.key) }) { _, latest in latest }
        }
        updated = Date()
    }
}

/// One cancellable, non-writing cache collection, also suitable for a future service.
public struct FinderRepositoryCollection:Sendable {
    public let root:URL
    public let bare:Bool
    public let entries:[StatusEntry]
    public let branch:String
    public let conflictIsRebase:Bool
    public let submodules:Set<String>
    public let metadata:FinderRepositoryMetadata
    public let watchDirectories:[URL]
    public let snapshots:[FinderSnapshot]
    public let failures:[String:String]
}
extension GitRepository {
    public func collectFinderRepository(authorizedRoot:URL,cancellation:OperationCancellation? = nil,watchReady:(@Sendable ([URL]) async -> Void)? = nil) async throws -> FinderRepositoryCollection {
        try cancellation?.check()
        guard RepositoryAccessLease.pathIsContained(root,by:authorizedRoot) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let bare=try isBare(cancellation:cancellation)
        let watch=try finderWatchDirectories(cancellation:cancellation)
        await watchReady?(watch)
        try cancellation?.check()
        let entries=try bare ? [] : status(refreshIndex:false,cancellation:cancellation)
        let conflict=try bare ? false : conflictIsRebase(cancellation:cancellation)
        let submodules=try bare ? Set<String>() : submodulePaths(cancellation:cancellation)
        let branch=try self.branch(cancellation:cancellation)
        let tracked=try bare ? [] : trackedPaths(cancellation:cancellation)
        let metadata=try finderMetadata(knownBare:bare,cancellation:cancellation)
        var base=FinderSnapshot.build(root:root,tracked:tracked,changes:entries)
        base.indexFlags=try bare ? [:] : finderIndexFlags(cancellation:cancellation)
        base.repositories[root.path]=metadata
        let children=try await bare ? FinderSubmoduleScan() : finderSubmoduleSnapshots(authorizedRoot:authorizedRoot,cancellation:cancellation)
        try cancellation?.check()
        return FinderRepositoryCollection(root:root,bare:bare,entries:entries,branch:branch,conflictIsRebase:conflict,submodules:submodules,metadata:metadata,watchDirectories:watch,snapshots:[base]+children.snapshots,failures:children.failures)
    }
}

public enum FinderPublicationFailure:LocalizedError {
    case invalidUpdate,corruptStore,lockTimeout
    public var errorDescription:String? {
        switch self {
        case .invalidUpdate:return "The Finder cache update does not belong to its repository."
        case .corruptStore:return "The Finder cache store is invalid; its previous data was retained."
        case .lockTimeout:return "Another Finder cache writer did not release its lock."
        }
    }
}
public struct FinderPublicationTicket:Codable,Sendable {
    public let root:String
    fileprivate let store:UUID
    fileprivate let sequence:UInt64
}
public struct FinderPublicationResult:Sendable {
    public let published:Bool
    public let snapshot:FinderSnapshot
}
/// Serializes app/service updates. Tickets are ordering identities, never access grants.
public final class FinderSnapshotStore:@unchecked Sendable {
    public let url:URL
    private struct Control:Codable {
        var version=1
        var id=UUID()
        var counter:UInt64=0
        var sequences:[String:UInt64]=[:]
        var consumed:[String:UInt64]=[:]
    }
    public init(url:URL) { self.url=url }
    private var controlURL:URL { URL(fileURLWithPath:url.path+".writers") }
    private func read<T:Decodable>(_ type:T.Type,_ location:URL) throws -> T? {
        var attributes=stat()
        if lstat(location.path,&attributes) != 0 {
            if errno==ENOENT { return nil };throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
        }
        guard attributes.st_mode & S_IFMT == S_IFREG else { throw FinderPublicationFailure.corruptStore }
        do { return try JSONDecoder().decode(type,from:Data(contentsOf:location)) }
        catch { throw FinderPublicationFailure.corruptStore }
    }
    private func control() throws -> Control {
        let value=try read(Control.self,controlURL) ?? Control()
        guard value.version==1 else { throw FinderPublicationFailure.corruptStore };return value
    }
    private func save<T:Encodable>(_ value:T,_ location:URL) throws {
        try JSONEncoder().encode(value).write(to:location,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:location.path)
    }
    private func locked<T>(_ cancellation:OperationCancellation?,_ operation:() throws -> T) throws -> T {
        try cancellation?.check()
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let descriptor=Darwin.open(url.path+".lock",O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,mode_t(0o600))
        guard descriptor>=0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        let deadline=DispatchTime.now().uptimeNanoseconds+5_000_000_000
        while flock(descriptor,LOCK_EX | LOCK_NB) != 0 {
            let failure=errno
            try cancellation?.check()
            guard failure==EWOULDBLOCK || failure==EINTR else { throw POSIXError(POSIXErrorCode(rawValue:failure) ?? .EIO) }
            guard DispatchTime.now().uptimeNanoseconds<deadline else { throw FinderPublicationFailure.lockTimeout };usleep(10_000)
        }
        defer { flock(descriptor,LOCK_UN) }
        try cancellation?.check();return try operation()
    }
    private func path(_ root:URL) throws -> String {
        guard root.isFileURL,!root.path.utf8.contains(0) else { throw FinderPublicationFailure.invalidUpdate };return root.standardizedFileURL.path
    }
    public func begin(root:URL,cancellation:OperationCancellation? = nil) throws -> FinderPublicationTicket {
        let root=try path(root)
        return try locked(cancellation) {
            var state=try control()
            guard state.counter<UInt64.max else { throw FinderPublicationFailure.corruptStore }
            state.counter += 1;state.sequences[root]=state.counter;try save(state,controlURL)
            return FinderPublicationTicket(root:root,store:state.id,sequence:state.counter)
        }
    }
    public func publish(_ ticket:FinderPublicationTicket,snapshots:[FinderSnapshot],cancellation:OperationCancellation? = nil) throws -> FinderPublicationResult {
        func belongs(_ value:String) -> Bool {
            guard !value.utf8.contains(0),URL(fileURLWithPath:value).standardizedFileURL.path==value else { return false }
            return value==ticket.root || value.hasPrefix(ticket.root=="/" ? "/" : ticket.root+"/")
        }
        guard snapshots.contains(where: { $0.roots.contains(ticket.root) }),snapshots.allSatisfy({ snapshot in
            !snapshot.roots.isEmpty && snapshot.roots.allSatisfy(belongs) && snapshot.states.keys.allSatisfy(belongs) && snapshot.repositories.keys.allSatisfy(belongs) && (snapshot.overlayEntries ?? [:]).keys.allSatisfy(belongs) && (snapshot.indexFlags ?? [:]).keys.allSatisfy(belongs)
        }) else { throw FinderPublicationFailure.invalidUpdate }
        return try locked(cancellation) {
            var state=try control()
            var latest=try read(FinderSnapshot.self,url) ?? FinderSnapshot(roots:[],states:[:])
            func nested(_ lhs:String,_ rhs:String) -> Bool { lhs==rhs || lhs.hasPrefix(rhs=="/" ? "/" : rhs+"/") }
            let newerOverlap=state.sequences.contains { root,sequence in sequence>ticket.sequence && (nested(root,ticket.root) || nested(ticket.root,root)) }
            guard state.id==ticket.store,state.sequences[ticket.root]==ticket.sequence,!newerOverlap,(state.consumed[ticket.root] ?? 0)<ticket.sequence else { return FinderPublicationResult(published:false,snapshot:latest) }
            state.consumed[ticket.root]=ticket.sequence;try save(state,controlURL)
            latest.replaceSubtree(root:URL(fileURLWithPath:ticket.root,isDirectory:true),snapshots:snapshots)
            latest.updated=Date();try cancellation?.check();try save(latest,url)
            return FinderPublicationResult(published:true,snapshot:latest)
        }
    }
    /// Invalidate outstanding reads before removing only this repository's owned subtree.
    public func remove(root:URL,cancellation:OperationCancellation? = nil) throws -> FinderSnapshot {
        let root=try path(root)
        return try locked(cancellation) {
            var state=try control()
            guard state.counter<UInt64.max else { throw FinderPublicationFailure.corruptStore }
            var latest=try read(FinderSnapshot.self,url) ?? FinderSnapshot(roots:[],states:[:])
            state.counter += 1;state.sequences[root]=state.counter;state.consumed[root]=state.counter
            try cancellation?.check();try save(state,controlURL)
            latest.replaceSubtree(root:URL(fileURLWithPath:root,isDirectory:true),snapshots:[]);latest.updated=Date();try save(latest,url)
            return latest
        }
    }
}
