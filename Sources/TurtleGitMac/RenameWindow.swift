// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RenameWindowController: NSWindowController, NSWindowDelegate {
    let model: RenameWindowModel
    var onClosed: () -> Void = {}
    private var panel: (UUID, NSSavePanel)?
    private var question: (UUID, NSAlert, (Bool) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, source: String, preferences: UserDefaults = .standard) {
        model = RenameWindowModel(repository: repository, access: access, source: source, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 160), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Rename – TurtleGit"; window.contentMinSize = NSSize(width: 520, height: 160); window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 160); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RenameDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in self?.window?.performClose(nil) }; model.browse = { [weak self] in self?.browse() }
        model.presentProgress = { [weak window] in window?.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude); window?.contentMinSize = NSSize(width: 620, height: 300); window?.setContentSize(NSSize(width: 760, height: 430)) }
        model.restoreInput = { [weak window] in window?.contentMinSize = NSSize(width: 520, height: 160); window?.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 160); window?.setContentSize(NSSize(width: 610, height: 160)) }
        model.confirmCancel = { [weak self] in await self?.confirmCancellation() ?? false }
        DialogGeometry.attach(window, identifier: "RenameDialog", legacyName: "RenameDialog")
    }
    private func browse() {
        guard model.canEdit, panel == nil, let window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel(), id = UUID(), original = model.repository.root.appendingPathComponent(model.source)
        panel.title = "Rename"; panel.prompt = "Choose destination"; panel.directoryURL = original.deletingLastPathComponent(); panel.nameFieldStringValue = model.name; panel.canCreateDirectories = true
        self.panel = (id, panel); model.choosingDestination = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.panel?.0 == id else { return }; self.panel = nil; self.model.choosingDestination = false
            if !self.model.retired, response == .OK, let target = panel.url { self.model.chooseDestination(target) }
        }
    }
    private func confirmCancellation() async -> Bool {
        guard !model.retired, question == nil, let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = "The process is still running."; alert.informativeText = "Stop the current rename? Review the resulting index and working paths before retrying."; alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
        let id = UUID(); model.hasQuestion = true
        return await withCheckedContinuation { continuation in
            question = (id, alert, { continuation.resume(returning: $0) }); alert.beginSheetModal(for: window) { [weak self] response in self?.finishQuestion(id, accepted: response == .alertFirstButtonReturn) }
        }
    }
    private func finishQuestion(_ id: UUID, accepted: Bool) {
        guard let pending = question, pending.0 == id else { return }; question = nil; model.hasQuestion = false
        if pending.1.window.sheetParent === window { window?.endSheet(pending.1.window) }; pending.1.window.orderOut(nil); pending.2(accepted)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.choosingDestination && !model.hasQuestion && !model.confirmingCancellation }
    func windowWillClose(_ notification: Notification) { guard !model.retired else { return }; model.retire(); if let (_, panel) = panel { panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil; if let pending = question { finishQuestion(pending.0, accepted: false) }; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class RenameWindowModel: ObservableObject, ActionLogProgress {
    static private(set) var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let source: String
    let preferences: UserDefaults
    private var token: OperationCancellation?
    private(set) var retired = false
    @Published var name: String
    @Published var busy = false
    @Published var error: String?
    @Published var choosingDestination = false
    @Published var hasQuestion = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var cancelling = false
    @Published private(set) var progress = false
    @Published private(set) var failed = false
    @Published private(set) var cancelled = false
    @Published var output = ""
    var canEdit: Bool { !retired && !busy && !progress && !choosingDestination && !hasQuestion }
    var close: () -> Void = {}
    var browse: () -> Void = {}
    var presentProgress: () -> Void = {}
    var restoreInput: () -> Void = {}
    var confirmCancel: () async -> Bool = { false }
    var onRenamed: (String, String, String) -> Void = { _, _, _ in }
    var onChanged: () -> Void = {}
    var resolveDestination: ((URL, OperationCancellation) async throws -> String)?
    init(repository: GitRepository, access: RepositoryAccessLease?, source: String, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; self.source = source; self.preferences = preferences; name = (source as NSString).lastPathComponent }
    private func requireAccess() throws { if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable } }
    func retire() { if busy { cancelled = true }; retired = true; token?.cancel(); saveActionLog() }
    func chooseDestination(_ target: URL) {
        guard canEdit else { return }; let token = OperationCancellation(); self.token = token; busy = true; error = nil; Self.activeOperations += 1
        Task {
            defer { Self.activeOperations -= 1; withExtendedLifetime(access) {}; if self.token === token { self.token = nil; busy = false } }
            do { try requireAccess(); let value: String; if let resolveDestination { value = try await resolveDestination(target, token) } else { value = try await repository.renameDestination(target, source: source, cancellation: token) }; try token.check(); if !retired { name = value } }
            catch { if !retired, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func rename() {
        guard canEdit else { return }; let options = RenameOptions(source: source, name: name), token = OperationCancellation(); self.token = token; busy = true; error = nil; cancelled = false; failed = false; output = ""; Self.activeOperations += 1; LocalGitCommandProgress.begin()
        Task {
            var attempted = false
            defer { Self.activeOperations -= 1; LocalGitCommandProgress.end(); withExtendedLifetime(access) {}; if self.token === token { self.token = nil; busy = false; cancelling = false }; if attempted && !retired { onChanged() } }
            do {
                try requireAccess(); let plan = try await repository.prepareRename(options, cancellation: token); try token.check(); guard !retired else { return }
                progress = true; ProgressActionLog.nextAttempt(self, savePrevious: false); presentProgress(); attempted = true
                let text = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] value in guard let self, !self.retired, self.token === token else { return }; self.output = value.output }, resultText: { $0 }) { [self] emit in try await repository.executeRename(plan, cancellation: token, onOutput: emit) }
                guard !retired else { return }; onRenamed(source, plan.destination, text); onChanged(); attempted = false
                busy = false; self.token = nil; saveActionLog(); close()
            } catch {
                guard !retired else { return }; cancelled = token.isCancelled; failed = !cancelled
                if progress { output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences) }
                else if !cancelled { self.error = error.localizedDescription }
            }
        }
    }
    func back() { guard !retired, !busy, progress, !hasQuestion, !confirmingCancellation else { return }; saveActionLog(); progress = false; restoreInput() }
    func cancel() {
        guard !retired, busy, !hasQuestion, !confirmingCancellation, !cancelling, let token else { return }
        if !progress || !preferences.bool(forKey: "ConfirmKillProcess") { cancelling = true; token.cancel(); return }
        confirmingCancellation = true
        Task { let accepted = await confirmCancel(); confirmingCancellation = false; if accepted && !retired && self.token === token { cancelling = true; token.cancel() } }
    }
    var actionLogRepository: URL { repository.root }
    var actionLogEligible: Bool { progress }
    var actionLogFailed: Bool { failed }
    var actionLogCancelled: Bool { cancelled }
}
private struct RenameDialog: View {
    @ObservedObject var model: RenameWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.progress {
                Text(model.busy ? "Renaming…" : model.cancelled ? "Rename stopped. Review current paths before retrying." : "Rename failed.").font(.headline)
                SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: !model.failed && !model.cancelled, preferences: model.preferences)
                HStack { if !model.busy { Button("Back") { model.back() } }; Spacer(); Button(model.busy ? "Cancel" : "Close") { if model.busy { model.cancel() } else { model.saveActionLog(); model.close() } }.disabled(model.cancelling || model.hasQuestion || model.confirmingCancellation) }
            } else {
                Text("Rename “\((model.source as NSString).lastPathComponent)”: ").lineLimit(2).help(model.source)
                HStack { Text("New name:").frame(width: 90, alignment: .leading); PathEntryField(text: $model.name, label: "New name", base: model.repository.root.appendingPathComponent(model.source).deletingLastPathComponent(), permissions: [model.access].compactMap { $0 }, focus: true, mayEdit: { model.canEdit }).frame(height: 22).disabled(!model.canEdit); Button("…") { model.browse() }.disabled(!model.canEdit) }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer(minLength: 0)
                HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer(); Button("OK") { model.rename() }.keyboardShortcut(.defaultAction).disabled(!model.canEdit); Button("Cancel") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction).disabled(model.choosingDestination) }
            }
        }.padding(16)
    }
}
