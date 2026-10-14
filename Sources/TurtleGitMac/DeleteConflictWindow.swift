import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class DeleteConflictWindowController: NSWindowController, NSWindowDelegate {
    let model: DeleteConflictWindowModel
    var onClosed: () -> Void = {}
    var configureComparison: (FileComparisonWindowModel) -> Void = { _ in }
    private(set) var comparison: FileComparisonWindowController?
    private(set) var sheets: ConflictReviewSheets!
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, preferences: UserDefaults = .standard) {
        model = DeleteConflictWindowModel(repository: repository, access: access, path: path, preferences: preferences)
        let size = NSSize(width: 760, height: 280)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(path) – Conflict – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = size
        window.contentViewController = NSHostingController(rootView: DeleteConflictDialog(model: model, operation: model.operation))
        super.init(window: window); window.delegate = self; window.setContentSize(size); window.center()
        sheets = ConflictReviewSheets(window: window, operation: model.operation)
        model.close = { [weak self] in self?.window?.performClose(nil) }
        model.operation.confirmCancellation = { [weak self] reply in Task { reply(await self?.sheets.ask("The process is still running.", message: "Are you sure to abort?", buttons: ["Yes", "No"]) == .alertFirstButtonReturn) } }
        model.onProgress = { [weak window] in window?.setContentSize(NSSize(width: 760, height: 400)) }
        model.onComparison = { [weak self] prepared in
            guard let self, self.model.operation.active, self.comparison == nil else { return }
            let child = FileComparisonWindowController(repository: repository, access: access, conflict: prepared, preferences: preferences)
            self.configureComparison(child.model); self.comparison = child; self.model.operation.hasChild = true
            child.onClosed = { [weak self] in
                guard let self else { return }; self.comparison = nil; self.model.operation.hasChild = false
                if self.model.operation.active { self.model.load() }
            }
            child.showWindow(nil); child.window?.makeKeyAndOrderFront(nil)
        }
        DialogGeometry.attach(window, identifier: "DeleteConflictWindowController")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.abort(); return false }; return model.operation.canClose && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        guard model.operation.active else { return }; model.invalidate(); sheets.retire(); comparison?.close(); comparison = nil; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class DeleteConflictWindowModel: ObservableObject {
    let repository: GitRepository
    let path: String
    let operation: ConflictReviewOperation
    var busy: Bool { operation.busy }
    var error: String? { get { operation.error } set { operation.error = newValue } }
    @Published var details: DeleteConflictDetails?
    private var reloadQueued = false, closeAfterRead = false
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onLog: (String) -> Void = { _ in }
    var onProgress: () -> Void = {}
    var onComparison: (ConflictBaseComparison) -> Void = { _ in }
    var readDetails: ((OperationCancellation) async throws -> DeleteConflictDetails)?
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, preferences: UserDefaults = .standard) {
        self.repository = repository; self.path = path; operation = ConflictReviewOperation(repository: repository, access: access, preferences: preferences)
        operation.onIdle = { [weak self] in
            guard let self, self.operation.active, self.operation.canClose else { return }
            if self.closeAfterRead || self.operation.success { self.closeAfterRead = false; self.close() }
            else if self.reloadQueued, !self.operation.showingProgress { self.reloadQueued = false; self.load() }
        }
    }
    func invalidate() { reloadQueued = false; operation.invalidate() }
    func abort() { guard operation.active else { return }; if busy { if !operation.showingProgress { closeAfterRead = true }; operation.cancel() } else if operation.canClose { close() } }
    func load() {
        guard operation.active else { return }
        guard operation.canInteract else { reloadQueued = true; return }; reloadQueued = false
        let token = operation.begin()
        Task {
            defer { operation.finish(token); withExtendedLifetime(operation.access) {} }
            do {
                try operation.checkAccess()
                let value: DeleteConflictDetails
                if let readDetails { value = try await readDetails(token) } else { value = try await repository.deleteConflictDetails(path: path, cancellation: token) }
                try token.check(); guard operation.live(token) else { return }; details = value
            } catch { operation.fail(error, token: token) }
        }
    }
    func back() { guard operation.canClose else { return }; operation.back(); details = nil; load() }
    func resolve(deleting: Bool) {
        guard operation.canInteract, let details else { return }
        let token = operation.begin(progress: true); onProgress()
        Task {
            defer { operation.finish(token); withExtendedLifetime(operation.access) {} }
            do {
                let text = try await operation.stream(token) { [repository] emit in
                    try await repository.resolveDeleteConflict(details.entry, deleting: deleting, cancellation: token, onOutput: emit)
                }
                guard operation.live(token) else { return }; operation.complete(token); onChanged(text)
            } catch { guard operation.live(token) else { return }; operation.fail(error, token: token); onChanged(operation.output) }
        }
    }
    func log(_ revision: String) {
        guard operation.canInteract, let details, [details.first.commit, details.second.commit].contains(revision) else { return }
        let token = operation.begin()
        Task {
            defer { operation.finish(token); withExtendedLifetime(operation.access) {} }
            do {
                try operation.checkAccess(); let current = try await repository.deleteConflictDetails(path: path, cancellation: token)
                guard current.entry == details.entry, [current.first.commit, current.second.commit].contains(revision) else { throw ResolveFailure.stale }
                try token.check(); guard operation.live(token) else { return }; onLog(revision)
            } catch { operation.fail(error, token: token) }
        }
    }
    func compare() {
        guard operation.canInteract, let details, details.canCompare else { return }
        let token = operation.begin()
        Task {
            defer { operation.finish(token); withExtendedLifetime(operation.access) {} }
            do {
                try operation.checkAccess(); let value = try await repository.conflictBaseComparison(details.entry, cancellation: token)
                try token.check(); guard operation.live(token) else { return }; onComparison(value)
            } catch { operation.fail(error, token: token) }
        }
    }
}
private struct DeleteConflictDialog: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: DeleteConflictWindowModel
    @ObservedObject var operation: ConflictReviewOperation
    func side(_ side: ConflictSide, details: DeleteConflictDetails) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(side.reference).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if let commit = side.commit { Button { model.log(commit) } label: { CommandLabel(title: "Show log", icon: .log) }.frame(width: 140).accessibilityLabel("Show log for \(side.reference)") }
            }.frame(height: 26)
            HStack {
                Text(side.status).foregroundStyle(side.status == "Deleted" ? FileState.deleted.textColor : FileState.modified.textColor).frame(maxWidth: .infinity, alignment: .leading)
                if details.canCompare && side.stage == details.changedStage { Button { model.compare() } label: { CommandLabel(title: "Show changes", icon: .compare) }.frame(width: 140) }
            }.frame(height: 26)
        }
    }
    var body: some View {
        Group {
        if operation.showingProgress { ConflictReviewProgressView(operation: operation, back: model.back) } else {
        VStack(spacing: 12) {
            GroupBox("Delete/modify merge conflict") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let details = model.details { side(details.first, details: details); side(details.second, details: details) }
                    else { ProgressView().controlSize(.small).frame(height: 105) }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(!operation.canInteract)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }; Spacer()
                Button(model.details?.keepTitle ?? "Modified") { model.resolve(deleting: false) }.disabled(model.details == nil || !operation.canInteract)
                Button("Delete") { model.resolve(deleting: true) }.disabled(model.details == nil || !operation.canInteract)
                Button(model.busy ? "Cancel" : "Abort") { model.abort() }.keyboardShortcut(.defaultAction)
                Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-resolve.html")!) } label: { CommandLabel(title: "Help", icon: .help) }
            }
        }.padding(12)
        }
        }.onAppear { model.load() }
        .background(Button("") { model.abort() }.keyboardShortcut(.cancelAction).hidden())
        .alert("Could not resolve conflict", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }

    }
}

