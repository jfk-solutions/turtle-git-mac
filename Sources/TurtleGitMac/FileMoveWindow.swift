// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FileMoveWindowController: NSWindowController, NSWindowDelegate {
    let model: FileMoveWindowModel
    var onClosed: () -> Void = {}
    private var panel: (UUID, NSOpenPanel)?
    private var question: (UUID, NSAlert, (Bool) -> Void)?
    private(set) var namePicker: FileMoveNameController?
    var presentQuestion: (NSWindow, NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Bool = { owner, alert, reply in
        guard owner.attachedSheet == nil else { return false }; alert.beginSheetModal(for: owner, completionHandler: reply); return true
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], preferences: UserDefaults = .standard, savesGeometry:Bool = true) {
        model = FileMoveWindowModel(repository: repository, access: access, paths: paths, preferences: preferences)
        let size = NSSize(width: 760, height: 440)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Move", preferences: preferences); window.contentMinSize = NSSize(width: 650, height: 340); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FileMoveDialog(model: model))
        super.init(window: window); window.delegate = self; window.setContentSize(size); window.center()
        model.close = { [weak self] in self?.window?.performClose(nil) }
        model.browse = { [weak self] in self?.browse() }
        model.chooseName = { [weak self] source, folder, initial, token in
            guard let self, !self.model.retired, !self.model.confirmingQuit, self.namePicker == nil, let window = self.window, window.attachedSheet == nil else { return nil }
            self.model.hasQuestion = true
            return await withCheckedContinuation { continuation in
                let child = FileMoveNameController(repository: repository, access: access, source: source, folder: folder, name: initial, cancellation: token) { [weak self] plan in
                    if let child = self?.namePicker?.window, child.sheetParent === self?.window { self?.window?.endSheet(child) }
                    self?.namePicker = nil; self?.model.hasQuestion = false; continuation.resume(returning: plan)
                }
                self.namePicker = child; if let childWindow = child.window { childWindow.alphaValue = window.alphaValue; childWindow.appearance = window.appearance; window.beginSheet(childWindow, completionHandler: nil) } else { child.retire() }
            }
        }
        model.continueAfterError = { [weak self] source, message in await self?.ask(title: "Could not move “\(source)”", message: message, buttons: ["Ignore", "Abort"]) ?? false }
        model.confirmCancellation = { [weak self] reply in Task { reply(await self?.ask(title: "The process is still running.", message: "Are you sure to abort?", buttons: ["Yes", "No"]) ?? false) } }
        if savesGeometry { DialogGeometry.attach(window, identifier: "TurtleGit.FileMove") }
    }
    private func browse() {
        guard model.canEdit, let window, window.attachedSheet == nil, panel == nil else { return }
        let panel = NSOpenPanel(); panel.alphaValue = window.alphaValue; panel.appearance = window.appearance; panel.title = "Move to folder"; panel.prompt = "Choose destination"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.directoryURL = model.folder
        panel.message = "Choose a destination in the same working tree."
        let id = UUID(); self.panel = (id, panel); model.choosingFolder = true
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard let self, self.panel?.0 == id else { return }; self.panel = nil; self.model.choosingFolder = false
            if !self.model.retired, !self.model.confirmingQuit, answer == .OK, let folder = panel.url { self.model.setFolder(folder) }
        }
    }
    private func ask(title: String, message: String, buttons: [String]) async -> Bool {
        guard !model.retired, !model.confirmingQuit, question == nil, let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.window.alphaValue = window.alphaValue; alert.window.appearance = window.appearance; alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
        for button in buttons { alert.addButton(withTitle: button) }
        if buttons == ["Ignore", "Abort"] { alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r" }
        let id = UUID(); model.hasQuestion = true
        return await withCheckedContinuation { continuation in
            question = (id, alert, { continuation.resume(returning: $0) })
            if !presentQuestion(window, alert, { [weak self] answer in self?.finishQuestion(id, accepted: answer == .alertFirstButtonReturn) }) { finishQuestion(id, accepted: false) }
        }
    }
    private func finishQuestion(_ id: UUID, accepted: Bool) {
        guard let pending = question, pending.0 == id else { return }; question = nil; model.hasQuestion = false
        if pending.1.window.sheetParent === window { window?.endSheet(pending.1.window, returnCode: accepted ? .alertFirstButtonReturn : .alertSecondButtonReturn) }
        pending.1.window.orderOut(nil); pending.2(accepted)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { guard !model.confirmingQuit else { return false }; if model.busy { model.cancel(); return false }; return !model.hasQuestion && !model.choosingFolder && namePicker == nil && !model.confirmingCancellation }
    func windowWillClose(_ notification: Notification) {
        guard !model.retired else { return }; model.retire()
        if let pending = question { finishQuestion(pending.0, accepted: false) }
        if let (_, panel) = panel { panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        namePicker?.retire(); namePicker = nil; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class FileMoveWindowModel: ObservableObject, ActionLogProgress {
    static private(set) var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    var presentationPreferences: UserDefaults { preferences }
    @Published var confirmingQuit = false
    @Published private(set) var paths: [String]
    private(set) var retired = false
    private var pasteMode = false
    private var cancellation: OperationCancellation?
    @Published var folder: URL
    @Published var renameFirst = false
    @Published var busy = false
    @Published var progress = false
    @Published var output = ""
    @Published var currentPath = ""
    @Published var processed = 0
    @Published var moved = 0
    @Published var skipped = 0
    @Published var error: String?
    @Published var choosingFolder = false
    @Published var hasQuestion = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var failed = false
    var close: () -> Void = {}
    var browse: () -> Void = {}
    var onChanged: () -> Void = {}
    var onMoved: (String, String, String) -> Void = { _, _, _ in }
    var chooseName: (String, URL, String, OperationCancellation) async -> FileMovePlan? = { _, _, _, _ in nil }
    var continueAfterError: (String, String) async -> Bool = { _, _ in false }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var executeMove: ((FileMovePlan, OperationCancellation, @escaping @Sendable (GitOutputChunk) -> Void) async throws -> String)?
    var canEdit: Bool { !retired && !confirmingQuit && !busy && !progress && !choosingFolder && !hasQuestion }
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.preferences = preferences; folder = repository.root
        var seen = GitPathSet(); self.paths = paths.filter { seen.insert($0).inserted }
    }
    func loadClipboard(_ urls: [URL], destination: URL? = nil, stopOnError: Bool = true, automaticallyStart: Bool = false) {
        guard canEdit else { return }; pasteMode = stopOnError; let token = OperationCancellation(); cancellation = token; busy = true; error = nil; Self.activeOperations += 1
        Task {
            var start = false
            defer { Self.activeOperations -= 1; if cancellation === token { cancellation = nil; busy = false }; withExtendedLifetime(access) {}; if start && !retired { move() } }
            do { try checkAccess(); let folder = try await repository.fileMoveDestination(destination ?? self.folder, cancellation: token); let paths = try await repository.clipboardMovePaths(urls, cancellation: token); if live(token) { self.folder = folder; self.paths = paths; start = automaticallyStart } }
            catch { if live(token) { self.error = error.localizedDescription } }
        }
    }
    func retire() { if busy { cancelled = true }; saveActionLog(); retired = true; cancellation?.cancel() }
    private func live(_ token: OperationCancellation) -> Bool { !retired && cancellation === token && !token.isCancelled }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func setFolder(_ proposed: URL) {
        guard canEdit else { return }; let token = OperationCancellation(); cancellation = token; busy = true; error = nil; Self.activeOperations += 1
        Task {
            defer { Self.activeOperations -= 1; if cancellation === token { cancellation = nil; busy = false }; withExtendedLifetime(access) {} }
            do { try checkAccess(); let value = try await repository.fileMoveDestination(proposed, cancellation: token); if live(token) { folder = value } }
            catch { if live(token) { self.error = error.localizedDescription } }
        }
    }
    func move() {
        guard canEdit, !paths.isEmpty else { return }
        let destination = folder, rename = renameFirst && paths.count == 1, token = OperationCancellation()
        cancellation = token; busy = true; progress = true; output = ""; processed = 0; moved = 0; skipped = 0; failed = false; cancelled = false; error = nil
        ProgressActionLog.nextAttempt(self, savePrevious: false); Self.activeOperations += 1; LocalGitCommandProgress.begin()
        Task {
            defer { if !retired { onChanged() }; Self.activeOperations -= 1; LocalGitCommandProgress.end(); if cancellation === token { cancellation = nil; busy = false; currentPath = ""; cancelling = false }; withExtendedLifetime(access) {} }
            do {
                try checkAccess(); _ = try RemovalRequest(paths: paths, keepLocal: true)
                let folder = try await repository.fileMoveDestination(destination, cancellation: token)
                let head = try await repository.run(["rev-parse", "--verify", "--quiet", "HEAD"], successfulExitCodes: 0...1, cancellation: token).stdout
                for source in paths {
                    try token.check(); guard !retired else { return }; currentPath = source
                    do {
                        let plan: FileMovePlan?
                        if rename { plan = await chooseName(source, folder, (source as NSString).lastPathComponent, token) }
                        else {
                            do { plan = try await repository.prepareFileMove(source: source, to: folder, cancellation: token) }
                            catch FileMoveFailure.occupied { plan = await chooseName(source, folder, (source as NSString).lastPathComponent, token) }
                            catch FileMoveFailure.unchanged { plan = await chooseName(source, folder, (source as NSString).lastPathComponent, token) }
                        }
                        try token.check(); guard !retired else { return }; guard let plan else { cancelled = true; break }
                        guard plan.head == head else { throw FileMoveFailure.changed }
                        let prefix = output
                        let text = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in
                            guard let self, !self.retired, self.cancellation === token else { return }; self.output = LocalGitCommandProgress.bounded(prefix + state.output, preferences: self.preferences)
                        }, resultText: { $0 }) { [self] emit in
                            if let executeMove { return try await executeMove(plan, token, emit) }
                            return try await repository.executeFileMove(plan, cancellation: token, onOutput: emit)
                        }
                        guard !retired else { return }; moved += 1; processed += 1
                        output = LocalGitCommandProgress.bounded(output + (output.hasSuffix("\n") || output.isEmpty ? "" : "\n") + "Moved: \(source) → \(plan.destination)\n", preferences: preferences)
                        onMoved(source, plan.destination, text)
                    } catch {
                        try token.check(); guard !retired else { return }
                        output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences)
                        if pasteMode { failed = true; break }
                        let ignore = await continueAfterError(source, error.localizedDescription)
                        try token.check(); guard !retired else { return }
                        if !ignore { failed = true; break }; skipped += 1; processed += 1
                    }
                }
            } catch {
                guard !retired else { return }; cancelled = token.isCancelled || error is OperationCancellationFailure || error is GitCommandCancellationFailure
                failed = !cancelled; output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences)
            }
        }
    }
    func cancel() {
        guard !retired, !confirmingQuit, busy, !hasQuestion, !confirmingCancellation, !cancelling, let token = cancellation else { return }
        if !progress || !preferences.bool(forKey: "ConfirmKillProcess") { cancelling = true; token.cancel(); return }
        confirmingCancellation = true; var answered = false
        confirmCancellation { [weak self] accepted in
            guard !answered, let self, !self.retired else { return }; answered = true; self.confirmingCancellation = false
            if accepted, !self.confirmingQuit, self.busy, self.cancellation === token { self.cancelling = true; token.cancel() }
        }
    }
    var actionLogRepository: URL { repository.root }
    var actionLogEligible: Bool { progress }
    var actionLogFailed: Bool { failed || skipped > 0 }
    var actionLogCancelled: Bool { cancelled }
}

