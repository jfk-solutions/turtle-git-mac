// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RemoveWindowController: NSWindowController, NSWindowDelegate {
    let model: RemoveWindowModel
    var repository: GitRepository { model.repository }
    var request: RemovalRequest { model.request }
    var onClosed: () -> Void = {}
    var onChanged: (String) -> Void { get { model.onChanged } set { model.onChanged = newValue } }
    private var closing=false
    private var release:FinderFilesystemWorkflowRelease?
    private var retiringChildren:[NSWindow]=[]
    private var underlyingWorkPending:Bool {question != nil || model.pendingOperations>0 || window?.sheetParent != nil || window?.attachedSheet != nil || retiringChildren.contains{$0.sheetParent != nil || $0.attachedSheet != nil}}
    var finderServiceCanPresent:Bool {!closing && !model.retired}
    var finderServiceWorkPending:Bool {release != nil || underlyingWorkPending}
    var transportBatchWorkPending:Bool {finderServiceWorkPending}
    private var question: (UUID, NSAlert, (Bool) -> Void)?
    var presentQuestion: (NSWindow, NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Bool = { owner, alert, reply in
        guard owner.attachedSheet == nil else { return false }; alert.beginSheetModal(for: owner, completionHandler: reply); return true
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, request: RemovalRequest, preferences: UserDefaults = .standard) {
        model = RemoveWindowModel(repository: repository, access: access, request: request, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Delete\(request.keepLocal ? " (keep local)" : "")", preferences: preferences); window.contentMinSize = NSSize(width: 620, height: 300); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RemoveDialog(model: model))
        super.init(window: window); window.delegate = self; window.center(); DialogGeometry.attach(window, identifier: "RemoveWindowController")
        model.close = { [weak self] in self?.window?.performClose(nil) }
        model.confirm = { [weak self] in await self?.ask(request.confirmation, detail: request.keepLocal ? "Local files will remain on disk. Their removal from version control will be staged." : "This removes versioned files from the index and working tree, including local modifications. Commit to record the deletion.", buttons: ["Remove", "Abort"], defaultIndex: 1) ?? false }
        model.ignoreError = { [weak self] path, message in await self?.ask("Could not remove “\(path)”", detail: message, buttons: ["Ignore", "Abort"], defaultIndex: 1) ?? false }
        model.confirmCancel = { [weak self] in await self?.ask("The process is still running.", detail: "Stop the current removal? Earlier deletions remain applied.", buttons: ["Yes", "No"], defaultIndex: 1) ?? false }
    }
    func start() { model.start() }
    private func ask(_ title: String, detail: String, buttons: [String], defaultIndex: Int) async -> Bool {
        guard !model.retired, question == nil, let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.alertStyle = .warning
        for (index, title) in buttons.enumerated() { let button = alert.addButton(withTitle: title); button.keyEquivalent = index == defaultIndex ? "\r" : "" }
        alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
        let id = UUID(); model.hasQuestion = true
        return await withCheckedContinuation { continuation in
            question = (id, alert, { continuation.resume(returning: $0) })
            if !presentQuestion(window, alert, { [weak self] reply in self?.settle(id, accepted: reply == .alertFirstButtonReturn) }) { settle(id, accepted: false) }
        }
    }
    private func settle(_ id: UUID, accepted: Bool) {
        guard let pending = question, pending.0 == id else { return }; question = nil; model.hasQuestion = false
        if pending.1.window.sheetParent === window { window?.endSheet(pending.1.window) }; pending.1.window.orderOut(nil); pending.2(accepted)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.hasQuestion && !model.confirmingCancellation }
    func windowWillClose(_ notification:Notification){
        guard notification.object as? NSWindow === window,!closing else{return};closing=true;model.retire()
        if let pending=question{retiringChildren.append(pending.1.window);settle(pending.0,accepted:false);pending.1.window.close()}
        if let window{if let child=window.attachedSheet{retiringChildren.append(child);window.endSheet(child,returnCode:.abort);child.close()};window.sheetParent?.endSheet(window,returnCode:.abort)}
        let release=FinderFilesystemWorkflowRelease(ready:{[self] in !underlyingWorkPending}){[self] in self.release=nil;retiringChildren.removeAll();let done=onClosed;onClosed={};done()};self.release=release;release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class RemoveWindowModel: ObservableObject, ActionLogProgress {
    static private(set) var activeOperations = 0
    private(set) var pendingOperations=0
    let repository: GitRepository
    let request: RemovalRequest
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    private var token: OperationCancellation?
    private(set) var retired = false
    private var started = false
    @Published var busy = false
    @Published var preparing = false
    @Published var hasQuestion = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var cancelling = false
    @Published private(set) var cancelled = false
    @Published private(set) var failed = false
    @Published var output = ""
    @Published var current = ""
    @Published var processed = 0
    @Published var removed = 0
    @Published var ignored = 0
    var confirm: () async -> Bool = { false }
    var ignoreError: (String, String) async -> Bool = { _, _ in false }
    var confirmCancel: () async -> Bool = { false }
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var prepare: ((String, OperationCancellation) async throws -> RemovalPlan)?
    var execute: ((RemovalPlan, OperationCancellation, @escaping @Sendable (GitOutputChunk) -> Void) async throws -> String)?
    init(repository: GitRepository, access: RepositoryAccessLease?, request: RemovalRequest, preferences: UserDefaults) { self.repository = repository; self.access = access; self.request = request; self.preferences = preferences }
    func retire() { if busy { cancelled = true }; retired = true; token?.cancel(); saveActionLog() }
    func start() {
        guard !started, !retired else { return }; started = true; busy = true; preparing = true
        let token = OperationCancellation(); self.token = token; Self.activeOperations += 1;pendingOperations += 1; LocalGitCommandProgress.begin(); ProgressActionLog.nextAttempt(self, savePrevious: false)
        Task {
            var attempted = false
            defer { Self.activeOperations -= 1;pendingOperations -= 1; LocalGitCommandProgress.end(); withExtendedLifetime(access) {}; if self.token === token { self.token = nil; busy = false; preparing = false; cancelling = false; current = "" }; if attempted && !retired { onChanged(output) } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                var plans: [(String, Result<RemovalPlan, Error>)] = []
                for path in request.paths {
                    try token.check(); guard !retired else { return }; current = path
                    do { let plan: RemovalPlan; if let prepare { plan = try await prepare(path, token) } else { plan = try await repository.prepareRemoval(path, keepLocal: request.keepLocal, cancellation: token) }; plans.append((path, .success(plan))) }
                    catch { try token.check(); plans.append((path, .failure(error))) }
                }
                preparing = false; current = ""
                let accepted = await confirm(); try token.check(); guard !retired else { return }
                if !accepted { busy = false; self.token = nil; close(); return }
                for (path, captured) in plans {
                    try token.check(); guard !retired else { return }; current = path
                    do {
                        let plan = try captured.get(); attempted = true; let prefix = output
                        _ = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in guard let self, !self.retired, self.token === token else { return }; self.output = LocalGitCommandProgress.bounded(prefix + state.output, preferences: self.preferences) }, resultText: { $0 }) { [self] emit in
                            if let execute { return try await execute(plan, token, emit) }
                            return try await repository.executeRemoval(plan, cancellation: token, onOutput: emit)
                        }
                        guard !retired else { return }; removed += 1; processed += 1; append("Removed: " + path)
                    } catch {
                        try token.check(); guard !retired else { return }; attempted = true
                        output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences)
                        let ignore = await ignoreError(path, error.localizedDescription); try token.check(); guard !retired else { return }
                        if !ignore { failed = true; break }; ignored += 1; processed += 1
                    }
                }
                guard !retired else { return }; append("\(removed) files removed.")
            } catch { if !retired { cancelled = token.isCancelled; failed = !cancelled; output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences); append("\(removed) files removed.") } }
        }
    }
    private func append(_ text: String) { output = LocalGitCommandProgress.bounded(output + (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + text + "\n", preferences: preferences) }
    func cancel() {
        guard busy, !retired, !hasQuestion, !confirmingCancellation, !cancelling, let token else { return }
        if preparing || !preferences.bool(forKey: "ConfirmKillProcess") { cancelling = true; token.cancel(); return }
        confirmingCancellation = true;Self.activeOperations += 1;pendingOperations += 1
        Task { [self] in defer{Self.activeOperations -= 1;pendingOperations -= 1};let accepted=await confirmCancel();confirmingCancellation=false;if accepted && !retired && self.token === token{cancelling=true;token.cancel()} }
    }
    var actionLogRepository: URL { repository.root }
    var actionLogEligible: Bool { started }
    var actionLogFailed: Bool { failed || ignored > 0 }
    var actionLogCancelled: Bool { cancelled }
}
private struct RemoveDialog: View {
    @ObservedObject var model: RemoveWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.preparing ? "Reading selected paths…" : model.busy ? "Removing versioned paths…" : model.cancelled ? "Removal stopped. Earlier deletions remain applied." : model.failed ? "Removal aborted." : "\(model.removed) files removed.").font(.headline)
            SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: !model.failed && !model.cancelled, preferences: model.preferences)
            Text(model.current).lineLimit(1).truncationMode(.middle)
            HStack { if model.busy { ProgressView(value: Double(model.processed), total: Double(max(1, model.request.paths.count))) }; Spacer(); Button(model.busy ? (model.cancelling ? "Cancelling…" : "Cancel") : "Close") { if model.busy { model.cancel() } else { model.saveActionLog(); model.close() } }.disabled(model.hasQuestion || model.confirmingCancellation || model.cancelling) }
        }.padding(16)
    }
}
