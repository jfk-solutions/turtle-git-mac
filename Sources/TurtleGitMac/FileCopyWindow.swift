// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class FileCopyWindowController: NSWindowController, NSWindowDelegate {
    let model: FileCopyWindowModel
    var onClosed: () -> Void = {}
    private var panel: NSOpenPanel?
    private var pending: (UUID, NSAlert, (Int) -> Void)?
    private(set) var name: FileCopyNameController?
    init(repository: GitRepository, access: RepositoryAccessLease?, sources: [URL], folder: URL? = nil, paste: Bool = false, preferences: UserDefaults = .standard) {
        model = FileCopyWindowModel(repository: repository, access: access, sources: sources, folder: folder, paste: paste, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Copy and Add – TurtleGit"; window.contentMinSize = NSSize(width: 650, height: 340); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FileCopyDialog(model: model))
        super.init(window: window); window.delegate = self; window.center(); DialogGeometry.attach(window, identifier: "TurtleGit.FileCopy")
        model.close = { [weak self] in self?.window?.performClose(nil) }
        model.browse = { [weak self] sources in self?.browse(sources: sources) }
        model.collision = { [weak self] destination in
            let reply = await self?.ask("An item already exists at “\(destination)”.", detail: "Choose how to copy this item.", buttons: ["Overwrite", "Keep", "Cancel"], defaultIndex: 1) ?? 2
            return reply == 0 ? .overwrite : reply == 1 ? .keep : .cancel
        }
        model.repositoryChoice = { [weak self] item in
            let reply = await self?.ask(item.gitFile ? "The copied folder contains submodule metadata." : "The copied folder contains a Git repository.", detail: "\(item.path)\nDelete removes only the copied .git metadata and adds its files. Ignore keeps this copied repository outside the Add operation. Abort leaves the copied files for recovery.", buttons: ["Delete", "Ignore", "Abort"], defaultIndex: 0) ?? 2
            return reply == 0 ? .deleteMetadata : reply == 1 ? .ignore : .abort
        }
        model.chooseName = { [weak self] source, folder, token in
            guard let self, !self.model.retired, let window = self.window, window.attachedSheet == nil else { return nil }
            self.model.question = true
            return await withCheckedContinuation { continuation in
                let child = FileCopyNameController(repository: repository, source: source, folder: folder, token: token) { [weak self] plan in
                    self?.name = nil; self?.model.question = false; continuation.resume(returning: plan)
                }
                self.name = child; if let childWindow = child.window { window.beginSheet(childWindow) }
            }
        }
        model.confirmCancel = { [weak self] in await self?.ask("The process is still running.", detail: "Are you sure to abort?", buttons: ["Yes", "No"], defaultIndex: 1) == 0 }
    }
    private func browse(sources: Bool) {
        guard model.canEdit, let window, window.attachedSheet == nil, panel == nil else { return }
        let panel = NSOpenPanel(); panel.title = sources ? "Copy and Add files or folders" : "Copy to folder"; panel.canChooseFiles = sources; panel.canChooseDirectories = true; panel.allowsMultipleSelection = sources; panel.canCreateDirectories = !sources; panel.directoryURL = model.folder
        self.panel = panel; model.question = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.panel === panel else { return }; self.panel = nil; self.model.question = false
            if response == .OK, !self.model.retired { if sources { self.model.setSources(panel.urls) } else if let url = panel.url { self.model.folder = url } }
        }
    }
    private func ask(_ title: String, detail: String, buttons: [String], defaultIndex: Int) async -> Int {
        guard !model.retired, pending == nil, let window, window.attachedSheet == nil else { return buttons.count - 1 }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.alertStyle = .warning
        for (index, title) in buttons.enumerated() { let button = alert.addButton(withTitle: title); button.keyEquivalent = index == defaultIndex ? "\r" : "" }
        let id = UUID(); model.question = true
        return await withCheckedContinuation { continuation in
            pending = (id, alert, { continuation.resume(returning: $0) })
            alert.beginSheetModal(for: window) { [weak self] response in self?.settle(id, answer: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        }
    }
    private func settle(_ id: UUID, answer: Int) {
        guard let pending, pending.0 == id else { return }; self.pending = nil; model.question = false
        if pending.1.window.sheetParent === window { window?.endSheet(pending.1.window) }; pending.1.window.orderOut(nil); pending.2(answer)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.question && !model.confirmingCancel }
    func windowWillClose(_ notification: Notification) {
        guard !model.retired else { return }; model.retire()
        if let pending { settle(pending.0, answer: 2) }
        if let panel { panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        name?.retire(); name = nil; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class FileCopyWindowModel: ObservableObject, ActionLogProgress {
    static private(set) var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    let paste: Bool
    private var sourceAccess: [RepositoryAccessLease] = []
    private var token: OperationCancellation?
    private(set) var retired = false
    @Published private(set) var sources: [URL] = []
    @Published var folder: URL
    @Published var busy = false
    @Published var progress = false
    @Published var question = false
    @Published private(set) var confirmingCancel = false
    @Published var output = ""
    @Published var current = ""
    @Published var processed = 0
    @Published var copied = 0
    @Published var kept = 0
    @Published private(set) var failed = false
    @Published private(set) var cancelled = false
    @Published var error: String?
    var close: () -> Void = {}
    var browse: (Bool) -> Void = { _ in }
    var onChanged: () -> Void = {}
    var onCopied: (String) -> Void = { _ in }
    var collision: (String) async -> FileCopyCollision = { _ in .cancel }
    var repositoryChoice: (CopiedRepository) async -> CopiedRepositoryChoice = { _ in .abort }
    var chooseName: (URL, URL, OperationCancellation) async -> FileCopyPlan? = { _, _, _ in nil }
    var confirmCancel: () async -> Bool = { false }
    var canEdit: Bool { !retired && !busy && !progress && !question }
    init(repository: GitRepository, access: RepositoryAccessLease?, sources: [URL], folder: URL?, paste: Bool = false, preferences: UserDefaults) {
        self.repository = repository; self.access = access; self.preferences = preferences; self.paste = paste; self.folder = folder ?? repository.root
        setSources(sources)
    }
    func setSources(_ urls: [URL]) {
        guard canEdit else { return }; var seen = Set<String>(); sources = urls.filter { $0.isFileURL && seen.insert($0.path).inserted }; sourceAccess = sources.map { RepositoryAccessLease(url: $0) }
    }
    @discardableResult func drop(_ providers: [NSItemProvider]) -> Bool {
        guard canEdit, !providers.isEmpty, providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        let token = OperationCancellation(); self.token = token; busy = true; Self.activeOperations += 1
        Task {
            defer { Self.activeOperations -= 1; if self.token === token { self.token = nil; busy = false }; withExtendedLifetime(sourceAccess) {} }
            do {
                var urls: [URL] = []; for provider in providers { try token.check(); urls.append(try await CommitFileURLReader.read(provider)) }; try token.check()
                guard !retired else { return }; busy = false; setSources(urls)
            } catch { if !retired && !token.isCancelled { self.error = error.localizedDescription } }
        }; return true
    }
    func retire() { if busy { cancelled = true }; saveActionLog(); retired = true; token?.cancel() }
    func run() {
        guard canEdit, !sources.isEmpty else { return }
        let urls = sources, folder = folder, token = OperationCancellation(); self.token = token; busy = true; progress = true; failed = false; cancelled = false; output = ""; processed = 0; copied = 0; kept = 0; error = nil
        Self.activeOperations += 1; LocalGitCommandProgress.begin(); ProgressActionLog.nextAttempt(self, savePrevious: false)
        Task {
            defer { if !retired { onChanged() }; Self.activeOperations -= 1; LocalGitCommandProgress.end(); if self.token === token { self.token = nil; busy = false; current = "" }; withExtendedLifetime(sourceAccess) {}; withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild {
                    guard access?.hasSecurityScope == true, access?.contains(repository.root) == true,
                          zip(urls, sourceAccess).allSatisfy({ url, lease in access?.contains(url) == true || lease.hasSecurityScope }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                }
                let destination = try await repository.fileMoveDestination(folder, cancellation: token)
                var additions: [(String, [String])] = []
                for source in urls {
                    try token.check(); guard !retired else { return }; current = source.path
                    let plan: FileCopyPlan
                    do { plan = try await repository.prepareFileCopy(source: source, to: destination, cancellation: token) }
                    catch FileMoveFailure.unchanged { guard let chosen = await chooseName(source, destination, token) else { token.cancel(); throw OperationCancellationFailure.cancelled }; plan = chosen }
                    try token.check(); guard !retired else { return }
                    if plan.targetDirectory && plan.sourceDirectory { kept += 1; processed += 1; append("Kept existing folder: \(plan.destination)"); continue }
                    var overwrite = false
                    if plan.occupied {
                        switch await collision(plan.destination) {
                        case .cancel: token.cancel(); throw OperationCancellationFailure.cancelled
                        case .keep:
                            try token.check(); guard !retired else { return }; kept += 1; processed += 1; append("Kept: \(plan.destination)")
                            if paste { try await add(plan.destination, ignored: [], token: token) } else { additions.append((plan.destination, [])) }; continue
                        case .overwrite: overwrite = true
                        }
                    }
                    try token.check(); guard !retired else { return }
                    let result = try await repository.copyWorkingItem(plan, overwrite: overwrite, cancellation: token)
                    guard !retired else { return }; copied += 1; append("Copied: \(source.path) → \(result.destination)"); onCopied(result.destination)
                    var ignored: [String] = []
                    while true {
                        let repos = try await repository.copiedRepositories(result.destination, cancellation: token).filter { !ignored.contains($0.path) }
                        guard let item = repos.first else { break }
                        let choice = await repositoryChoice(item); try token.check(); guard !retired else { return }
                        switch choice {
                        case .abort: token.cancel(); throw OperationCancellationFailure.cancelled
                        case .ignore: ignored.append(item.path); append("Ignored copied repository: \(item.path)")
                        case .deleteMetadata: try await repository.removeCopiedGitMetadata(item, cancellation: token); append("Deleted copied Git metadata: \(item.path)")
                        }
                    }
                    if paste { try await add(result.destination, ignored: ignored, token: token) } else { additions.append((result.destination, ignored)) }
                    try token.check(); guard !retired else { return }; processed += 1
                }
                if !paste { for (destination, ignored) in additions { try token.check(); guard !retired else { return }; current = "Adding: " + destination; try await add(destination, ignored: ignored, token: token) } }
            } catch { if !retired { cancelled = token.isCancelled; failed = !cancelled; output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences) } }
        }
    }
    private func add(_ destination: String, ignored: [String], token: OperationCancellation) async throws {
        let prefix = output
        _ = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in
            guard let self, !self.retired, self.token === token else { return }; self.output = LocalGitCommandProgress.bounded(prefix + state.output, preferences: self.preferences)
        }, resultText: { $0 }) { [self] emit in try await repository.stageCopiedItem(destination, ignoredRepositories: ignored, cancellation: token, onOutput: emit) }
        try token.check(); if !retired { append("Added: \(destination)") }
    }
    private func append(_ text: String) { output = LocalGitCommandProgress.bounded(output + (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + text + "\n", preferences: preferences) }
    func cancel() {
        guard !retired, busy, !question, !confirmingCancel, let token else { return }
        if !progress || !preferences.bool(forKey: "ConfirmKillProcess") { token.cancel(); return }
        confirmingCancel = true
        Task { let accepted = await confirmCancel(); confirmingCancel = false; if accepted && !retired && self.token === token { token.cancel() } }
    }
    var actionLogRepository: URL { repository.root }
    var actionLogEligible: Bool { progress }
    var actionLogFailed: Bool { failed }
    var actionLogCancelled: Bool { cancelled }
}
private struct FileCopyDialog: View {
    @ObservedObject var model: FileCopyWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.progress ? "Copy and Add" : "Copy files and folders into this working tree").font(.headline)
            if model.progress {
                SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: !model.failed && !model.cancelled, preferences: model.preferences)
                Text(model.busy ? model.current : model.cancelled ? "Cancelled. Copied files and earlier additions remain." : model.failed ? "Stopped. Copied files remain for recovery." : "Copied \(model.copied); kept \(model.kept).").lineLimit(2)
                HStack { if model.busy { ProgressView(value: Double(model.processed), total: Double(max(1, model.sources.count))) }; Spacer(); Button(model.busy ? "Cancel" : "Close") { if model.busy { model.cancel() } else { model.saveActionLog(); model.close() } }.disabled(model.question || model.confirmingCancel) }
            } else {
                List(model.sources, id: \.path) { Text($0.path).textSelection(.enabled) }
                    .onDrop(of: [UTType.fileURL], isTargeted: nil) { model.drop($0) }
                Button { model.browse(true) } label: { CommandLabel(title: "Choose files…", icon: .copy) }.disabled(!model.canEdit)
                HStack { Text("Destination:"); Text(model.folder.path).lineLimit(1).truncationMode(.middle); Spacer(); Button("…") { model.browse(false) }.disabled(!model.canEdit) }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer(); Button("Copy and Add") { model.run() }.keyboardShortcut(.defaultAction).disabled(!model.canEdit || model.sources.isEmpty); Button("Cancel") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction) }
            }
        }.padding(16)
    }
}
@MainActor final class FileCopyNameController: NSWindowController, NSWindowDelegate {
    private let repository: GitRepository, source: URL, folder: URL, token: OperationCancellation
    let field = NSTextField(string: ""), error = NSTextField(wrappingLabelWithString: "")
    private let ok = NSButton(title: "OK", target: nil, action: nil)
    private var reply: ((FileCopyPlan?) -> Void)?
    private(set) var busy = false
    private var retired = false
    init(repository: GitRepository, source: URL, folder: URL, token: OperationCancellation, reply: @escaping (FileCopyPlan?) -> Void) {
        self.repository = repository; self.source = source; self.folder = folder; self.token = token; self.reply = reply
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 165), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "New name for copying “\(source.lastPathComponent)”"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; field.stringValue = source.lastPathComponent; field.setAccessibilityLabel("New name"); error.textColor = .systemRed
        ok.bezelStyle = .rounded; ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let row = NSStackView(views: [NSTextField(labelWithString: "New name:"), field]); row.orientation = .horizontal
        let buttons = NSStackView(views: [ok, cancel]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [NSTextField(labelWithString: folder.path), row, error, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView { NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), field.widthAnchor.constraint(greaterThanOrEqualToConstant: 350)]) }; window.makeFirstResponder(field)
    }
    @objc func accept() {
        guard !busy, !retired else { return }; busy = true; ok.isEnabled = false; field.isEnabled = false; let name = field.stringValue
        Task {
            defer { busy = false; ok.isEnabled = true; field.isEnabled = true; if retired { finish(nil) } }
            do { let plan = try await repository.prepareFileCopy(source: source, to: folder, name: name, cancellation: token); try token.check(); if !retired { finish(plan) } }
            catch { if !retired && !token.isCancelled { self.error.stringValue = error.localizedDescription } }
        }
    }
    @objc private func cancel() { retire() }
    func retire() { guard !retired else { return }; retired = true; token.cancel(); window?.orderOut(nil); if !busy { finish(nil) } }
    private func finish(_ plan: FileCopyPlan?) { guard let reply else { return }; self.reply = nil; retired = true; if let window, let parent = window.sheetParent { parent.endSheet(window) }; window?.close(); reply(plan) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { retire(); return false }
    func windowWillClose(_ notification: Notification) { retire() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