private struct FileMoveDialog: View {
    @ObservedObject var model: FileMoveWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.progress {
                Text(model.busy ? "Moving files…" : model.cancelled ? "Move cancelled. Earlier moves remain applied." : model.failed ? "Move stopped." : "Moved \(model.moved) items; skipped \(model.skipped).").font(.headline)
                SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: !model.failed && !model.cancelled, preferences: model.preferences)
                HStack { if model.busy { ProgressView(value: Double(model.processed), total: Double(max(1, model.paths.count))); Text(model.currentPath).lineLimit(1).truncationMode(.middle) }; Spacer()
                    if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.disabled(model.cancelling || model.hasQuestion || model.confirmingCancellation) }
                    else { Button("Close") { model.saveActionLog(); model.close() }.keyboardShortcut(.defaultAction).disabled(model.confirmingCancellation) }
                }
            } else {
                Text("Move versioned files and folders").font(.headline)
                List(model.paths.map { GitReferenceName($0) }, id: \.self) { Text($0.rawValue).textSelection(.enabled) }
                HStack { Text("Destination:"); Text(model.folder.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled); Spacer(); Button("…") { model.browse() }.disabled(!model.canEdit) }
                if model.paths.count == 1 { Toggle("Rename while moving", isOn: $model.renameFirst).disabled(!model.canEdit) }
                Text("Moves preserve staged and working contents. A conflicting destination requires a new name.").font(.caption).foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.red) }
                HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer(); Button("Move") { model.move() }.keyboardShortcut(.defaultAction).disabled(!model.canEdit || model.paths.isEmpty); Button(model.busy ? "Cancel read" : "Cancel") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction) }
            }
        }.padding(16).disabled(model.confirmingQuit)
    }
}

