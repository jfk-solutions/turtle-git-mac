import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RepositoryModel: ObservableObject {
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
    private var logWindows: [String: LogWindowController] = [:]
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
            Task { @MainActor in if let self, !self.busy, self.root != nil { await self.refresh() } }
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
    private func openSession(_ lease: RepositoryAccessLease, selected: URL? = nil, action: RepositoryAction? = nil) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let candidate = try makeRepository(lease.url)
                let resolved = try await candidate.discoverRoot()
                if GitRuntime.isAppStoreBuild && !lease.contains(resolved) {
                    throw RepositoryAccessFailure.repositoryRootOutsidePermission(resolved.path)
                }
                repository = try makeRepository(resolved); activeAccess = lease; root = resolved
                selection = []; entries = []; branch = ""
                section = action == .commit ? .commit : .status
                output = "Repository: \(resolved.path)"
                try await reload()
                if let selected, selected.path.hasPrefix(resolved.path + "/") {
                    selection = [String(selected.path.dropFirst(resolved.path.count + 1))]
                }
                rememberAccess(lease)
                busy = false
                if let action { activate(action) }
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await reload() } catch { self.error = error.localizedDescription }
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
        }
    }
    func stage() { let paths = selectedPaths; perform { try await $0.stage(paths); return "Staged \(paths.count) file(s)." } }
    func unstage() { let paths = selectedPaths; perform { try await $0.unstage(paths); return "Unstaged \(paths.count) file(s)." } }
    func showDiff() {
        let paths = selectedPaths, staged = stagedDiff
        perform { repo in
            if paths.isEmpty { return try await repo.diff(staged: staged) }
            var text = ""
            for path in paths { text += try await repo.diff(path: path, staged: staged) }
            return text.isEmpty ? "No diff in this view. Untracked files must be staged before Git can show their diff." : text
        }
    }
    func showCommit(_ hash: String) { perform { try await $0.run(["show", "--no-ext-diff", "--no-color", hash, "--"]).text } }
    func commit() {
        let text = message
        perform { repo in let result = try await repo.commit(message: text); await MainActor.run { self.message = "" }; return result }
    }
    func activate(_ action: RepositoryAction) {
        switch action {
        case .status, .commit: section = action
        case .log:
            guard let repository, let root else { return }
            let controller = logWindows[root.path] ?? LogWindowController(repository: repository, access: activeAccess)
            controller.onClosed = { [weak self] in self?.logWindows.removeValue(forKey: root.path) }
            logWindows[root.path] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)

        case .diff: showDiff()
        default: dialog = action
        }
    }
    func execute(_ action: RepositoryAction, value: String) {
        dialog = nil
        guard let args = action.arguments(value: value) else { return }
        if action == .clone || action == .initialize {
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
        guard !busy, url.scheme == "turtlegit", url.host == "action",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = parts.queryItems?.first(where: { $0.name == "path" })?.value,
              let name = parts.queryItems?.first(where: { $0.name == "command" })?.value,
              let action = RepositoryAction(rawValue: name) else { return }
        if action == .initialize || action == .clone { activate(action); return }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        // A URL from Finder or another app is a request, not a sandbox permission grant.
        if let activeAccess, activeAccess.contains(candidate) {
            openSession(activeAccess, selected: candidate, action: action)
            return
        }
        if let store = accessStore {
            for saved in store.repositories {
                guard let lease = try? store.acquire(saved.id, requireSecurityScope: GitRuntime.isAppStoreBuild),
                      lease.contains(candidate) else { continue }
                recentRepositories = store.repositories
                openSession(lease, selected: candidate, action: action)
                return
            }
        }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Authorize repository"
        panel.message = "Choose the repository root containing the Finder selection to allow TurtleGit to work with it."
        panel.directoryURL = candidate.hasDirectoryPath ? candidate : candidate.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lease = RepositoryAccessLease(url: url)
        guard lease.contains(candidate) else {
            error = "The selected folder does not contain the requested Finder item."; return
        }
        openSession(lease, selected: candidate, action: action)
    }
}
