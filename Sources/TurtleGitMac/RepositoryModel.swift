import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RepositoryModel: ObservableObject {
    func showLoadImages() {
        guard !busy, !confirmingQuit, imageLoader == nil, workspaceWindow?.attachedSheet == nil else { return }
        let loader = ImageLoadWindowController(leftPath: "", permissions: [])
        imageLoader = loader
        loader.onAccepted = { [weak self] images, permissions in
            guard let self else { return }
            let key = "images-" + UUID().uuidString
            let controller = FileComparisonWindowController(images: images, permissions: permissions)
            controller.onClosed = { [weak self] in self?.fileComparisonWindows.removeValue(forKey: key) }
            self.fileComparisonWindows[key] = controller; controller.showWindow(nil)
        }
        loader.onClosed = { [weak self] in self?.imageLoader = nil }
        loader.present(parent: workspaceWindow)
    }
    weak var workspaceWindow: NSWindow?
    @Published var root: URL?
    @Published var branch = ""
    @Published var bare = false
    @Published var conflictRebase = false
    @Published var mergeActive = false
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
    @Published var workingComparisonMark: WorkingComparisonMarkSnapshot?
    private let comparisonMarkStore = WorkingComparisonMarkStore(storageURL: WorkingComparisonMarkStore.defaultStorageURL)
    var comparisonMarkTitle: String { workingComparisonMark.map { "Compare with " + $0.path } ?? RepositoryAction.diffLater.title }
    @Published var recentRepositories: [SavedRepository] = []
    private var accessStore: RepositoryAccessStore?
    private var activeAccess: RepositoryAccessLease?
    private var repository: GitRepository?
    private var commitWindows: [String: CommitWindowController] = [:]
    private var logWindows: [String: LogWindowController] = [:]
    private var revisionGraphWindows: [String: RevisionGraphWindowController] = [:]
    private var referenceBrowserWindows: [String: ReferenceBrowserWindowController] = [:]
    private var browserWindows: [String: RepositoryBrowserWindowController] = [:]
    private var worktreeListWindows: [String: WorktreeListWindowController] = [:]
    private var worktreeCreateWindows: [String: WorktreeCreateWindowController] = [:]
    private var requestPullWindows: [String: RequestPullWindowController] = [:]
    private var importPatchWindows: [String: ImportPatchWindowController] = [:]
    private var formatPatchWindows: [String: FormatPatchWindowController] = [:]
    private var blameWindows: [String: BlameWindowController] = [:]
    private var rebaseWindows: [String: RebaseWindowController] = [:]
    private var fetchWindows: [String: FetchWindowController] = [:]
    private var pushWindows: [String: PushWindowController] = [:]
    private var synchronizationWindows: [String: SynchronizationWindowController] = [:]
    private var referenceWindows: [String: BranchTagWindowController] = [:]
    private var switchProgressWindows: [UUID: SwitchProgressWindowController] = [:]
    private var switchWindows: [String: SwitchWindowController] = [:]
    private var revertProgressWindows: [UUID: RevertProgressWindowController] = [:]
    private var addWindows: [String: AddWindowController] = [:]
    private var addUnifiedWindows: [String: PatchWindowController] = [:]
    private var lfsLocksWindows: [String: LFSLocksWindowController] = [:]
    private var addProgressWindows: [UUID: AddProgressWindowController] = [:]
    private var cleanWindows: [String: CleanWindowController] = [:]
    private var cleanProgressWindows: [UUID: CleanProgressWindowController] = [:]
    private var revertWindows: [String: RevertWindowController] = [:]
    private var statusWindows: [String: StatusWindowController] = [:]
    private var bisectWindows: [String: BisectWindowController] = [:]
    private var exportWindows: [String: ExportWindowController] = [:]
    private var mergeAbortWindows: [UUID: MergeAbortWindowController] = [:]
    private var mergeWindows: [String: MergeWindowController] = [:]
    private var referenceLogWindows: [String: ReferenceLogWindowController] = [:]
    private var stashRestoreWindows: [String: StashRestoreWindowController] = [:]
    private var stashWindows: [String: StashWindowController] = [:]
    private var cloneWindows: [UUID: CloneWindowController] = [:]
    private var createWindows: [String: CreateRepositoryWindowController] = [:]
    private var renameWindows: [String: RenameWindowController] = [:]
    private var imageConflictWindows: [String: ImageConflictWindowController] = [:]
    private var textConflictWindows: [String: TextConflictWindowController] = [:]
    private var submoduleDiffWindows: [String: SubmoduleDiffWindowController] = [:]
    private var revisionComparisonWindows: [String: RevisionComparisonWindowController] = [:]
    private var imageLoader: ImageLoadWindowController?
    private var fileComparisonWindows: [String: FileComparisonWindowController] = [:]
    private var submoduleSyncWindows: [UUID: SubmoduleSyncWindowController] = [:]
    private var submoduleAddWindows: [String: SubmoduleAddWindowController] = [:]
    private var submoduleAddProgressWindows: [UUID: SubmoduleAddProgressWindowController] = [:]
    private var submoduleUpdateProgressWindows: [UUID: SubmoduleUpdateProgressWindowController] = [:]
    private var submoduleUpdateWindows: [String: SubmoduleUpdateWindowController] = [:]
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
    private var cacheRepositories: [String: FinderRepositoryMetadata] = [:]
    private var monitoredRoots: [String] = []
    var visibleEntries: [StatusEntry] { entries.filter { showIgnored || $0.state != .ignored } }
    var selectedPaths: [String] { entries.filter { selection.contains($0.id) }.map(\.path) }
    var canRevertSelection: Bool {
        let selected = entries.filter { selection.contains($0.id) }
        return !selected.isEmpty && selected.allSatisfy { ![FileState.untracked, .ignored].contains($0.state) }
    }
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
        do { _ = try FinderMenuSettings.from().write() }
        catch { finderStatus = "Finder menu preferences unavailable: " + error.localizedDescription }
        do { workingComparisonMark = try comparisonMarkStore.snapshot() } catch { self.error = error.localizedDescription }
        do {
            let store = try RepositoryAccessStore(storageURL: RepositoryAccessStore.defaultStorageURL)
            accessStore = store; recentRepositories = store.repositories
        } catch { self.error = "Saved repository permissions could not be loaded: " + error.localizedDescription }
        Task {
            if let snapshot = await Task.detached(operation: { FinderSnapshot.read() }).value, root == nil {
                cacheStates = snapshot.states; monitoredRoots = snapshot.roots; cacheRepositories = snapshot.repositories
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
        adoptionGeneration += 1; bare = false; mergeActive = false
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
                selection = []; entries = []; branch = ""; mergeActive = false
                section = .status
                output = "Repository: \(resolved.path)"
                try await reload()
                if bare { section = .log }
                if let selected { selection = selected.selectedStatusPaths(root: resolved, entries: entries) }
                rememberAccess(lease, repositoryRoot: resolved)
                busy = false
                if let action {
                    let paths = actionPaths ?? selected?.relativePaths(root: resolved) ?? []
                    activate(action, paths: paths)
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
        let metadata = try await repository.finderMetadata(knownBare: bare)
        mergeActive = metadata.mergeActive
        var snapshot = FinderSnapshot.build(root: root, tracked: tracked, changes: entries)
        snapshot.repositories[root.path] = metadata
        let children = bare ? FinderSubmoduleScan() : try await repository.finderSubmoduleSnapshots(authorizedRoot: activeAccess?.url ?? root)
        var cached = FinderSnapshot(roots: monitoredRoots, states: cacheStates, repositories: cacheRepositories)
        cached.replaceSubtree(root: root, snapshots: [snapshot] + children.snapshots)
        monitoredRoots = cached.roots; cacheStates = cached.states; cacheRepositories = cached.repositories
        do {
            let written = try await Task.detached(operation: { try cached.write() }).value
            finderStatus = written ? (children.failures.isEmpty ? "Finder cache updated" : "Finder cache updated; \(children.failures.count) submodule scan(s) failed: " + children.failures.sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value }.joined(separator: "; ")) : "Finder cache unavailable: App Group access required"
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
        if paths.count == 1, submodules.contains(paths[0]), let repository {
            showSubmoduleDiff(repository: repository, access: activeAccess, path: paths[0]); return
        }
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
        case .diffLater:
            let selected = paths.isEmpty ? selectedPaths : paths
            if selected.count == 1, let root { handleComparisonMark(file: root.appendingPathComponent(selected[0])) }
            else {
                let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
                panel.prompt = workingComparisonMark == nil ? "Mark for comparison" : "Compare"
                if panel.runModal() == .OK, let file = panel.url { handleComparisonMark(file: file, permission: RepositoryAccessLease(url: file)) }
            }
        case .clearComparisonMark: clearComparisonMark()
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
        case .submoduleSync:
            guard let repository else { return }
            showSubmoduleSync(repository: repository, access: activeAccess, scope: paths)
        case .submoduleAdd:
            guard let repository else { return }
            showSubmoduleAdd(repository: repository, access: activeAccess, path: paths.first ?? "")
        case .submoduleUpdate:
            guard let repository else { return }
            showSubmoduleUpdate(repository: repository, access: activeAccess, scope: paths.isEmpty ? selectedPaths : paths)
        case .add:
            guard let repository else { return }
            showAdd(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths)
        case .clean:
            guard !busy, let repository else { return }
            showClean(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths)
        case .revert:
            guard let repository else { return }
            showRevert(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths)
        case .status:
            guard let repository else { return }
            showStatus(repository: repository, access: activeAccess, paths: paths)
        case .commit:
            guard let repository else { return }
            showCommitDialog(repository: repository, access: activeAccess, paths: paths)
        case .referenceBrowser:
            guard let repository else { return }
            showReferenceBrowser(repository: repository, access: activeAccess)
        case .repositoryBrowser:
            guard let repository else { return }
            showRepositoryBrowser(repository: repository, access: activeAccess)
        case .worktreeList:
            guard let repository else { return }
            showWorktreeList(repository: repository, access: activeAccess)
        case .worktreeCreate:
            guard let repository else { return }
            showWorktreeCreate(repository: repository, access: activeAccess)
        case .bisect, .bisectStart, .bisectGood, .bisectBad, .bisectSkip, .bisectReset:
            guard let repository else { return }
            showBisect(repository: repository, access: activeAccess, operation: action.bisectOperation, requireStart: action == .bisectStart)
        case .export:
            guard let repository else { return }
            showExport(repository: repository, access: activeAccess, revision: "HEAD", paths: paths)
        case .requestPull:
            guard let repository else { return }
            showRequestPull(repository: repository, access: activeAccess)
        case .importPatch:
            guard let repository else { return }
            showImportPatch(repository: repository, access: activeAccess, paths: paths)
        case .formatPatch:
            guard let repository else { return }
            showFormatPatch(repository: repository, access: activeAccess)
        case .log:
            guard let repository else { return }
            showLog(repository: repository, access: activeAccess, paths: paths)
        case .revisionGraph:
            guard let repository else { return }
            showRevisionGraph(repository: repository, access: activeAccess)

        case .mergeAbort:
            guard let repository else { return }
            showMergeAbort(repository: repository, access: activeAccess)
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
        case .diff:
            let selected = paths.isEmpty ? selectedPaths : paths
            guard let repository else { return }
            if selected.isEmpty || selected.contains(where: { path in
                if submodules.contains(path) { return false }
                var directory: ObjCBool = false
                return path == "." || FileManager.default.fileExists(atPath: repository.root.appendingPathComponent(path).path, isDirectory: &directory) && directory.boolValue
            }) { showStatus(repository: repository, access: activeAccess, paths: selected) }
            else { showWorkingFiles(repository: repository, access: activeAccess, paths: selected) }
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
        let id = UUID(), controller = CloneWindowController(directory: directory ?? root, access: activeAccess)
        controller.onClosed = { [weak self] in self?.cloneWindows.removeValue(forKey: id) }
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
        cloneWindows[id] = controller
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
            entries = []; selection = []; branch = ""; mergeActive = false; section = bare ? .log : .status; self.output = output
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
                    if let document = try await repository.imageConflictDocument(path: path) {
                        let controller = imageConflictWindows[key] ?? ImageConflictWindowController(repository: repository, access: access, document: document)
                        controller.onClosed = { [weak self] in self?.imageConflictWindows.removeValue(forKey: key) }
                        controller.model.onChanged = { [weak self] output in
                            self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
                            for resolve in self?.resolveWindows.values ?? Dictionary<String, ResolveWindowController>().values where resolve.model.repository.root == root { resolve.model.load() }
                            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
                        }
                        imageConflictWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return
                    }
                    let controller = textConflictWindows[key] ?? TextConflictWindowController(repository: repository, access: access, path: path)
                    controller.onClosed = { [weak self] in self?.textConflictWindows.removeValue(forKey: key) }
                    controller.model.onChanged = { [weak self] output in
                        self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
                        for resolve in self?.resolveWindows.values ?? Dictionary<String, ResolveWindowController>().values where resolve.model.repository.root == root { resolve.model.load() }
                        if let self, self.root == root { self.output = output; Task { await self.refresh() } }
                    }
                    textConflictWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return
                }
                let root = repository.root, key = root.path + "\0" + path
                let controller = submoduleConflictWindows[key] ?? SubmoduleConflictWindowController(repository: repository, access: access, path: path)
                controller.onClosed = { [weak self] in self?.submoduleConflictWindows.removeValue(forKey: key) }
                controller.model.onChanged = { [weak self] output in
                    self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
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
            self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
            for resolve in self?.resolveWindows.values ?? Dictionary<String, ResolveWindowController>().values where resolve.model.repository.root == root { resolve.model.load() }
            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
        }
        controller.model.onLog = { [weak self] revision in self?.showLog(repository: repository, access: access, paths: [path], endRevision: revision) }
        deleteConflictWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showReset(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, mode: ResetMode? = nil, completion: (() -> Void)? = nil) {
        let root = repository.root, key = root.path + "\0" + (revision.map { $0 + "\0" + UUID().uuidString } ?? "")
        if revision == nil, let existing = resetWindows[key] {
            if let completion { let previous = existing.model.onReset; existing.model.onReset = { output in previous(output); completion() } }
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return
        }
        let controller = ResetWindowController(repository: repository, access: access, revision: revision)
        if let mode { controller.model.mode = mode }
        controller.onClosed = { [weak self] in self?.resetWindows.removeValue(forKey: key) }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
        controller.configureModifiedComparison = { [weak self] model in
            self?.configureRevisionComparisonInteractions(model, repository: repository, access: access)
        }
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload(); self?.statusWindows[root.path]?.model.reload()
            self?.refreshRepositoryLogs(root); self?.commitWindows[root.path]?.model.reload()
            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
        }
        controller.model.onReset = { _ in completion?() }
        controller.model.onPostAction = { [weak self] action in
            switch action {
            case .submoduleUpdate: self?.showSubmoduleUpdate(repository: repository, access: access, scope: [])
            case .clean: self?.showClean(repository: repository, access: access, paths: [])
            case .bisectGood: self?.showBisect(repository: repository, access: access, operation: .good)
            case .bisectBad: self?.showBisect(repository: repository, access: access, operation: .bad)
            case .bisectSkip: self?.showBisect(repository: repository, access: access, operation: .skip)
            case .bisectReset: self?.showBisect(repository: repository, access: access, operation: .reset)
            case .retry: break
            }
        }
        resetWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showResolve(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], quick: ResolveChoice?) {
        let root = repository.root, key = root.path + "\0" + String(quick?.rawValue ?? -1) + "\0" + paths.joined(separator: "\0")
        let controller = resolveWindows[key] ?? ResolveWindowController(repository: repository, access: access, paths: paths, quick: quick)
        controller.onClosed = { [weak self] in self?.resolveWindows.removeValue(forKey: key) }
        controller.onChanged = { [weak self] output in
            self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
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
                self?.refreshRepositoryLogs(root)
                self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
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
                self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
                guard let self, self.root == root else { return }
                self.output = output; Task { await self.refresh() }
            }
            removeWindows[key] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.start()
        } catch { self.error = error.localizedDescription }
    }
    private func showCommitDialog(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        let root = repository.root
        let controller = commitWindows[root.path] ?? CommitWindowController(repository: repository, access: access)
        controller.onPullAfterLFSLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.onClosed = { [weak self] in self?.commitWindows.removeValue(forKey: root.path) }
        controller.model.onCommitted = { [weak self] output in
            self?.statusWindows[root.path]?.model.reload(); self?.refreshRepositoryLogs(root)
            guard let self, self.root == root else { return }
            self.output = output
            Task { await self.refresh() }
        }
        let access = controller.model.access
        controller.model.onPush = { [weak self] in self?.showPush(repository: repository, access: access) }
        controller.model.onPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true, followUp: PullFollowUp(showPush: true)) }
        controller.model.onCreateTag = { [weak self] in self?.showReference(repository: repository, access: access, isTag: true) }
        configureCommitInteractions(controller.model, repository: repository, access: access)
        commitWindows[root.path] = controller
        controller.model.reload(paths: paths)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showAdd(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        Task {
            do {
                if try await repository.addSelectionIsFiles(paths) { showAddProgress(repository: repository, access: access, paths: paths); return }
                let key = repository.root.path
                let controller = addWindows[key] ?? AddWindowController(repository: repository, access: access)
                guard !controller.model.busy else { controller.window?.makeKeyAndOrderFront(nil); return }
                controller.onClosed = { [weak self] in self?.addWindows.removeValue(forKey: key) }
                controller.model.onAccepted = { [weak self] paths in self?.showAddProgress(repository: repository, access: access, paths: paths) }
                controller.model.onPreview = { [weak self] path in self?.showWorkingFiles(repository: repository, access: access, paths: [path]) }
                controller.model.onCompare = { [weak self] paths in self?.showWorkingFiles(repository: repository, access: access, paths: paths) }
                controller.model.onCompareTwo = { [weak self] paths in self?.showWorkingFilePair(repository: repository, access: access, paths: paths) }
                controller.model.unifiedViewerBusy = { [weak self] in self?.addUnifiedWindows[key]?.model.busy == true || self?.addUnifiedWindows[key]?.window?.attachedSheet != nil }
                controller.model.onUnifiedPatch = { [weak self] bytes, alternate in
                    guard let self else { return }
                    if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate) {
                        self.addUnifiedWindows[key] = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: self.addUnifiedWindows[key], title: "HEAD → Working tree", onClosed: { [weak self] in self?.addUnifiedWindows.removeValue(forKey: key) })
                    }
                }
                controller.model.onLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path]) }
                controller.model.onBlame = { [weak self] path in self?.showBlame(repository: repository, access: access, path: path, revision: "HEAD") }
                controller.model.onIgnoreChanged = { [weak self] output in
                    self?.statusWindows[key]?.model.reload(); self?.commitWindows[key]?.model.reload()
                    if let self, self.root == repository.root { self.output = output; Task { await self.refresh() } }
                }
                controller.model.onRevert = { [weak self] entries, done in
                    guard let self else { done(false); return {} }
                    let progress = self.showRevertProgress(repository: repository, access: access, entries: entries, autoCloseSuccess: true, completion: done)
                    return { [weak progress] in progress?.model.cancel() }
                }
                controller.model.onRestoreChanged = { [weak model = controller.model] in model?.onIgnoreChanged("Working copies restored.") }
                controller.model.onDeleteChanged = controller.model.onIgnoreChanged
                addWindows[key] = controller; controller.model.setScope(paths); controller.model.reload()
                controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
            } catch { self.error = error.localizedDescription }
        }
    }
    func showLFSLocks() {
        guard !busy, !confirmingQuit, !bare, let repository else { return }
        let key = repository.root.path
        if let existing = lfsLocksWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let access = activeAccess
        let controller = LFSLocksWindowController(repository: repository, access: access)
        controller.onPullAfterLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.onClosed = { [weak self] in self?.lfsLocksWindows.removeValue(forKey: key) }
        lfsLocksWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        Task { await controller.model.refresh() }
    }

    func showSynchronization() {
        guard !busy, !confirmingQuit, !bare, let repository else { return }
        let key = repository.root.path, access = activeAccess
        if let existing = synchronizationWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = SynchronizationWindowController(repository: repository, access: access)
        configureRevisionComparisonInteractions(controller.model.comparison, repository: repository, access: access)
        configureRevisionComparisonInteractions(controller.model.incomingComparison, repository: repository, access: access)
        controller.model.onTransportFinished = { [weak self] text in
            guard let self else { return }
            self.output = text; self.refreshRepositoryLogs(repository.root)
            if self.root?.path == repository.root.path { Task { await self.refresh() } }
        }
        controller.model.onLog = { [weak self] revision in self?.showLog(repository: repository, access: access, paths: [], endRevision: revision) }
        controller.model.onCommit = { [weak self] in self?.showCommitDialog(repository: repository, access: access, paths: []) }
        controller.model.onReferenceLog = { [weak self] reference in self?.showReferenceLog(repository: repository, access: access, reference: reference) }
        controller.model.onReferenceCompare = { [weak self] old, new in self?.showRevisionComparison(repository: repository, access: access, from: .revision(old), to: .revision(new)) }
        controller.model.onResolve = { [weak self] paths in self?.showResolve(repository: repository, access: access, paths: paths, quick: nil) }
        controller.model.runRebase = { [weak self, weak controller] target, autoStart, preserve in
            guard let self, let controller, !controller.model.closed, let owner = controller.window,
                  owner.attachedSheet == nil, self.rebaseWindows[key] == nil else { throw SynchronizationFailure.invalidInput }
            await withCheckedContinuation { continuation in
                self.showRebase(repository: repository, access: access, upstream: target, autoStart: autoStart, preserveMerges: preserve,
                    afterFetch: true, owner: owner, onDismissed: { continuation.resume() })
            }
        }
        controller.model.detachRebase = { [weak self, weak controller] in
            guard let child = self?.rebaseWindows[key], let window = child.window,
                  let owner = controller?.window, window.sheetParent === owner else { return }
            owner.endSheet(window)
            if child.model.busy { child.showWindow(nil) } else { child.close() }
        }
        controller.onClosed = { [weak self] in self?.synchronizationWindows.removeValue(forKey: key) }
        synchronizationWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }

    private func showAddProgress(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], mode: WorkingFileAddMode = .normal) {
        let id = UUID(), controller = AddProgressWindowController(repository: repository, access: access, paths: paths, mode: mode)
        controller.onClosed = { [weak self] in self?.addProgressWindows.removeValue(forKey: id) }
        controller.model.onFinished = { [weak self] text, _ in
            self?.refreshRepositoryLogs(repository.root)
            self?.output = text
            if self?.root?.path == repository.root.path { Task { await self?.refresh() } }
        }
        controller.model.onCommit = { [weak self] in self?.openSession(access ?? RepositoryAccessLease(url: repository.root), selected: FinderRequest(action: .commit, paths: [repository.root]), action: .commit) }
        addProgressWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
    }
    private func showClean(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        let root = repository.root
        let controller = cleanWindows[root.path] ?? CleanWindowController(repository: repository)
        controller.onClosed = { [weak self] in self?.cleanWindows.removeValue(forKey: root.path) }
        controller.model.setScope(paths)
        controller.model.onAccepted = { [weak self] request in
            guard let self else { return }
            let id = UUID(), progress = CleanProgressWindowController(repository: repository, access: access, request: request)
            progress.onClosed = { [weak self] in self?.cleanProgressWindows.removeValue(forKey: id) }
            progress.model.onFinished = { [weak self] output, changed in
                guard let self else { return }
                if changed {
                    self.statusWindows[root.path]?.model.reload()
                    self.commitWindows[root.path]?.model.reload()
                    self.refreshRepositoryLogs(root)
                    if self.root == root { Task { await self.refresh() } }
                }
                if self.root == root { self.output = output }
            }
            self.cleanProgressWindows[id] = progress
            progress.showWindow(nil); progress.window?.makeKeyAndOrderFront(nil); progress.model.start()
        }
        cleanWindows[root.path] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showRevert(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        let root = repository.root
        let controller = revertWindows[root.path] ?? RevertWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.revertWindows.removeValue(forKey: root.path) }
        controller.model.onFileLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path]) }
        controller.model.onAccepted = { [weak self] entries in self?.showRevertProgress(repository: repository, access: access, entries: entries) }
        revertWindows[root.path] = controller
        controller.model.setScope(paths)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showSubmoduleDiff(repository: GitRepository, access: RepositoryAccessLease?, path: String, from: String = "HEAD", to: String? = nil) {
        let key = repository.root.path + "\0" + path + "\0" + from + "\0" + (to ?? "Working tree")
        let controller = submoduleDiffWindows[key] ?? SubmoduleDiffWindowController(repository: repository, access: access, path: path, from: from, to: to)
        controller.onClosed = { [weak self] in self?.submoduleDiffWindows.removeValue(forKey: key) }
        controller.model.onLog = { [weak self] child, hash in self?.showLog(repository: child, access: access, paths: [], endRevision: hash) }
        controller.model.onStatus = { [weak self] child in self?.showStatus(repository: child, access: access) }
        controller.model.onCompare = { [weak self] child, old, new in self?.showRevisionComparison(repository: child, access: access, from: old, to: new) }
        controller.model.onUpdate = { [weak self] done in self?.showSubmoduleUpdate(repository: repository, access: access, scope: [], selected: [path], completion: done) }
        submoduleDiffWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.load()
    }
    private func showRevisionComparison(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision) {
        let baseKey = repository.root.path + "\0" + from.label + "\0" + to.label
        let reusable = revisionComparisonWindows.first { _, controller in
            controller.model.repository.root == repository.root && controller.model.repository.executable == repository.executable &&
            controller.window?.attachedSheet == nil && controller.model.canReuseForComparison(from: from, to: to)
        }
        let key = reusable?.key ?? (revisionComparisonWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? RevisionComparisonWindowController(repository: repository, access: access, from: from, to: to)
        controller.onClosed = { [weak self] in self?.revisionComparisonWindows.removeValue(forKey: key) }
        configureRevisionComparisonInteractions(controller.model, repository: repository, access: access)
        revisionComparisonWindows[key] = controller
        controller.model.load()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showRevisionGraph(repository: GitRepository, access: RepositoryAccessLease?) {
        let key = repository.root.path + "\0" + repository.executable.path
        if let existing = revisionGraphWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = RevisionGraphWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.revisionGraphWindows.removeValue(forKey: key) }
        controller.model.onLog = { [weak self] hash in self?.showLog(repository: repository, access: access, paths: [], endRevision: hash, selectedRevision: hash) }
        controller.model.onBrowse = { [weak self] hash in self?.showRepositoryBrowser(repository: repository, access: access, revision: hash) }
        controller.model.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: from, to: to) }
        controller.model.onCheckout = { [weak self] hash in self?.showSwitch(repository: repository, access: access, revision: hash) }
        controller.model.onLogRange = { [weak self] range in self?.showLog(repository: repository, access: access, paths: [], revisionRange: range) }
        controller.model.onSwitchBranch = { [weak self, weak controller] reference in
            guard let parent = controller?.window, parent.attachedSheet == nil else { return }
            self?.showSwitchProgress(repository: repository, access: access, reference: reference, parent: parent, completion: { [weak controller] in controller?.model.load() })
        }
        revisionGraphWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func configureRevisionComparisonInteractions(_ model: RevisionComparisonWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        model.onLog = { [weak self] hash in self?.showLog(repository: repository, access: access, paths: [], endRevision: hash) }
        model.onFileLog = { [weak self] path, hash in self?.showLog(repository: repository, access: access, paths: [path], endRevision: hash) }
        model.onSubmoduleCompare = { [weak self] path, old, new in
            let from = old == .emptyTree ? "" : old == .workingTree ? "Working tree" : old.label
            let to = new == .emptyTree ? "" : new == .workingTree ? nil : new.label
            self?.showSubmoduleDiff(repository: repository, access: access, path: path, from: from, to: to)
        }
    }
    private func showWorkingFiles(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], amendToParent: Bool = false) {
        guard !busy, !confirmingQuit else { return }; busy = true
        let conflicts = paths.filter { path in entries.contains { $0.path == path && $0.state == .conflicted } }
        for path in conflicts { showConflictEditor(repository: repository, access: access, path: path) }
        let ordinary = paths.filter { !conflicts.contains($0) }
        guard !ordinary.isEmpty else { busy = false; return }
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let snapshot = try await repository.workingFileComparison(paths: ordinary, amendToParent: amendToParent)
                if snapshot.files.isEmpty { output = "No changes for the selected files."; return }
                showFileComparisons(repository: repository, access: access, snapshot: snapshot)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func showWorkingFilePair(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        guard !busy, !confirmingQuit else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let snapshot = try await repository.workingFilePairComparison(paths: paths)
                showFileComparisons(repository: repository, access: access, snapshot: snapshot)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func showPreparedFileComparison(repository: GitRepository, access: RepositoryAccessLease?, marked: PreparedFileComparisonMark, current: PreparedFileComparisonMark) {
        guard !busy, !confirmingQuit else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                if let workingAccess = marked.workingAccess {
                    if GitRuntime.isAppStoreBuild && (!workingAccess.permission.hasSecurityScope || !workingAccess.permission.contains(workingAccess.file)) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let key = "historical-working:" + UUID().uuidString
                    let controller: FileComparisonWindowController
                    if current.revision.isEmpty {
                        let file = repository.root.appendingPathComponent(current.path)
                        if GitRuntime.isAppStoreBuild && access?.contains(file) != true { throw RepositoryAccessFailure.securityScopeUnavailable }
                        let comparison = try WorkingFileComparison(base: workingAccess.file, destination: file)
                        _ = try comparison.read()
                        controller = FileComparisonWindowController(comparison: comparison, permissions: [workingAccess.permission] + [access].compactMap { $0 })
                    } else {
                        let comparison = try await repository.historicalWorkingFileComparison(revision: current.revision, path: current.path, workingFile: workingAccess.file)
                        controller = FileComparisonWindowController(repository: repository, access: access, comparison: comparison, permission: workingAccess.permission)
                    }
                    controller.onClosed = { [weak self] in self?.fileComparisonWindows.removeValue(forKey: key) }
                    fileComparisonWindows[key] = controller
                    controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
                    _ = try comparisonMarkStore.consume(workingAccess.mark.id)
                    try publishComparisonMark()
                } else {
                    let snapshot = try await repository.preparedPathComparison(from: marked.revision.isEmpty ? .workingTree : .revision(marked.revision), fromPath: marked.path, to: current.revision.isEmpty ? .workingTree : .revision(current.revision), toPath: current.path)
                    showFileComparisons(repository: repository, access: access, snapshot: snapshot)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func showHistoricalFilePair(repository: GitRepository, access: RepositoryAccessLease?, revision: String, files: [CommitFile]) {
        guard !busy, !confirmingQuit else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let snapshot = try await repository.historicalFilePairComparison(revision: revision, files: files)
                showFileComparisons(repository: repository, access: access, snapshot: snapshot)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func showGroupedHistoricalFiles(repository: GitRepository, access: RepositoryAccessLease?, requests: [(ComparisonRevision, ComparisonRevision, [String])]) {
        guard !busy, !confirmingQuit, !requests.isEmpty else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                var snapshots: [RevisionComparisonSnapshot] = []
                for (from, to, paths) in requests {
                    snapshots.append(try await repository.revisionFileComparison(from: from, to: to, paths: paths))
                }
                for snapshot in snapshots { showFileComparisons(repository: repository, access: access, snapshot: snapshot) }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func showHistoricalFiles(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision, paths: [String]) {
        guard !busy, !confirmingQuit else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let snapshot = try await repository.revisionFileComparison(from: from, to: to, paths: paths)
                if snapshot.files.isEmpty { output = "No files exist at the selected comparison paths."; return }
                showFileComparisons(repository: repository, access: access, snapshot: snapshot)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func showFileComparisons(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot) {
        for file in snapshot.files {
            if file.isSubmodule {
                showSubmoduleDiff(repository: repository, access: access, path: file.path, from: snapshot.from == .emptyTree ? "" : snapshot.from.label, to: snapshot.to == .workingTree ? nil : snapshot.to == .emptyTree ? "" : snapshot.to.label)
                continue
            }
            let key = repository.root.path + "\0" + file.path + "\0" + (file.oldPath ?? file.path) + "\0" + snapshot.from.label + "\0" + snapshot.to.label
            let controller = fileComparisonWindows[key] ?? FileComparisonWindowController(repository: repository, access: access, snapshot: snapshot, path: file.path)
            controller.onClosed = { [weak self] in self?.fileComparisonWindows.removeValue(forKey: key) }
            fileComparisonWindows[key] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
    }
    private func showSubmoduleSync(repository: GitRepository, access: RepositoryAccessLease?, scope: [String]) {
        guard !submoduleSyncWindows.values.contains(where: { $0.model.repository.root == repository.root && $0.model.activeOperation }) else { return }
        let id = UUID(), controller = SubmoduleSyncWindowController(repository: repository, access: access, scope: scope)
        controller.onClosed = { [weak self] in self?.submoduleSyncWindows.removeValue(forKey: id) }
        controller.model.onSynced = { [weak self] _ in
            self?.refreshRepositoryLogs(repository.root)
            if let self, self.root == repository.root { Task { await self.refresh() } }
        }
        submoduleSyncWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
    }
    private func showSubmoduleAdd(repository: GitRepository, access: RepositoryAccessLease?, path: String) {
        let key = repository.root.path
        let controller = submoduleAddWindows[key] ?? SubmoduleAddWindowController(repository: repository, access: access, path: path)
        controller.onClosed = { [weak self] in self?.submoduleAddWindows.removeValue(forKey: key) }
        controller.model.onSubmit = { [weak self] progress in self?.showSubmoduleAddProgress(model: progress) }
        submoduleAddWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showSubmoduleAddProgress(model: SubmoduleAddProgressWindowModel) {
        let root = model.repository.root, key = root.path, id = UUID()
        let controller = SubmoduleAddProgressWindowController(model: model)
        controller.onClosed = { [weak self] in self?.submoduleAddProgressWindows.removeValue(forKey: id) }
        model.onAdded = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            self?.statusWindows[key]?.model.reload(); self?.commitWindows[key]?.model.reload()
            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
        }
        submoduleAddProgressWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); model.start()
    }
    private func showSubmoduleUpdate(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], selected: [String] = [], completion: (() -> Void)? = nil) {
        let root = repository.root, key = root.path + "\0" + scope.joined(separator: "\0") + "\0" + selected.joined(separator: "\0")
        let controller = submoduleUpdateWindows[key] ?? SubmoduleUpdateWindowController(repository: repository, access: access, scope: scope, selected: selected)
        controller.onClosed = { [weak self] in self?.submoduleUpdateWindows.removeValue(forKey: key) }
        controller.model.onSubmit = { [weak self] paths, options in
            self?.showSubmoduleUpdateProgress(repository: repository, access: access, paths: paths, options: options, completion: completion)
        }
        submoduleUpdateWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showSubmoduleUpdateProgress(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], options: SubmoduleUpdateOptions, completion: (() -> Void)? = nil) {
        let root = repository.root, id = UUID()
        let controller = SubmoduleUpdateProgressWindowController(repository: repository, access: access, paths: paths, options: options)
        controller.onClosed = { [weak self] in self?.submoduleUpdateProgressWindows.removeValue(forKey: id) }
        controller.model.onUpdated = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
            completion?()
        }
        controller.model.onBisect = { [weak self] operation in self?.showBisect(repository: repository, access: access, operation: operation) }
        submoduleUpdateProgressWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
    }
    @discardableResult private func showRevertProgress(repository: GitRepository, access: RepositoryAccessLease?, entries: [StatusEntry], amend: Bool = false, againstHead: Bool = false, autoCloseSuccess: Bool = false, completion: @escaping (Bool) -> Void = { _ in }) -> RevertProgressWindowController {
        let root = repository.root, id = UUID()
        let controller = RevertProgressWindowController(repository: repository, access: access, entries: entries, amend: amend, againstHead: againstHead, autoCloseSuccess: autoCloseSuccess)
        controller.onClosed = { [weak self] in self?.revertProgressWindows.removeValue(forKey: id) }
        controller.model.onFinished = { [weak self] output, succeeded in
            completion(succeeded)
            self?.refreshRepositoryLogs(root)
            self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onHandleSubmodules = { [weak self] revision, paths in
            for path in paths { self?.showSubmoduleDiff(repository: repository, access: access, path: path, from: revision) }
        }
        revertProgressWindows[id] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
        return controller
    }
    private func showStatus(repository: GitRepository, access: RepositoryAccessLease?, paths: [String] = []) {
        let root = repository.root
        section = .status
        let controller = statusWindows[root.path] ?? StatusWindowController(repository: repository, access: access)
        controller.onPullAfterLFSLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.onClosed = { [weak self] in self?.statusWindows.removeValue(forKey: root.path) }
        controller.model.onAction = { [weak self] action, paths in
            guard let self else { return }
            if self.root != root, let access {
                self.openSession(access, action: action, actionPaths: paths); return
            }
            self.activate(action, paths: paths)
            if action != .clean && action != .add && action != .diff && action != .submoduleSync && action != .submoduleAdd && action != .submoduleUpdate && action != .commit && action != .revert && action != .log && action != .switchBranch && action != .branch && action != .tag && action != .push && action != .fetch && action != .pull && action != .rebase && action != .merge && action != .mergeAbort && action != .export && action != .bisect && action != .bisectStart && action.bisectOperation == nil && action != .stash && action != .stashApply && action != .stashPop && action != .stashList && action != .reflog && action != .rename && !action.isIgnore && !action.isResolve && action != .reset { self.workspaceWindow?.makeKeyAndOrderFront(nil) }
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
        controller.model.onLog = { [weak self] hash in self?.showLog(repository: repository, access: access, paths: [], endRevision: hash, selectedRevision: hash) }
        controller.model.onLogRange = { [weak self] range in self?.showLog(repository: repository, access: access, paths: [], revisionRange: range) }
        controller.model.onBrowseRepository = { [weak self] hash in self?.showRepositoryBrowser(repository: repository, access: access, revision: hash) }
        controller.model.onCreateReference = { [weak self] isTag, hash in self?.showReference(repository: repository, access: access, isTag: isTag, revision: hash) }
        controller.model.onExport = { [weak self] hash in self?.showExport(repository: repository, access: access, revision: hash) }
        controller.model.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: from, to: to) }
        controller.model.onCheckout = { [weak self] hash in self?.showSwitch(repository: repository, access: access, revision: hash) }
        controller.model.onReset = { [weak self] hash in self?.showReset(repository: repository, access: access, revision: hash) }
        controller.model.onSwitchBranch = { [weak self, weak controller] reference in
            guard let parent = controller?.window, parent.attachedSheet == nil else { return }
            self?.showSwitchProgress(repository: repository, access: access, reference: reference, parent: parent)
        }
        controller.model.onApply = { [weak self] hash in self?.showStashRestore(repository: repository, access: access, pop: false, reference: hash) }
        controller.model.onChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        referenceLogWindows[root.path] = controller
        controller.model.reference = reference; controller.model.reload()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showStashRestore(repository: GitRepository, access: RepositoryAccessLease?, pop: Bool, reference: String? = nil, showChanges: Int = 1) {
        let root = repository.root, key = repository.root.path + (pop ? ":pop" : ":apply:" + (reference ?? "latest")) + ":show:" + String(showChanges)
        if let existing = stashRestoreWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = StashRestoreWindowController(repository: repository, access: access, pop: pop, reference: reference, showChanges: showChanges)
        controller.onClosed = { [weak self] in self?.stashRestoreWindows.removeValue(forKey: key) }
        controller.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.reload(); self?.refreshRepositoryLogs(root)
            self?.commitWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.onViewChanges = { [weak self] in self?.showStatus(repository: repository, access: access) }
        stashRestoreWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.start()
    }
    private func showWorktreeList(repository: GitRepository, access: RepositoryAccessLease?) {
        let key = repository.root.path
        let controller = worktreeListWindows[key] ?? WorktreeListWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.worktreeListWindows.removeValue(forKey: key) }
        controller.onSubmodules = { [weak self] path, lease in
            self?.showSubmoduleUpdate(repository: GitRepository(root: path, executable: repository.executable), access: lease, scope: [])
        }
        worktreeListWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showWorktreeCreate(repository: GitRepository, access: RepositoryAccessLease?) {
        let key = repository.root.path
        let controller = worktreeCreateWindows[key] ?? WorktreeCreateWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.worktreeCreateWindows.removeValue(forKey: key) }
        controller.model.onCreated = { [weak self] output in
            if self?.root?.path == key { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onSubmodules = { [weak self] path, lease in
            self?.showSubmoduleUpdate(repository: GitRepository(root: path, executable: repository.executable), access: lease, scope: [])
        }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
        worktreeCreateWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showRequestPull(repository: GitRepository, access: RepositoryAccessLease?, end: String? = nil, repositoryURL: String? = nil) {
        let key = repository.root.path + ":requestPull:" + UUID().uuidString
        let controller = RequestPullWindowController(repository: repository, access: access, end: end, repositoryURL: repositoryURL)
        controller.onClosed = { [weak self] in self?.requestPullWindows.removeValue(forKey: key) }
        requestPullWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showImportPatch(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        let key = repository.root.path
        let controller = importPatchWindows[key] ?? ImportPatchWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.importPatchWindows.removeValue(forKey: key) }
        controller.model.onChanged = { [weak self] output in
            self?.statusWindows[key]?.model.reload()
            if self?.root?.path == key { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.add(paths.map { repository.root.appendingPathComponent($0) }.filter { ["patch", "diff"].contains($0.pathExtension.lowercased()) })
        importPatchWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showFormatPatch(repository: GitRepository, access: RepositoryAccessLease?, preset: FormatPatchPreset? = nil, sendMail: Bool = false) {
        let rootKey = repository.root.path
        let suffix: String
        switch preset?.selection {
        case .since(let revision): suffix = "\0since\0" + revision
        case .range(let from, let to): suffix = "\0range\0" + from + "\0" + to
        case .number(let count): suffix = "\0number\0" + String(count)
        case nil: suffix = ""
        }
        let key = rootKey + suffix
        let existing = formatPatchWindows[key]
        let controller = existing ?? FormatPatchWindowController(repository: repository, access: access, preset: preset, sendMail: sendMail)
        if existing != nil { controller.model.apply(preset) }
        if sendMail && !controller.model.busy && !controller.model.progress && !controller.model.composingMail { controller.model.sendMail = true }
        controller.onClosed = { [weak self] in self?.formatPatchWindows.removeValue(forKey: key) }
        controller.model.onOutputChanged = { [weak self] output in
            self?.statusWindows[rootKey]?.model.reload()
            if self?.root?.path == rootKey { self?.output = output; Task { await self?.refresh() } }
        }
        formatPatchWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showRepositoryBrowser(repository: GitRepository, access: RepositoryAccessLease?, revision: String = "HEAD") {
        let baseKey = repository.root.path + "\0" + revision
        let reusable = browserWindows.first { _, controller in
            controller.model.repository.root == repository.root && controller.model.repository.executable == repository.executable &&
            controller.window?.attachedSheet == nil && controller.model.canReuseForRevision(revision)
        }
        let key = reusable?.key ?? (browserWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? RepositoryBrowserWindowController(repository: repository, access: access, revision: revision)
        controller.onClosed = { [weak self] in self?.browserWindows.removeValue(forKey: key) }
        controller.model.onLog = { [weak self] path, hash in self?.showLog(repository: repository, access: access, paths: path.isEmpty ? [] : [path], endRevision: hash) }
        controller.model.onBlame = { [weak self] path, hash in self?.showBlame(repository: repository, access: access, path: path, revision: hash) }
        controller.model.onCompare = { [weak self] path, hash in self?.showHistoricalFiles(repository: repository, access: access, from: .revision(hash), to: .workingTree, paths: [path]) }
        controller.model.onChanged = { [weak self] in
            guard let self else { return }
            self.statusWindows[repository.root.path]?.model.reload()
            self.commitWindows[repository.root.path]?.model.reload()
            if self.root == repository.root { Task { await self.refresh() } }
        }
        controller.model.importWorkingComparisonMark(try? comparisonMarkStore.acquire(requireSecurityScope: GitRuntime.isAppStoreBuild))
        controller.model.onPreparedFileCompare = { [weak self] marked, current in self?.showPreparedFileComparison(repository: repository, access: access, marked: marked, current: current) }
        controller.model.onSubmodule = { [weak self, weak model = controller.model, weak window = controller.window] snapshot, entry, showLog in
            guard model?.busy == false, model?.confirmingQuit == false else { return }
            model?.busy = true
            Task {
                defer { model?.busy = false; withExtendedLifetime(access) {} }
                do {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let module = try await repository.repositoryBrowserSubmodule(snapshot, entry: entry)
                    guard let model, let window, window.isVisible else { return }
                    guard let checkout = module.checkout, module.from.available else {
                        if showLog {
                            model.error = "Cannot show submodule history at " + entry.objectID + ". The child repository is not initialized or the revision is unavailable."
                            return
                        }
                        guard window.attachedSheet == nil else { return }
                        let alert = NSAlert(); alert.messageText = "Update submodule?"
                        alert.informativeText = "Revision " + entry.objectID + " is unavailable in submodule “" + entry.path + "”. Update the submodule to browse it."
                        alert.addButton(withTitle: "Update"); alert.addButton(withTitle: "Cancel")
                        alert.beginSheetModal(for: window) { [weak self] response in
                            if response == .alertFirstButtonReturn { self?.showSubmoduleUpdate(repository: repository, access: access, scope: [], selected: [entry.path]) }
                        }
                        return
                    }
                    let child = GitRepository(root: checkout, executable: repository.executable)
                    if showLog { self?.showLog(repository: child, access: access, paths: [], endRevision: entry.objectID) }
                    else { self?.showRepositoryBrowser(repository: child, access: access, revision: entry.objectID) }
                } catch { model?.error = error.localizedDescription }
            }
        }
        browserWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showBlame(repository: GitRepository, access: RepositoryAccessLease?, path: String, revision: String, line: Int? = nil, options: GitBlameOptions? = nil) {
        let key = repository.root.path + "\0" + path + "\0" + revision
        let controller = blameWindows[key] ?? BlameWindowController(repository: repository, access: access, path: path, revision: revision, options: options ?? GitBlamePreferences.load())
        controller.onClosed = { [weak self] in self?.blameWindows.removeValue(forKey: key) }
        controller.model.onLog = { [weak self] origin, hash in self?.showLog(repository: repository, access: access, paths: [origin], endRevision: hash) }
        controller.model.onChanges = { [weak self] snapshot in self?.showFileComparisons(repository: repository, access: access, snapshot: snapshot) }
        controller.model.onPrevious = { [weak self] origin, hash, number, inherited in self?.showBlame(repository: repository, access: access, path: origin, revision: hash, line: number, options: inherited) }
        if let options { controller.model.configure(options: options, line: line) }
        else if let line { controller.model.selectOriginalLine(line) }
        blameWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func refreshRepositoryLogs(_ root: URL) {
        for log in logWindows.values where log.model.repository.root == root && !log.model.isInvalidated { log.model.requestRepositoryRefresh() }
        for graph in revisionGraphWindows.values where graph.model.repository.root == root && !graph.model.closed { graph.requestRepositoryRefresh() }
    }
    private func showLog(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], endRevision: String? = nil, selectedRevision: String? = nil, revisionRange: HistoryRevisionRange? = nil) {
        let root = repository.root
        var baseKey = root.path
        if let revisionRange { baseKey += "\0range\0" + revisionRange.expression }
        else if let endRevision { baseKey += "\0" + endRevision }
        if !paths.isEmpty { baseKey += "\0paths\0" + paths.sorted().joined(separator: "\0") }
        let reusable: (key: String, value: LogWindowController)?
        if let revisionRange {
            reusable = logWindows.first { _, controller in
                controller.model.repository.root == root && controller.model.repository.executable == repository.executable &&
                controller.window?.attachedSheet == nil && controller.model.canReuseForRange(revisionRange)
            }
        } else { reusable = logWindows[baseKey].map { (key: baseKey, value: $0) } }
        let key = reusable?.key ?? (logWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? LogWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.logWindows.removeValue(forKey: key) }
        controller.model.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        controller.model.onFormatPatch = { [weak self] preset in self?.showFormatPatch(repository: repository, access: access, preset: preset) }
        controller.model.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
        controller.model.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
        configureLogSwitch(controller.model, repository: repository, access: access)
        controller.model.onCherryPick = { [weak self] commits in self?.showRebase(repository: repository, access: access, cherryPick: commits) }
        controller.model.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision, paths: paths) }
        controller.model.onMergeRevision = { [weak self] revision in self?.showMerge(repository: repository, access: access, revision: revision) }
        controller.model.onRebaseRevision = { [weak self] revision in self?.showRebase(repository: repository, access: access, upstream: revision, fromLog: true) }
        configureLogBisect(controller.model, repository: repository, access: access)
        controller.model.onWorkingCommand = { [weak self] action in
            switch action {
            case .stash: self?.showStash(repository: repository, access: access)
            case .stashPop: self?.showStashRestore(repository: repository, access: access, pop: true)
            case .stashList: self?.showReferenceLog(repository: repository, access: access, reference: "refs/stash")
            case .pull, .fetch: self?.showFetch(repository: repository, access: access, isPull: action == .pull)
            case .submoduleUpdate: self?.showSubmoduleUpdate(repository: repository, access: access, scope: [])
            default: break
            }
        }
        controller.model.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
        controller.model.onContainingLog = { [weak self] name, select, range in
            self?.showLog(repository: repository, access: access, paths: [], endRevision: name, selectedRevision: select ? name : nil, revisionRange: range)
        }
        controller.model.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: from, to: to) }
        controller.model.importWorkingComparisonMark(try? comparisonMarkStore.acquire(requireSecurityScope: GitRuntime.isAppStoreBuild))
        controller.model.onPreparedFileCompare = { [weak self] marked, current in self?.showPreparedFileComparison(repository: repository, access: access, marked: marked, current: current) }
        controller.model.onFilePairCompare = { [weak self] revision, files in self?.showHistoricalFilePair(repository: repository, access: access, revision: revision, files: files) }
        controller.model.onWorkingFiles = { [weak self] action, paths in
            if action == .add { self?.showAdd(repository: repository, access: access, paths: paths) }
            else if action == .commit { self?.showCommitDialog(repository: repository, access: access, paths: paths) }
            else if action == .revert { self?.showRevert(repository: repository, access: access, paths: paths) }
        }
        controller.model.onWorkingAdd = { [weak self] paths, mode in
            self?.showAddProgress(repository: repository, access: access, paths: paths, mode: mode)
        }
        controller.model.onIgnoreFiles = { [weak self] action, paths in
            self?.showIgnore(repository: repository, access: access, paths: paths, action: action)
        }
        controller.model.onWorkingFilePairCompare = { [weak self] paths in self?.showWorkingFilePair(repository: repository, access: access, paths: paths) }
        controller.model.onConflictAction = { [weak self] action, paths in
            if action == .editConflict, let path = paths.first { self?.showConflictEditor(repository: repository, access: access, path: path) }
            else { self?.showResolve(repository: repository, access: access, paths: paths, quick: action.resolveChoice) }
        }
        controller.model.onFileCompare = { [weak self] from, to, paths in self?.showHistoricalFiles(repository: repository, access: access, from: from, to: to, paths: paths) }
        controller.model.onFileComparisons = { [weak self] requests in self?.showGroupedHistoricalFiles(repository: repository, access: access, requests: requests) }
        controller.model.onFileLog = { [weak self] path, hash in self?.showLog(repository: repository, access: access, paths: [path], endRevision: hash) }
        controller.model.onSubmoduleFileLog = { [weak self] checkout, hash in
            let child = GitRepository(root: checkout, executable: repository.executable)
            self?.showLog(repository: child, access: access, paths: [], endRevision: hash)
        }
        controller.model.onBlame = { [weak self] path, hash in self?.showBlame(repository: repository, access: access, path: path, revision: hash) }
        controller.model.onCommit = { [weak self] in
            guard let self else { return }
            if self.root == root { self.activate(.commit) }
            else if let access { self.openSession(access, action: .commit) }
        }
        controller.model.onRevisionChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onBrowseRepository = { [weak self] hash in self?.showRepositoryBrowser(repository: repository, access: access, revision: hash) }
        logWindows[key] = controller
        controller.model.endRevision = endRevision
        controller.model.revisionRange = revisionRange
        let location = paths.count == 1 ? root.lastPathComponent + "/" + paths[0] : root.lastPathComponent
        controller.window?.title = location + " – Log Messages" + (endRevision.map { " at " + $0.prefix(7) } ?? "") + " – TurtleGit"
        controller.model.setPathScope(paths)
        if let selectedRevision { ReferenceLogWindowModel.configureRevisionLog(controller.model, revision: selectedRevision) }
        if let revisionRange {
            ReferenceLogWindowModel.configureRangeLog(controller.model, range: revisionRange)
            controller.window?.title = location + " – Log Messages " + revisionRange.expression + " – TurtleGit"
        }
        controller.model.reload()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }

    private func configureLogSwitch(_ model: LogWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        model.onSwitchBranch = { [weak self, weak model] reference in
            guard let parent = model?.window, parent.attachedSheet == nil else { return }
            self?.showSwitchProgress(repository: repository, access: access, reference: reference, parent: parent)
        }
    }
    private func configureLogBisect(_ model: LogWindowModel, repository: GitRepository, access: RepositoryAccessLease?, refreshPicker: Bool = false) {
        model.onBisect = { [weak self, weak model] request in
            self?.showBisect(repository: repository, access: access, good: request.good, bad: request.bad, operation: request.operation, revisions: request.revisions, requireStart: request.operation == nil, sourceLog: refreshPicker ? model : nil)
        }
    }
    private func showBisect(repository: GitRepository, access: RepositoryAccessLease?, good: String? = nil, bad: String? = nil, operation: BisectOperation? = nil, revisions: [String] = [], requireStart: Bool = false, sourceLog: LogWindowModel? = nil) {
        let root = repository.root
        let controller: BisectWindowController
        if let existing = bisectWindows[root.path] {
            controller = existing
            if !existing.activeOperation { existing.model.load(good: good, bad: bad, operation: operation, revisions: revisions, requireStart: requireStart) }
        } else { controller = BisectWindowController(repository: repository, access: access, good: good, bad: bad, operation: operation, revisions: revisions, requireStart: requireStart) }
        if let sourceLog { controller.model.observeLog(sourceLog) }
        controller.onClosed = { [weak self] in self?.bisectWindows.removeValue(forKey: root.path) }
        controller.model.onChanged = { [weak self] output in
            guard let self else { return }
            self.refreshRepositoryLogs(root)
            self.commitWindows[root.path]?.model.reload(); self.statusWindows[root.path]?.model.reload()
            if self.root == root { self.output = output; Task { await self.refresh() } }
        }
        controller.model.onSubmoduleUpdate = { [weak self] in self?.showSubmoduleUpdate(repository: repository, access: access, scope: []) }
        bisectWindows[root.path] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showExport(repository: GitRepository, access: RepositoryAccessLease?, revision: String, paths: [String] = []) {
        let root = repository.root
        let directory = ExportWindowModel.directoryScope(root: root, paths: paths)
        let baseKey = root.path + "\0" + revision + "\0" + directory
        let reusable = exportWindows.first { _, controller in
            controller.model.repository.root == repository.root && controller.model.repository.executable == repository.executable &&
            controller.window?.attachedSheet == nil && controller.model.canReuseForRevision(revision, directory: directory)
        }
        let key = reusable?.key ?? (exportWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? ExportWindowController(repository: repository, access: access, revision: revision, directory: directory)
        controller.onClosed = { [weak self] in self?.exportWindows.removeValue(forKey: key) }
        exportWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showMergeAbort(repository: GitRepository, access: RepositoryAccessLease?) {
        let id = UUID(), root = repository.root
        let controller = MergeAbortWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.mergeAbortWindows.removeValue(forKey: id) }
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.statusWindows[root.path]?.model.reload()
            self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPostAction = { [weak self] action in
            if let operation = action.bisectOperation { self?.showBisect(repository: repository, access: access, operation: operation) }
            else if action == .submoduleUpdate { self?.showSubmoduleUpdate(repository: repository, access: access, scope: []) }
            else if action == .clean { self?.showClean(repository: repository, access: access, paths: []) }
        }
        mergeAbortWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func configureMergeInteractions(_ controller: MergeWindowController, repository: GitRepository, access: RepositoryAccessLease?, showStashPop: Bool = false) {
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
        let root = repository.root
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.reload(); self?.refreshRepositoryLogs(root)
            self?.commitWindows[root.path]?.model.reload()
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.configureLogPicker = { [weak self] log in
            log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
            log.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
            log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
            self?.configureLogSwitch(log, repository: repository, access: access)
            log.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision) }
            log.onMergeRevision = { [weak self] revision in self?.showMerge(repository: repository, access: access, revision: revision) }
            log.onRebaseRevision = { [weak self] revision in self?.showRebase(repository: repository, access: access, upstream: revision, fromLog: true) }
            self?.configureLogBisect(log, repository: repository, access: access, refreshPicker: true)
                log.onCherryPick = { [weak self] commits in self?.showRebase(repository: repository, access: access, cherryPick: commits) }
            log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
        }
        controller.model.showStashPop = showStashPop
        controller.model.onAbortRequested = { [weak self] in self?.showMergeAbort(repository: repository, access: access) }
        controller.model.onPostAction = { [weak self] action, request in
            switch action {
            case .resolve: self?.showResolve(repository: repository, access: access, paths: [], quick: nil)
            case .commit: self?.showCommitDialog(repository: repository, access: access, paths: [])
            case .stash:
                var followUp = StashSaveFollowUp(); followUp.mergeRevision = request.revision
                self?.showStash(repository: repository, access: access, followUp: followUp)
            case .stashPop: self?.showStashRestore(repository: repository, access: access, pop: true)
            case .push: self?.showPush(repository: repository, access: access)
            case .mergeUnrelated, .removeBranch: break
            }
        }
    }
    private func showMerge(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, showStashPop: Bool = false) {
        let key = repository.root.path + "\0" + UUID().uuidString
        let controller = MergeWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.mergeWindows.removeValue(forKey: key) }
        configureMergeInteractions(controller, repository: repository, access: access, showStashPop: showStashPop)
        mergeWindows[key] = controller; controller.model.load(revision: revision)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showStash(repository: GitRepository, access: RepositoryAccessLease?, followUp: StashSaveFollowUp = StashSaveFollowUp()) {
        let root = repository.root, key = repository.root.path + "\0" + UUID().uuidString
        let controller = StashWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.stashWindows.removeValue(forKey: key) }
        let changed: (String) -> Void = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.reload(); self?.refreshRepositoryLogs(root)
            self?.commitWindows[root.path]?.model.reload()
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onSaved = { result in changed(result.output) }
        controller.model.onFailed = changed
        controller.model.followUp = followUp
        controller.model.onPostAction = { [weak self] action, request in
            switch action {
            case .pull: self?.showFetch(repository: repository, access: access, isPull: true, followUp: PullFollowUp(stashSave: request))
            case .merge: if let revision = request.mergeRevision { self?.showMerge(repository: repository, access: access, revision: revision, showStashPop: true) }
            case .pop, .apply: self?.showStashRestore(repository: repository, access: access, pop: action == .pop)
            }
        }
        stashWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func configureCommitInteractions(_ model: CommitWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        model.onCommitSubmodule = { [weak self] checkout in
            guard !GitRuntime.isAppStoreBuild || access?.hasSecurityScope == true && access?.contains(checkout) == true else { self?.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
            self?.showCommitDialog(repository: GitRepository(root: checkout, executable: repository.executable), access: access, paths: [])
        }
        model.onCompare = { [weak self] paths, amendToParent in
            self?.showWorkingFiles(repository: repository, access: access, paths: paths, amendToParent: amendToParent)
        }
        model.onCompareTwoFiles = { [weak self] paths in
            self?.showWorkingFilePair(repository: repository, access: access, paths: paths)
        }
        model.onFileLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path]) }
        model.onFileBlame = { [weak self] path in self?.showBlame(repository: repository, access: access, path: path, revision: "HEAD") }
        model.onResolve = { [weak self] action, paths in
            if action == .editConflict, let path = paths.first { self?.showConflictEditor(repository: repository, access: access, path: path) }
            else { self?.showResolve(repository: repository, access: access, paths: paths, quick: action.resolveChoice) }
        }
        model.onIgnore = { [weak self] action, paths in self?.showIgnore(repository: repository, access: access, paths: paths, action: action) }
        model.onRevert = { [weak self, weak model] entries, amend, againstHead, done in
            guard let self else { done(false); return }
            self.showRevertProgress(repository: repository, access: access, entries: entries, amend: amend, againstHead: againstHead, autoCloseSuccess: !entries.contains(where: { model?.submodules.contains($0.path) == true }), completion: done)
        }
        model.onRename = { [weak self] path in self?.showRename(repository: repository, access: access, source: path) }
        model.configureLogPicker = { [weak self] log in
            log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
            log.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
            log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
            self?.configureLogSwitch(log, repository: repository, access: access)
            log.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision) }
            log.onMergeRevision = { [weak self] revision in self?.showMerge(repository: repository, access: access, revision: revision) }
            log.onRebaseRevision = { [weak self] revision in self?.showRebase(repository: repository, access: access, upstream: revision, fromLog: true) }
            self?.configureLogBisect(log, repository: repository, access: access, refreshPicker: true)
            log.onCherryPick = { [weak self] commits in self?.showRebase(repository: repository, access: access, cherryPick: commits) }
        log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
        }
    }
    private func showRebase(repository: GitRepository, access: RepositoryAccessLease?, upstream: String? = nil, autoStart: Bool = false, preserveMerges: Bool = false, cherryPick: [String]? = nil, afterFetch: Bool = false, fromLog: Bool = false, owner: NSWindow? = nil, onDismissed: (() -> Void)? = nil) {
        let root = repository.root
        let existing = rebaseWindows[root.path]
        if let existing, existing.window?.sheetParent != nil { existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = existing ?? RebaseWindowController(repository: repository, access: access)
        var dismissed = false
        controller.onClosed = { [weak self, weak controller] in
            guard !dismissed else { return }; dismissed = true
            if let window = controller?.window { window.sheetParent?.endSheet(window) }
            self?.rebaseWindows.removeValue(forKey: root.path); onDismissed?()
        }
        controller.model.onChanged = { [weak self] in
            self?.refreshRepositoryLogs(root); self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
            if self?.root == root { Task { await self?.refresh() } }
        }
        controller.model.onShowStatus = { [weak self] in
            guard let self else { return }
            if self.root == root { self.activate(.status) }
            else if let access { self.openSession(access, action: .status) }
        }
        controller.model.onConflictAction = { [weak self] action, paths in
            if action == .editConflict, let path = paths.first { self?.showConflictEditor(repository: repository, access: access, path: path) }
            else { self?.showResolve(repository: repository, access: access, paths: paths, quick: action.resolveChoice) }
        }
        controller.model.completionAfterFetch = afterFetch
        controller.model.completionFromLog = fromLog
        controller.model.completionAutoStart = autoStart
        controller.model.onCompletedLog = { [weak self] in self?.showLog(repository: repository, access: access, paths: []) }
        controller.model.onCompletedPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        controller.model.onCompletedMail = { [weak self] preset in self?.showFormatPatch(repository: repository, access: access, preset: preset, sendMail: true) }
        controller.model.configureCommitSelection = { [weak self] commit in self?.configureCommitInteractions(commit, repository: repository, access: access) }
        let revisionLog = controller.model.revisionMenuLog
        revisionLog.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: from, to: to) }
        revisionLog.onBrowseRepository = { [weak self] hash in self?.showRepositoryBrowser(repository: repository, access: access, revision: hash) }
        revisionLog.onCreateReference = { [weak self] tag, hash in self?.showReference(repository: repository, access: access, isTag: tag, revision: hash) }
        revisionLog.onPush = { [weak self] hash in self?.showPush(repository: repository, access: access, source: hash) }
        revisionLog.onFormatPatch = { [weak self] preset in self?.showFormatPatch(repository: repository, access: access, preset: preset) }
        revisionLog.onRevisionChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output }
        }
        controller.model.onShowRevisionLog = { [weak self] hash in self?.showLog(repository: repository, access: access, paths: [], endRevision: hash) }
        controller.model.configureLogPicker = { [weak self] log in
            log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
            log.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
            log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
            self?.configureLogSwitch(log, repository: repository, access: access)
            log.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision) }
            log.onMergeRevision = { [weak self] revision in self?.showMerge(repository: repository, access: access, revision: revision) }
            log.onRebaseRevision = { [weak self] revision in self?.showRebase(repository: repository, access: access, upstream: revision, fromLog: true) }
            self?.configureLogBisect(log, repository: repository, access: access, refreshPicker: true)
            log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
        }
        rebaseWindows[root.path] = controller
        if existing == nil || controller.model.finished || upstream != nil || cherryPick != nil { controller.model.load(upstream: upstream, autoStart: autoStart, preserveMerges: preserveMerges, cherryPick: cherryPick) }
        if let owner, let child = controller.window { owner.beginSheet(child) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
    }
    private func configureFetchInteractions(_ controller: FetchWindowController, repository: GitRepository, access: RepositoryAccessLease?, followUp: PullFollowUp = PullFollowUp()) {
        let root = repository.root
        controller.model.onShowStatus = { [weak self] in
            guard let self else { return }
            if self.root == root { self.activate(.status) }
            else if let access { self.openSession(access, action: .status) }
        }
        controller.model.onFetched = { [weak self, weak controller] output in
            guard controller?.model.progress == nil, controller?.model.fetchProgress == nil else { return }
            self?.refreshRepositoryLogs(root)
            self?.statusWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.followUp = followUp
        controller.model.onChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root); self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.referenceLogWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPullPostAction = { [weak self] action, result in
            switch action {
            case .resolve: self?.showResolve(repository: repository, access: access, paths: [], quick: nil)
            case .commit: self?.showCommitDialog(repository: repository, access: access, paths: [])
            case .pull: self?.showFetch(repository: repository, access: access, isPull: true)
            case .stash:
                var request = StashSaveFollowUp(); request.showPull = true
                self?.showStash(repository: repository, access: access, followUp: request)
            case .reset: self?.showReset(repository: repository, access: access, revision: result.resetRevision.isEmpty ? "HEAD" : result.resetRevision, mode: .hard)
            case .stashPop: self?.showStashRestore(repository: repository, access: access, pop: true)
            case .diff: self?.showRevisionComparison(repository: repository, access: access, from: .revision(result.oldHead), to: .revision(result.newHead))
            case .log: self?.showLog(repository: repository, access: access, paths: [], revisionRange: HistoryRevisionRange(from: result.oldHead, to: result.newHead))
            case .push: self?.showPush(repository: repository, access: access)
            case .submoduleUpdate: self?.showSubmoduleUpdate(repository: repository, access: access, scope: [])
            case .mergeUnrelated: break
            }
        }
        controller.model.onFetchPostAction = { [weak self] action, revision in
            switch action {
            case .log: self?.showLog(repository: repository, access: access, paths: [])
            case .reset: self?.showReset(repository: repository, access: access, revision: revision.isEmpty ? "HEAD" : revision, mode: .hard)
            case .fetch: self?.showFetch(repository: repository, access: access)
            case .rebase: self?.showRebase(repository: repository, access: access, afterFetch: true)
            case .switchBranch: self?.showSwitch(repository: repository, access: access)
            case .resolve: self?.showCommitDialog(repository: repository, access: access, paths: [])
            case .retry: break
            }
        }
        controller.model.onRebase = { [weak self] upstream, autoStart, preserveMerges in
            self?.showRebase(repository: repository, access: access, upstream: upstream, autoStart: autoStart, preserveMerges: preserveMerges, afterFetch: true)
        }
    }
    private func showFetch(repository: GitRepository, access: RepositoryAccessLease?, isPull: Bool = false, followUp: PullFollowUp = PullFollowUp(), remote: String? = nil, allRemotes: Bool? = nil) {
        let key = repository.root.path + (isPull ? ":pull:" : ":fetch:") + UUID().uuidString
        let controller = FetchWindowController(repository: repository, access: access, isPull: isPull)
        controller.onClosed = { [weak self] in self?.fetchWindows.removeValue(forKey: key) }
        configureFetchInteractions(controller, repository: repository, access: access, followUp: followUp)
        fetchWindows[key] = controller; controller.model.load(remote: remote, allRemotes: allRemotes)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showPush(repository: GitRepository, access: RepositoryAccessLease?, source: String? = nil) {
        let root = repository.root, key = repository.root.path + ":push:" + UUID().uuidString
        let controller = PushWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.pushWindows.removeValue(forKey: key) }
        controller.model.onTransportResult = { [weak self] output, _ in
            self?.refreshRepositoryLogs(root); self?.statusWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.referenceLogWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPostAction = { [weak self] action, options, superproject in
            guard let self else { return }
            switch action {
            case .requestPull: self.showRequestPull(repository: repository, access: access, end: options.destination)
            case .push: self.showPush(repository: repository, access: access, source: options.source)
            case .switchBranch: self.showSwitch(repository: repository, access: access)
            case .pull: self.showFetch(repository: repository, access: access, isPull: true, followUp: PullFollowUp(showPush: true))
            case .fetch: self.showFetch(repository: repository, access: access, remote: options.allRemotes ? nil : options.remote, allRemotes: options.allRemotes)
            case .commitSuperproject:
                guard let superproject else { return }
                if !GitRuntime.isAppStoreBuild || access?.hasSecurityScope == true && access?.contains(superproject) == true {
                    self.showCommitDialog(repository: GitRepository(root: superproject, executable: repository.executable), access: access, paths: [])
                } else {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.directoryURL = superproject
                    panel.prompt = "Authorize super project"; panel.message = "Choose the super project folder to open its Commit dialog."
                    panel.begin { [weak self] response in
                        guard response == .OK, let folder = panel.url else { return }
                        let lease = RepositoryAccessLease(url: folder)
                        guard lease.hasSecurityScope, lease.contains(superproject) else { self?.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
                        self?.showCommitDialog(repository: GitRepository(root: superproject, executable: repository.executable), access: lease, paths: [])
                    }
                }
            }
        }
        pushWindows[key] = controller; controller.model.load(source: source)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func configureReferenceInteractions(_ controller: BranchTagWindowController, repository: GitRepository, access: RepositoryAccessLease?) {
        let root = repository.root
        controller.model.onCreated = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            self?.statusWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onSwitch = { [weak self, weak controller] reference, done in
            guard let self, let parent = controller?.window, parent.attachedSheet == nil else { done(); return }
            self.showSwitchProgress(repository: repository, access: access, reference: reference, parent: parent, completion: done)
        }
        controller.model.onPushTag = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
    }
    private func showReference(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool, revision: String? = nil) {
        let key = repository.root.path + (isTag ? ":tag:" : ":branch:") + UUID().uuidString
        let controller = referenceWindows[key] ?? BranchTagWindowController(repository: repository, access: access, isTag: isTag)
        controller.onClosed = { [weak self] in self?.referenceWindows.removeValue(forKey: key) }
        configureReferenceInteractions(controller, repository: repository, access: access)
        referenceWindows[key] = controller; controller.model.load(revision: revision)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showSwitchProgress(repository: GitRepository, access: RepositoryAccessLease?, reference: String, parent: NSWindow, completion: (() -> Void)? = nil) {
        let id = UUID(), root = repository.root
        let controller = SwitchProgressWindowController(repository: repository, access: access, reference: reference)
        controller.onClosed = { [weak self] in self?.switchProgressWindows.removeValue(forKey: id) }
        controller.model.onFinished = { [weak self] output, _ in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.commitWindows[root.path]?.model.reload(); self?.statusWindows[root.path]?.model.reload()
            self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPostAction = { [weak self] action, branch in self?.performSwitchPostAction(action, previousBranch: branch, repository: repository, access: access) }
        switchProgressWindows[id] = controller
        if let window = controller.window { parent.beginSheet(window) { _ in completion?() } }
        controller.model.start()
    }
    private func performSwitchPostAction(_ action: SwitchPostAction, previousBranch: String, repository: GitRepository, access: RepositoryAccessLease?) {
        switch action {
        case .submoduleUpdate: showSubmoduleUpdate(repository: repository, access: access, scope: [])
        case .mergePreviousBranch: showMerge(repository: repository, access: access, revision: "refs/heads/" + previousBranch)
        case .pull: showFetch(repository: repository, access: access, isPull: true)
        case .commit, .resolve: showCommitDialog(repository: repository, access: access, paths: [])
        case .stash:
            var followUp = StashSaveFollowUp(); followUp.showPull = true
            showStash(repository: repository, access: access, followUp: followUp)
        case .retry, .switchWithMerge: break
        }
    }
    private func showReferenceBrowser(repository: GitRepository, access: RepositoryAccessLease?) {
        let key = repository.root.path
        if let existing = referenceBrowserWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = ReferenceBrowserWindowController(repository: repository, access: access, initial: "HEAD", picking: false) { _ in }
        configureReferenceBrowser(controller.model, repository: repository, access: access)
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller, self.referenceBrowserWindows[key] === controller else { return }
            self.referenceBrowserWindows.removeValue(forKey: key)
        }
        referenceBrowserWindows[key] = controller
        controller.model.load(); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func configureReferenceBrowser(_ model: ReferenceBrowserWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        model.configureComparison = { [weak self] comparison in self?.configureRevisionComparisonInteractions(comparison, repository: repository, access: access) }
        model.onLogRange = { [weak self] range in self?.showLog(repository: repository, access: access, paths: [], revisionRange: range) }
        model.onLog = { [weak self] name in self?.showLog(repository: repository, access: access, paths: [], endRevision: name) }
        model.onBrowse = { [weak self] name in self?.showRepositoryBrowser(repository: repository, access: access, revision: name) }
        model.onCompare = { [weak self] name in self?.showRevisionComparison(repository: repository, access: access, from: .revision(name), to: .workingTree) }
        model.configureFetch = { [weak self] controller in self?.configureFetchInteractions(controller, repository: repository, access: access) }
        model.configureBranch = { [weak self] controller in self?.configureReferenceInteractions(controller, repository: repository, access: access) }
        model.configureMerge = { [weak self] controller in self?.configureMergeInteractions(controller, repository: repository, access: access) }
        model.configureSwitch = { [weak self] controller in self?.configureSwitchInteractions(controller, repository: repository, access: access) }
    }
    private func configureSwitchInteractions(_ controller: SwitchWindowController, repository: GitRepository, access: RepositoryAccessLease?) {
        let root = repository.root
        controller.model.onSwitched = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.commitWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.reload()
            self?.refreshRepositoryLogs(root)
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.statusWindows[root.path]?.model.reload(); self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPostAction = { [weak self] action, branch in self?.performSwitchPostAction(action, previousBranch: branch, repository: repository, access: access) }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
    }
    private func showSwitch(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil) {
        let root = repository.root
        let key = root.path + ":switch:" + UUID().uuidString
        let controller = switchWindows[key] ?? SwitchWindowController(repository: repository, access: access, revision: revision)
        controller.onClosed = { [weak self] in self?.switchWindows.removeValue(forKey: key) }
        configureSwitchInteractions(controller, repository: repository, access: access)
        switchWindows[key] = controller; controller.model.load(revision: revision)
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
    private func publishComparisonMark() throws {
        workingComparisonMark = try comparisonMarkStore.snapshot()
        if workingComparisonMark != nil {
            let access = try? comparisonMarkStore.acquire(requireSecurityScope: GitRuntime.isAppStoreBuild)
            if let access { workingComparisonMark = access.mark }
            for controller in logWindows.values { controller.model.importWorkingComparisonMark(access) }
        }
        if try WorkingComparisonMarkSnapshot.publish(workingComparisonMark) {
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification), object: nil)
        }
    }
    private func clearComparisonMark() {
        guard !busy, !confirmingQuit else { return }
        do { try comparisonMarkStore.clear(); try publishComparisonMark() }
        catch { self.error = error.localizedDescription }
    }
    private func comparisonPermission(for file: URL) throws -> RepositoryAccessLease? {
        if let activeAccess, activeAccess.contains(file), !GitRuntime.isAppStoreBuild || activeAccess.hasSecurityScope { return activeAccess }
        if let accessStore {
            for saved in accessStore.repositories {
                if let lease = try? accessStore.acquire(saved.id, requireSecurityScope: GitRuntime.isAppStoreBuild), lease.contains(file) { return lease }
            }
        }
        if !GitRuntime.isAppStoreBuild { return RepositoryAccessLease(url: file) }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.directoryURL = file.deletingLastPathComponent(); panel.prompt = "Authorize comparison"
        panel.message = "Choose the requested file or its containing folder to allow TurtleGit to compare it."
        guard panel.runModal() == .OK, let grant = panel.url else { return nil }
        let lease = RepositoryAccessLease(url: grant)
        guard lease.hasSecurityScope, lease.contains(file) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        return lease
    }
    private func handleComparisonMark(file: URL, permission: RepositoryAccessLease? = nil) {
        guard !busy, !confirmingQuit else { return }
        do {
            guard let permission = try permission ?? comparisonPermission(for: file) else { return }
            if try comparisonMarkStore.snapshot() == nil {
                _ = try comparisonMarkStore.remember(file: file, permission: permission, requireSecurityScope: GitRuntime.isAppStoreBuild)
                try publishComparisonMark(); output = "Marked for comparison: " + file.path
            } else {
                let marked = try comparisonMarkStore.acquire(requireSecurityScope: GitRuntime.isAppStoreBuild)
                let comparison = try WorkingFileComparison(base: marked.file, destination: file)
                guard !GitRuntime.isAppStoreBuild || permission.hasSecurityScope && permission.contains(file) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                _ = try comparison.read()
                let key = "working-mark:" + UUID().uuidString
                let controller = FileComparisonWindowController(comparison: comparison, permissions: [marked.permission, permission])
                controller.onClosed = { [weak self] in self?.fileComparisonWindows.removeValue(forKey: key) }
                fileComparisonWindows[key] = controller
                controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
                _ = try comparisonMarkStore.consume(marked.mark.id)
                try publishComparisonMark()
            }
        } catch { self.error = error.localizedDescription }
    }
    private func handleFilePair(paths: [URL]) {
        do {
            guard let prepared = try WorkingFilePairAccess.prepare(paths: paths, requireSecurityScope: GitRuntime.isAppStoreBuild,
                acquire: { try comparisonPermission(for: $0) }) else { return }
            let key = "working-pair:" + UUID().uuidString
            let controller = FileComparisonWindowController(comparison: prepared.comparison, permissions: prepared.permissions)
            controller.onClosed = { [weak self] in self?.fileComparisonWindows.removeValue(forKey: key) }
            fileComparisonWindows[key] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } catch { self.error = error.localizedDescription }
    }
    func handle(_ url: URL) {
        guard !busy, !confirmingQuit, let request = FinderRequest(url: url) else { return }
        let action = request.action
        if action == .clearComparisonMark { clearComparisonMark(); return }
        if action == .diffLater {
            guard request.paths.count == 1 else { error = "Select one file to mark or compare."; return }
            handleComparisonMark(file: request.paths[0]); return
        }
        if action == .clone { showClone(directory: request.paths.first); return }
        if action == .initialize { showCreateRepository(folder: request.paths.first); return }
        if action == .diff && request.paths.count == 2 { handleFilePair(paths: request.paths); return }
        let candidate = request.paths[0]
        var permissionTargets = request.paths
        if action == .rename || action == .remove || action == .submoduleSync,
           let parent = FinderSnapshot.read()?.repositories[candidate.standardizedFileURL.path]?.submoduleParentRoot {
            let parentURL = URL(fileURLWithPath: parent, isDirectory: true)
            if parentURL.path != candidate.path && candidate.standardizedFileURL.path.hasPrefix(parentURL.path.hasSuffix("/") ? parentURL.path : parentURL.path + "/") {
                permissionTargets.append(parentURL)
            }
        }
        // A URL from Finder or another app is a request, not a sandbox permission grant.
        if let activeAccess, permissionTargets.allSatisfy({ activeAccess.contains($0) }) {
            openSession(activeAccess, selected: request, action: action)
            return
        }
        if let store = accessStore {
            for saved in store.repositories {
                guard let lease = try? store.acquire(saved.id, requireSecurityScope: GitRuntime.isAppStoreBuild),
                      permissionTargets.allSatisfy({ lease.contains($0) }) else { continue }
                recentRepositories = store.repositories
                openSession(lease, selected: request, action: action)
                return
            }
        }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Authorize repository"
        panel.message = "Choose the repository root containing the Finder selection to allow TurtleGit to work with it."
        panel.directoryURL = permissionTargets.count > request.paths.count ? permissionTargets.last : (candidate.hasDirectoryPath ? candidate : candidate.deletingLastPathComponent())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lease = RepositoryAccessLease(url: url)
        guard permissionTargets.allSatisfy({ lease.contains($0) }) else {
            error = "The selected folder does not contain every requested Finder item."; return
        }
        openSession(lease, selected: request, action: action)
    }
}

private enum FinderSelectionFailure: LocalizedError {
    case multipleRepositories
    var errorDescription: String? { "Select files from one repository at a time. The Finder selection spans different repositories." }
}
