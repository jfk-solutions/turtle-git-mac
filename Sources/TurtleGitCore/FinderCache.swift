import Foundation
import Darwin
import Security

public enum FinderIntegration {
    public static let groupSuffix = "org.turtlegit.macos"
    /// macOS authorizes this namespace from the signature's developer team;
    /// unlike a registered group.* identifier it needs no profile group entry.
    public static func groupIdentifier(team: String) -> String? {
        guard team.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { return nil }
        return team + "." + groupSuffix
    }
    public static let group = (try? FinderCacheServiceIdentity.currentTeam()).flatMap(groupIdentifier) ?? groupSuffix
    public static let notification = "org.turtlegit.macos.statusChanged"
    public static var container: URL? {
        // Unsigned development builds cannot access the signed app's shared cache.
        // Merely constructing a group-container path can otherwise trigger protected
        // data access and stall startup on recent macOS versions.
        guard group != groupSuffix, let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
              groups.contains(group) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
    public static var snapshotURL: URL? { container?.appendingPathComponent("status.json") }
}
/// Presentation preferences are independent of repository status and app menus.
public struct FinderMenuSettings: Codable, Equatable, Sendable {
    public var showIcons: Bool
    public var language = AppLanguageChoice.system
    public var topLevelMask = FinderMenuEntry.defaultTopMask
    public var extendedOnlyMask = FinderMenuEntry.defaultExtendedMask
    public var hideForUnversioned = false
    public var excludedPaths = ""
    public var clipboardTransfers = true
    public init(showIcons: Bool = true) { self.showIcons = showIcons }
    private enum CodingKeys: String, CodingKey { case language, showIcons, topLevelMask, extendedOnlyMask, hideForUnversioned, excludedPaths, clipboardTransfers }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(showIcons: try values.decodeIfPresent(Bool.self, forKey: .showIcons) ?? true)
        let requested = try values.decodeIfPresent(String.self, forKey: .language) ?? AppLanguageChoice.system
        language = AppLanguageChoice.isAvailable(requested) ? requested : AppLanguageChoice.system
        topLevelMask = try values.decodeIfPresent(UInt64.self, forKey: .topLevelMask) ?? FinderMenuEntry.defaultTopMask
        extendedOnlyMask = try values.decodeIfPresent(UInt64.self, forKey: .extendedOnlyMask) ?? FinderMenuEntry.defaultExtendedMask
        hideForUnversioned = try values.decodeIfPresent(Bool.self, forKey: .hideForUnversioned) ?? false
        excludedPaths = try values.decodeIfPresent(String.self, forKey: .excludedPaths) ?? ""
        clipboardTransfers = try values.decodeIfPresent(Bool.self, forKey: .clipboardTransfers) ?? true
    }
    public static var sharedURL: URL? { FinderIntegration.container?.appendingPathComponent("menu-settings.json") }
    public static func from(defaults: UserDefaults = .standard) -> Self {
        var settings = defaults.data(forKey: "TurtleGit.FinderMenuSettings").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        settings.language = AppLanguageChoice.selected(in: defaults)
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
        AppLanguageChoice.isAvailable(language) && !excludedPaths.contains("\0") && excludedPaths.replacingOccurrences(of: "\r", with: "").split(separator: "\n").allSatisfy {
            $0.hasPrefix("/") || $0 == "~" || $0.hasPrefix("~/") || $0 == "~*" || $0 == "$HOME" || $0.hasPrefix("$HOME/") || $0 == "$HOME*"
        }
    }
    public func save(to defaults: UserDefaults = .standard) throws {
        guard valid else { throw GitConfigurationFailure.invalidValue }
        defaults.set(try JSONEncoder().encode(self), forKey: "TurtleGit.FinderMenuSettings")
    }
    public func visible(_ entry: FinderMenuEntry, extended: Bool) -> Bool { entry == .inaccessible || extended || extendedOnlyMask & entry.mask == 0 }
    public func firstLevel(_ entry: FinderMenuEntry) -> Bool { entry == .inaccessible || topLevelMask & entry.mask != 0 }
    public mutating func set(_ entry: FinderMenuEntry, checked: Bool, extendedOnly: Bool) {
        if extendedOnly { extendedOnlyMask = checked ? extendedOnlyMask | entry.mask : extendedOnlyMask & ~entry.mask }
        else { topLevelMask = checked ? topLevelMask | entry.mask : topLevelMask & ~entry.mask }
    }
    /// Finder preferences describe the account's folders, even when the app or
    /// extension runs in a sandbox whose Foundation home is its container.
    /// An explicit home is a matching input only; it grants no filesystem access.
    public func allowsPath(_ path: String, caseSensitive: Bool = true, home: URL = UserAccountPaths.homeDirectory) -> Bool {
        for line in excludedPaths.replacingOccurrences(of: "\r", with: "").split(separator: "\n") {
            var pattern = String(line)
            let prefix = pattern.hasSuffix("*"), descendants = pattern.hasSuffix("/")
            if prefix { pattern.removeLast() }
            if pattern == "~" || pattern.hasPrefix("~/") { pattern = home.path + pattern.dropFirst() }
            if pattern == "$HOME" || pattern.hasPrefix("$HOME/") { pattern = home.path + pattern.dropFirst(5) }
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
    /// Explicit macOS first-use registration is independent of source Git menu eligibility.
    public var registrationAction: RepositoryAction? { directory ? .registerRepository:nil }
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
        let owner = snapshot?.repositoryRoot(for: url)
        let known = owner != nil, knownRoot = owner.map { snapshot?.isRepositoryRoot(url,root:$0) == true } ?? false
        let state = snapshot?.cachedState(for: url)
        let versioned = knownRoot || known && state.map { [.normal, .modified, .added, .deleted, .conflicted].contains($0) } == true
        let ignored = !knownRoot && state == .ignored
        let fm = FileManager.default
        // Same loose-ref metadata checks as pinned GitAdminDir::IsBareRepo.
        func hasDirectory(_ name: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let bareLayout = ["HEAD", "config"].allSatisfy {
            fm.fileExists(atPath: url.appendingPathComponent($0).path)
        } && ["objects", "refs"].allSatisfy(hasDirectory)
        let bare = bareLayout && hasDirectory("refs/heads")
        // GitAdminDir::IsBareRepo reports invalidFormat for a repository-shaped
        // folder whose refs/heads is not a directory (including reftable).
        // Cache absence is only a menu heuristic; the app diagnoses afresh.
        let inaccessible = values == nil || (!known && (fm.fileExists(atPath: url.appendingPathComponent(".git").path) || bareLayout && !bare))
        return Self(directory: folder, versioned: versioned && !bare, folderInGit: known && !bare, bare: bare,
                    ignored: ignored, inaccessible: inaccessible, extended: extended)
    }
}

/// Cache-only source eligibility for Finder's New Worktree destination workflow.
/// The application revalidates the repository and authorizes both locations.
public enum FinderWorktreeContext {
    public static func sourceRequest(selection: [URL], snapshot: FinderSnapshot?) -> FinderRequest? {
        guard selection.count == 1, let snapshot,
              let source = FinderRequest.normalizedSelection(selection).first,
              source.path != "/", !source.path.contains("\0"),
              !source.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }),
              (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let root = snapshot.repositoryRoot(for: source), snapshot.isRepositoryRoot(source, root: root),
              FinderShellRules.allows(.worktreeCreate, flags: FinderShellRules.flags(paths: [source], snapshot: snapshot)) else { return nil }
        let request = FinderRequest(action: .worktreeCreate, paths: [source])
        return request.url == nil ? nil : request
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
        if bare { return [.fetch, .push, .log, .daemon, .revisionGraph, .reflog, .referenceBrowser, .repositoryBrowser, .export, .worktreeCreate, .worktreeList].contains(action) }
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

/// Collector provenance is separate from context-menu status and filesystem case.
public struct FinderOverlayPolicyMetadata: Codable, Equatable, Sendable {
    public let identity: String
    public let caseSensitive: Bool
    public init(identity: String, caseSensitive: Bool) {self.identity=identity;self.caseSensitive=caseSensitive}
}
public struct FinderSnapshot: Codable, Sendable {
    // A value copy may share already-built immutable queries. Any field that
    // changes path/owner eligibility detaches the copy's private query generation.
    var queries=FinderSnapshotQueries()
    public var roots: [String] { didSet { queries=FinderSnapshotQueries() } }
    public var states: GitPathMap<FileState> { didSet { queries=FinderSnapshotQueries() } }
    public var updated: Date
    public var liveRevision: String? = nil
    /// A transient durable-save diagnostic; never written into a snapshot.
    public var persistenceFailure: String? = nil
    public var repositories: GitPathMap<FinderRepositoryMetadata> { didSet { queries=FinderSnapshotQueries() } }
    public var overlayEntries: GitPathMap<FileState>? { didSet { queries=FinderSnapshotQueries() } }
    public var overlayPolicies: GitPathMap<FinderOverlayPolicyMetadata> = [:]
    public var indexFlags: GitPathMap<FinderIndexFlags>?
    public init(roots: [String], states: GitPathMap<FileState>, updated: Date = Date(), repositories: GitPathMap<FinderRepositoryMetadata> = [:], overlayEntries: GitPathMap<FileState>? = nil, indexFlags: GitPathMap<FinderIndexFlags>? = nil, overlayPolicies: GitPathMap<FinderOverlayPolicyMetadata> = [:]) {
        self.roots = roots; self.states = states; self.updated = updated; self.repositories = repositories
        self.overlayEntries = overlayEntries
        self.indexFlags = indexFlags; self.overlayPolicies = overlayPolicies
    }
    private enum CodingKeys: String, CodingKey { case roots, states, statesV2, updated, repositories, repositoriesV2, overlayEntries, overlayEntriesV2, indexFlags, indexFlagsV2, liveRevision, overlayPolicies }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roots = try values.decode([String].self, forKey: .roots)
        states = try values.decodeIfPresent(GitPathMap<FileState>.self, forKey: .statesV2)
            ?? GitPathMap(uniqueKeysWithValues: values.decode([String: FileState].self, forKey: .states).map { ($0.key,$0.value) })
        updated = try values.decode(Date.self, forKey: .updated)
        liveRevision = try values.decodeIfPresent(String.self,forKey:.liveRevision)
        overlayPolicies = try values.decodeIfPresent(GitPathMap<FinderOverlayPolicyMetadata>.self,forKey:.overlayPolicies) ?? [:]
        repositories = try values.decodeIfPresent(GitPathMap<FinderRepositoryMetadata>.self, forKey: .repositoriesV2)
            ?? GitPathMap(uniqueKeysWithValues: (values.decodeIfPresent([String: FinderRepositoryMetadata].self, forKey: .repositories) ?? [:]).map { ($0.key,$0.value) })
        overlayEntries = try values.decodeIfPresent(GitPathMap<FileState>.self, forKey: .overlayEntriesV2)
            ?? values.decodeIfPresent([String: FileState].self, forKey: .overlayEntries).map { GitPathMap(uniqueKeysWithValues: $0.map { ($0.key,$0.value) }) }
        if values.contains(.indexFlagsV2) {
            indexFlags = try values.decodeIfPresent(GitPathMap<FinderIndexFlags>.self,forKey:.indexFlagsV2)
        } else {
            indexFlags = try values.decodeIfPresent([String:FinderIndexFlags].self,forKey:.indexFlags).map {
                GitPathMap($0.map { ($0.key,$0.value) },uniquingKeysWith:{ _,last in last })
            }
        }
    }
    public func encode(to encoder:Encoder) throws {
        var values = encoder.container(keyedBy:CodingKeys.self)
        try values.encode(roots,forKey:.roots)
        // Each exact/legacy pair shares one byte ordering, then releases its
        // temporary records before the next potentially large map is prepared.
        // No ordering or projection is retained as authority across calls.
        func pair<Value:Codable>(_ map:GitPathMap<Value>,exact:CodingKeys,legacy:CodingKeys,
                                 combine:(Value,Value)->Value)throws {
            let ordered=map.orderedEncoding()
            try values.encode(ordered,forKey:exact)
            try values.encode(ordered.legacy(uniquingKeysWith:combine),forKey:legacy)
        }
        try pair(states,exact:.statesV2,legacy:.states) {Self.statePriority($0)>=Self.statePriority($1) ? $0:$1}
        try values.encode(updated,forKey:.updated)
        try values.encodeIfPresent(liveRevision,forKey:.liveRevision)
        try values.encode(overlayPolicies,forKey:.overlayPolicies)
        // Current peers use lossless records; older installed peers retain the
        // same deterministic canonical-collision projection during updates.
        try pair(repositories,exact:.repositoriesV2,legacy:.repositories) {first,_ in first}
        if let entries=overlayEntries {
            try pair(entries,exact:.overlayEntriesV2,legacy:.overlayEntries) {Self.statePriority($0)>=Self.statePriority($1) ? $0:$1}
        }
        if let flags=indexFlags {
            try pair(flags,exact:.indexFlagsV2,legacy:.indexFlags) {_,last in last}
        }
    }
    static func statePriority(_ state: FileState) -> Int {
        switch state {
        case .normal: return 0
        case .ignored: return 1
        case .untracked: return 2
        case .added: return 3
        case .deleted: return 4
        case .modified: return 5
        case .conflicted: return 6
        }
    }
    /// Shared cache names are lexical UTF-8 identities, not Swift's canonical
    /// String equality. The filesystem/grant layer separately validates access.
    static func contains(_ path: String, root: String) -> Bool {
        root == "/" ? path.hasPrefix("/") : FileTransferPaths.contains(path,in:root)
    }
    public func repositoryMetadata(for paths: [URL]) -> FinderRepositoryMetadata? {
        commonRepositoryRoot(for: paths).flatMap { repositories[$0] }
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
        var states: GitPathMap<FileState> = [:]
        for path in tracked { states[root.path + "/" + path] = .normal }
        let priority: [FileState: Int] = [.normal: 0, .ignored: 1, .untracked: 2, .added: 3, .deleted: 4, .modified: 5, .conflicted: 6]
        for change in changes {
            var path=change.path
            // Porcelain keeps a trailing directory marker for untracked nested
            // repositories and ignored directories, even with --untracked-files=all.
            // A Finder cache key names the directory itself. Remove exactly that
            // marker only from a valid relative ??/!! path; malformed paths remain
            // untouched so the publication authority validator still rejects them.
            if (change.state == .untracked || change.state == .ignored),path.utf8.last==47 {
                let candidate=String(decoding:path.utf8.dropLast(),as:UTF8.self)
                let components=candidate.utf8.split(separator:47,omittingEmptySubsequences:false)
                if !candidate.isEmpty,!candidate.utf8.contains(0),components.allSatisfy({!$0.isEmpty && !$0.elementsEqual([46]) && !$0.elementsEqual([46,46])}) {
                    path=candidate
                }
            }
            states[root.path + "/" + path] = change.state
        }
        let files = states
        for (path, state) in files {
            // GitStatus::AdjustFolderStatus treats added/deleted children as
            // modifications of their containing folders, preserving leaf state.
            let folderState: FileState = state == .added || state == .deleted ? .modified : state
            var parent = FileTransferPaths.fileURL(FinderSnapshot.parentPath(path))
            while Self.contains(parent.path,root:root.path) {
                if priority[folderState, default: 0] >= priority[states[parent.path] ?? .normal, default: 0] { states[parent.path] = folderState }
                if GitReferenceName.equal(parent.path,root.path) { break }
                parent = FileTransferPaths.fileURL(FinderSnapshot.parentPath(parent.path))
            }
        }
        states[root.path] = states[root.path] ?? .normal
        return FinderSnapshot(roots: [root.path], states: states, overlayEntries: files)
    }
    /// Cached eligibility only. The containing app revalidates tracked paths and
    /// the working tree before Git mutates anything.
    public func canRename(_ selection: [URL]) -> Bool {
        guard selection.count == 1, let url = selection.first, let root = repositoryRoot(for: url),
              !isRepositoryRoot(url,root:root) || repositories[root]?.submoduleParentRoot != nil else { return false }
        return hasFileState([.normal, .modified, .added, .conflicted], at: url, includingDescendants: true)
    }
    public func canRemove(_ selection: [URL]) -> Bool {
        guard commonFileOperationOwner(for: selection) != nil else { return false }
        return selection.allSatisfy { url in
            guard let root = repositoryRoot(for: url), !isRepositoryRoot(url,root:root) || repositories[root]?.submoduleParentRoot != nil else { return false }
            return hasFileState([.normal, .modified, .conflicted], at: url, includingDescendants: true)
        }
    }
    public func canRevert(_ selection: [URL]) -> Bool {
        guard commonRepositoryRoot(for: selection) != nil else { return false }
        return selection.contains { hasFileState([.modified, .added, .deleted, .conflicted], at: $0, includingDescendants: true) }
    }
    public func canResolve(_ selection: [URL]) -> Bool {
        guard commonRepositoryRoot(for: selection) != nil else { return false }
        return selection.contains { hasFileState([.conflicted], at: $0, includingDescendants: true) }
    }
    public func canIgnore(_ selection: [URL], deleting: Bool) -> Bool {
        guard let root = commonRepositoryRoot(for: selection), selection.allSatisfy({ $0.standardizedFileURL.path != root }) else { return false }
        return selection.allSatisfy { path in
            guard let state = cachedState(for: path) else { return false }
            return deleting ? [.normal, .modified, .added, .conflicted].contains(state) : [.untracked, .deleted].contains(state)
        }
    }
}

public enum RepositoryAction: String, CaseIterable, Identifiable, Sendable {
    case inaccessible, registerRepository
    case svnDCommit, svnRebase, svnFetch, svnIgnore
    case reviewPatch, daemon, lfs, lfsLocks, lfsLock, lfsUnlock, sendMail
    case synchronize, blame, previousDiff, logSubmodule, properties, settings, help, about
    case showCompare, cat, commitIsOnRefs, firstStartWizard, dropMove, dropCopyAdd, updateCheck, autotextTest, introduction
    case status, commit, add, revert, clean, submoduleAdd, submoduleUpdate, submoduleSync, log, revisionGraph, referenceBrowser, repositoryBrowser, export, bisect, bisectStart, bisectGood, bisectBad, bisectSkip, bisectReset, formatPatch, importPatch, requestPull, worktreeCreate, worktreeList, diff, diffLater, clearComparisonMark, pull, push, fetch, branch, tag, switchBranch, merge, mergeAbort, rebase, stash, stashApply, stashPop, stashList, reflog, clone, initialize, rename, move, pasteCopy, pasteMove, transferFiles, remove, removeKeep, ignore, ignoreMask, ignoreDelete, ignoreDeleteMask, resolve, resolveCurrent, resolveMine, resolveTheirs, reset, editConflict
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .registerRepository: return "Add to TurtleGit…"
        case .inaccessible: return "Inaccessible…"
        case .updateCheck: return "Check for Updates…"
        case .autotextTest: return "Autotext Tester…"
        case .introduction: return "Using TurtleGit for Mac…"
        case .dropMove: return "Move here"
        case .dropCopyAdd: return "Copy and add here"
        case .firstStartWizard: return "First Start Wizard…"
        case .showCompare: return "Compare revisions…"
        case .cat: return "Save historical file…"
        case .commitIsOnRefs: return "References commit is on…"
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
        case .move: return "Move…"
        case .pasteCopy: return "Paste Copy and Add…"
        case .pasteMove: return "Paste Move…"
        case .transferFiles: return "Transfer…"
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
    public var isApplicationUtility: Bool { [.settings, .help, .about, .firstStartWizard, .updateCheck, .autotextTest, .introduction].contains(self) }
    public var allowsEmptySelection: Bool { isApplicationUtility || self == .clone || self == .initialize }
    public var isMenuHeader: Bool { self == .lfs }
    public var isDropTransfer: Bool { self == .dropMove || self == .dropCopyAdd }
    public var isFileTransfer: Bool { self == .pasteCopy || self == .pasteMove || self == .transferFiles }
    public var isLFS: Bool { [.lfs, .lfsLocks, .lfsLock, .lfsUnlock].contains(self) }
    public var isIgnore: Bool { [.ignore, .ignoreMask, .ignoreDelete, .ignoreDeleteMask].contains(self) }
    public var ignoresByExtension: Bool { self == .ignoreMask || self == .ignoreDeleteMask }
    public var removesWhenIgnoring: Bool { self == .ignoreDelete || self == .ignoreDeleteMask }
    public var requiresValue: Bool { [.branch, .tag, .switchBranch, .merge, .rebase, .stash, .clone].contains(self) }
    public var requiresWorkingTree: Bool { [.dropMove, .dropCopyAdd, .svnDCommit, .svnRebase, .svnFetch, .svnIgnore, .lfs, .lfsLocks, .lfsLock, .lfsUnlock, .synchronize, .blame, .previousDiff, .logSubmodule, .status, .commit, .importPatch, .add, .revert, .clean, .submoduleAdd, .submoduleUpdate, .submoduleSync, .diff, .bisect, .bisectStart, .bisectGood, .bisectBad, .bisectSkip, .bisectReset, .pull, .switchBranch, .merge, .mergeAbort, .rebase, .stash, .stashApply, .stashPop, .stashList, .rename, .move, .pasteCopy, .pasteMove, .transferFiles, .remove, .removeKeep, .ignore, .ignoreMask, .ignoreDelete, .ignoreDeleteMask, .resolve, .resolveCurrent, .resolveMine, .resolveTheirs, .editConflict].contains(self) }
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
        .inaccessible: [.init([.inaccessible], [.inGit, .folderInGit, .bare]), .init([], []), .init([], []), .init([], [])],
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
        // Direct macOS source selection adapts Explorer's DropNewWorktree:
        // only a repository root (including bare), never a nested working folder.
        .worktreeCreate: [.init([.folder, .workingTreeRoot, .onlyOne], []), .init([.folder, .bare, .onlyOne], []), .init([], []), .init([], [])],
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
        let paths = FinderRequest.normalizedSelection(paths)
        var flags: FinderShellFlags = extended ? [.extended] : []
        if paths.count == 1 { flags.insert(.onlyOne) }
        if paths.count == 2 { flags.insert(.two) }
        if paths.contains(where: { ["patch", "diff"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }) { flags.insert(.patchFile) }
        // ContextMenu::Initialize stops fetching status after its representative
        // item. Later items still contribute cardinality/patch-file metadata.
        if let first = paths.first {
            let path = first
            // A tracked symbolic link is a Git file even when its target is a
            // directory. Inspect the selected leaf itself, never its target.
            let type = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.type] as? FileAttributeType
            let directory = type.map { $0 == .typeDirectory } ?? path.hasDirectoryPath
            if directory { flags.insert(.folder) }
            let root = snapshot?.repositoryRoot(for: path)
            if root == nil, directory, FinderCreationMenuContext.read(directory: path, snapshot: snapshot, extended: extended).inaccessible { flags.insert(.inaccessible) }
            let metadata = root.flatMap { snapshot?.repositories[$0] }
            let bare = metadata?.bare ?? root.map { FinderCreationMenuContext.read(directory: URL(fileURLWithPath: $0, isDirectory: true), snapshot: snapshot, extended: false).bare } ?? false
            if let root, !bare {
                flags.formUnion([.inGit, .inVersionedFolder])
                if directory { flags.insert(.folderInGit) }
                if snapshot?.isRepositoryRoot(path,root:root) == true {
                    flags.insert(.workingTreeRoot)
                    if directory && metadata?.submoduleParentRoot != nil { flags.insert(.submodule) }
                }
                if metadata?.hasGitSVN == true { flags.insert(.gitSVN) }
                if metadata?.hasStash != false { flags.insert(.stash) }
                if metadata?.hasSubmoduleConfig != false { flags.insert(.submoduleContainer) }
                if metadata?.mergeActive == true { flags.insert(.merge) }
                if metadata?.bisectActive == true { flags.insert(.bisect) }
            } else if let root, bare && snapshot?.isRepositoryRoot(path,root:root) == true { flags.insert(.bare) }
            switch snapshot?.cachedState(for: path) {
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
            if directory, root.map({snapshot?.isRepositoryRoot(path,root:$0) == true}) == true, !bare { flags.insert(.inGit); flags.remove(.ignored) }
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
    public var failures: GitPathMap<String> = [:]
    public init() {}
}

extension GitRepository {
    /// Foreground app refresh only. Finder consumes the resulting cache without Git.
    public func finderSubmoduleSnapshots(authorizedRoot: URL,additionalAuthorizedRoots:[URL]? = nil,cancellation:OperationCancellation? = nil,policy:FinderStatusPolicy? = nil) async throws -> FinderSubmoduleScan {
        try cancellation?.check()
        guard RepositoryAccessLease.pathIsContained(root, by: authorizedRoot) else {
            throw RepositoryAccessFailure.securityScopeUnavailable
        }
        return try await scanFinderSubmodules(authorizedRoot:authorizedRoot,additionalAuthorizedRoots:additionalAuthorizedRoots,ancestors:[],cancellation:cancellation,policy:policy)
    }
    private func configuredFinderSubmodulePaths(cancellation:OperationCancellation?) throws -> GitPathSet {
        let modules = root.appendingPathComponent(".gitmodules")
        guard FileManager.default.fileExists(atPath: modules.path) else { return [] }
        guard (try FileManager.default.attributesOfItem(atPath: modules.path)[.type] as? FileAttributeType) == .typeRegular else {
            throw SubmoduleComparisonFailure.unsafeCheckout
        }
        let names = try run(["config", "--no-includes", "--null", "--file", modules.path, "--name-only", "--get-regexp", "^submodule\\..*\\.path$"], successfulExitCodes:0...1,cancellation:cancellation).stdout.split(separator: 0)
        var paths = GitPathSet()
        for name in names {
            let values = try run(["config", "--no-includes", "--null", "--file", modules.path, "--get-all", String(decoding: name, as: UTF8.self)], successfulExitCodes:0...1,cancellation:cancellation).stdout.split(separator: 0)
            paths.formUnion(values.map { String(decoding: $0, as: UTF8.self) })
        }
        return paths
    }
    private func scanFinderSubmodules(authorizedRoot: URL, additionalAuthorizedRoots:[URL]?, ancestors:GitPathSet,cancellation:OperationCancellation?,policy:FinderStatusPolicy?,light:Bool = false) async throws -> FinderSubmoduleScan {
        try cancellation?.check()
        var result = FinderSubmoduleScan()
        let canonical = root.resolvingSymlinksInPath().path
        guard !ancestors.contains(canonical) else { return result }
        let visited = ancestors.union([canonical])
        let paths: GitPathSet
        do { paths = try configuredFinderSubmodulePaths(cancellation:cancellation) }
        catch { try cancellation?.check();result.failures[root.path] = error.localizedDescription; return result }
        for path in paths.sorted() {
            try cancellation?.check()
            var failurePath = root.path + "/" + path
            do {
                let location = try restoreLocation(path)
                failurePath = location.path
                guard RepositoryAccessLease.pathIsContained(location, by: authorizedRoot) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) else { continue }
                guard directory.boolValue else { throw SubmoduleComparisonFailure.unsafeCheckout }
                let child = GitRepository(root: location, executable: executable,askpass:askpass,diffDetection:diffDetection,libgit2Configuration:libgit2Configuration)
                let discovered = try await child.discoverRoot(cancellation:cancellation)
                // An uninitialized directory inherits its parent's root; it is not a child repository.
                guard GitReferenceName.equal(discovered.path,location.path), try await !child.isBare(cancellation:cancellation) else { continue }
                if let additionalAuthorizedRoots {
                    let scopes=[authorizedRoot]+additionalAuthorizedRoots
                    for directory in try await child.finderWatchDirectories(cancellation:cancellation) where !scopes.contains(where:{ RepositoryAccessLease.pathIsContained(directory,by:$0) }) {
                        throw RepositoryAccessFailure.repositoryRootOutsidePermission(directory.path)
                    }
                }
                let metadata = try await child.finderMetadata(knownBare:false,cancellation:cancellation)
                guard GitReferenceName.equal(root.path,metadata.submoduleParentRoot) else { continue }
                var snapshot:FinderSnapshot
                if light,let policy {
                    let overlay=try await child.collectFinderOverlay(policy:policy,cancellation:cancellation)
                    snapshot=FinderSnapshot(roots:[location.path],states:overlay.entries,repositories:[location.path:metadata])
                    snapshot.recordOverlay(policy:policy,caseSensitive:overlay.caseSensitive,entries:overlay.entries,indexFlags:overlay.indexFlags)
                } else {
                    let tracked = try await child.trackedPaths(cancellation:cancellation), changes = try await child.status(readPolicy:.automatic,cancellation:cancellation)
                    snapshot = FinderSnapshot.build(root: location, tracked: tracked, changes: changes)
                    snapshot.indexFlags = try await child.finderIndexFlags(cancellation:cancellation)
                    snapshot.repositories[location.path] = metadata
                    if let policy {let overlay=try await child.collectFinderOverlay(policy:policy,cancellation:cancellation);snapshot.recordOverlay(policy:policy,caseSensitive:overlay.caseSensitive,entries:overlay.entries,indexFlags:overlay.indexFlags)}
                }
                result.snapshots.append(snapshot)
                let nested = try await child.scanFinderSubmodules(authorizedRoot:authorizedRoot,additionalAuthorizedRoots:additionalAuthorizedRoots,ancestors:visited,cancellation:cancellation,policy:policy,light:light)
                result.snapshots.append(contentsOf: nested.snapshots)
                result.failures.merge(nested.failures) { _, latest in latest }
            } catch { try cancellation?.check();result.failures[failurePath] = error.localizedDescription }
        }
        return result
    }
}

extension FinderSnapshot {
    public static func readLive(from url: URL? = FinderIntegration.snapshotURL) -> FinderSnapshot? {
        guard let url else {return nil};return try? FinderSnapshotStore(url:url).readLive()
    }
    /// Extract restart data without expanding its saved repository authority.
    public mutating func recordOverlay(policy: FinderStatusPolicy, caseSensitive: Bool, entries: GitPathMap<FileState>, indexFlags: GitPathMap<FinderIndexFlags>) {
        self.overlayEntries=entries;self.indexFlags=indexFlags
        for root in roots {overlayPolicies[root] = .init(identity:policy.identity,caseSensitive:caseSensitive)}
    }
    public func overlayRepositoryRoot(for path:String) -> String? {exactRepositoryRoot(for:path)}
    public func overlayCaseSensitive(for path: String, fallback: Bool) -> Bool {
        guard let root=exactRepositoryRoot(for:path) else{return fallback}
        return overlayPolicies[root]?.caseSensitive ?? fallback
    }
    public func subtree(root: URL) -> FinderSnapshot {
        let path=FileTransferPaths.lexicalPath(root.path)
        func belongs(_ candidate:String)->Bool {Self.contains(candidate,root:path)}
        return FinderSnapshot(roots:roots.filter(belongs),states:states.filter {belongs($0.key)},updated:updated,
            repositories:repositories.filter {belongs($0.key)},overlayEntries:overlayEntries?.filter {belongs($0.key)},indexFlags:indexFlags?.filter {belongs($0.key)},overlayPolicies:overlayPolicies.filter {belongs($0.key)})
    }
    /// Replace one refreshed tree, dropping stale removed/deinitialized child roots.
    /// Other opened repositories survive. Parent gitlink dirtiness contributes to a child-root badge.
    public mutating func replaceSubtree(root: URL, snapshots: [FinderSnapshot]) {
        let path = FileTransferPaths.lexicalPath(root.path)
        func contains(_ candidate: String) -> Bool { Self.contains(candidate,root:path) }
        let incoming = GitPathSet(snapshots.flatMap(\.roots))
        let independent = roots.filter { !GitReferenceName.equal($0,path) && contains($0) && repositories[$0]?.submoduleParentRoot == nil && !incoming.contains($0) }
        let preserved = independent.map { candidate -> FinderSnapshot in
            func belongs(_ value: String) -> Bool { Self.contains(value,root:candidate) }
            return FinderSnapshot(roots: roots.filter(belongs), states: states.filter { belongs($0.key) },
                repositories: repositories.filter { belongs($0.key) }, overlayEntries: overlayEntries?.filter { belongs($0.key) }, indexFlags: indexFlags?.filter { belongs($0.key) },overlayPolicies:overlayPolicies.filter { belongs($0.key) })
        }
        roots.removeAll(where: contains)
        states = states.filter { !contains($0.key) }
        repositories = repositories.filter { !contains($0.key) }
        overlayEntries = (overlayEntries ?? states).filter { !contains($0.key) }
        indexFlags = indexFlags?.filter { !contains($0.key) }
        overlayPolicies = overlayPolicies.filter { !contains($0.key) }
        let priority: [FileState: Int] = [.normal: 0, .ignored: 1, .untracked: 2, .added: 3, .deleted: 4, .modified: 5, .conflicted: 6]
        for snapshot in (snapshots + preserved).sorted(by: { ($0.roots.first?.utf8.count ?? 0) < ($1.roots.first?.utf8.count ?? 0) }) {
            let accepted = snapshot.roots.filter(contains)
            guard !accepted.isEmpty else { continue }
            for candidate in accepted where !roots.contains(where:{ GitReferenceName.equal($0,candidate) }) { roots.append(candidate) }
            let rootStates = GitPathMap(uniqueKeysWithValues: accepted.compactMap { candidate in states[candidate].map { (candidate, $0) } })
            states.merge(snapshot.states.filter { contains($0.key) }) { _, latest in latest }
            overlayEntries?.merge((snapshot.overlayEntries ?? snapshot.states).filter { contains($0.key) }) { _, latest in latest }
            if let flags = snapshot.indexFlags {
                if indexFlags == nil { indexFlags = [:] }; indexFlags?.merge(flags.filter { contains($0.key) }) { _, latest in latest }
            }
            for (candidate, state) in rootStates where snapshot.repositories[candidate]?.submoduleParentRoot != nil && priority[state, default: 0] > priority[states[candidate] ?? .normal, default: 0] { states[candidate] = state }
            repositories.merge(snapshot.repositories.filter { contains($0.key) }) { _, latest in latest }
            overlayPolicies.merge(snapshot.overlayPolicies.filter { contains($0.key) }) { _, latest in latest }
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
    public let submodules:GitPathSet
    public let metadata:FinderRepositoryMetadata
    public let watchDirectories:[URL]
    public let snapshots:[FinderSnapshot]
    public let failures:GitPathMap<String>
}
extension GitRepository {
    public func collectFinderRepository(authorizedRoot:URL,additionalAuthorizedRoots:[URL]? = nil,cancellation:OperationCancellation? = nil,watchReady:(@Sendable ([URL]) async -> Void)? = nil,policy:FinderStatusPolicy? = nil) async throws -> FinderRepositoryCollection {
        try cancellation?.check()
        guard RepositoryAccessLease.pathIsContained(root,by:authorizedRoot) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let bare=try isBare(cancellation:cancellation)
        let watch=try finderWatchDirectories(cancellation:cancellation)
        if let additionalAuthorizedRoots {
            let scopes=[authorizedRoot]+additionalAuthorizedRoots
            for directory in watch where !scopes.contains(where:{ RepositoryAccessLease.pathIsContained(directory,by:$0) }) {
                throw RepositoryAccessFailure.repositoryRootOutsidePermission(directory.path)
            }
        }
        await watchReady?(watch)
        try cancellation?.check()
        let entries=try bare ? [] : status(readPolicy:.automatic,cancellation:cancellation)
        let conflict=try bare ? false : conflictIsRebase(cancellation:cancellation)
        let submodules=try bare ? GitPathSet() : GitPathSet(submodulePathNames(cancellation:cancellation).map(\.rawValue))
        let branch=try self.branch(cancellation:cancellation)
        let tracked=try bare ? [] : trackedPaths(cancellation:cancellation)
        let metadata=try finderMetadata(knownBare:bare,cancellation:cancellation)
        var base=FinderSnapshot.build(root:root,tracked:tracked,changes:entries)
        base.indexFlags=try bare ? [:] : finderIndexFlags(cancellation:cancellation)
        base.repositories[root.path]=metadata
        let overlayPolicy:FinderStatusPolicy?
        if let policy,(policy.cacheMode == .shell || policy.cacheMode == .shellExtended),policy.blockStatus,FinderStatusOperationLease.isBlocked(root:root) {overlayPolicy=nil} else {overlayPolicy=policy}
        if let policy=overlayPolicy {if bare {base.recordOverlay(policy:policy,caseSensitive:policy.caseSensitive,entries:[:],indexFlags:[:])} else {let overlay=try await collectFinderOverlay(policy:policy,cancellation:cancellation);base.recordOverlay(policy:policy,caseSensitive:overlay.caseSensitive,entries:overlay.entries,indexFlags:overlay.indexFlags)}}
        let children=try await bare ? FinderSubmoduleScan() : finderSubmoduleSnapshots(authorizedRoot:authorizedRoot,additionalAuthorizedRoots:additionalAuthorizedRoots,cancellation:cancellation,policy:overlayPolicy)
        try cancellation?.check()
        return FinderRepositoryCollection(root:root,bare:bare,entries:entries,branch:branch,conflictIsRebase:conflict,submodules:submodules,metadata:metadata,watchDirectories:watch,snapshots:[base]+children.snapshots,failures:children.failures)
    }
    /// Shell-service reads do not run full worktree status for badge callbacks.
    /// Context-menu facts are conservative fresh index/light states; each action
    /// revalidates its actual Git state before mutation in the containing app.
    public func collectFinderOverlayRepository(authorizedRoot:URL,additionalAuthorizedRoots:[URL]? = nil,policy:FinderStatusPolicy,cancellation:OperationCancellation? = nil,watchReady:(@Sendable ([URL]) async -> Void)? = nil) async throws -> FinderRepositoryCollection {
        try cancellation?.check()
        guard RepositoryAccessLease.pathIsContained(root,by:authorizedRoot) else {throw RepositoryAccessFailure.securityScopeUnavailable}
        let bare=try isBare(cancellation:cancellation),watch=try finderWatchDirectories(cancellation:cancellation)
        let scopes=[authorizedRoot]+(additionalAuthorizedRoots ?? [])
        guard watch.allSatisfy({directory in scopes.contains {RepositoryAccessLease.pathIsContained(directory,by:$0)}}) else {throw RepositoryAccessFailure.securityScopeUnavailable}
        await watchReady?(watch)
        let metadata=try finderMetadata(knownBare:bare,cancellation:cancellation)
        let overlay=try await bare ? FinderOverlayCollection(entries:[:],indexFlags:[:],caseSensitive:policy.caseSensitive,policy:policy):collectFinderOverlay(policy:policy,cancellation:cancellation)
        var base=FinderSnapshot(roots:[root.path],states:overlay.entries,repositories:[root.path:metadata]);base.states[root.path]=base.states[root.path] ?? .normal
        base.recordOverlay(policy:policy,caseSensitive:overlay.caseSensitive,entries:overlay.entries,indexFlags:overlay.indexFlags)
        let children=try await bare ? FinderSubmoduleScan():scanFinderSubmodules(authorizedRoot:authorizedRoot,additionalAuthorizedRoots:additionalAuthorizedRoots,ancestors:[],cancellation:cancellation,policy:policy,light:true)
        let branch=try branch(cancellation:cancellation),conflict=try bare ? false:conflictIsRebase(cancellation:cancellation)
        let submodules=try bare ? GitPathSet():GitPathSet(submodulePathNames(cancellation:cancellation).map(\.rawValue))
        return FinderRepositoryCollection(root:root,bare:bare,entries:[],branch:branch,conflictIsRebase:conflict,submodules:submodules,metadata:metadata,watchDirectories:watch,snapshots:[base]+children.snapshots,failures:children.failures)
    }

}

/// Source CacheSave controls durable restart data, independently of live badges.
public struct FinderCachePersistencePreferences: Codable, Equatable, Sendable {
    public static let notification = "org.turtlegit.macos.cachePersistenceChanged"
    public var cacheSave: Bool
    public init(cacheSave: Bool = true) { self.cacheSave = cacheSave }
    public static func from(defaults: UserDefaults = .standard) -> Self { .init(cacheSave: (defaults.object(forKey: "CacheSave") as? NSNumber)?.boolValue ?? true) }
    public func save(to defaults: UserDefaults = .standard) { defaults.set(cacheSave, forKey: "CacheSave") }
    public static func read(from url: URL? = FinderIntegration.snapshotURL) throws -> Self { guard let url else { return Self() }; return try FinderSnapshotStore(url: url).persistence() }
    @discardableResult public func write(to url: URL? = FinderIntegration.snapshotURL) throws -> Bool { guard let url else { return false }; try FinderSnapshotStore(url: url).setPersistence(self); return true }
}
public enum FinderPublicationFailure: LocalizedError {
    case invalidUpdate, corruptStore, lockTimeout, retiredSession, corruptWarmCacheReset, invalidWarmCache, policyChanged
    public var errorDescription: String? {
        switch self {
        case .corruptWarmCacheReset: return "The invalid saved Finder cache was discarded and rebuilt from current repository status."
        case .invalidWarmCache: return "Invalid saved Finder cache data for this repository was ignored. Current repository status will rebuild it."
        case .policyChanged: return "Finder status settings changed while this update was being collected."
        case .invalidUpdate: return "The Finder cache update does not belong to its repository."
        case .corruptStore: return "The Finder cache store is invalid; its previous data was retained."
        case .lockTimeout: return "Another Finder cache writer did not release its lock."
        case .retiredSession: return "The Finder cache publisher has ended its live session."
        }
    }
}
/// An advisory lease is held by an open file description, never by PID or age.
/// Close-on-exec prevents a Git/helper child from extending its owner's lifetime.
public final class FinderPublicationSession: @unchecked Sendable {
    public let id: UUID
    fileprivate let store: UUID, instance: UUID
    private let lock = NSLock()
    private let leaseURL: URL
    private var descriptor: Int32
    private var warning: String?
    public var persistenceFailure: String? { lock.lock(); defer { lock.unlock() }; return warning }
    fileprivate var active: Bool { lock.lock(); defer { lock.unlock() }; return descriptor >= 0 }
    fileprivate init(id: UUID, store: UUID, instance: UUID, descriptor: Int32, leaseURL: URL, warning: String?) { self.id=id;self.store=store;self.instance=instance;self.descriptor=descriptor;self.leaseURL=leaseURL;self.warning=warning }
    fileprivate func closeLease() { lock.lock();defer {lock.unlock()};if descriptor>=0 {flock(descriptor,LOCK_UN);Darwin.close(descriptor);descriptor = -1;_ = unlink(leaseURL.path)} }
    deinit { closeLease() }
}
public struct FinderPublicationTicket: Codable, Sendable {
    public let root: String
    public let persistenceFailure: String?
    fileprivate let store: UUID, instance: UUID, session: UUID
    fileprivate let sequence: UInt64
    public let policyIdentity: String?
}
public struct FinderPublicationResult: Sendable {
    public let published: Bool
    public let snapshot: FinderSnapshot
    public let persistenceFailure: String?
    /// True only when invalid restart JSON was replaced successfully. The
    /// retained notice is informational; failed persistence remains distinct.
    public let warmCacheRebuilt:Bool
    public init(published: Bool, snapshot: FinderSnapshot, persistenceFailure: String? = nil, warmCacheRebuilt:Bool=false) { self.published=published;self.snapshot=snapshot;self.persistenceFailure=persistenceFailure;self.warmCacheRebuilt=warmCacheRebuilt }
}
/// Serializes policy, publication tickets and lease ownership under one store
/// lock. Contributions remain separate so retiring one publisher reveals other
/// active publishers rather than deleting their roots or trusting restart data.
/// Internal operation diagnostics for focused cost/ownership regression checks;
/// these count actual work and never change cache authority or wire records.
struct FinderPublicationWorkCounters:Equatable,Sendable {
    var controlDecodes=0,rawDecodes=0,contributionEncodes=0,controlWrites=0,projections=0,localWaits=0
    var warmDecodes=0,warmWrites=0
}
public final class FinderSnapshotStore: @unchecked Sendable {
    public let url: URL
    public var warmURL: URL { URL(fileURLWithPath: url.path + ".warm") }
    private let instance = UUID(), sessionLock = NSRecursiveLock()
    private var owned: [UUID: FinderPublicationSession] = [:]
    private var implicit: FinderPublicationSession?
    private let liveReadLock=NSLock()
    private struct FileIdentity: Codable, Equatable {
        let device: dev_t, inode: ino_t, size: off_t
        let modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
    }
    private struct LiveReadCache {
        let control: FileIdentity?, raw: FileIdentity?, state: Control
        let ownerIDs: Set<UUID>
        var liveIDs: Set<UUID>, snapshot: FinderSnapshot
    }
    private var liveReadCache: LiveReadCache?
    private func identity(_ location: URL) throws -> FileIdentity? {
        var info=stat()
        if lstat(location.path,&info) != 0 {if errno==ENOENT{return nil};throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        guard info.st_mode & S_IFMT == S_IFREG else {throw FinderPublicationFailure.corruptStore}
        return FileIdentity(device:info.st_dev,inode:info.st_ino,size:info.st_size,
            modifiedSeconds:info.st_mtimespec.tv_sec,modifiedNanoseconds:info.st_mtimespec.tv_nsec,
            changedSeconds:info.st_ctimespec.tv_sec,changedNanoseconds:info.st_ctimespec.tv_nsec)
    }
    private final class Contribution: Codable {
        let root: String, session: UUID, sequence: UInt64
        /// Publication precedence stays fixed when an owned nested tree is
        /// removed. Its separate revision still invalidates readers' projections.
        let revision: UInt64
        let snapshots: [FinderSnapshot]
        let restored: Bool
        private let encodingLock=NSLock()
        private var encodedBody:Data?
        func encoding() throws -> (Data,Bool) {
            encodingLock.lock();defer{encodingLock.unlock()}
            if let encodedBody{return (encodedBody,false)}
            let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            let bytes=try encoder.encode(self);encodedBody=bytes;return (bytes,true)
        }
        init(root: String, session: UUID, sequence: UInt64, revision: UInt64? = nil, snapshots: [FinderSnapshot], restored: Bool) {
            self.root=root;self.session=session;self.sequence=sequence;self.revision=revision ?? sequence
            self.snapshots=snapshots;self.restored=restored
        }
        private enum CodingKeys: String, CodingKey {case root,session,sequence,revision,snapshots,restored}
        init(from decoder: Decoder) throws {
            let values=try decoder.container(keyedBy:CodingKeys.self)
            root=try values.decode(String.self,forKey:.root);session=try values.decode(UUID.self,forKey:.session)
            sequence=try values.decode(UInt64.self,forKey:.sequence)
            revision=try values.decodeIfPresent(UInt64.self,forKey:.revision) ?? sequence
            snapshots=try values.decode([FinderSnapshot].self,forKey:.snapshots);restored=try values.decode(Bool.self,forKey:.restored)
        }
    }
    /// A maintenance receipt is valid only for these immutable contributions
    /// and this exact regular archive file. Replacing/removing the archive or
    /// changing a contribution forces full maintenance; policy equality alone
    /// never authenticates optional restart data.
    private struct WarmMaintenance: Codable {
        let authority: [String]
        let identity: FileIdentity?
    }
    private struct Control: Codable {
        var version = 4
        var id = UUID()
        var counter: UInt64 = 0
        var sequences: GitPathMap<UInt64> = [:], consumed: GitPathMap<UInt64> = [:]
        var claims: GitPathMap<UUID> = [:]
        var contributions: [Contribution] = []
        var statusPolicyIdentity: String?
        var policy = FinderCachePersistencePreferences()
        var warmResetRequired = false
        var warmMaintenance: WarmMaintenance?
        var legacy = false
        init() {}
        private enum CodingKeys: String, CodingKey { case version,id,counter,sequences,consumed,claims,contributions,policy,warmResetRequired,statusPolicyIdentity,warmMaintenance }
        init(from decoder: Decoder) throws {
            let values=try decoder.container(keyedBy:CodingKeys.self),stored=try values.decode(Int.self,forKey:.version)
            guard (1...4).contains(stored) else {throw FinderPublicationFailure.corruptStore}
            legacy=stored<3;id=try values.decode(UUID.self,forKey:.id);counter=try values.decode(UInt64.self,forKey:.counter)
            if stored>=2 {sequences=try values.decode(GitPathMap<UInt64>.self,forKey:.sequences);consumed=try values.decode(GitPathMap<UInt64>.self,forKey:.consumed)}
            else {sequences=GitPathMap(uniqueKeysWithValues:try values.decode([String:UInt64].self,forKey:.sequences).map {($0.key,$0.value)});consumed=GitPathMap(uniqueKeysWithValues:try values.decode([String:UInt64].self,forKey:.consumed).map {($0.key,$0.value)})}
            if stored>=3 {claims=try values.decode(GitPathMap<UUID>.self,forKey:.claims);contributions=try values.decode([Contribution].self,forKey:.contributions);policy=try values.decode(FinderCachePersistencePreferences.self,forKey:.policy);warmResetRequired=try values.decodeIfPresent(Bool.self,forKey:.warmResetRequired) ?? false}
            statusPolicyIdentity=try values.decodeIfPresent(String.self,forKey:.statusPolicyIdentity)
            // A malformed optional optimization hint cannot damage live authority.
            warmMaintenance=try? values.decodeIfPresent(WarmMaintenance.self,forKey:.warmMaintenance)
        }
        func encode(to encoder: Encoder) throws {
            try encode(to:encoder,includePayload:true)
        }
        func encode(to encoder:Encoder,includePayload:Bool)throws {
            var values=encoder.container(keyedBy:CodingKeys.self)
            try values.encode(4,forKey:.version);try values.encodeIfPresent(statusPolicyIdentity,forKey:.statusPolicyIdentity);try values.encode(id,forKey:.id);try values.encode(counter,forKey:.counter);try values.encode(sequences,forKey:.sequences);try values.encode(consumed,forKey:.consumed);try values.encode(claims,forKey:.claims);try values.encode(includePayload ? contributions:[],forKey:.contributions);try values.encode(policy,forKey:.policy);try values.encode(warmResetRequired,forKey:.warmResetRequired);try values.encodeIfPresent(warmMaintenance,forKey:.warmMaintenance)
        }
    }
    /// Instances in one process share immutable decoded/encoded contributions.
    /// Every reuse is fenced by the actual atomic control-file identity; another
    /// process or noncooperating replacement always forces fresh validation.
    private final class Coordination:@unchecked Sendable {
        let writer=NSRecursiveLock(),cacheLock=NSLock()
        var control:(FileIdentity?,Control)?
        var raw:(FileIdentity?,FinderSnapshot?)?
        var warm:(FileIdentity?,FinderSnapshot?)?
        var projection:(String,[Contribution],FinderSnapshot)?
        var work=FinderPublicationWorkCounters()
    }
    private struct ControlHeader:Encodable {
        let state:Control
        func encode(to encoder:Encoder)throws{try state.encode(to:encoder,includePayload:false)}
    }
    private final class WeakCoordination {weak var value:Coordination?;init(_ value:Coordination){self.value=value}}
    private final class CoordinationRegistry:@unchecked Sendable {
        let lock=NSLock();var values:[GitReferenceName:WeakCoordination]=[:]
    }
    private static let coordinationRegistry=CoordinationRegistry()
    private static func coordination(for url:URL)->Coordination {
        let registry=coordinationRegistry;registry.lock.lock();defer{registry.lock.unlock()}
        let key=GitReferenceName(url.standardizedFileURL.resolvingSymlinksInPath().path)
        if let existing=registry.values[key]?.value{return existing}
        registry.values=registry.values.filter{$0.value.value != nil}
        let value=Coordination();registry.values[key]=WeakCoordination(value);return value
    }
    private let coordination:Coordination
    var publicationWorkCounters:FinderPublicationWorkCounters {
        coordination.cacheLock.lock();defer{coordination.cacheLock.unlock()};return coordination.work
    }
    public init(url: URL) { self.url=url;coordination=Self.coordination(for:url) }
    deinit { for session in owned.values {session.closeLease()} }
    private var controlURL: URL { URL(fileURLWithPath:url.path + ".writers") }
    private var leasesURL: URL { URL(fileURLWithPath:url.path + ".sessions",isDirectory:true) }
    private func leaseURL(_ id: UUID) -> URL { leasesURL.appendingPathComponent(id.uuidString + ".lease") }
    private func read<T: Decodable>(_ type: T.Type, _ location: URL) throws -> T? {
        var attributes=stat()
        if lstat(location.path,&attributes) != 0 {if errno==ENOENT{return nil};throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        guard attributes.st_mode & S_IFMT == S_IFREG,attributes.st_size>=0,attributes.st_size<=268435456 else {throw FinderPublicationFailure.corruptStore}
        do {return try JSONDecoder().decode(type,from:Data(contentsOf:location))} catch {throw FinderPublicationFailure.corruptStore}
    }
    private func readWarm(rebuildCorrupt: Bool = false) throws -> (snapshot: FinderSnapshot?, discarded: Bool) {
        var attributes=stat()
        if lstat(warmURL.path,&attributes) != 0 {if errno==ENOENT{return (nil,false)};throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        guard attributes.st_mode & S_IFMT == S_IFREG,attributes.st_size>=0,attributes.st_size<=268435456 else {throw FinderPublicationFailure.corruptStore}
        do {return (try checkedWarmSnapshot(),false)}
        catch {if rebuildCorrupt {return (nil,true)};throw FinderPublicationFailure.corruptStore}
    }
    /// Session startup must still report a damaged optional restart archive.
    /// Reuse only an unchanged, successfully decoded regular file; malformed
    /// reads and foreign replacements never acquire a memoized success.
    private func checkedWarmSnapshot()throws->FinderSnapshot? {
        for _ in 0..<3 {
            let before=try identity(warmURL)
            if let before {guard before.size>=0,before.size<=268435456 else{throw FinderPublicationFailure.corruptStore}}
            coordination.cacheLock.lock();let known=coordination.warm;coordination.cacheLock.unlock()
            if let known,known.0==before,before == (try identity(warmURL)){return known.1}
            let value=try read(FinderSnapshot.self,warmURL)
            coordination.cacheLock.lock();coordination.work.warmDecodes += 1;coordination.cacheLock.unlock()
            guard before == (try identity(warmURL)) else{continue}
            coordination.cacheLock.lock();coordination.warm=(before,value);coordination.cacheLock.unlock()
            return value
        }
        throw POSIXError(.EAGAIN)
    }
    private func save<T: Encodable>(_ value: T, _ location: URL) throws {
        var attributes=stat()
        if lstat(location.path,&attributes)==0 {guard attributes.st_mode & S_IFMT == S_IFREG else {throw FinderPublicationFailure.corruptStore}}
        else if errno != ENOENT {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        let bytes:Data=try autoreleasepool {
            let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            let bytes:Data
            if let state=value as? Control {
                let header=try encoder.encode(ControlHeader(state:state)),placeholder=Data("\"contributions\":[]".utf8)
                guard let range=header.range(of:placeholder) else{throw FinderPublicationFailure.corruptStore}
                var bodies:[Data]=[],total=header.count
                for item in state.contributions {
                    let (bytes,encoded)=try item.encoding()
                    if encoded {coordination.cacheLock.lock();coordination.work.contributionEncodes += 1;coordination.cacheLock.unlock()}
                    let extra=bytes.count+(bodies.isEmpty ? 0:1)
                    guard extra<=268435456-total else{throw FinderPublicationFailure.corruptStore}
                    total+=extra;bodies.append(bytes)
                }
                guard total<=268435456 else{throw FinderPublicationFailure.corruptStore}
                var combined=Data();combined.reserveCapacity(total)
                combined.append(header.prefix(range.upperBound-1))
                for (index,body) in bodies.enumerated(){if index>0{combined.append(44)};combined.append(body)}
                combined.append(header.suffix(from:range.upperBound-1));bytes=combined
            }else{bytes=try encoder.encode(value)}
            return bytes
        }
        guard bytes.count<=268435456 else {throw FinderPublicationFailure.corruptStore}
        if value is Control || value is FinderSnapshot {
            // Bind every memoized record to our actual staged inode. A foreign
            // replacement between rename and stat must not authenticate it.
            // Snapshots otherwise force the next queued writer to decode the
            // complete live/restart archive that this process just produced.
            let staged=location.deletingLastPathComponent().appendingPathComponent(".finder-control-"+UUID().uuidString)
            let fd=Darwin.open(staged.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,mode_t(0o600))
            guard fd>=0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
            defer{Darwin.close(fd);_ = unlink(staged.path)}
            // Snapshot writes previously forced0600 after Data.write(.atomic).
            // Preserve that policy independently of this process's umask,
            // applying it to our owned descriptor before the destination rename.
            if value is FinderSnapshot, fchmod(fd,mode_t(0o600)) != 0 {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
            try bytes.withUnsafeBytes {buffer in
                var offset=0
                while offset<buffer.count {
                    let count=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                    if count<0,errno==EINTR{continue}
                    guard count>0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
                    offset+=count
                }
            }
            var stagedInfo=stat();guard fstat(fd,&stagedInfo)==0 else{throw POSIXError(.EIO)}
            guard rename(staged.path,location.path)==0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
            let isWarm=GitReferenceName.equal(location.path,warmURL.path)
            coordination.cacheLock.lock()
            if value is Control {coordination.work.controlWrites += 1}
            else if isWarm {coordination.work.warmWrites += 1}
            coordination.cacheLock.unlock()
            let witness=try identity(location)
            if let witness,witness.device==stagedInfo.st_dev,witness.inode==stagedInfo.st_ino,witness.size==stagedInfo.st_size,
               witness.modifiedSeconds==stagedInfo.st_mtimespec.tv_sec,witness.modifiedNanoseconds==stagedInfo.st_mtimespec.tv_nsec {
                coordination.cacheLock.lock()
                if let state=value as? Control {coordination.control=(witness,state)}
                else if var snapshot=value as? FinderSnapshot {
                    // This diagnostic is deliberately absent from wire records.
                    // Cached values must have the same semantics as a decode.
                    snapshot.persistenceFailure=nil
                    if isWarm {coordination.warm=(witness,snapshot)}
                    else if GitReferenceName.equal(location.path,url.path) {coordination.raw=(witness,snapshot)}
                }
                coordination.cacheLock.unlock()
            }
        }else{
            try bytes.write(to:location,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:location.path)
            if GitReferenceName.equal(location.path,warmURL.path) {coordination.cacheLock.lock();coordination.work.warmWrites += 1;coordination.cacheLock.unlock()}
        }
    }
    /// Trust is scoped to this one locked operation (or atomic read attempt).
    /// Immutable contribution identities are retained strongly so allocator
    /// reuse cannot accidentally authenticate a different contribution.
    private final class ValidationContext {
        let cancellation: OperationCancellation?
        var canonicalPaths: GitPathMap<Bool> = [:]
        var contributions: [ObjectIdentifier: Contribution] = [:]
        var rawSnapshot: (identity:FileIdentity?, value:FinderSnapshot?)?
        private var visited = 0
        init(cancellation: OperationCancellation?) {self.cancellation=cancellation}
        func check() throws {try cancellation?.check()}
        func checkpoint() throws {
            visited += 1
            if visited & 255 == 0 {try check()}
        }
        func canonical(_ value:String) throws -> Bool {
            try checkpoint()
            if let known=canonicalPaths[value] {return known}
            let valid=value.hasPrefix("/") && !value.utf8.contains(0) && GitReferenceName.equal(FileTransferPaths.lexicalPath(value),value)
            canonicalPaths[value]=valid
            return valid
        }
    }
    private func locked<T>(_ cancellation: OperationCancellation?, validation supplied: ValidationContext? = nil, _ operation: (ValidationContext) throws -> T) throws -> T {
        let validation=supplied ?? ValidationContext(cancellation:cancellation)
        // Queue local owners before starting the cross-process deadline. A live
        // writer in this process is not a stale external lock; cancellation still
        // interrupts queued work without claiming or mutating the cache.
        var queued=false
        while !coordination.writer.try(){
            if !queued {coordination.cacheLock.lock();coordination.work.localWaits += 1;coordination.cacheLock.unlock();queued=true}
            try validation.check();usleep(10_000)
        }
        defer{coordination.writer.unlock()}
        try validation.check();try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let descriptor=Darwin.open(url.path + ".lock",O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,mode_t(0o600))
        guard descriptor>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)};defer {Darwin.close(descriptor)}
        let deadline=DispatchTime.now().uptimeNanoseconds+5_000_000_000
        while flock(descriptor,LOCK_EX | LOCK_NB) != 0 {let failure=errno;try validation.check();guard failure==EWOULDBLOCK || failure==EINTR else {throw POSIXError(POSIXErrorCode(rawValue:failure) ?? .EIO)};guard DispatchTime.now().uptimeNanoseconds<deadline else {throw FinderPublicationFailure.lockTimeout};usleep(10_000)}
        defer {flock(descriptor,LOCK_UN)};try validation.check();return try operation(validation)
    }
    private func path(_ root: URL) throws -> String {guard root.isFileURL,!root.path.utf8.contains(0) else {throw FinderPublicationFailure.invalidUpdate};return FileTransferPaths.lexicalPath(root.path)}
    /// Reuse only a successful read of the same unchanged regular file within
    /// one transaction. Noncooperating writers and arbitrary settings callbacks
    /// can replace files despite the advisory lock, so identity is checked on
    /// every use; failed/changed reads are never memoized.
    private func checkedRawSnapshot(validation:ValidationContext)throws->FinderSnapshot? {
        for _ in 0..<3 {
            try validation.check()
            let before=try identity(url)
            if let known=validation.rawSnapshot,known.identity==before {return known.value}
            coordination.cacheLock.lock();let shared=coordination.raw;coordination.cacheLock.unlock()
            if let shared,shared.0==before,before == (try identity(url)) {
                validation.rawSnapshot=(before,shared.1);return shared.1
            }
            let value=try read(FinderSnapshot.self,url)
            coordination.cacheLock.lock();coordination.work.rawDecodes += 1;coordination.cacheLock.unlock()
            guard before == (try identity(url)) else {continue}
            validation.rawSnapshot=(before,value)
            coordination.cacheLock.lock();coordination.raw=(before,value);coordination.cacheLock.unlock()
            return value
        }
        throw POSIXError(.EAGAIN)
    }
    private func control(validation: ValidationContext) throws -> Control {
        let before=try identity(controlURL)
        coordination.cacheLock.lock();let cached=coordination.control;coordination.cacheLock.unlock()
        if let cached,cached.0==before,before == (try identity(controlURL)) {
            // Payload objects are immutable and were namespace-validated for
            // precisely this file identity. Mutable counters are still checked.
            for item in cached.1.contributions {validation.contributions[ObjectIdentifier(item)]=item}
            try checkControl(cached.1,validation:validation);return cached.1
        }
        var value=try read(Control.self,controlURL) ?? Control()
        coordination.cacheLock.lock();coordination.work.controlDecodes += 1;coordination.cacheLock.unlock()
        if before==nil,try checkedRawSnapshot(validation:validation) != nil {value.legacy=true}
        try checkControl(value,validation:validation)
        guard before == (try identity(controlURL)) else{throw POSIXError(.EAGAIN)}
        // Do not memoize a missing control: a new UUID belongs to its first
        // committed writer, never to an uncommitted read-only observation.
        if before != nil {coordination.cacheLock.lock();coordination.control=(before,value);coordination.cacheLock.unlock()}
        return value
    }
    private func checkControl(_ value: Control, validation: ValidationContext) throws {
        try validation.check()
        guard value.contributions.count<=4096,value.claims.count<=16384,value.sequences.count<=65536,value.consumed.count<=65536 else {throw FinderPublicationFailure.corruptStore}
        for item in value.contributions {
            try validation.checkpoint()
            let identity=ObjectIdentifier(item)
            let alreadyChecked=validation.contributions[identity] != nil
            if !alreadyChecked {try validate(root:item.root,snapshots:item.snapshots,validation:validation)}
            // Counter changes remain subject to validation even for an already
            // checked immutable payload retained within this operation.
            guard item.sequence<=value.counter,item.revision<=value.counter else {throw FinderPublicationFailure.corruptStore}
            if !alreadyChecked {validation.contributions[identity]=item}
        }
        try validation.check()
    }
    private func validate(root: String, snapshots: [FinderSnapshot], validation: ValidationContext) throws {
        try validation.check()
        // The same path normally appears in several snapshot dictionaries.
        // Membership is root-specific; canonical spelling is not. Both caches
        // use byte-exact Git paths rather than Swift's canonical String equality.
        var membership: GitPathMap<Bool> = [:]
        func belongs(_ value: String) throws -> Bool {
            try validation.checkpoint()
            if let known=membership[value] {return known}
            let valid=try validation.canonical(value) && FinderSnapshot.contains(value,root:root)
            membership[value]=valid
            return valid
        }
        guard try belongs(root),snapshots.contains(where:{$0.roots.contains(where:{GitReferenceName.equal($0,root)})}) else {throw FinderPublicationFailure.invalidUpdate}
        for snapshot in snapshots {
            guard !snapshot.roots.isEmpty else {throw FinderPublicationFailure.invalidUpdate}
            for name in snapshot.roots {guard try belongs(name) else {throw FinderPublicationFailure.invalidUpdate}}
            for name in snapshot.states.keys {guard try belongs(name) else {throw FinderPublicationFailure.invalidUpdate}}
            for name in snapshot.repositories.keys {guard try belongs(name) else {throw FinderPublicationFailure.invalidUpdate}}
            for name in (snapshot.overlayEntries ?? [:]).keys {guard try belongs(name) else {throw FinderPublicationFailure.invalidUpdate}}
            for name in (snapshot.indexFlags ?? [:]).keys {guard try belongs(name) else {throw FinderPublicationFailure.invalidUpdate}}
            for (name,policy) in snapshot.overlayPolicies {
                guard try belongs(name),policy.identity.utf8.count<=512,!policy.identity.utf8.contains(0) else {throw FinderPublicationFailure.invalidUpdate}
            }
        }
        try validation.check()
    }
    private func alive(_ id: UUID) throws -> Bool {
        let location=leaseURL(id);var attributes=stat()
        if lstat(location.path,&attributes) != 0 {if errno==ENOENT{return false};throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        guard attributes.st_mode & S_IFMT == S_IFREG,attributes.st_uid==geteuid() else {throw FinderPublicationFailure.corruptStore}
        let descriptor=Darwin.open(location.path,O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor>=0 else {if errno==ENOENT{return false};throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)};defer {Darwin.close(descriptor)}
        if flock(descriptor,LOCK_EX | LOCK_NB)==0 {flock(descriptor,LOCK_UN);return false}
        guard errno==EWOULDBLOCK else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)};return true
    }
    private func live(_ state: Control) throws -> [Contribution] {
        var checked: [UUID: Bool] = [:]
        return try state.contributions.filter { item in
            if let valid=checked[item.session] {return valid};let valid=try alive(item.session);checked[item.session]=valid;return valid
        }
    }
    private func projection(_ contributions: [Contribution], id: UUID, statusPolicyIdentity: String?) -> FinderSnapshot {
        let sorted=contributions.sorted {a,b in a.root.utf8.count==b.root.utf8.count ? a.sequence<b.sequence : a.root.utf8.count<b.root.utf8.count}
        let revisions=sorted.map {Data($0.root.utf8).base64EncodedString()+":"+$0.session.uuidString+":"+String($0.sequence)+":"+String($0.revision)}
        let revision=id.uuidString+"/"+(statusPolicyIdentity ?? "legacy")+"/"+revisions.joined(separator:"/")
        coordination.cacheLock.lock();let cached=coordination.projection;coordination.cacheLock.unlock()
        if let cached,cached.0==revision,cached.1.count==sorted.count,zip(cached.1,sorted).allSatisfy({pair in pair.0 === pair.1}) {return cached.2}
        var result=FinderSnapshot(roots:[],states:[:],updated:Date(timeIntervalSince1970:0))
        coordination.cacheLock.lock();coordination.work.projections += 1;coordination.cacheLock.unlock()
        for item in sorted {
            result.replaceSubtree(root:FileTransferPaths.fileURL(item.root),snapshots:item.snapshots)
        }
        if let identity=statusPolicyIdentity {
            let accepted=GitPathSet(result.overlayPolicies.filter {$0.value.identity==identity}.keys)
            result.overlayEntries=(result.overlayEntries ?? [:]).filter {entry in result.exactRepositoryRoot(for:entry.key).map {accepted.contains($0)} ?? false}
            result.indexFlags=result.indexFlags?.filter {entry in result.exactRepositoryRoot(for:entry.key).map {accepted.contains($0)} ?? false}
            result.overlayPolicies=result.overlayPolicies.filter {$0.value.identity==identity}
        }
        result.updated=contributions.flatMap(\.snapshots).map(\.updated).max() ?? Date(timeIntervalSince1970:0)
        result.liveRevision=revision
        coordination.cacheLock.lock();coordination.projection=(revision,sorted,result);coordination.cacheLock.unlock()
        return result
    }
    private func writeLive(_ state: inout Control, validation: ValidationContext) throws -> FinderSnapshot {
        // Read the legacy projection for corruption/type checks, but never use
        // its roots as live authority. Only lease-backed contributions count.
        _ = try checkedRawSnapshot(validation:validation)
        state.contributions=try live(state)
        try checkControl(state,validation:validation)
        let result=projection(state.contributions,id:state.id,statusPolicyIdentity:state.statusPolicyIdentity)
        try validation.check()
        try save(result,url);state.legacy=false;try save(state,controlURL);return result
    }
    private func warmWarning(_ operation: () throws -> Void) -> String? {do {try operation();return nil} catch {return error.localizedDescription}}
    private func mergeWarm(root: String, snapshots: [FinderSnapshot], enabled: Bool, rebuildFrom:FinderSnapshot?=nil) throws {
        try mergeWarm([(root,snapshots)],enabled:enabled,rebuildFrom:rebuildFrom)
    }
    private func sameWarmContents(_ lhs:FinderSnapshot,_ rhs:FinderSnapshot)->Bool {
        let left=lhs.roots.sorted {$0.utf8.lexicographicallyPrecedes($1.utf8)},right=rhs.roots.sorted {$0.utf8.lexicographicallyPrecedes($1.utf8)}
        // Synthesized metadata equality normalizes String values. Parent roots
        // are filesystem identities and must also retain their exact UTF-8.
        let parentsMatch=lhs.repositories.allSatisfy { path,value in
            guard let other=rhs.repositories[path] else {return false}
            switch (value.submoduleParentRoot,other.submoduleParentRoot) {
            case (nil,nil):return true
            case let (a?,b?):return GitReferenceName.equal(a,b)
            default:return false
            }
        }
        return left.elementsEqual(right,by:{GitReferenceName.equal($0,$1)}) && lhs.states==rhs.states && lhs.repositories==rhs.repositories && parentsMatch &&
            lhs.overlayEntries==rhs.overlayEntries && lhs.indexFlags==rhs.indexFlags && lhs.overlayPolicies==rhs.overlayPolicies
    }
    /// Retirement has no new scan timestamp to publish. Merge its complete root
    /// cohort once, and preserve the existing archive inode when exact contents
    /// already match. Ordinary fresh publications retain their timestamp policy.
    private func mergeWarm(_ updates:[(String,[FinderSnapshot])],enabled:Bool,rebuildFrom:FinderSnapshot?=nil,retiring:Bool=false)throws {
        guard enabled,!updates.isEmpty else {return}
        let recovered=try readWarm(rebuildCorrupt:true)
        // A successful live publication is already namespace/lease validated.
        // Retain those live siblings when unreadable restart JSON has no usable
        // archive to merge, instead of reducing it to only this refreshed root.
        var warm=recovered.snapshot ?? rebuildFrom ?? FinderSnapshot(roots:[],states:[:]);warm.liveRevision=nil;warm.persistenceFailure=nil
        for (root,snapshots) in updates {warm.replaceSubtree(root:FileTransferPaths.fileURL(root),snapshots:snapshots)}
        if retiring,let previous=recovered.snapshot,sameWarmContents(previous,warm){return}
        try save(warm,warmURL)
        if recovered.discarded {throw FinderPublicationFailure.corruptWarmCacheReset}
    }
    private func migrateWarm(_ state: Control, validation:ValidationContext) throws {
        guard state.policy.cacheSave else {return}
        let existing=try checkedWarmSnapshot()
        guard state.legacy,existing==nil,let legacy=try checkedRawSnapshot(validation:validation) else {return}
        var warm=legacy;warm.liveRevision=nil;warm.persistenceFailure=nil;try save(warm,warmURL)
    }
    private func owner(_ session: FinderPublicationSession, state: Control) throws {
        guard session.instance==instance,session.store==state.id,session.active,try alive(session.id) else {throw FinderPublicationFailure.retiredSession}
    }
    public func startSession(cancellation: OperationCancellation? = nil) throws -> FinderPublicationSession {
        sessionLock.lock();defer {sessionLock.unlock()}
        return try locked(cancellation) { validation in
            var state=try control(validation:validation);let raw=try checkedRawSnapshot(validation:validation)
            let warning=warmWarning {try migrateWarm(state,validation:validation)}
            try FileManager.default.createDirectory(at:leasesURL,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            var attributes=stat();guard lstat(leasesURL.path,&attributes)==0,attributes.st_mode & S_IFMT == S_IFDIR else {throw FinderPublicationFailure.corruptStore}
            let id=UUID(),location=leaseURL(id),descriptor=Darwin.open(location.path,O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,mode_t(0o600))
            guard descriptor>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
            guard flock(descriptor,LOCK_EX | LOCK_NB)==0 else {let code=errno;Darwin.close(descriptor);throw POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)}
            let session=FinderPublicationSession(id:id,store:state.id,instance:instance,descriptor:descriptor,leaseURL:location,warning:warning)
            do {
                let retained=try live(state)
                if state.legacy || raw?.liveRevision == nil || retained.count != state.contributions.count {
                    state.contributions=retained;_ = try writeLive(&state,validation:validation)
                }
                try validation.check();owned[id]=session;return session
            } catch {session.closeLease();throw error}
        }
    }
    private func defaultSession(cancellation: OperationCancellation?) throws -> FinderPublicationSession {
        sessionLock.lock();defer {sessionLock.unlock()};if let implicit,implicit.active{return implicit}
        let session=try startSession(cancellation:cancellation);implicit=session;return session
    }
    public func persistence(cancellation: OperationCancellation? = nil) throws -> FinderCachePersistencePreferences {try locked(cancellation) { validation in try control(validation:validation).policy}}
    private func warmAuthority(_ contributions: [Contribution]) -> [String] {
        contributions.map { item in
            let fields=[Data(item.root.utf8).base64EncodedString(),item.session.uuidString,
                        String(item.sequence),String(item.revision),item.restored ? "1":"0"]
            return fields.joined(separator:":")
        }.sorted()
    }
    private func warmIsCurrent(_ state: Control, contributions: [Contribution]) throws -> Bool {
        guard state.policy.cacheSave,!state.legacy,!state.warmResetRequired,
              let receipt=state.warmMaintenance else{return false}
        guard receipt.authority == warmAuthority(contributions) else {return false}
        return receipt.identity == (try identity(warmURL))
    }
    private func warmReceipt(_ contributions: [Contribution]) throws -> WarmMaintenance {
        WarmMaintenance(authority:warmAuthority(contributions),identity:try identity(warmURL))
    }
    public func setPersistence(_ preferences: FinderCachePersistencePreferences, cancellation: OperationCancellation? = nil) throws {
        try locked(cancellation) { validation in
            var state=try control(validation:validation);_ = try checkedRawSnapshot(validation:validation)
            func clearWarm() throws {
                var attributes=stat()
                if lstat(warmURL.path,&attributes)==0 {guard attributes.st_mode & S_IFMT == S_IFREG else {throw FinderPublicationFailure.corruptStore};try FileManager.default.removeItem(at:warmURL)}
                else if errno != ENOENT {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
            }
            if !preferences.cacheSave {
                // An already disabled, fully cleaned store needs no rewrite.
                // An unexpected archive or a durable failed-unlink fence must
                // still be cleaned, even when the requested policy is unchanged.
                if state.policy==preferences,!state.legacy,!state.warmResetRequired {
                    // A nonregular/unreadable path still needs the durable
                    // invalidation fence before cleanup reports its failure.
                    do {if try identity(warmURL)==nil {return}} catch {}
                }
                // This durable fence precedes deletion, including deletion failure.
                state.policy=preferences;state.legacy=false;state.warmResetRequired=true;state.warmMaintenance=nil
                try save(state,controlURL)
                try clearWarm();state.warmResetRequired=false;try save(state,controlURL)
            } else {
                // Capture the actual lease cohort once. The receipt must name
                // precisely the projection merged below, even if a process dies
                // while optional archive I/O is in progress.
                let liveContributions=try live(state)
                if state.policy==preferences,try warmIsCurrent(state,contributions:liveContributions) {return}
                // Never re-enable an archive whose earlier invalidation failed.
                if state.warmResetRequired {try clearWarm();state.warmResetRequired=false;state.warmMaintenance=nil;try save(state,controlURL)}
                let recovered=try readWarm(rebuildCorrupt:true)
                var warm=recovered.snapshot
                if warm==nil,state.legacy {warm=try checkedRawSnapshot(validation:validation)}
                let contributions=liveContributions.sorted {a,b in a.root.utf8.count==b.root.utf8.count ? a.sequence<b.sequence : a.root.utf8.count<b.root.utf8.count}
                // Decode once and publish once, rather than re-reading and
                // rewriting the entire archive once per live repository.
                if warm != nil || !contributions.isEmpty || recovered.discarded {
                    var merged=warm ?? FinderSnapshot(roots:[],states:[:])
                    merged.liveRevision=nil;merged.persistenceFailure=nil
                    for item in contributions {
                        try validation.check()
                        merged.replaceSubtree(root:FileTransferPaths.fileURL(item.root),snapshots:item.snapshots)
                    }
                    try validation.check();try save(merged,warmURL)
                }
                state.policy=preferences;state.legacy=false
                try checkControl(state,validation:validation)
                state.warmMaintenance=try warmReceipt(liveContributions)
                try save(state,controlURL)
                if recovered.discarded {throw FinderPublicationFailure.corruptWarmCacheReset}
            }
        }
    }
    /// Atomic file reads and lease probes never wait for a writer's store lock.
    /// A retained store (or FinderSnapshotLiveReader) reuses decoding/projection
    /// until an atomic file identity or the set of live lease owners changes.
    /// Finder's synchronous callbacks never wait for an in-flight decoder and
    /// never rebuild a projection. Nil means the caller must clear status until
    /// an owned asynchronous read completes; it does not authorize stale data.
    public func cachedLiveIfCurrent() -> FinderSnapshot? {
        guard liveReadLock.try() else { return nil }
        defer { liveReadLock.unlock() }
        do {
            guard let cached = liveReadCache,
                  cached.control == (try identity(controlURL)), cached.raw == (try identity(url)) else { return nil }
            var current = Set<UUID>()
            for id in cached.ownerIDs { if try alive(id) { current.insert(id) } }
            guard current == cached.liveIDs,
                  cached.control == (try identity(controlURL)), cached.raw == (try identity(url)) else { return nil }
            return cached.snapshot
        } catch { return nil }
    }
    public func readLive(cancellation: OperationCancellation? = nil) throws -> FinderSnapshot {
        try cancellation?.check();liveReadLock.lock();defer {liveReadLock.unlock()}
        do {
            for _ in 0..<3 {
                let controlIdentity=try identity(controlURL),rawIdentity=try identity(url)
                if var cached=liveReadCache,cached.control==controlIdentity,cached.raw==rawIdentity {
                    var current=Set<UUID>()
                    for id in cached.ownerIDs {if try alive(id) {current.insert(id)}}
                    if current != cached.liveIDs {
                        cached.snapshot=projection(cached.state.contributions.filter {current.contains($0.session)},id:cached.state.id,statusPolicyIdentity:cached.state.statusPolicyIdentity)
                        cached.liveIDs=current;liveReadCache=cached
                    }
                    return cached.snapshot
                }
                let validation=ValidationContext(cancellation:cancellation)
                let state=try control(validation:validation),raw=try checkedRawSnapshot(validation:validation)
                guard controlIdentity == (try identity(controlURL)),rawIdentity == (try identity(url)) else {continue}
                let active: [Contribution]
                if !state.legacy,raw?.liveRevision != nil {active=try live(state)} else {active=[]}
                let snapshot: FinderSnapshot
                if state.legacy || raw?.liveRevision == nil {snapshot=FinderSnapshot(roots:[],states:[:],updated:Date(timeIntervalSince1970:0))}
                else {snapshot=projection(active,id:state.id,statusPolicyIdentity:state.statusPolicyIdentity)}
                liveReadCache=LiveReadCache(control:controlIdentity,raw:rawIdentity,state:state,ownerIDs:Set(state.contributions.map(\.session)),liveIDs:Set(active.map(\.session)),snapshot:snapshot)
                return snapshot
            }
            throw POSIXError(.EAGAIN)
        } catch {liveReadCache=nil;throw error}
    }
    /// Publishing settings fences in-flight readers without erasing context-menu
    /// snapshots, watched roots, permissions or live publisher leases.
    /// Read both settings records, fence readers, and publish the owned record
    /// under one cross-process writer lock. A second app cannot interleave its
    /// other-record merge or roll back a later successful writer's setting.
    public func configureStatusPolicy(policy:() throws -> FinderStatusPolicy,publish:() throws -> Void,rollback:() throws -> Void,cancellation:OperationCancellation? = nil) throws {
        try locked(cancellation) { validation in
            var value=try control(validation:validation);let previous=value.statusPolicyIdentity,next=try policy()
            value.statusPolicyIdentity=next.identity;_ = try writeLive(&value,validation:validation)
            do {try publish()}
            catch {
                let failure=error
                do {try rollback();value.statusPolicyIdentity=previous;_ = try writeLive(&value,validation:validation)}
                catch {throw NSError(domain:"TurtleGit.FinderStatusPolicy",code:1,userInfo:[NSLocalizedDescriptionKey:failure.localizedDescription+"\nSettings rollback: "+error.localizedDescription])}
                throw failure
            }
        }
    }
    public func setStatusPolicy(_ policy: FinderStatusPolicy, cancellation: OperationCancellation? = nil) throws {
        try locked(cancellation) { validation in var value=try control(validation:validation);value.statusPolicyIdentity=policy.identity;_ = try writeLive(&value,validation:validation)}
    }
    public func fence(root: URL, cancellation: OperationCancellation? = nil) throws {
        let name=try path(root)
        try locked(cancellation) { validation in var value=try control(validation:validation);guard value.counter<UInt64.max else{throw FinderPublicationFailure.corruptStore};value.counter+=1;value.sequences[name]=value.counter;_ = try writeLive(&value,validation:validation)}
    }
    public func begin(root: URL, session supplied: FinderPublicationSession? = nil, cancellation: OperationCancellation? = nil, policy: FinderStatusPolicy? = nil, authorize: (@Sendable () throws -> Void)? = nil) throws -> FinderPublicationTicket {
        let root=try path(root)
        let session: FinderPublicationSession
        if let supplied {session=supplied} else {session=try defaultSession(cancellation:cancellation)}
        return try locked(cancellation) { validation in
            var state=try control(validation:validation);try owner(session,state:state);let raw=try checkedRawSnapshot(validation:validation)
            let oldContributions=state.contributions.map(ObjectIdentifier.init),oldPolicy=state.statusPolicyIdentity
            // Check immutable watch identity while claim ordering is locked.
            // A queued retired watch cannot claim after its replacement began.
            try authorize?()
            try validation.check()
            if let policy {guard state.statusPolicyIdentity == nil || state.statusPolicyIdentity == policy.identity else {throw FinderPublicationFailure.policyChanged};state.statusPolicyIdentity=policy.identity}
            guard state.counter<UInt64.max else {throw FinderPublicationFailure.corruptStore}
            state.counter += 1;state.sequences[root]=state.counter;state.claims[root]=session.id
            state.contributions=try live(state)
            var warning: String?
            let alreadyLive=state.contributions.contains { FinderSnapshot.contains(root,root:$0.root) }
            if !alreadyLive && state.policy.cacheSave && !state.contributions.contains(where:{$0.session==session.id && GitReferenceName.equal($0.root,root)}) {
                warning=warmWarning {
                    if let warm=try checkedWarmSnapshot() {
                        let selected=warm.subtree(root:FileTransferPaths.fileURL(root))
                        if selected.roots.contains(where:{GitReferenceName.equal($0,root)}) {
                            // Restart data is optional. Validate its claimed
                            // namespace before it can enter the lease-backed
                            // control record: writeLive's strict validation must
                            // never turn an invalid archive into a failed claim.
                            // Keep the archive/sibling roots until a fresh
                            // publication replaces exactly this subtree.
                            do {try validate(root:root,snapshots:[selected],validation:validation)}
                            catch {throw FinderPublicationFailure.invalidWarmCache}
                            state.contributions.append(.init(root:root,session:session.id,sequence:state.counter,snapshots:[selected],restored:true))
                        }
                    }
                }
            }
            if state.legacy || raw?.liveRevision == nil || oldPolicy != state.statusPolicyIdentity || oldContributions != state.contributions.map(ObjectIdentifier.init) {
                _ = try writeLive(&state,validation:validation)
            }else {
                // A new claim fences later publications but does not change
                // existing live badge authority. Commit only ordering metadata;
                // retain immutable payload bytes and the existing raw snapshot.
                try validation.check();try save(state,controlURL)
            }
            return .init(root:root,persistenceFailure:warning,store:state.id,instance:instance,session:session.id,sequence:state.counter,policyIdentity:policy?.identity)
        }
    }
    public func publish(_ ticket: FinderPublicationTicket, snapshots: [FinderSnapshot], cancellation: OperationCancellation? = nil) throws -> FinderPublicationResult {
        let validation=ValidationContext(cancellation:cancellation)
        let submitted=Contribution(root:ticket.root,session:ticket.session,sequence:ticket.sequence,snapshots:snapshots,restored:false)
        try validate(root:submitted.root,snapshots:submitted.snapshots,validation:validation)
        validation.contributions[ObjectIdentifier(submitted)]=submitted
        sessionLock.lock();let session=owned[ticket.session];sessionLock.unlock()
        return try locked(cancellation,validation:validation) { validation in
            var state=try control(validation:validation);_ = try checkedRawSnapshot(validation:validation)
            func nested(_ a:String,_ b:String)->Bool {FinderSnapshot.contains(a,root:b)}
            let newer=state.sequences.contains {root,sequence in sequence>ticket.sequence && (nested(root,ticket.root) || nested(ticket.root,root))}
            guard ticket.policyIdentity==state.statusPolicyIdentity,ticket.instance==instance,ticket.store==state.id,state.claims[ticket.root]==ticket.session,state.sequences[ticket.root]==ticket.sequence,!newer,(state.consumed[ticket.root] ?? 0)<ticket.sequence,let session,session.active,try alive(ticket.session) else {return .init(published:false,snapshot:projection(try live(state),id:state.id,statusPolicyIdentity:state.statusPolicyIdentity))}
            if let identity=ticket.policyIdentity {guard snapshots.allSatisfy({snapshot in snapshot.roots.allSatisfy {snapshot.overlayPolicies[$0]?.identity==identity}}) else {throw FinderPublicationFailure.invalidUpdate}}
            // Optional archive damage must never refuse an accepted live update.
            let priorLive=try live(state)
            let completeWarm=(try? warmIsCurrent(state,contributions:priorLive)) == true
            let expectedLive=priorLive.filter { !($0.session==ticket.session && GitReferenceName.equal($0.root,ticket.root)) }+[submitted]
            // A local subtree merge alone cannot prove the complete warm
            // projection when another retained contribution overlaps it. Let
            // the next full maintenance reconcile that precedence instead.
            let overlapping=state.contributions.contains { item in
                !(item.session==ticket.session && GitReferenceName.equal(item.root,ticket.root)) &&
                    (nested(item.root,ticket.root) || nested(ticket.root,item.root))
            }
            state.consumed[ticket.root]=ticket.sequence
            state.contributions.removeAll {$0.session==ticket.session && GitReferenceName.equal($0.root,ticket.root)}
            state.contributions.append(submitted)
            state.warmMaintenance=nil
            // Preserve the live authority commit before optional archive work.
            // A crash or warm/receipt write failure cannot revoke this update.
            let published=try writeLive(&state,validation:validation)
            var rebuilt=false
            let warning=warmWarning {
                do {
                    try mergeWarm(root:ticket.root,snapshots:snapshots,enabled:state.policy.cacheSave,rebuildFrom:published)
                    if completeWarm,!overlapping,warmAuthority(state.contributions)==warmAuthority(expectedLive) {
                        state.warmMaintenance=try warmReceipt(state.contributions)
                        try save(state,controlURL)
                    }
                }
                catch let failure as FinderPublicationFailure {
                    if case .corruptWarmCacheReset=failure {rebuilt=true}
                    throw failure
                }
            }
            return .init(published:true,snapshot:published,persistenceFailure:warning,warmCacheRebuilt:rebuilt)
        }
    }
    /// An explicit session removes only its contribution. The legacy no-session
    /// API remains an intentional global Forget operation for older callers.
    public func remove(root: URL, session: FinderPublicationSession? = nil, cancellation: OperationCancellation? = nil) throws -> FinderSnapshot {
        let root=try path(root)
        return try locked(cancellation) { validation in
            var state=try control(validation:validation);if let session {try owner(session,state:state)}
            guard state.counter<UInt64.max else {throw FinderPublicationFailure.corruptStore};state.counter += 1
            state.contributions=state.contributions.compactMap { item in
                guard session==nil || item.session==session!.id else {return item}
                if FinderSnapshot.contains(item.root,root:root) {return nil}
                guard FinderSnapshot.contains(root,root:item.root) else {return item}
                let snapshots=item.snapshots.map { original -> FinderSnapshot in
                    var copy=original
                    copy.roots.removeAll {FinderSnapshot.contains($0,root:root)}
                    copy.states=copy.states.filter {!FinderSnapshot.contains($0.key,root:root)}
                    copy.repositories=copy.repositories.filter {!FinderSnapshot.contains($0.key,root:root)}
                    copy.overlayEntries=copy.overlayEntries?.filter {!FinderSnapshot.contains($0.key,root:root)}
                    copy.indexFlags=copy.indexFlags?.filter {!FinderSnapshot.contains($0.key,root:root)}
                    copy.overlayPolicies=copy.overlayPolicies.filter {!FinderSnapshot.contains($0.key,root:root)}
                    return copy
                }.filter {!$0.roots.isEmpty}
                return Contribution(root:item.root,session:item.session,sequence:item.sequence,revision:state.counter,snapshots:snapshots,restored:item.restored)
            }
            let revoked=state.claims.filter { claim in
                (session==nil || claim.value==session!.id) &&
                    (FinderSnapshot.contains(claim.key,root:root) || FinderSnapshot.contains(root,root:claim.key))
            }.keys
            for claim in revoked {state.sequences[claim]=state.counter;state.consumed[claim]=state.counter;state.claims.removeValue(forKey:claim)}
            if session==nil {state.sequences[root]=state.counter;state.consumed[root]=state.counter}
            var result=try writeLive(&state,validation:validation)
            result.persistenceFailure=warmWarning {
                guard state.policy.cacheSave else {return}
                let selected=result.subtree(root:FileTransferPaths.fileURL(root))
                try mergeWarm(root:root,snapshots:selected.roots.isEmpty ? []:[selected],enabled:true)
            }
            return result
        }
    }
    /// Retire one independently watched root without pruning nested or
    /// ancestor watches that happen to share this publisher's process lease.
    /// The broader remove API intentionally retains its subtree semantics.
    public func removeWatchContribution(root: URL, session: FinderPublicationSession, expected: FinderPublicationTicket? = nil, cancellation: OperationCancellation? = nil) throws -> FinderSnapshot {
        let root = try path(root)
        return try locked(cancellation) { validation in
            var state = try control(validation: validation)
            try owner(session, state: state)
            if let expected {
                guard GitReferenceName.equal(expected.root, root), expected.session == session.id,
                      expected.sequence <= state.counter else { throw FinderPublicationFailure.invalidUpdate }
                guard expected.instance == instance, expected.store == state.id else { throw FinderPublicationFailure.retiredSession }
            }
            let through = expected?.sequence ?? UInt64.max
            let removesContribution = state.contributions.contains {
                $0.session == session.id && GitReferenceName.equal($0.root, root) && $0.sequence <= through
            }
            let revokesClaim = state.claims[root] == session.id &&
                (expected == nil || state.sequences[root].map { $0 <= through } == true)
            // A delayed old reader may drain after a new watch has begun or
            // published under this same process lease. Retire only through the
            // old owner's latest BEGIN, including an unpublished/cancelled one.
            guard removesContribution || revokesClaim else {
                return projection(try live(state), id: state.id, statusPolicyIdentity: state.statusPolicyIdentity)
            }
            guard state.counter < UInt64.max else { throw FinderPublicationFailure.corruptStore }
            state.counter += 1
            state.contributions.removeAll {
                $0.session == session.id && GitReferenceName.equal($0.root, root) && $0.sequence <= through
            }
            if revokesClaim {
                state.claims.removeValue(forKey: root)
                state.consumed[root] = state.counter
                // Do not advance this root's overlap sequence. A new ancestor
                // sequence would also fence valid independent nested tickets.
                // Removing the exact claim and consuming its epoch rejects all
                // old root tickets while preserving earlier overlap fences.
            }
            state.warmMaintenance = nil
            var result = try writeLive(&state, validation: validation)
            result.persistenceFailure = warmWarning {
                guard state.policy.cacheSave else { return }
                let selected = result.subtree(root: FileTransferPaths.fileURL(root))
                try mergeWarm(root: root, snapshots: selected.roots.isEmpty ? [] : [selected], enabled: true)
            }
            return result
        }
    }
    public func endSession(_ session: FinderPublicationSession, cancellation: OperationCancellation? = nil) throws -> FinderSnapshot {
        guard session.instance==instance else {throw FinderPublicationFailure.retiredSession}
        defer {session.closeLease();sessionLock.lock();owned.removeValue(forKey:session.id);if implicit?.id==session.id {implicit=nil};sessionLock.unlock()}
        return try locked(cancellation) { validation in
            var state=try control(validation:validation);guard session.instance==instance,session.store==state.id else {throw FinderPublicationFailure.retiredSession}
            let liveBefore=try live(state)
            let departing=state.contributions.filter {$0.session==session.id}
            let remaining=liveBefore.filter {$0.session != session.id},claims=state.claims.filter {$0.value != session.id}
            let claimsChanged=claims.count != state.claims.count
            if departing.isEmpty,remaining.count==state.contributions.count {
                if claimsChanged {state.claims=claims;try validation.check();try save(state,controlURL)}
                return projection(remaining,id:state.id,statusPolicyIdentity:state.statusPolicyIdentity)
            }
            var archived=false
            let warning=warmWarning {
                guard state.policy.cacheSave,!departing.isEmpty else{return}
                if try warmIsCurrent(state,contributions:liveBefore) {archived=true;return}
                let current=projection(liveBefore,id:state.id,statusPolicyIdentity:state.statusPolicyIdentity)
                let updates=departing.compactMap {item -> (String,[FinderSnapshot])? in
                    let saved=current.subtree(root:FileTransferPaths.fileURL(item.root))
                    return saved.roots.isEmpty ? nil:(item.root,[saved])
                }
                // A successful subtree merge does not certify disjoint peers
                // that may have missed an earlier warm write. Only the exact
                // pre-existing full-cohort receipt authorizes that shortcut.
                try mergeWarm(updates,enabled:true,rebuildFrom:current,retiring:true)
            }
            // Removing an overlapping publisher can expose an older peer's
            // different payload. Do not certify that newly visible cohort from
            // an archive of the pre-retirement projection.
            let overlaps=departing.contains {old in remaining.contains {other in
                FinderSnapshot.contains(old.root,root:other.root) || FinderSnapshot.contains(other.root,root:old.root)
            }}
            state.contributions=remaining;state.claims=claims;state.warmMaintenance=nil
            if archived,!overlaps {state.warmMaintenance=try? warmReceipt(remaining)}
            var result=try writeLive(&state,validation:validation);result.persistenceFailure=warning;return result
        }
    }
}

/// Finder callbacks retain one reader. Every request rechecks process leases;
/// unchanged atomic files reuse their decoded ownership and badge projection.
public final class FinderSnapshotLiveReader: @unchecked Sendable {
    private let store: FinderSnapshotStore
    public init(url: URL) {store=FinderSnapshotStore(url:url)}
    public func read(cancellation: OperationCancellation? = nil) throws -> FinderSnapshot {try store.readLive(cancellation: cancellation)}
    public func cachedLiveIfCurrent() -> FinderSnapshot? { store.cachedLiveIfCurrent() }
}
