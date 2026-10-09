// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SubmoduleAddWindowController: NSWindowController, NSWindowDelegate {
    let model: SubmoduleAddWindowModel
    var onClosed: () -> Void = {}
    private var panel: NSOpenPanel?
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String = "", preferences: UserDefaults = .standard) {
        model = SubmoduleAddWindowModel(repository: repository, access: access, path: path, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 310), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Submodule Add – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 670, height: 310)
        window.contentViewController = NSHostingController(rootView: SubmoduleAddDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in self?.window?.close() }
        model.pick = { [weak self] kind in self?.pick(kind) }
        model.presentSSH = { [weak self] prompt in
            guard let window = self?.window, window.attachedSheet == nil, let child = prompt.window else { return false }
            window.makeFirstResponder(nil); window.beginSheet(child); return true
        }
        DialogGeometry.attach(window, identifier: "SubmoduleAddDlg")
    }
    private func pick(_ kind: SubmoduleAddWindowModel.Picker) {
        guard !model.activeOperation, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); self.panel = panel; model.picking = true
        panel.canChooseFiles = kind == .key; panel.canChooseDirectories = kind != .key
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = kind == .path
        panel.directoryURL = kind == .path ? model.repository.root : nil
        panel.prompt = kind == .key ? "Select OpenSSH key" : "Select folder"
        window.makeFirstResponder(nil)
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self, self.panel === panel else { return }
            self.panel = nil; self.model.picking = false
            if response == .OK, let url = panel?.url { self.model.acceptSelection(url, kind: kind) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.activeOperation && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        model.invalidate(); panel?.cancel(nil); panel = nil
        if let window, let child = window.attachedSheet { window.endSheet(child, returnCode: .abort); child.close() }
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class SubmoduleAddWindowModel: ObservableObject {
    enum Picker { case repository, path, key }
    let repository: GitRepository
    private let access: RepositoryAccessLease?, preferences: UserDefaults, basePath: String
    private var sourceAccess: RepositoryAccessLease?, keyAccess: RepositoryAccessLease?
    private var token: OperationCancellation?, invalidated = false
    private var submitted: SubmoduleAddOptions?
    private var streamState: GitProgressOutputState
    @Published var source: String
    @Published var path: String
    @Published var useBranch = false
    @Published var branch = ""
    @Published var force = false
    @Published var useKey = false
    @Published var key = ""
    @Published var busy = false
    @Published var picking = false
    @Published var confirmingQuit = false
    @Published var success = false
    @Published var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var completionRange: NSRange?
    @Published var error: String?
    let sources: [String], paths: [String], keys: [String]
    var identities = SSHIdentityAccessStore()
    var makeSSHCoordinator: SSHCloneTransportFactory?
    var presentSSH: (SSHKeyPassphraseWindowController) -> Bool = { _ in false }
    var pick: (Picker) -> Void = { _ in }
    var close: () -> Void = {}
    var onAdded: (String) -> Void = { _ in }
    var sshAvailable: Bool { makeSSHCoordinator != nil || (try? SSHAgentRuntime.resolve())?.askpass != nil }
    var activeOperation: Bool { busy || picking || confirmingQuit }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, preferences: UserDefaults = .standard) {
        streamState = GitProgressOutputState(preferences: preferences)
        self.repository = repository; self.access = access; self.preferences = preferences; basePath = path == "." ? "" : path
        sources = preferences.stringArray(forKey: "SubmoduleAdd.URLHistory") ?? []
        paths = preferences.stringArray(forKey: "SubmoduleAdd.PathHistory") ?? []
        keys = preferences.stringArray(forKey: "Clone.KeyHistory") ?? []
        source = sources.first ?? ""; self.path = basePath; key = keys.first ?? ""; useKey = sshAvailable
    }
    func sourceEndedEditing() {
        guard !activeOperation, !invalidated, submitted == nil else { return }
        var name = source.trimmingCharacters(in: CharacterSet(charactersIn: "/\\").union(.whitespacesAndNewlines)).components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? ""
        if name.hasSuffix(".git") { name.removeLast(4) }
        if !name.isEmpty { path = basePath.isEmpty ? name : basePath + "/" + name }
    }
    func acceptSelection(_ url: URL, kind: Picker) {
        guard !activeOperation, !invalidated, submitted == nil else { return }
        do {
            switch kind {
            case .repository: sourceAccess = RepositoryAccessLease(url: url); source = url.path
            case .path:
                var options = SubmoduleAddOptions(); options.path = url.path
                var selected = url.standardizedFileURL.path == repository.root.path ? "" : try options.relativePath(root: repository.root)
                let name = source.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/").last ?? ""
                let component = name.hasSuffix(".git") ? String(name.dropLast(4)) : name
                if !component.isEmpty { selected += (selected.isEmpty ? "" : "/") + component }; options.path = selected
                path = try options.relativePath(root: repository.root)
            case .key: try identities.remember(url, requireSecurityScope: GitRuntime.isAppStoreBuild); key = url.path
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func invalidate() { invalidated = true; token?.cancel(); keyAccess = nil }
    func cancelOperation() { token?.cancel() }
    func apply() {
        guard !activeOperation, !invalidated, submitted == nil else { return }
        do {
            var options = SubmoduleAddOptions(); options.source = source; options.path = path; options.force = force
            if useBranch { options.branch = branch.trimmingCharacters(in: .whitespacesAndNewlines) }
            if useKey && !key.isEmpty { guard sshAvailable else { throw CloneFailure.keyRuntime }; options.sshKey = URL(fileURLWithPath: key); guard key.hasPrefix("/") else { throw SubmoduleAddFailure.key } }
            _ = try options.arguments(root: repository.root)
            if GitRuntime.isAppStoreBuild {
                guard access?.hasSecurityScope == true, access?.contains(repository.root) == true else { throw RepositoryAccessFailure.securityScopeUnavailable }
                let local = options.source.hasPrefix("/") ? URL(fileURLWithPath: options.source) : URL(string: options.source).flatMap { $0.isFileURL ? $0 : nil }
                if let local { guard sourceAccess?.hasSecurityScope == true, sourceAccess?.contains(local) == true else { throw RepositoryAccessFailure.securityScopeUnavailable } }
            }
            if let key = options.sshKey { keyAccess = try identities.acquire(path: key.path, requireSecurityScope: GitRuntime.isAppStoreBuild).permission }
            for (field, value) in [("SubmoduleAdd.URLHistory", options.source.trimmingCharacters(in: .whitespacesAndNewlines)), ("SubmoduleAdd.PathHistory", options.path.trimmingCharacters(in: .whitespacesAndNewlines))] { saveHistory(field, value) }
            saveHistory("Clone.KeyHistory", key)
            submitted = options; execute(options)
        } catch { self.error = error.localizedDescription }
    }
    private func saveHistory(_ field: String, _ value: String) {
        guard !value.isEmpty else { return }; preferences.set(([value] + (preferences.stringArray(forKey: field) ?? []).filter { $0 != value }).prefix(25).map { $0 }, forKey: field)
    }
    func retry() { guard !activeOperation, !invalidated, !success, let submitted else { return }; execute(submitted) }
    private func execute(_ options: SubmoduleAddOptions) {
        let request = OperationCancellation(); token = request; busy = true; success = false; output = "Adding submodule…"; error = nil; streamState.reset(); currentWork = ""; percentage = nil; completionRange = nil
        let startedAt = ProcessInfo.processInfo.systemUptime
        let factory = makeSSHCoordinator, identities = identities, presenter = presentSSH
        let grants = (access, sourceAccess, keyAccess)
        Task {
            let coordinator = factory?(repository) ?? SSHTransportCoordinator(repository: repository, identities: identities)
            if factory == nil { coordinator.present = presenter }
            defer { coordinator.close(); withExtendedLifetime(grants) {}; if token === request { token = nil; busy = false } }
            do {
                let parser = GitCliOutputParser(limit: streamState.limit)
                let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let operation = Task {
                    defer { continuation.finish() }
                    return try await repository.addSubmodule(options, cancellation: request, prepareTransport: options.sshKey.map { coordinator.explicitPreparation(path: $0.path) }, onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) })
                }
                for await _ in updates { if !invalidated { streamState.consume(parser.processPending(), parser: parser); refreshOutput() } }
                if !invalidated { streamState.consume(parser.processPending(), parser: parser); streamState.consume(parser.finish(), parser: parser); refreshOutput() }
                let text = try await operation.value
                guard !invalidated else { return }; if !streamState.hasOutput { output = text.isEmpty ? "Submodule added." : text }; success = true; finishOutput(success: true, request: request, startedAt: startedAt); onAdded(output)
            } catch {
                guard !invalidated else { return }
                let message: String
                if let failure = error as? GitFailure, streamState.hasOutput { message = "Git command failed (\(failure.code))." }
                else { message = error.localizedDescription }
                output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + message
                if !request.isCancelled { self.error = message }
                finishOutput(success: false, request: request, startedAt: startedAt, exitCode: (error as? GitFailure)?.code)
            }
        }
    }
    private func refreshOutput() {
        output = streamState.output; currentWork = streamState.currentWork; percentage = streamState.percentage
    }
    private func finishOutput(success: Bool, request: OperationCancellation, startedAt: TimeInterval, exitCode: Int32? = nil) {
        let completion = SubmoduleProgressCompletion(success: success, cancelled: request.isCancelled, exitCode: exitCode,
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt, preferences: preferences)
        currentWork = completion.currentWork; percentage = 100; completionRange = completion.append(to: &output)
    }
}

private struct SubmoduleAddDialog: View {
    @ObservedObject var model: SubmoduleAddWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.busy || model.success || !model.output.isEmpty {
                Text(model.success ? "Submodule added" : "Submodule Add").font(.headline)
                if !model.currentWork.isEmpty { Text(model.currentWork).font(.caption).lineLimit(2) }
                if model.busy { ProgressView(value: model.percentage.map(Double.init), total: 100) }
                else { ProgressView(value: 100, total: 100) }
                SubmoduleProgressOutputView(text: model.output, completed: !model.busy, completionRange: model.completionRange, success: model.success).frame(minHeight: 160)
                HStack { Spacer(); if model.busy { ProgressView().controlSize(.small); Button("Cancel") { model.cancelOperation() } } else { if !model.success { Button("Retry") { model.retry() } }; Button("Close") { model.close() }.keyboardShortcut(.defaultAction) } }
            } else {
                GroupBox("Submodule of Project: " + model.repository.root.path) {
                    VStack(spacing: 12) {
                        HStack { Text("Repository:").frame(width: 80, alignment: .leading); CloneHistoryCombo(value: $model.source, choices: model.sources, label: "Submodule repository", onEndEditing: { model.sourceEndedEditing() }); Button("…") { model.pick(.repository) } }
                        HStack { Text("Path:").frame(width: 80, alignment: .leading); CloneHistoryCombo(value: $model.path, choices: model.paths, label: "Submodule path"); Button("…") { model.pick(.path) } }
                    }.padding(8)
                }
                HStack { Toggle("Branch", isOn: $model.useBranch).frame(width: 100, alignment: .leading); if model.useBranch { TextField("Branch", text: $model.branch) }; Spacer(minLength: 0) }
                Toggle("Force", isOn: $model.force)
                HStack { Toggle("Auto-load SSH key", isOn: $model.useKey).disabled(!model.sshAvailable); CloneHistoryCombo(value: $model.key, choices: model.keys, label: "OpenSSH private key").disabled(!model.useKey); Button("…") { model.pick(.key) }.disabled(!model.useKey) }
                HStack { Spacer(); Button("OK") { model.apply() }.keyboardShortcut(.defaultAction); Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction); Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-submodules.html")!) } label: { CommandLabel(title: "Help", icon: .help) } }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }.padding(12).disabled(model.picking || model.confirmingQuit)
    }
}