/// Shared conflict-review request lifetime. The chooser owns its permission and
/// callbacks; this state owns the child-process token and bounded presentation.
@MainActor final class ConflictReviewOperation: ObservableObject, ActionLogProgress {
    static private(set) var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    private(set) var active = true
    private(set) var generation = UUID()
    private var cancellation: OperationCancellation?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var showingProgress = false
    @Published private(set) var output = ""
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published var hasQuestion = false
    @Published var hasChild = false
    var onIdle: () -> Void = {}
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canInteract: Bool { active && !busy && !showingProgress && !hasQuestion && !hasChild && !confirmingCancellation }
    var canClose: Bool { active && !busy && !hasQuestion && !hasChild && !confirmingCancellation }
    var canCancel: Bool { active && busy && !hasQuestion && !hasChild && !cancelling && !confirmingCancellation }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults) { self.repository = repository; self.access = access; self.preferences = preferences }
    func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func begin(progress: Bool = false) -> OperationCancellation {
        let token = OperationCancellation(); cancellation = token; generation = UUID(); busy = true; error = nil
        if progress { ProgressActionLog.nextAttempt(self, savePrevious: showingProgress); showingProgress = true; output = ""; success = false; cancelled = false }
        Self.activeOperations += 1; return token
    }
    func live(_ token: OperationCancellation) -> Bool { active && cancellation === token }
    func finish(_ token: OperationCancellation) {
        Self.activeOperations -= 1
        if cancellation === token { cancellation = nil; busy = false; cancelling = false; if active { onIdle() } }
    }
    func invalidate() {
        if busy { cancelled = true }; saveActionLog(); active = false; generation = UUID(); cancellation?.cancel()
    }
    func stream(_ token: OperationCancellation, _ work: @escaping (@escaping @Sendable (GitOutputChunk) -> Void) async throws -> String) async throws -> String {
        try checkAccess(); LocalGitCommandProgress.begin(); defer { LocalGitCommandProgress.end() }
        return try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in
            guard let self, self.live(token) else { return }; self.output = state.output
        }, resultText: { $0 }, operation: work)
    }
    func fail(_ failure: Error, token: OperationCancellation) {
        guard live(token) else { return }
        cancelled = token.isCancelled || failure is OperationCancellationFailure || failure is GitCommandCancellationFailure || (failure as? ResolveFailure).map { if case .cancelled = $0 { return true }; return false } == true
        success = false
        if showingProgress {
            output = LocalGitCommandProgress.failure(failure, existing: output, preferences: preferences)
            if cancelled { output = LocalGitCommandProgress.bounded(output + "\nResolution aborted. Earlier changes remain applied.", preferences: preferences) }
        } else if !cancelled { error = failure.localizedDescription }
    }
    func complete(_ token: OperationCancellation) { guard live(token) else { return }; success = !token.isCancelled; cancelled = token.isCancelled }
    func cancel() {
        guard canCancel, let token = cancellation else { return }
        if !showingProgress || !preferences.bool(forKey: "ConfirmKillProcess") { cancelling = true; token.cancel(); return }
        confirmingCancellation = true; var answered = false
        confirmCancellation { [weak self] accepted in
            guard !answered, let self, self.active else { return }; answered = true; self.confirmingCancellation = false
            if accepted, self.busy, self.cancellation === token { self.cancelling = true; token.cancel() }
            if !self.busy { self.onIdle() }
        }
    }
    func back() { guard canClose else { return }; saveActionLog(); showingProgress = false; success = false; cancelled = false; error = nil }
    var actionLogRepository: URL { repository.root }
    var actionLogEligible: Bool { showingProgress }
    var actionLogFailed: Bool { !success }
    var actionLogCancelled: Bool { cancelled }
}

