import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RepositoryModel: ObservableObject {
    weak var workspaceWindow: NSWindow?
    @Published var root: URL?
    @Published var branch = ""
    @Published var entries: [StatusEntry] = []
    @Published var selection = Set<String>()
    @Published var output = "Open a repository to get started."
    @Published var busy = false
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
    private var cloneKeyAccess: [String: RepositoryAccessLease] = [:]
    private var timer: Timer?
    private var cacheStates: [String: FileState] = [:]
    private var monitoredRoots: [String] = []
    var visibleEntries: [StatusEntry] { entries.filter { showIgnored || $0.state != .ignored } }
    var selectedPaths: [String] { entries.filter { selection.contains($0.id) }.map(\.path) }

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
            Task { @MainActor in if let self, !self.busy, self.root != nil { await self.refresh(refreshStatus: false) } }
        }
    }
    private func makeRepository(_ url: URL) throws -> GitRepository {
        GitRepository(root: url, executable: try GitRuntime.executable())
    }
    func chooseRepository(preferred: URL? = nil) {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Open repository"
        panel.message = "Choose the repository’s root folder. TurtleGit remembers your permission to work in this folder."
        panel.directoryURL = preferred
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL) { openSession(RepositoryAccessLease(url: url)) }
    func openRecent(_ saved: SavedRepository) {
        guard !busy else { return }
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
        guard !busy else { return }
        repository = nil; activeAccess = nil; root = nil; entries = []; selection = []
        branch = ""; message = ""; output = "Open a repository to get started."
    }
    private func rememberAccess(_ lease: RepositoryAccessLease) {
        do { try accessStore?.remember(lease.url); recentRepositories = accessStore?.repositories ?? [] }
        catch { self.error = "The repository is open, but its permission could not be saved: " + error.localizedDescription }
    }
    private func openSession(_ lease: RepositoryAccessLease, selected: FinderRequest? = nil, action: RepositoryAction? = nil, actionPaths: [String]? = nil) {
        guard !busy else { return }
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
                let resolved = try await candidate.discoverRoot()
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
                        let itemRoot = try await makeRepository(location).discoverRoot()
                        guard itemRoot.standardizedFileURL == resolved.standardizedFileURL else { throw FinderSelectionFailure.multipleRepositories }
                    }
                }
                repository = try makeRepository(resolved); activeAccess = lease; root = resolved
                restoreCloneKeyAccess(root: resolved)
                selection = []; entries = []; branch = ""
                section = .status
                output = "Repository: \(resolved.path)"
                try await reload()
                if let selected { selection = selected.selectedStatusPaths(root: resolved, entries: entries) }
                rememberAccess(lease)
                busy = false
                if let action {
                    let paths = actionPaths ?? selected?.relativePaths(root: resolved) ?? []
                    if action == .diff { showDiff(paths: paths) } else { activate(action, paths: paths) }
                    if ![RepositoryAction.status, .commit, .log, .diff].contains(action) { workspaceWindow?.makeKeyAndOrderFront(nil) }
                }
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
    func refresh(refreshStatus: Bool = true) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await reload() } catch { self.error = error.localizedDescription }
        if refreshStatus, let root { statusWindows[root.path]?.model.reload() }
    }
    private func reload() async throws {
        guard let repository, let root else { return }
        entries = try await repository.status()
        selection.formIntersection(Set(entries.map(\.id)))
        branch = try await repository.branch()
        let tracked = try await repository.trackedPaths()
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
        switch action {
        case .clone: showClone()
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
            controller.model.configureLogPicker = { [weak self] log in
                log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
                log.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
                log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
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
        default: dialog = action
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
            // The workspace currently requires a working tree; bare clones use
            // their own Log/Finder post-actions until bare workspace support lands.
            guard !bare else { return }
            do { try self.accessStore?.remember(repo.root); self.recentRepositories = self.accessStore?.repositories ?? [] }
            catch { self.error = "The clone completed, but its folder permission could not be saved.\n" + error.localizedDescription }
            guard !self.busy else { return }
            self.repository = repo; self.activeAccess = access; self.root = repo.root; self.selection = []; self.output = result
            Task { await self.refresh() }
        }
        cloneWindow = controller
        if let source { controller.model.source = source }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
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
            if action != .commit && action != .log && action != .switchBranch && action != .branch && action != .tag && action != .push && action != .fetch && action != .pull && action != .rebase && action != .merge && action != .stash && action != .stashApply && action != .stashPop && action != .stashList && action != .reflog { self.workspaceWindow?.makeKeyAndOrderFront(nil) }
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
    private func showLog(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        let root = repository.root
        let controller = logWindows[root.path] ?? LogWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.logWindows.removeValue(forKey: root.path) }
        controller.model.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        controller.model.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
        controller.model.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
        logWindows[root.path] = controller
        controller.model.setPathScope(paths)
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
        guard let args = action.arguments(value: value) else { return }
        if action == .initialize {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.prompt = "Choose destination"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            guard !busy else { return }; busy = true
            Task {
                do {
                    let lease = RepositoryAccessLease(url: destination)
                    let repo = try makeRepository(destination)
                    output = try await repo.run(args).text
                    repository = repo; activeAccess = lease; root = destination; selection = []
                    try await reload(); rememberAccess(lease)
                } catch { self.error = error.localizedDescription }
                busy = false
            }
        } else { perform { try await $0.run(args).text } }
    }
    func handle(_ url: URL) {
        guard !busy, let request = FinderRequest(url: url) else { return }
        let action = request.action
        if action == .clone { showClone(directory: request.paths.first); return }
        if action == .initialize { activate(action); return }
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
