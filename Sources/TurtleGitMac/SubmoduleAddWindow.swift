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
        model.close = { [weak self] in self?.window?.makeFirstResponder(nil); self?.window?.close() }
        model.pick = { [weak self] kind in self?.pick(kind) }
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
    private var invalidated = false, submitted = false
    @Published var source: String
    @Published var path: String
    @Published var useBranch = false
    @Published var branch = ""
    @Published var force = false
    @Published var useKey = false
    @Published var key = ""
    @Published var picking = false
    @Published var confirmingQuit = false
    @Published var error: String?
    let sources: [String], paths: [String], keys: [String]
    var identities = SSHIdentityAccessStore()
    var makeSSHCoordinator: SSHCloneTransportFactory?
    var pick: (Picker) -> Void = { _ in }
    var close: () -> Void = {}
    var onSubmit: ((SubmoduleAddProgressWindowModel) -> Void)?
    var sshAvailable: Bool { makeSSHCoordinator != nil || (try? SSHAgentRuntime.resolve())?.askpass != nil }
    var activeOperation: Bool { picking || confirmingQuit }
    var canApply: Bool { !activeOperation && !invalidated && !submitted && onSubmit != nil }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.preferences = preferences; basePath = path == "." ? "" : path
        sources = preferences.stringArray(forKey: "SubmoduleAdd.URLHistory") ?? []
        paths = preferences.stringArray(forKey: "SubmoduleAdd.PathHistory") ?? []
        keys = preferences.stringArray(forKey: "Clone.KeyHistory") ?? []
        source = sources.first ?? ""; self.path = basePath; key = keys.first ?? ""; useKey = sshAvailable
    }
    func sourceEndedEditing() {
        guard !activeOperation, !invalidated, !submitted else { return }
        var name = source.trimmingCharacters(in: CharacterSet(charactersIn: "/\\").union(.whitespacesAndNewlines)).components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? ""
        if name.hasSuffix(".git") { name.removeLast(4) }
        if !name.isEmpty { path = basePath.isEmpty ? name : basePath + "/" + name }
    }
    func acceptSelection(_ url: URL, kind: Picker) {
        guard !activeOperation, !invalidated, !submitted else { return }
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
    func invalidate() { invalidated = true; keyAccess = nil; sourceAccess = nil }
    func apply() {
        guard canApply, let onSubmit else { return }
        do {
            var options = SubmoduleAddOptions(); options.source = source; options.path = path; options.force = force
            if useBranch { options.branch = branch.trimmingCharacters(in: .whitespacesAndNewlines) }
            if useKey && !key.isEmpty { guard sshAvailable else { throw CloneFailure.keyRuntime }; options.sshKey = URL(fileURLWithPath: key); guard key.hasPrefix("/") else { throw SubmoduleAddFailure.key } }
            _ = try options.arguments(root: repository.root)
            if GitRuntime.isAppStoreBuild {
                guard access?.hasSecurityScope == true, access?.contains(repository.root) == true else { throw RepositoryAccessFailure.securityScopeUnavailable }
                let source = options.source.trimmingCharacters(in: .whitespacesAndNewlines)
                let local = source.hasPrefix("/") ? URL(fileURLWithPath: source) : URL(string: source).flatMap { $0.isFileURL ? $0 : nil }
                if let local { guard sourceAccess?.hasSecurityScope == true, sourceAccess?.contains(local) == true else { throw RepositoryAccessFailure.securityScopeUnavailable } }
            }
            if let key = options.sshKey { keyAccess = try identities.acquire(path: key.path, requireSecurityScope: GitRuntime.isAppStoreBuild).permission }
            for (field, value) in [("SubmoduleAdd.URLHistory", options.source.trimmingCharacters(in: .whitespacesAndNewlines)), ("SubmoduleAdd.PathHistory", options.path.trimmingCharacters(in: .whitespacesAndNewlines))] { saveHistory(field, value) }
            saveHistory("Clone.KeyHistory", key)
            submitted = true
            let progress = SubmoduleAddProgressWindowModel(repository: repository, access: access, sourceAccess: sourceAccess, keyAccess: keyAccess,
                options: options, preferences: preferences, identities: identities, makeSSHCoordinator: makeSSHCoordinator)
            sourceAccess = nil; keyAccess = nil
            onSubmit(progress); close()
        } catch { self.error = error.localizedDescription }
    }
    private func saveHistory(_ field: String, _ value: String) {
        guard !value.isEmpty else { return }; preferences.set(([value] + (preferences.stringArray(forKey: field) ?? []).filter { $0 != value }).prefix(25).map { $0 }, forKey: field)
    }
}

private struct SubmoduleAddDialog: View {
    @ObservedObject var model: SubmoduleAddWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Submodule of Project: " + model.repository.root.path) {
                VStack(spacing: 12) {
                    HStack { Text("Repository:").frame(width: 80, alignment: .leading); CloneHistoryCombo(value: $model.source, choices: model.sources, label: "Submodule repository", onEndEditing: { model.sourceEndedEditing() }); Button("…") { model.pick(.repository) } }
                    HStack { Text("Path:").frame(width: 80, alignment: .leading); CloneHistoryCombo(value: $model.path, choices: model.paths, label: "Submodule path"); Button("…") { model.pick(.path) } }
                }.padding(8)
            }
            HStack { Toggle("Branch", isOn: $model.useBranch).frame(width: 100, alignment: .leading); if model.useBranch { TextField("Branch", text: $model.branch) }; Spacer(minLength: 0) }
            Toggle("Force", isOn: $model.force)
            HStack { Toggle("Auto-load SSH key", isOn: $model.useKey).disabled(!model.sshAvailable); CloneHistoryCombo(value: $model.key, choices: model.keys, label: "OpenSSH private key").disabled(!model.useKey); Button("…") { model.pick(.key) }.disabled(!model.useKey) }
            HStack { Spacer(); Button("OK") { model.apply() }.keyboardShortcut(.defaultAction).disabled(!model.canApply); Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction); Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-submodules.html")!) } label: { CommandLabel(title: "Help", icon: .help) } }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(12).disabled(model.picking || model.confirmingQuit)
    }
}