@MainActor final class ConflictReviewSheets {
    weak var window: NSWindow?
    let operation: ConflictReviewOperation
    private var pending: (UUID, NSAlert, (NSApplication.ModalResponse?) -> Void)?
    var present: (NSWindow, NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Bool = { owner, alert, reply in
        guard owner.attachedSheet == nil else { return false }; alert.beginSheetModal(for: owner, completionHandler: reply); return true
    }
    init(window: NSWindow, operation: ConflictReviewOperation) { self.window = window; self.operation = operation }
    func ask(_ title: String, message: String = "", buttons: [String]) async -> NSApplication.ModalResponse? {
        guard operation.active, pending == nil, let window, window.attachedSheet == nil else { return nil }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
        for button in buttons { alert.addButton(withTitle: button) }
        if buttons == ["Delete", "Abort"] { alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r" }
        let id = UUID(); operation.hasQuestion = true
        return await withCheckedContinuation { continuation in
            pending = (id, alert, { continuation.resume(returning: $0) })
            if !present(window, alert, { [weak self] answer in self?.finish(id, answer: answer) }) { finish(id, answer: nil) }
        }
    }
    private func finish(_ id: UUID, answer: NSApplication.ModalResponse?) {
        guard let question = pending, question.0 == id else { return }; pending = nil; operation.hasQuestion = false
        if question.1.window.sheetParent === window { window?.endSheet(question.1.window, returnCode: answer ?? .abort) }
        question.1.window.orderOut(nil); question.2(answer)
    }
    func retire() { if let pending { finish(pending.0, answer: nil) } }
}

struct ConflictReviewProgressView: View {
    @ObservedObject var operation: ConflictReviewOperation
    let back: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(operation.busy ? "Resolving conflict…" : operation.hasChild ? "Waiting for submodule Reset…" : operation.success ? "Conflict resolved." : operation.cancelled ? "Resolution aborted." : "Resolution failed.").font(.headline)
            SubmoduleProgressOutputView(text: operation.output, completed: !operation.busy, success: operation.success, preferences: operation.preferences)
            Text("Reminder: Commit your change after resolve").font(.caption).foregroundStyle(.secondary)
            HStack {
                if operation.busy { ProgressView().controlSize(.small); Text(operation.cancelling ? "Cancelling…" : "Working…").font(.caption) }
                Spacer()
                if operation.busy { Button("Cancel") { operation.cancel() }.disabled(!operation.canCancel) }
                else { Button("Back") { back() }.disabled(!operation.canClose).keyboardShortcut(.defaultAction) }
            }
        }.padding(16)
    }
}
