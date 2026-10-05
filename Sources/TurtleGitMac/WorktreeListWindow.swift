import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class WorktreeListWindowController: NSWindowController, NSWindowDelegate {
    let model: WorktreeListWindowModel
    var onClosed: () -> Void = {}
    var onSubmodules: (URL, RepositoryAccessLease?) -> Void = { _, _ in }
    private var createWindow: WorktreeCreateWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = WorktreeListWindowModel(repository: repository, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 410), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Worktree List – TurtleGit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WorktreeListDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 1000, height: 410)); window.contentMinSize = NSSize(width: 720, height: 280)
        window.setFrameAutosaveName("WorktreeList"); window.center()
        model.close = { [weak self] in self?.window?.performClose(nil) }
        model.add = { [weak self] in self?.addWorktree() }
        model.explore = { path in NSWorkspace.shared.activateFileViewerSelecting([path]) }
        model.confirmRemoval = { [weak self] rows, force in
            await self?.ask(title: "Remove worktree\(rows.count == 1 ? "" : "s")?", message: (force ? "Remove with Force will also delete uncommitted and untracked files.\n\n" : "") + rows.map(\.path.path).joined(separator: "\n"), buttons: ["Yes", "No"]) == .alertFirstButtonReturn
        }
        model.continueAfterError = { [weak self] message in
            await self?.ask(title: "Worktree operation failed", message: message, buttons: ["Continue", "Abort"]) == .alertFirstButtonReturn
        }
        model.confirmResetColumns = { [weak self] in
            await self?.ask(title: "Reset columns", message: "Are you sure to reset columns?", buttons: ["Yes", "No"]) == .alertFirstButtonReturn
        }
        model.authorizeWorktrees = { [weak self] paths, purpose in
            guard let self else { throw RepositoryAccessFailure.securityScopeUnavailable }
            return try await self.authorizeWorktrees(paths, purpose: purpose)
        }
        model.reload()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && sender.attachedSheet == nil && createWindow == nil }
    func windowWillClose(_ notification: Notification) { onClosed() }
    private func ask(title: String, message: String, buttons: [String]) async -> NSApplication.ModalResponse {
        guard let window else { return .abort }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
        for button in buttons { alert.addButton(withTitle: button) }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window.attachedSheet ?? window) { continuation.resume(returning: $0) }
        }
    }
    private func authorizeWorktrees(_ paths: [URL], purpose: WorktreeListWindowModel.AccessPurpose) async throws -> [RepositoryAccessLease] {
        guard GitRuntime.isAppStoreBuild else { return [] }
        var granted: [RepositoryAccessLease] = []
        for path in paths where !model.hasWorktreeAccess(path) && !granted.contains(where: { $0.contains(path) }) {
            guard let window else { throw RepositoryAccessFailure.securityScopeUnavailable }
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.title = "Worktree Access – \(path.lastPathComponent)"; panel.prompt = "Allow Access"
            panel.message = purpose == .prune ? "Choose this directory or a parent directory so TurtleGit can check which worktrees are missing before pruning." : "Choose this worktree directory or a parent directory to allow removal."
            panel.directoryURL = path.deletingLastPathComponent()
            let response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window.attachedSheet ?? window) { continuation.resume(returning: $0) }
            }
            guard response == .OK, let selected = panel.url else { throw OperationCancellationFailure.cancelled }
            let lease = RepositoryAccessLease(url: selected)
            guard lease.hasSecurityScope && lease.contains(path) else { throw RepositoryAccessFailure.securityScopeUnavailable }
            granted.append(lease)
        }
        return granted
    }
    private func addWorktree() {
        guard !model.busy, createWindow == nil, let window, window.attachedSheet == nil else { return }
        let controller = WorktreeCreateWindowController(repository: model.repository, access: model.access)
        controller.model.onCreated = { [weak self] _ in self?.model.reload() }
        controller.model.onSubmodules = { [weak self] path, lease in self?.onSubmodules(path, lease) }
        controller.onClosed = { [weak self, weak controller] in
            if let child = controller?.window { self?.window?.endSheet(child) }
            self?.createWindow = nil; self?.model.reload()
        }
        createWindow = controller
        if let child = controller.window { window.beginSheet(child) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class WorktreeListWindowModel: ObservableObject {
    enum Action { case lock, unlock, remove, removeForce }
    enum AccessPurpose { case removal, prune }
    let requiresScope: Bool
    let repository: GitRepository
    let access: RepositoryAccessLease?
    @Published var rows: [GitWorktree] = []
    @Published var selection = Set<String>()
    @Published var busy = false
    @Published var error: String?
    @Published var showProgress = false
    @Published var output = ""
    @Published var result = ""
    @Published var failedRemoval: GitWorktree?
    @Published private(set) var remainingRemovals: [GitWorktree] = []
    private var queuedRemovalAction = Action.remove
    private var removedCount = 0
    private var worktreeAccess: [RepositoryAccessLease] = []
    private var cancellation: OperationCancellation?
    var close: () -> Void = {}
    var add: () -> Void = {}
    var explore: (URL) -> Void = { _ in }
    var confirmResetColumns: () async -> Bool = { false }
    var confirmRemoval: ([GitWorktree], Bool) async -> Bool = { _, _ in false }
    var continueAfterError: (String) async -> Bool = { _ in false }
    var authorizeWorktrees: @MainActor ([URL], AccessPurpose) async throws -> [RepositoryAccessLease] = { _, _ in
        if GitRuntime.isAppStoreBuild { throw RepositoryAccessFailure.securityScopeUnavailable }; return []
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, requiresScope: Bool = GitRuntime.isAppStoreBuild) { self.repository = repository; self.access = access; self.requiresScope = requiresScope }
    func selected(_ ids: Set<String>) -> [GitWorktree] { rows.filter { ids.contains($0.id) } }
    func showLock(_ ids: Set<String>) -> Bool { let selected = selected(ids); return !selected.isEmpty && (selected.count > 1 || selected[0].lockReason == nil) }
    func showUnlock(_ ids: Set<String>) -> Bool { let selected = selected(ids); return !selected.isEmpty && (selected.count > 1 || selected[0].lockReason != nil) }
    func showRemove(_ ids: Set<String>) -> Bool { let selected = selected(ids); return !selected.isEmpty && (selected.count > 1 || !selected[0].isMain) }
    func hasWorktreeAccess(_ path: URL) -> Bool { access?.hasSecurityScope == true && access?.contains(path) == true || worktreeAccess.contains { $0.hasSecurityScope && $0.contains(path) } }
    func canInspect(_ path: URL) -> Bool { !requiresScope || hasWorktreeAccess(path) }
    func checkAccess() throws {
        if requiresScope && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func branchLabel(_ row: GitWorktree) -> String {
        if !row.isMain && canInspect(row.path) && !FileManager.default.fileExists(atPath: row.path.path) { return "" }
        if row.isDetached { return row.isMain ? "HEAD" : "detached HEAD" }
        return row.branch.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 } ?? ""
    }
    func hashLabel(_ row: GitWorktree) -> String { !row.isMain && canInspect(row.path) && !FileManager.default.fileExists(atPath: row.path.path) ? "" : row.head ?? "" }
    func open(_ ids: Set<String>) { guard !busy, let row = selected(ids).first, ids.count == 1 else { return }; explore(row.path) }
    private func refresh() async throws {
        try checkAccess(); rows = try await repository.worktrees()
        if let index = rows.firstIndex(where: { $0.isMain && $0.isBare }) {
            // Porcelain omits bare HEAD; the upstream libgit2 list includes it.
            let path = rows[index].path.path
            rows[index].head = try? await repository.run(["--git-dir", path, "rev-parse", "--verify", "HEAD"]).text.trimmingCharacters(in: .newlines)
            rows[index].branch = try? await repository.run(["--git-dir", path, "symbolic-ref", "--quiet", "HEAD"]).text.trimmingCharacters(in: .newlines)
            rows[index].isDetached = rows[index].head != nil && rows[index].branch == nil
        }
        selection.formIntersection(Set(rows.map(\.id)))
    }
    func reload() {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do { try await refresh() } catch { self.error = error.localizedDescription } }
    }
    func modify(_ action: Action, ids: Set<String>) {
        guard !busy else { return }
        let chosen = selected(ids), targets = chosen.filter { !$0.isMain }
        guard !chosen.isEmpty else { return }
        let removing = action == .remove || action == .removeForce
        busy = true
        Task {
            defer { busy = false; cancellation = nil }
            do {
                try checkAccess()
                if removing {
                    guard !targets.isEmpty, await confirmRemoval(targets, action == .removeForce) else { return }
                    worktreeAccess += try await authorizeWorktrees(targets.map(\.path), .removal)
                    if requiresScope && !targets.allSatisfy({ hasWorktreeAccess($0.path) }) { throw RepositoryAccessFailure.securityScopeUnavailable }
                }
                let token = OperationCancellation(); cancellation = token
                showProgress = true; output = ""; result = ""; removedCount = 0
                try await runBatch(action, targets: targets, token: token)
            } catch OperationCancellationFailure.cancelled { }
            catch { self.error = error.localizedDescription }
        }
    }
    private func runBatch(_ action: Action, targets: [GitWorktree], token: OperationCancellation) async throws {
        let removing = action == .remove || action == .removeForce
        var completed = removing ? removedCount : 0
        remainingRemovals = []; failedRemoval = nil
        for (index, target) in targets.enumerated() {
            if token.isCancelled { break }
            do {
                let text: String
                switch action {
                case .lock: text = try await repository.lockWorktree(at: target.path, cancellation: token)
                case .unlock: text = try await repository.unlockWorktree(at: target.path, cancellation: token)
                case .remove, .removeForce: text = try await repository.removeWorktree(at: target.path, force: action == .removeForce, cancellation: token)
                }
                completed += 1; output += target.path.path + "\n" + text
            } catch {
                output += target.path.path + "\n" + error.localizedDescription + "\n"
                if token.isCancelled { break }
                if removing {
                    if action == .remove { failedRemoval = target }
                    remainingRemovals = Array(targets.dropFirst(index + 1)); queuedRemovalAction = action
                    break
                }
                if !(await continueAfterError(error.localizedDescription)) { break }
            }
        }
        if removing { removedCount = completed }
        result = token.isCancelled ? "Cancelled" : action == .lock ? "Locked \(completed) worktree(s)." : action == .unlock ? "Successfully unlocked \(completed) worktree(s)." : "Removed \(completed) worktree(s)."
        try await refresh()
    }
    func prune() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false; cancellation = nil }
            do {
                try checkAccess()
                if requiresScope {
                    // Git treats denied stat() like a missing .git file. Do not
                    // let sandbox denial prune a valid linked checkout's index.
                    let registered = try await repository.worktrees()
                    let inspected = registered.filter { !$0.isMain && $0.lockReason == nil }.map(\.path)
                    worktreeAccess += try await authorizeWorktrees(inspected, .prune)
                    guard inspected.allSatisfy({ hasWorktreeAccess($0) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                    for path in inspected {
                        do { _ = try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent(".git").path) }
                        catch let error as NSError {
                            let missing = error.domain == NSCocoaErrorDomain && [CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue].contains(error.code)
                            if !missing { throw error } // ACL/TCC denial is not evidence of absence.
                        }
                    }
                }
                let token = OperationCancellation(); cancellation = token
                showProgress = true; result = ""; output = ""; failedRemoval = nil; remainingRemovals = []
                output = try await repository.pruneWorktrees(cancellation: token)
                result = "Prune completed"; try await refresh()
            } catch OperationCancellationFailure.cancelled { }
            catch {
                if showProgress { result = cancellation?.isCancelled == true ? "Cancelled" : "Prune failed"; output = error.localizedDescription }
                else { self.error = error.localizedDescription }
            }
        }
    }
    func retryRemovalWithForce() {
        guard !busy, let failedRemoval else { return }
        // ProgressDlg's post-action ends with IDOK, resuming the original batch.
        // Force applies to this failed row; subsequent rows retain their original mode.
        let next = remainingRemovals, nextAction = queuedRemovalAction
        busy = true; let token = OperationCancellation(); cancellation = token
        Task {
            defer { busy = false; cancellation = nil }
            do {
                try checkAccess()
                worktreeAccess += try await authorizeWorktrees([failedRemoval.path] + next.map(\.path), .removal)
                if requiresScope && !([failedRemoval] + next).allSatisfy({ hasWorktreeAccess($0.path) }) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await runBatch(.removeForce, targets: [failedRemoval], token: token)
                if !token.isCancelled && !next.isEmpty { try await runBatch(nextAction, targets: next, token: token) }
            } catch OperationCancellationFailure.cancelled { }
            catch { self.error = error.localizedDescription }
        }
    }
    func closeProgress() {
        guard !busy else { return }
        guard !remainingRemovals.isEmpty else { showProgress = false; failedRemoval = nil; return }
        let next = remainingRemovals, action = queuedRemovalAction
        busy = true; let token = OperationCancellation(); cancellation = token
        Task {
            defer { busy = false; cancellation = nil }
            do { try checkAccess(); try await runBatch(action, targets: next, token: token) }
            catch { self.error = error.localizedDescription }
        }
    }
    func abortRemovalBatch() { guard !busy else { return }; remainingRemovals = []; failedRemoval = nil; showProgress = false }
    func cancel() { cancellation?.cancel() }
}

