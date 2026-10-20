import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class WorktreeListWindowController: NSWindowController, NSWindowDelegate {
    let model: WorktreeListWindowModel
    var onClosed: () -> Void = {}
    var onSubmodules: (URL, RepositoryAccessLease?) -> Void = { _, _ in }
    var externalAvailability: () -> Bool = { true }
    private(set) var createWindow: WorktreeCreateWindowController?
    private var ownedSheets: [UUID:NSWindow] = [:]
    private var ownedReplies:[UUID:(NSApplication.ModalResponse)->Void]=[:]
    private var closing=false
    private var release:FinderFilesystemWorkflowRelease?
    private var retiringChildren:[NSWindow]=[]
    var onCreatePresentation:(WorktreeCreateWindowController)->Bool={_ in true}
    var finderServiceCanPresent:Bool {!closing && model.active}
    private var underlyingWorkPending:Bool {model.pendingOperations>0 || !ownedSheets.isEmpty || createWindow != nil || window?.sheetParent != nil || window?.attachedSheet != nil || retiringChildren.contains{$0.sheetParent != nil || $0.attachedSheet != nil}}
    var finderServiceWorkPending:Bool {release != nil || underlyingWorkPending}
    private func settle(_ identity:UUID,response:NSApplication.ModalResponse){
        guard let reply=ownedReplies.removeValue(forKey:identity) else{return}
        if let child=ownedSheets.removeValue(forKey:identity){retiringChildren.append(child);child.sheetParent?.endSheet(child,returnCode:response);child.orderOut(nil);child.close()}
        reply(response)
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences:UserDefaults = .standard) {
        model = WorktreeListWindowModel(repository: repository, access: access,preferences:preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 410), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Worktree List", preferences: preferences)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WorktreeListDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 1000, height: 410)); window.contentMinSize = NSSize(width: 720, height: 280)
        window.center()
        model.close = { [weak self] in self?.window?.performClose(nil) }
        model.add = { [weak self] in self?.addWorktree() }
        model.explore = { path in NSWorkspace.shared.activateFileViewerSelecting([path]) }
        model.confirmRemoval = { [weak self] rows, force in
            await self?.ask(title: "Remove worktree\(rows.count == 1 ? "" : "s")?", message: (force ? "Remove with Force will also delete uncommitted and untracked files.\n\n" : "") + rows.map(\.path.path).joined(separator: "\n"), buttons: ["Yes", "No"]) == .alertFirstButtonReturn
        }
        model.confirmCancellation = { [weak self] reply in
            Task { let response = await self?.ask(title: "The process is still running.", message: "Are you sure to abort?", buttons: ["Yes", "No"]); reply(response == .alertFirstButtonReturn) }
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

        DialogGeometry.attach(window, identifier: "WorktreeList", legacyName: "WorktreeList")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.canInteract && sender.attachedSheet == nil && createWindow == nil }
    func windowWillClose(_ notification:Notification){
        guard notification.object as? NSWindow === window,!closing else{return};closing=true;model.saveActionLog();model.invalidate()
        createWindow?.close()
        for identity in Array(ownedReplies.keys){settle(identity,response:.abort)}
        if let window{if let child=window.attachedSheet{retiringChildren.append(child);window.endSheet(child,returnCode:.abort);child.close()};window.sheetParent?.endSheet(window,returnCode:.abort)}
        let release=FinderFilesystemWorkflowRelease(ready:{[self] in !underlyingWorkPending}){[self] in self.release=nil;retiringChildren.removeAll();let done=onClosed;onClosed={};done()};self.release=release;release.start()
    }
    private func ask(title: String, message: String, buttons: [String]) async -> NSApplication.ModalResponse {
        guard model.active, let window else { return .abort }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
        for button in buttons { alert.addButton(withTitle: button) }
        if title.hasPrefix("Remove worktree"), alert.buttons.count > 1 {
            alert.buttons[0].keyEquivalent=""; alert.buttons[1].keyEquivalent="\r"
        }
        alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
        let identity=UUID();ownedSheets[identity]=alert.window
        return await withCheckedContinuation { continuation in
            ownedReplies[identity]={continuation.resume(returning:$0)}
            alert.beginSheetModal(for:window.attachedSheet ?? window){[weak self] response in self?.settle(identity,response:response)}
        }
    }
    private func authorizeWorktrees(_ paths: [URL], purpose: WorktreeListWindowModel.AccessPurpose) async throws -> [RepositoryAccessLease] {
        guard GitRuntime.isAppStoreBuild else { return [] }
        var granted: [RepositoryAccessLease] = []
        for path in paths where !model.hasWorktreeAccess(path) && !granted.contains(where: { $0.contains(path) }) {
            guard model.active, let window else { throw RepositoryAccessFailure.securityScopeUnavailable }
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.title = "Worktree Access – \(path.lastPathComponent)"; panel.prompt = "Allow Access"
            panel.message = purpose == .prune ? "Choose this directory or a parent directory so TurtleGit can check which worktrees are missing before pruning." : "Choose this worktree directory or a parent directory to allow removal."
            panel.directoryURL = path.deletingLastPathComponent()
            panel.alphaValue=window.alphaValue;panel.appearance=window.appearance
            let identity=UUID();ownedSheets[identity]=panel
            let response=await withCheckedContinuation { continuation in
                ownedReplies[identity]={continuation.resume(returning:$0)}
                panel.beginSheetModal(for:window.attachedSheet ?? window){[weak self] response in self?.settle(identity,response:response)}
            }
            guard model.active, response == .OK, let selected = panel.url else { throw OperationCancellationFailure.cancelled }
            let lease = RepositoryAccessLease(url: selected)
            guard lease.hasSecurityScope && lease.contains(path) else { throw RepositoryAccessFailure.securityScopeUnavailable }
            granted.append(lease)
        }
        return granted
    }
    private func addWorktree() {
        guard externalAvailability(), model.canInteract, createWindow == nil, let window, window.attachedSheet == nil else { return }
        let controller = WorktreeCreateWindowController(repository: model.repository, access: model.access,preferences:model.preferences)
        controller.externalAvailability = { [weak self] in self?.model.active == true && self?.externalAvailability() == true }
        controller.model.onCreated = { [weak self] _ in self?.model.requestReload() }
        controller.model.onSubmodules = { [weak self] path, lease in guard let self, self.model.active, self.externalAvailability() else { return }; self.onSubmodules(path, lease) }
        controller.onClosed = { [weak self, weak controller] in
            if let child = controller?.window { self?.window?.endSheet(child) }
            self?.createWindow = nil; self?.model.childActive=false; self?.model.reload()
        }
        model.childActive=true
        createWindow = controller
        guard onCreatePresentation(controller),model.active,controller.finderServiceCanPresent else{controller.close();return}
        if let child = controller.window { child.alphaValue = window.alphaValue; child.appearance = window.appearance; window.beginSheet(child) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class WorktreeListWindowModel: ObservableObject {
    let progressPresentation: GitCommandPresentation
    static var activeOperations = 0
    private(set) var pendingOperations=0
    let preferences:UserDefaults
    private(set) var active=true
    private(set) var generation=UUID()
    @Published var childActive=false { didSet { scheduleReload() } }
    var canInteract:Bool { active && !busy && !showProgress && !childActive && error == nil }
    func invalidate() { active=false; generation=UUID(); cancellation?.cancel(); confirmingCancellation=false }
    enum Action { case lock, unlock, remove, removeForce }
    enum AccessPurpose { case removal, prune }
    let requiresScope: Bool
    let repository: GitRepository
    let access: RepositoryAccessLease?
    @Published var rows: [GitWorktree] = []
    @Published var selection = Set<String>()
    @Published var busy = false { didSet { if !busy { scheduleReload() } } }
    @Published var error: String? { didSet { if error == nil { scheduleReload() } } }
    @Published var showProgress = false { didSet { if !showProgress { scheduleReload() } } }
    @Published var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var cancelled = false
    @Published private(set) var failed = false
    private var pendingErrorQuestion = false
    private var autoClosePolicy: GitProgressAutoClose?
    private var displayTruncated = false
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { active && busy && showProgress && !cancelling && !confirmingCancellation && !pendingErrorQuestion }
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
    init(repository: GitRepository, access: RepositoryAccessLease?, requiresScope: Bool = GitRuntime.isAppStoreBuild,preferences:UserDefaults = .standard) { self.repository = repository; self.access = access; self.requiresScope = requiresScope; self.preferences=preferences; progressPresentation = GitCommandPresentation(defaults: preferences) }
    func beginRequest() -> OperationCancellation {
        let token=OperationCancellation(); cancellation=token; generation=UUID(); busy=true; Self.activeOperations += 1;pendingOperations += 1; return token
    }
    func finishRequest() { busy=false; cancellation=nil; cancelling=false; currentWork=""; percentage=nil; Self.activeOperations -= 1;pendingOperations -= 1; finishAutomaticClose() }
    private func beginProgress() {
        ProgressActionLog.nextAttempt(self, savePrevious: showProgress)
        showProgress=true; output=""; result=""; failed=false; cancelled=false; displayTruncated=false
        cancelling=false; confirmingCancellation=false; autoClosePolicy=GitProgressAutoClose(preferences: preferences)
    }
    private func finishAutomaticClose() {
        guard active, showProgress, !busy, !confirmingCancellation, !pendingErrorQuestion, !failed, !cancelled,
              autoClosePolicy?.shouldClose(success: true, postActionCount: failedRemoval == nil ? 0 : 1) == true else { return }
        closeProgress()
    }
    private func appendOutput(_ text: String) {
        guard !displayTruncated else { return }
        output=LocalGitCommandProgress.bounded(output + text, preferences: preferences)
        displayTruncated=output.utf8.count >= GitProgressOutputState(preferences: preferences).limit
    }
    private func stream(token: OperationCancellation, operation: @escaping (@escaping @Sendable (GitOutputChunk) -> Void) async throws -> String) async throws -> String {
        let prefix=output, wasTruncated=displayTruncated
        LocalGitCommandProgress.begin(); defer { LocalGitCommandProgress.end() }
        return try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in
            guard let self, self.active, self.cancellation === token else { return }
            if !wasTruncated {
                self.output=LocalGitCommandProgress.bounded(prefix + state.output, preferences: self.preferences)
                self.displayTruncated=self.output.utf8.count >= GitProgressOutputState(preferences: self.preferences).limit
            }
            self.currentWork=state.currentWork; self.percentage=state.percentage
        }, resultText: { $0 }, operation: operation)
    }
    func isLive(_ token:OperationCancellation) -> Bool { active && !token.isCancelled }
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
    func open(_ ids: Set<String>) { guard canInteract, let row = selected(ids).first, ids.count == 1 else { return }; explore(row.path) }
    private func refresh(token:OperationCancellation) async throws {
        try checkAccess(); var fresh=try await repository.worktrees(cancellation:token)
        if let index=fresh.firstIndex(where:{ $0.isMain && $0.isBare }) {
            let path=fresh[index].path.path
            fresh[index].head=try? await repository.run(["--git-dir",path,"rev-parse","--verify","HEAD"],cancellation:token).text.trimmingCharacters(in:.newlines)
            fresh[index].branch=try? await repository.run(["--git-dir",path,"symbolic-ref","--quiet","HEAD"],cancellation:token).text.trimmingCharacters(in:.newlines)
            fresh[index].isDetached=fresh[index].head != nil && fresh[index].branch == nil
        }
        if token.isCancelled { throw OperationCancellationFailure.cancelled }; guard active else { return }
        rows=fresh; selection.formIntersection(Set(rows.map(\.id)))
    }
    private func refreshAfterBatch(_ token:OperationCancellation) async throws {
        guard active else { return }
        let read=token.isCancelled ? OperationCancellation() : token
        cancellation=read; try await refresh(token:read)
    }
    private var reloadRequested = false, reloadScheduled = false
    /// A newly created checkout may arrive during management/result review.
    /// Defer its list read without changing that workflow's selection or token.
    func requestReload() { guard active else { return }; reloadRequested = true; scheduleReload() }
    private func scheduleReload() {
        guard active, reloadRequested, !reloadScheduled else { return }; reloadScheduled = true
        Task { [weak self] in
            await Task.yield()
            guard let self else { return }; self.reloadScheduled = false
            guard self.active, self.reloadRequested, self.canInteract else { return }
            self.reload()
        }
    }
    func reload() {
        guard canInteract else { return }; reloadRequested = false; let token=beginRequest()
        Task {
            defer { finishRequest(); withExtendedLifetime(access) {} }
            do { try await refresh(token:token) }
            catch { if isLive(token) { self.error=error.localizedDescription } }
        }
    }
    func modify(_ action: Action, ids: Set<String>) {
        guard canInteract else { return }
        let chosen = selected(ids), targets = chosen.filter { !$0.isMain }
        guard !chosen.isEmpty else { return }
        let removing = action == .remove || action == .removeForce
        let token=beginRequest()
        Task {
            defer { finishRequest(); withExtendedLifetime(access) {} }
            do {
                try checkAccess()
                if removing {
                    guard !targets.isEmpty, await confirmRemoval(targets, action == .removeForce) else { return }
                    guard isLive(token) else { return }
                    let granted=try await authorizeWorktrees(targets.map(\.path), .removal)
                    guard isLive(token) else { return }; worktreeAccess += granted
                    if requiresScope && !targets.allSatisfy({ hasWorktreeAccess($0.path) }) { throw RepositoryAccessFailure.securityScopeUnavailable }
                }
                guard isLive(token) else { return }
                beginProgress(); removedCount = 0
                try await runBatch(action, targets: targets, token: token)
            } catch OperationCancellationFailure.cancelled {
                if active && showProgress { cancelled=true; result="Cancelled" }
            }
            catch { if isLive(token) { self.error = error.localizedDescription } }
        }
    }
    private func runBatch(_ action: Action, targets: [GitWorktree], token: OperationCancellation) async throws {
        let removing = action == .remove || action == .removeForce
        var completed = removing ? removedCount : 0
        remainingRemovals = []; failedRemoval = nil
        for (index, target) in targets.enumerated() {
            if token.isCancelled || !active { break }
            do {
                appendOutput(target.path.path + "\n")
                let repository=self.repository
                _ = try await stream(token: token) { emit in
                    switch action {
                    case .lock: return try await repository.lockWorktree(at: target.path, cancellation: token, onOutput: emit)
                    case .unlock: return try await repository.unlockWorktree(at: target.path, cancellation: token, onOutput: emit)
                    case .remove, .removeForce: return try await repository.removeWorktree(at: target.path, force: action == .removeForce, cancellation: token, onOutput: emit)
                    }
                }
                guard active else { break }
                completed += 1
            } catch {
                guard active else { break }
                failed=true
                if !(error is GitFailure || error is GitCommandCancellationFailure) { appendOutput(error.localizedDescription + "\n") }
                else if output.hasSuffix(target.path.path + "\n") { appendOutput(error.localizedDescription + "\n") }
                if token.isCancelled || !active { break }
                if removing {
                    if action == .remove { failedRemoval = target }
                    remainingRemovals = Array(targets.dropFirst(index + 1)); queuedRemovalAction = action
                    break
                }
                pendingErrorQuestion=true
                let shouldContinue=await continueAfterError(error.localizedDescription); pendingErrorQuestion=false
                if !shouldContinue || !isLive(token) { break }
            }
        }
        guard active else { return }
        cancelled=token.isCancelled
        if removing { removedCount = completed }
        result = token.isCancelled ? "Cancelled" : action == .lock ? "Locked \(completed) worktree(s)." : action == .unlock ? "Successfully unlocked \(completed) worktree(s)." : "Removed \(completed) worktree(s)."
        try await refreshAfterBatch(token)
    }
    func prune() {
        guard canInteract else { return }; let token=beginRequest()
        Task {
            defer { finishRequest(); withExtendedLifetime(access) {} }
            do {
                try checkAccess()
                if requiresScope {
                    // Git treats denied stat() like a missing .git file. Do not
                    // let sandbox denial prune a valid linked checkout's index.
                    let registered = try await repository.worktrees(cancellation:token)
                    let inspected = registered.filter { !$0.isMain && $0.lockReason == nil }.map(\.path)
                    let granted=try await authorizeWorktrees(inspected, .prune)
                    guard isLive(token) else { return }; worktreeAccess += granted
                    guard inspected.allSatisfy({ hasWorktreeAccess($0) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                    for path in inspected {
                        do { _ = try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent(".git").path) }
                        catch let error as NSError {
                            let missing = error.domain == NSCocoaErrorDomain && [CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue].contains(error.code)
                            if !missing { throw error } // ACL/TCC denial is not evidence of absence.
                        }
                    }
                }
                guard isLive(token) else { return }
                beginProgress(); failedRemoval = nil; remainingRemovals = []
                let repository=self.repository
                _ = try await stream(token: token) { emit in try await repository.pruneWorktrees(cancellation: token, onOutput: emit) }
                guard active else { return }
                result = "Prune completed"; try await refreshAfterBatch(token)
            } catch OperationCancellationFailure.cancelled {
                if active && showProgress { cancelled=true; result="Cancelled" }
            }
            catch {
                guard active else { return }
                if showProgress { cancelled=token.isCancelled; failed=true; result = cancelled ? "Cancelled" : "Prune failed"; output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences) }
                else { self.error = error.localizedDescription }
            }
        }
    }
    func retryRemovalWithForce() {
        guard active, !busy, !confirmingCancellation, let failedRemoval else { return }
        // ProgressDlg's post-action ends with IDOK, resuming the original batch.
        // Force applies to this failed row; subsequent rows retain their original mode.
        let next = remainingRemovals, nextAction = queuedRemovalAction
        saveActionLog(); ProgressActionLog.nextAttempt(self, savePrevious: false); failed=false; cancelled=false
        let token=beginRequest()
        Task {
            defer { finishRequest(); withExtendedLifetime(access) {} }
            do {
                try checkAccess()
                let granted=try await authorizeWorktrees([failedRemoval.path] + next.map(\.path), .removal)
                guard isLive(token) else { return }; worktreeAccess += granted
                if requiresScope && !([failedRemoval] + next).allSatisfy({ hasWorktreeAccess($0.path) }) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await runBatch(.removeForce, targets: [failedRemoval], token: token)
                if isLive(token) && !next.isEmpty { try await runBatch(nextAction, targets: next, token: token) }
            } catch OperationCancellationFailure.cancelled {
                if active && showProgress { cancelled=true; result="Cancelled" }
            }
            catch { if isLive(token) { self.error = error.localizedDescription } }
        }
    }
    func closeProgress() {
        guard active, !busy, !confirmingCancellation else { return }; saveActionLog()
        guard !remainingRemovals.isEmpty else { showProgress = false; failedRemoval = nil; return }
        let next = remainingRemovals, action = queuedRemovalAction
        let token=beginRequest()
        Task {
            defer { finishRequest(); withExtendedLifetime(access) {} }
            do { try checkAccess(); try await runBatch(action, targets: next, token: token) }
            catch { if isLive(token) { self.error = error.localizedDescription } }
        }
    }
    func abortRemovalBatch() { guard active, !busy, !confirmingCancellation else { return }; saveActionLog(); remainingRemovals = []; failedRemoval = nil; showProgress = false }
    func cancel() {
        guard canCancel, let token=cancellation else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation=true; var answered=false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, self.active else { return }; answered=true; self.confirmingCancellation=false
                if self.busy, self.cancellation === token, accepted { self.cancelling=true; token.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling=true; token.cancel() }
    }
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
                Button("Help") { TurtleGitHelp.show(.worktrees) }
            }
        }.padding(12).disabled(!model.canInteract)
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
            SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: !model.failed && !model.cancelled, preferences: model.preferences)
            HStack { if model.busy { LocalGitProgressIndicator(percentage: model.percentage, animate: model.progressPresentation.animateActivity); Text(model.cancelling ? "Cancelling…" : model.currentWork).font(.caption) }; Spacer()
                if model.busy { Button("Cancel") { model.cancel() }.disabled(!model.canCancel) }
                else {
                    if model.failedRemoval != nil { Button { model.retryRemovalWithForce() } label: { CommandLabel(title: "Force remove", icon: .remove) } }
                    if !model.remainingRemovals.isEmpty { Button("Cancel") { model.abortRemovalBatch() } }
                    Button("Close") { model.closeProgress() }.keyboardShortcut(.defaultAction).disabled(model.confirmingCancellation)
                }
            }
        }.padding(16).frame(width: 700, height: 330).interactiveDismissDisabled(model.busy || model.confirmingCancellation)
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