/// Shared source Rename prompt for collision and Move/Rename. Validation remains
/// visible in the sheet; it returns an immutable plan, never performs the move.
@MainActor final class FileMoveNameController: NSWindowController, NSWindowDelegate {
    let nameField = NSTextField(string: "")
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let ok = NSButton(title: "OK", target: nil, action: nil)
    private let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let source: String
    private let folder: URL
    private let cancellation: OperationCancellation
    private var reply: ((FileMovePlan?) -> Void)?
    private(set) var busy = false
    private var closed = false
    init(repository: GitRepository, access: RepositoryAccessLease?, source: String, folder: URL, name: String, cancellation: OperationCancellation, reply: @escaping (FileMovePlan?) -> Void) {
        self.repository = repository; self.access = access; self.source = source; self.folder = folder; self.cancellation = cancellation; self.reply = reply
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 165), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "New name for moving “\((source as NSString).lastPathComponent)”"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let label = NSTextField(labelWithString: "New name:"), destination = NSTextField(labelWithString: folder.path)
        destination.lineBreakMode = .byTruncatingMiddle; destination.maximumNumberOfLines = 1
        nameField.stringValue = name; nameField.setAccessibilityLabel("New name")
        errorLabel.textColor = .systemRed; ok.bezelStyle = .rounded; ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let row = NSStackView(views: [label, nameField]); row.orientation = .horizontal; row.spacing = 12
        let buttons = NSStackView(views: [ok, cancel]); buttons.orientation = .horizontal; buttons.spacing = 8
        let stack = NSStackView(views: [destination, row, errorLabel, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); window.contentView = content; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 350)])
        window.makeFirstResponder(nameField)
    }
    @objc func accept() {
        guard !closed, !busy, !cancellation.isCancelled else { return }; busy = true; ok.isEnabled = false; nameField.isEnabled = false
        let name = nameField.stringValue
        Task {
            defer { busy = false; ok.isEnabled = true; nameField.isEnabled = true; withExtendedLifetime(access) {}; if closed { finish(nil) } }
            do {
                let plan = try await repository.prepareFileMove(source: source, to: folder, name: name, cancellation: cancellation)
                try cancellation.check(); guard !closed else { return }; finish(plan)
            } catch { if !closed, !cancellation.isCancelled { errorLabel.stringValue = error.localizedDescription } }
        }
    }
    @objc private func cancel() { cancellation.cancel(); retire() }
    func retire() { guard !closed else { return }; closed = true; cancellation.cancel(); window?.orderOut(nil); if !busy { finish(nil) } }
    private func finish(_ plan: FileMovePlan?) {
        guard let reply else { return }; self.reply = nil; closed = true
        if let parent = window?.sheetParent, let window { parent.endSheet(window) }; window?.orderOut(nil); window?.close(); reply(plan)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    func windowWillClose(_ notification: Notification) { retire() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