private struct WorktreeListDialog: View {
    @ObservedObject var model: WorktreeListWindowModel
    var body: some View {
        VStack(spacing: 12) {
            WorktreeListTable(model: model)
            HStack {
                Button("Add") { model.add() }; Button("Prune") { model.prune() }
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.close() }.keyboardShortcut(.defaultAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-worktrees.html")!) }
            }
        }.padding(12).disabled(model.busy)
        .background(WorktreeRefreshShortcut(action: model.reload))
        .alert("Worktree List", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.showProgress, onDismiss: { model.abortRemovalBatch() }) { WorktreeProgress(model: model).disabled(false) }
    }
}

private struct WorktreeProgress: View {
    @ObservedObject var model: WorktreeListWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.busy ? "Working…" : model.result).font(.headline)
            ScrollView { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Spacer()
                if model.busy { Button("Cancel") { model.cancel() } }
                else {
                    if model.failedRemoval != nil { Button { model.retryRemovalWithForce() } label: { CommandLabel(title: "Force remove", icon: .remove) } }
                    if !model.remainingRemovals.isEmpty { Button("Cancel") { model.abortRemovalBatch() } }
                    Button("Close") { model.closeProgress() }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(16).frame(width: 700, height: 330).interactiveDismissDisabled(model.busy)
    }
}

private struct WorktreeRefreshShortcut: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> NSView { KeyView() }
    func updateNSView(_ view: NSView, context: Context) { (view as? KeyView)?.action = action }
    private final class KeyView: NSView {
        var action: () -> Void = {}
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.keyCode == 96 { action(); return true }
            return super.performKeyEquivalent(with: event)
        }
    }
}
