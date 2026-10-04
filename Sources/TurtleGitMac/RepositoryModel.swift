import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RepositoryModel: ObservableObject {
    weak var workspaceWindow: NSWindow?
    @Published var root: URL?
    @Published var branch = ""
    @Published var bare = false
    @Published var conflictRebase = false
    @Published var submodules = Set<String>()
    @Published var entries: [StatusEntry] = []
    @Published var selection = Set<String>()
    @Published var output = "Open a repository to get started."
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var section = RepositoryAction.status
    @Published var dialog: RepositoryAction?
    @Published var message = ""
    @Published var stagedDiff = false
    @Published var showIgnored = false
    @Published var finderStatus = "Finder cache not configured"
    @Published var recentRepositories: [SavedRepository] = []
    private var accessStore: RepositoryAccessStore?
    private var activeAccess: RepositoryAccessLease?
    private var repository: GitRepository?
    private var commitWindows: [String: CommitWindowController] = [:]
    private var logWindows: [String: LogWindowController] = [:]
    private var rebaseWindows: [String: RebaseWindowController] = [:]
    private var fetchWindows: [String: FetchWindowController] = [:]
    private var pushWindows: [String: PushWindowController] = [:]
    private var referenceWindows: [String: BranchTagWindowController] = [:]
    private var switchWindows: [String: SwitchWindowController] = [:]
    private var statusWindows: [String: StatusWindowController] = [:]
    private var mergeWindows: [String: MergeWindowController] = [:]
    private var referenceLogWindows: [String: ReferenceLogWindowController] = [:]
    private var stashRestoreWindows: [String: StashRestoreWindowController] = [:]
    private var stashWindows: [String: StashWindowController] = [:]
    private var cloneWindow: CloneWindowController?
    private var createWindows: [String: CreateRepositoryWindowController] = [:]
    private var renameWindows: [String: RenameWindowController] = [:]
    private var textConflictWindows: [String: TextConflictWindowController] = [:]
    private var submoduleConflictWindows: [String: SubmoduleConflictWindowController] = [:]
    private var deleteConflictWindows: [String: DeleteConflictWindowController] = [:]
    private var resetWindows: [String: ResetWindowController] = [:]
    private var resolveWindows: [String: ResolveWindowController] = [:]
    private var ignoreWindows: [String: IgnoreWindowController] = [:]
    private var removeWindows: [String: RemoveWindowController] = [:]
    private var adoptionGeneration = 0
    private var cloneKeyAccess: [String: RepositoryAccessLease] = [:]
    private var timer: Timer?
    private var cacheStates: [String: FileState] = [:]
    private var monitoredRoots: [String] = []
    var visibleEntries: [StatusEntry] { entries.filter { showIgnored || $0.state != .ignored } }
    var selectedPaths: [String] { entries.filter { selection.contains($0.id) }.map(\.path) }
    var canRenameSelection: Bool {
        let selected = entries.filter { selection.contains($0.id) }
        return !bare && !busy && selected.count == 1 && ![FileState.untracked, .ignored, .deleted].contains(selected[0].state)
    }
    var canRemoveSelection: Bool {
        let selected = entries.filter { selection.contains($0.id) }
        return !bare && !busy && !selected.isEmpty && selected.allSatisfy { $0.index != "A" && $0.index != "D" && ![FileState.untracked, .ignored].contains($0.state) }
    }

    var canResolveSelection: Bool { !bare && !busy && entries.contains { $0.state == .conflicted && (selection.isEmpty || selection.contains($0.id)) } }
    func canIgnoreSelection(_ action: RepositoryAction) -> Bool {
        let selected = entries.filter { selection.contains($0.id) }
        guard !bare, !busy, !selected.isEmpty else { return false }
        let eligible = selected.allSatisfy { action.removesWhenIgnoring ? ![FileState.untracked, .ignored, .deleted].contains($0.state) : [.untracked, .deleted].contains($0.state) }
        return eligible && (!action.ignoresByExtension || selected.contains { !($0.path as NSString).pathExtension.isEmpty })
    }

    init() {
        do {
            let store = try RepositoryAccessStore(storageURL: RepositoryAccessStore.defaultStorageURL)
            accessStore = store; recentRepositories = store.repositories
        } catch { self.error = "Saved repository permissions could not be loaded: " + error.localizedDescription }
        Task {
            if let snapshot = await Task.detached(operation: { FinderSnapshot.read() }).value, root == nil {
                cacheStates = snapshot.states; monitoredRoots = snapshot.roots
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self, !self.busy, !self.confirmingQuit, self.root != nil { await self.refresh(refreshStatus: false) } }
        }
    }
    private func makeRepository(_ url: URL) throws -> GitRepository {
        GitRepository(root: url, executable: try GitRuntime.executable())
    }
    func chooseRepository(preferred: URL? = nil) {
        guard !busy, !confirmingQuit else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Open repository"
        panel.message = "Choose the repository’s root folder. TurtleGit remembers your permission to work in this folder."
        panel.directoryURL = preferred
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL, onOpened: (() -> Void)? = nil) { openSession(RepositoryAccessLease(url: url), onOpened: onOpened) }
    func openRecent(_ saved: SavedRepository) {
        guard !busy, !confirmingQuit else { return }
        do {
            guard let store = accessStore else { throw RepositoryAccessFailure.unknownRepository }
            let lease = try store.acquire(saved.id, requireSecurityScope: GitRuntime.isAppStoreBuild)
            recentRepositories = store.repositories
            openSession(lease)
        } catch {
            self.error = "Could not reopen “\(saved.name)”. Select its folder with Open Repository to renew access.\n" + error.localizedDescription
        }
    }
    func forgetRepository(_ saved: SavedRepository) {
        do { try accessStore?.forget(saved.id); recentRepositories = accessStore?.repositories ?? [] }
        catch { self.error = error.localizedDescription }
    }
    func closeRepository() {
        guard !busy, !confirmingQuit else { return }
        adoptionGeneration += 1; bare = false
        repository = nil; activeAccess = nil; root = nil; entries = []; selection = []
        branch = ""; message = ""; output = "Open a repository to get started."
    }
    private func rememberAccess(_ lease: RepositoryAccessLease, repositoryRoot: URL? = nil) {
        do { try accessStore?.remember(repositoryRoot ?? lease.url); recentRepositories = accessStore?.repositories ?? [] }
        catch { self.error = "The repository is open, but its permission could not be saved: " + error.localizedDescription }
    }
    private func openSession(_ lease: RepositoryAccessLease, selected: FinderRequest? = nil, action: RepositoryAction? = nil, actionPaths: [String]? = nil, onOpened: (() -> Void)? = nil) {
        guard !busy, !confirmingQuit else { return }
        adoptionGeneration += 1
        busy = true
        Task {
            do {
                let first = selected?.paths.first ?? lease.url
                var location = first
                var directory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) || !directory.boolValue {
                    location.deleteLastPathComponent()
                }
                let candidate = try makeRepository(location)
                let resolved = try await candidate.discoverSelectionRoot(for: action ?? .status, selected: first)
                if GitRuntime.isAppStoreBuild && !lease.contains(resolved) {
                    throw RepositoryAccessFailure.repositoryRootOutsidePermission(resolved.path)
                }
                if let selected {
                    for item in selected.paths {
                        guard lease.contains(item), item.path == resolved.path || item.path.hasPrefix(resolved.path + "/") else {
                            throw FinderSelectionFailure.multipleRepositories
                        }
                        var location = item
                        var directory: ObjCBool = false
                        if !FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) || !directory.boolValue { location.deleteLastPathComponent() }
                        let itemRoot = try await makeRepository(location).discoverSelectionRoot(for: action ?? .status, selected: item)
                        guard itemRoot.standardizedFileURL == resolved.standardizedFileURL else { throw FinderSelectionFailure.multipleRepositories }
                    }
                }
                repository = try makeRepository(resolved); activeAccess = lease; root = resolved
                restoreCloneKeyAccess(root: resolved)
                selection = []; entries = []; branch = ""
                section = .status
                output = "Repository: \(resolved.path)"
                try await reload()
                if bare { section = .log }
                if let selected { selection = selected.selectedStatusPaths(root: resolved, entries: entries) }
                rememberAccess(lease, repositoryRoot: resolved)
                busy = false
                if let action {
                    let paths = actionPaths ?? selected?.relativePaths(root: resolved) ?? []
                    if action == .diff { showDiff(paths: paths) } else { activate(action, paths: paths) }
                    // Dedicated dialogs raise their own windows. Only Diff uses
                    // the workspace output; do not cover a Finder-launched dialog.
                    if action == .diff { workspaceWindow?.makeKeyAndOrderFront(nil) }
                }
                onOpened?()
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
    func refresh(refreshStatus: Bool = true) async {
        guard !busy, !confirmingQuit else { return }
        busy = true; defer { busy = false }
        do { try await reload() } catch { self.error = error.localizedDescription }
        if refreshStatus, let root { statusWindows[root.path]?.model.reload() }
    }
    private func reload() async throws {
        guard let repository, let root else { return }
        bare = try await repository.isBare()
        entries = bare ? [] : try await repository.status()
        conflictRebase = bare ? false : try await repository.conflictIsRebase()
        submodules = bare ? [] : try await repository.submodulePaths()
        selection.formIntersection(Set(entries.map(\.id)))
        branch = try await repository.branch()
        let tracked = bare ? [] : try await repository.trackedPaths()
        let snapshot = FinderSnapshot.build(root: root, tracked: tracked, changes: entries)
        cacheStates = cacheStates.filter { $0.key != root.path && !$0.key.hasPrefix(root.path + "/") }
        cacheStates.merge(snapshot.states) { _, new in new }
        if !monitoredRoots.contains(root.path) { monitoredRoots.append(root.path) }
        do {
            let cached = FinderSnapshot(roots: monitoredRoots, states: cacheStates)
            let written = try await Task.detached(operation: { try cached.write() }).value
            finderStatus = written ? "Finder cache updated" : "Finder cache unavailable: App Group access required"
            if written { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification), object: nil) }
        } catch { finderStatus = "Finder cache unavailable: " + error.localizedDescription }
    }
    func perform(_ operation: @escaping (GitRepository) async throws -> String) {
        guard let repository, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { output = try await operation(repository); try await reload() }
            catch { self.error = error.localizedDescription; try? await reload() }
            if let root { statusWindows[root.path]?.model.reload() }
        }
    }
    func stage() { let paths = selectedPaths; perform { try await $0.stage(paths); return "Staged \(paths.count) file(s)." } }
    func unstage() { let paths = selectedPaths; perform { try await $0.unstage(paths); return "Unstaged \(paths.count) file(s)." } }
    func showDiff(paths requested: [String]? = nil) {
        let paths = requested ?? selectedPaths, staged = stagedDiff
        perform { repo in
            let text = try await repo.diff(paths: paths, staged: staged)
            return text.isEmpty ? "No diff in this view. Untracked files must be staged before Git can show their diff." : text
        }
    }
    func showCommit(_ hash: String) { perform { try await $0.run(["show", "--no-ext-diff", "--no-color", hash, "--"]).text } }
    func commit() {
        let text = message
        perform { repo in let result = try await repo.commit(message: text); await MainActor.run { self.message = "" }; return result }
    }
    func activate(_ action: RepositoryAction, paths: [String] = []) {
        guard !confirmingQuit else { return }
        guard !bare || !action.requiresWorkingTree else { error = "\(action.title) requires a working tree. This repository is bare."; return }
        switch action {
        case .clone: showClone()
        case .initialize: showCreateRepository()
        case .rename:
            guard let repository else { return }
            let selected = paths.isEmpty ? selectedPaths : paths
            guard selected.count == 1, selected[0] != "." else { error = RenameFailure.source.localizedDescription; return }
            showRename(repository: repository, access: activeAccess, source: selected[0])
        case .editConflict:
            guard let repository else { return }
            let selected = paths.isEmpty ? selectedPaths : paths
            guard selected.count == 1, selected[0] != "." else { error = "Select one conflict to edit."; return }
            showConflictEditor(repository: repository, access: activeAccess, path: selected[0])
        case .resolve, .resolveCurrent, .resolveMine, .resolveTheirs:
            guard let repository else { return }
            showResolve(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths, quick: action.resolveChoice)
        case .ignore, .ignoreMask, .ignoreDelete, .ignoreDeleteMask:
            guard let repository else { return }
            showIgnore(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths, action: action)
        case .remove, .removeKeep:
            guard let repository else { return }
            showRemove(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths, keepLocal: action == .removeKeep)
        case .status:
            guard let repository else { return }
            showStatus(repository: repository, access: activeAccess, paths: paths)
        case .commit:
            guard let repository, let root else { return }
            let controller = commitWindows[root.path] ?? CommitWindowController(repository: repository, access: activeAccess)
            controller.onClosed = { [weak self] in self?.commitWindows.removeValue(forKey: root.path) }
            controller.model.onCommitted = { [weak self] output in
                self?.statusWindows[root.path]?.model.reload()
                guard let self, self.root == root else { return }
                self.output = output
                Task { await self.refresh() }
            }
            let access = controller.model.access
            controller.model.onPush = { [weak self] in self?.showPush(repository: repository, access: access) }
            controller.model.onFileLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path]) }
            controller.model.onResolve = { [weak self] action, paths in
                if action == .editConflict, let path = paths.first { self?.showConflictEditor(repository: repository, access: access, path: path) }
                else { self?.showResolve(repository: repository, access: access, paths: paths, quick: action.resolveChoice) }
            }
            controller.model.onIgnore = { [weak self] action, paths in self?.showIgnore(repository: repository, access: access, paths: paths, action: action) }
            controller.model.onRename = { [weak self] path in self?.showRename(repository: repository, access: access, source: path) }
            controller.model.configureLogPicker = { [weak self] log in
                log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
                log.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
                log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
            log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
            }
            commitWindows[root.path] = controller
            controller.model.reload(paths: paths)
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        case .log:
            guard let repository else { return }
            showLog(repository: repository, access: activeAccess, paths: paths)

        case .merge:
            guard let repository else { return }
            showMerge(repository: repository, access: activeAccess)
        case .rebase:
            guard let repository else { return }
            showRebase(repository: repository, access: activeAccess)
        case .pull:
            guard let repository else { return }
            showFetch(repository: repository, access: activeAccess, isPull: true)
        case .fetch:
            guard let repository else { return }
            showFetch(repository: repository, access: activeAccess)
        case .push:
            guard let repository else { return }
            showPush(repository: repository, access: activeAccess)
        case .branch, .tag:
            guard let repository else { return }
            showReference(repository: repository, access: activeAccess, isTag: action == .tag)
        case .reset:
            guard let repository else { return }
            showReset(repository: repository, access: activeAccess)
        case .switchBranch:
            guard let repository else { return }
            showSwitch(repository: repository, access: activeAccess)
        case .diff: showDiff()
        case .stashList, .reflog:
            guard let repository else { return }
            showReferenceLog(repository: repository, access: activeAccess, reference: action == .stashList ? "refs/stash" : "HEAD")
        case .stashApply, .stashPop:
            guard let repository else { return }
            showStashRestore(repository: repository, access: activeAccess, pop: action == .stashPop)
        case .stash:
            guard let repository else { return }
            showStash(repository: repository, access: activeAccess)
        }
    }
    private func restoreCloneKeyAccess(root: URL) {
        guard cloneKeyAccess[root.path] == nil, let data = UserDefaults.standard.data(forKey: "Clone.KeyBookmark." + root.path) else { return }
        do {
            let provider = SystemRepositoryBookmarkProvider()
            let resolved = try provider.resolve(data)
            let lease = RepositoryAccessLease(url: resolved.url)
            if GitRuntime.isAppStoreBuild && !lease.hasSecurityScope { throw RepositoryAccessFailure.securityScopeUnavailable }
            cloneKeyAccess[root.path] = lease
            if resolved.stale { UserDefaults.standard.set(try provider.create(for: resolved.url), forKey: "Clone.KeyBookmark." + root.path) }
        } catch { self.error = "The clone’s SSH-key permission could not be renewed.\n" + error.localizedDescription }
    }
    private func showClone(directory: URL? = nil, source: String? = nil) {
        let controller = cloneWindow ?? CloneWindowController(directory: directory ?? root, access: activeAccess)
        controller.onClosed = { [weak self] in self?.cloneWindow = nil }
        controller.model.onLog = { [weak self] repository, access in self?.showLog(repository: repository, access: access, paths: []) }
        controller.model.onCloned = { [weak self] repo, access, keyAccess, bare, result in
            guard let self else { return }
            if let keyAccess {
                self.cloneKeyAccess[repo.root.path] = keyAccess
                do { UserDefaults.standard.set(try SystemRepositoryBookmarkProvider().create(for: keyAccess.url), forKey: "Clone.KeyBookmark." + repo.root.path) }
                catch { self.error = "The clone completed, but its SSH-key permission could not be saved.\n" + error.localizedDescription }
            }
            self.adoptRepository(repo, access: access, bare: bare, output: result)
        }
        cloneWindow = controller
        if let source { controller.model.source = source }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func adoptRepository(_ repo: GitRepository, access: RepositoryAccessLease, bare: Bool, output: String) {
        rememberAccess(access, repositoryRoot: repo.root)
        adoptionGeneration += 1; let generation = adoptionGeneration
        Task {
            // Let an operation on the previous repository finish before switching
            // workspace state. An explicit Open/Close supersedes this handoff.
            while busy && generation == adoptionGeneration { try? await Task.sleep(nanoseconds: 50_000_000) }
            guard generation == adoptionGeneration else { return }
            repository = repo; activeAccess = access; root = repo.root; self.bare = bare
            entries = []; selection = []; branch = ""; section = bare ? .log : .status; self.output = output
            await refresh()
        }
    }
    private func showCreateRepository(folder preferred: URL? = nil) {
        let folder = preferred
        var lease: RepositoryAccessLease?
        if let folder, let activeAccess, activeAccess.contains(folder) { lease = activeAccess }
        else if let folder, !GitRuntime.isAppStoreBuild { lease = RepositoryAccessLease(url: folder) }
        if lease == nil {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.prompt = "Create repository here"; panel.directoryURL = folder ?? root?.deletingLastPathComponent()
            panel.message = "Choose the folder that will contain the new repository."
            panel.begin { [weak self] response in
                guard response == .OK, let selected = panel.url else { return }
                self?.presentCreateRepository(folder: selected, lease: RepositoryAccessLease(url: selected))
            }
            return
        }
        guard let folder, let lease else { return }
        presentCreateRepository(folder: folder, lease: lease)
    }
    private func presentCreateRepository(folder: URL, lease: RepositoryAccessLease) {
        guard lease.contains(folder), !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
        let controller = createWindows[folder.path] ?? CreateRepositoryWindowController(folder: folder, access: lease)
        let fresh = createWindows[folder.path] == nil
        controller.onClosed = { [weak self] in self?.createWindows.removeValue(forKey: folder.path) }
        controller.model.onInitialized = { [weak self] repo, access, bare, output in self?.adoptRepository(repo, access: access, bare: bare, output: output) }
        createWindows[folder.path] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        if fresh { controller.model.prepare() }
    }
    private func showRename(repository: GitRepository, access: RepositoryAccessLease?, source: String) {
        let root = repository.root, key = root.path + "/" + source
        let controller = renameWindows[key] ?? RenameWindowController(repository: repository, access: access, source: source)
        controller.onClosed = { [weak self] in self?.renameWindows.removeValue(forKey: key) }
        controller.model.onRenamed = { [weak self] old, new, output in
            guard let self else { return }
            self.statusWindows[root.path]?.model.didRename(old, to: new)
            self.commitWindows[root.path]?.model.didRename(old, to: new)
            if self.root == root {
                self.selection = Set(self.selection.map { $0 == old ? new : $0.hasPrefix(old + "/") ? new + $0.dropFirst(old.count) : $0 })
                self.output = output.isEmpty ? "Renamed \(old) to \(new)." : output; Task { await self.refresh() }
            }
        }
        renameWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showConflictEditor(repository: GitRepository, access: RepositoryAccessLease?, path: String) {
        Task {
            do {
                guard let entry = try await repository.conflicts(paths: [path]).first(where: { $0.path == path }) else { throw ResolveFailure.stale }
                if entry.isDeleteModify { showDeleteConflict(repository: repository, access: access, path: path); return }
                if !entry.isSubmodule {
                    let root = repository.root, key = root.path + "\0" + path
                    let controller = textConflictWindows[key] ?? TextConflictWindowController(repository: repository, access: access, path: path)
                    controller.onClosed = { [weak self] in self?.textConflictWindows.removeValue(forKey: key) }
                    controller.model.onChanged = { [weak self] output in
                        self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload()
                        for resolve in self?.resolveWindows.values ?? Dictionary<String, ResolveWindowController>().values where resolve.model.repository.root == root { resolve.model.load() }
                        if let self, self.root == root { self.output = output; Task { await self.refresh() } }
                    }
                    textConflictWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return
                }
                let root = repository.root, key = root.path + "\0" + path
                let controller = submoduleConflictWindows[key] ?? SubmoduleConflictWindowController(repository: repository, access: access, path: path)
                controller.onClosed = { [weak self] in self?.submoduleConflictWindows.removeValue(forKey: key) }
                controller.model.onChanged = { [weak self] output in
                    self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload()
                    for resolve in self?.resolveWindows.values ?? Dictionary<String, ResolveWindowController>().values where resolve.model.repository.root == root { resolve.model.load() }
                    if let self, self.root == root { self.output = output; Task { await self.refresh() } }
                }
                controller.model.onLog = { [weak self] child, revision in self?.showLog(repository: child, access: access, paths: [], endRevision: revision) }
                controller.model.onReset = { [weak self] child, revision, done in self?.showReset(repository: child, access: access, revision: revision, completion: done) }
                submoduleConflictWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func showDeleteConflict(repository: GitRepository, access: RepositoryAccessLease?, path: String) {
        let root = repository.root, key = root.path + "\0" + path
        let controller = deleteConflictWindows[key] ?? DeleteConflictWindowController(repository: repository, access: access, path: path)
        controller.onClosed = { [weak self] in self?.deleteConflictWindows.removeValue(forKey: key) }
        controller.model.onChanged = { [weak self] output in
            self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload()
            for resolve in self?.resolveWindows.values ?? Dictionary<String, ResolveWindowController>().values where resolve.model.repository.root == root { resolve.model.load() }
            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
        }
        controller.model.onLog = { [weak self] revision in self?.showLog(repository: repository, access: access, paths: [path], endRevision: revision) }
        deleteConflictWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showReset(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, completion: (() -> Void)? = nil) {
        let root = repository.root, key = root.path + "\0" + (revision ?? "")
        if let existing = resetWindows[key] {
            if let completion { let previous = existing.model.onReset; existing.model.onReset = { output in previous(output); completion() } }
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return
        }
        let controller = ResetWindowController(repository: repository, access: access, revision: revision)
        controller.onClosed = { [weak self] in self?.resetWindows.removeValue(forKey: key) }
        controller.model.onStatus = { [weak self] in self?.showStatus(repository: repository, access: access, paths: []) }
        controller.model.onReset = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload(); self?.statusWindows[root.path]?.model.reload()
            self?.logWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload()
            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
            completion?()
        }
        resetWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showResolve(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], quick: ResolveChoice?) {
        let root = repository.root, key = root.path + "\0" + String(quick?.rawValue ?? -1) + "\0" + paths.joined(separator: "\0")
        let controller = resolveWindows[key] ?? ResolveWindowController(repository: repository, access: access, paths: paths, quick: quick)
        controller.onClosed = { [weak self] in self?.resolveWindows.removeValue(forKey: key) }
        controller.onChanged = { [weak self] output in
            self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload()
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onEdit = { [weak self] path in self?.showConflictEditor(repository: repository, access: access, path: path) }
        controller.model.onSubmoduleReset = { [weak self] child, revision, done in
            self?.showReset(repository: child, access: access, revision: revision, completion: done)
        }
        controller.onCommit = { [weak self] in
            guard let self else { return }
            if self.root == root { self.activate(.commit) }
            else if let access { self.openSession(access, action: .commit) }
        }
        resolveWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showIgnore(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], action: RepositoryAction) {
        do {
            let root = repository.root, key = root.path + "\0" + action.rawValue + "\0" + paths.joined(separator: "\0")
            let controller = try ignoreWindows[key] ?? IgnoreWindowController(repository: repository, access: access, paths: paths, mask: action.ignoresByExtension, delete: action.removesWhenIgnoring)
            controller.onClosed = { [weak self] in self?.ignoreWindows.removeValue(forKey: key) }
            controller.onChanged = { [weak self] output in
                self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload()
                guard let self, self.root == root else { return }
                self.output = output; Task { await self.refresh() }
            }
            ignoreWindows[key] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } catch { self.error = error.localizedDescription }
    }
    private func showRemove(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], keepLocal: Bool) {
        do {
            let request = try RemovalRequest(paths: paths, keepLocal: keepLocal)
            let root = repository.root, key = root.path + "\0" + String(keepLocal) + "\0" + request.paths.joined(separator: "\0")
            let controller = removeWindows[key] ?? RemoveWindowController(repository: repository, access: access, request: request)
            controller.onClosed = { [weak self] in self?.removeWindows.removeValue(forKey: key) }
            controller.onChanged = { [weak self] output in
                self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload()
                guard let self, self.root == root else { return }
                self.output = output; Task { await self.refresh() }
            }
            removeWindows[key] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.start()
        } catch { self.error = error.localizedDescription }
    }
    private func showStatus(repository: GitRepository, access: RepositoryAccessLease?, paths: [String] = []) {
        let root = repository.root
        section = .status
        let controller = statusWindows[root.path] ?? StatusWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.statusWindows.removeValue(forKey: root.path) }
        controller.model.onAction = { [weak self] action, paths in
            guard let self else { return }
            if self.root != root, let access {
                self.openSession(access, action: action, actionPaths: paths); return
            }
            self.activate(action, paths: paths)
            if action != .commit && action != .log && action != .switchBranch && action != .branch && action != .tag && action != .push && action != .fetch && action != .pull && action != .rebase && action != .merge && action != .stash && action != .stashApply && action != .stashPop && action != .stashList && action != .reflog && action != .rename && !action.isIgnore && !action.isResolve && action != .reset { self.workspaceWindow?.makeKeyAndOrderFront(nil) }
        }
        controller.model.onChanged = { [weak self] in Task { await self?.refresh() } }
        statusWindows[root.path] = controller
        controller.model.setScope(paths)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showReferenceLog(repository: GitRepository, access: RepositoryAccessLease?, reference: String) {
        let root = repository.root
        let controller = referenceLogWindows[root.path] ?? ReferenceLogWindowController(repository: repository, access: access, reference: reference)
        controller.onClosed = { [weak self] in self?.referenceLogWindows.removeValue(forKey: root.path) }
        controller.model.onApply = { [weak self] hash in self?.showStashRestore(repository: repository, access: access, pop: false, reference: hash) }
        controller.model.onChanged = { [weak self] output in
            self?.logWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        referenceLogWindows[root.path] = controller
        controller.model.reference = reference; controller.model.reload()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showStashRestore(repository: GitRepository, access: RepositoryAccessLease?, pop: Bool, reference: String? = nil) {
        let root = repository.root, key = repository.root.path + (pop ? ":pop" : ":apply:" + (reference ?? "latest"))
        if let existing = stashRestoreWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = StashRestoreWindowController(repository: repository, access: access, pop: pop, reference: reference)
        controller.onClosed = { [weak self] in self?.stashRestoreWindows.removeValue(forKey: key) }
        controller.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.reload(); self?.logWindows[root.path]?.model.reload()
            self?.commitWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.onViewChanges = { [weak self] in self?.showStatus(repository: repository, access: access) }
        stashRestoreWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.start()
    }
    private func showLog(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], endRevision: String? = nil) {
        let root = repository.root, key = endRevision == nil ? root.path : root.path + "\0" + endRevision!
        let controller = logWindows[key] ?? LogWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.logWindows.removeValue(forKey: key) }
        controller.model.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        controller.model.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
        controller.model.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
        controller.model.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
        logWindows[key] = controller
        controller.model.endRevision = endRevision
        if let endRevision { controller.window?.title = "\(root.lastPathComponent) – Log Messages at \(endRevision.prefix(7)) – TurtleGit" }
        controller.model.setPathScope(paths)
        controller.model.reload()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }

    private func showMerge(repository: GitRepository, access: RepositoryAccessLease?) {
        let root = repository.root
        let controller = mergeWindows[root.path] ?? MergeWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.mergeWindows.removeValue(forKey: root.path) }
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.reload(); self?.logWindows[root.path]?.model.reload()
            self?.commitWindows[root.path]?.model.reload()
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.configureLogPicker = { [weak self] log in
            log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
            log.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
            log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
            log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
        }
        mergeWindows[root.path] = controller; controller.model.load()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showStash(repository: GitRepository, access: RepositoryAccessLease?) {
        let root = repository.root
        let controller = stashWindows[root.path] ?? StashWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.stashWindows.removeValue(forKey: root.path) }
        let changed: (String) -> Void = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.reload(); self?.logWindows[root.path]?.model.reload()
            self?.commitWindows[root.path]?.model.reload()
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onSaved = { result in changed(result.output) }
        controller.model.onFailed = changed
        stashWindows[root.path] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showRebase(repository: GitRepository, access: RepositoryAccessLease?, upstream: String? = nil, autoStart: Bool = false, preserveMerges: Bool = false) {
        let root = repository.root
        let existing = rebaseWindows[root.path]
        let controller = existing ?? RebaseWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.rebaseWindows.removeValue(forKey: root.path) }
        controller.model.onChanged = { [weak self] in
            self?.logWindows[root.path]?.model.reload(); self?.statusWindows[root.path]?.model.reload()
            if self?.root == root { Task { await self?.refresh() } }
        }
        controller.model.onShowStatus = { [weak self] in
            guard let self else { return }
            if self.root == root { self.activate(.status) }
            else if let access { self.openSession(access, action: .status) }
        }
        rebaseWindows[root.path] = controller
        if existing == nil || controller.model.finished || upstream != nil { controller.model.load(upstream: upstream, autoStart: autoStart, preserveMerges: preserveMerges) }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showFetch(repository: GitRepository, access: RepositoryAccessLease?, isPull: Bool = false) {
        let root = repository.root, key = repository.root.path + (isPull ? ":pull" : ":fetch")
        let controller = fetchWindows[key] ?? FetchWindowController(repository: repository, access: access, isPull: isPull)
        controller.onClosed = { [weak self] in self?.fetchWindows.removeValue(forKey: key) }
        controller.model.onShowStatus = { [weak self] in
            guard let self else { return }
            if self.root == root { self.activate(.status) }
            else if let access { self.openSession(access, action: .status) }
        }
        controller.model.onFetched = { [weak self] output in
            self?.logWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onRebase = { [weak self] upstream, autoStart, preserveMerges in
            self?.showRebase(repository: repository, access: access, upstream: upstream, autoStart: autoStart, preserveMerges: preserveMerges)
        }
        fetchWindows[key] = controller; controller.model.load()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showPush(repository: GitRepository, access: RepositoryAccessLease?, source: String? = nil) {
        let root = repository.root
        let controller = pushWindows[root.path] ?? PushWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.pushWindows.removeValue(forKey: root.path) }
        controller.model.onPushed = { [weak self] output in
            self?.logWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        pushWindows[root.path] = controller; controller.model.load(source: source)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showReference(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool, revision: String? = nil) {
        let root = repository.root, key = repository.root.path + (isTag ? ":tag" : ":branch")
        let controller = referenceWindows[key] ?? BranchTagWindowController(repository: repository, access: access, isTag: isTag)
        controller.onClosed = { [weak self] in self?.referenceWindows.removeValue(forKey: key) }
        controller.model.onCreated = { [weak self] output in
            self?.logWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPushTag = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        referenceWindows[key] = controller; controller.model.load(revision: revision)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showSwitch(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil) {
        let root = repository.root
        let controller = switchWindows[root.path] ?? SwitchWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.switchWindows.removeValue(forKey: root.path) }
        controller.model.onSwitched = { [weak self] output in
            self?.statusWindows[root.path]?.model.reload()
            self?.logWindows[root.path]?.model.reload()
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        switchWindows[root.path] = controller; controller.model.load(revision: revision)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func execute(_ action: RepositoryAction, value: String) {
        dialog = nil
        if action == .clone { showClone(source: value); return }
        if action == .initialize { showCreateRepository(); return }
        guard let args = action.arguments(value: value) else { return }
        guard !bare || !action.requiresWorkingTree else { error = "This operation requires a working tree."; return }
        perform { try await $0.run(args).text }
    }
    func handle(_ url: URL) {
        guard !busy, !confirmingQuit, let request = FinderRequest(url: url) else { return }
        let action = request.action
        if action == .clone { showClone(directory: request.paths.first); return }
        if action == .initialize { showCreateRepository(folder: request.paths.first); return }
        let candidate = request.paths[0]
        // A URL from Finder or another app is a request, not a sandbox permission grant.
        if let activeAccess, request.paths.allSatisfy({ activeAccess.contains($0) }) {
            openSession(activeAccess, selected: request, action: action)
            return
        }
        if let store = accessStore {
            for saved in store.repositories {
                guard let lease = try? store.acquire(saved.id, requireSecurityScope: GitRuntime.isAppStoreBuild),
                      request.paths.allSatisfy({ lease.contains($0) }) else { continue }
                recentRepositories = store.repositories
                openSession(lease, selected: request, action: action)
                return
            }
        }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Authorize repository"
        panel.message = "Choose the repository root containing the Finder selection to allow TurtleGit to work with it."
        panel.directoryURL = candidate.hasDirectoryPath ? candidate : candidate.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lease = RepositoryAccessLease(url: url)
        guard request.paths.allSatisfy({ lease.contains($0) }) else {
            error = "The selected folder does not contain every requested Finder item."; return
        }
        openSession(lease, selected: request, action: action)
    }
}

private enum FinderSelectionFailure: LocalizedError {
    case multipleRepositories
    var errorDescription: String? { "Select files from one repository at a time. The Finder selection spans different repositories." }
}
