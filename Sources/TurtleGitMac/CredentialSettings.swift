// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class CredentialSettingsModel: ObservableObject {
    let settingsRegistration = UUID()
    static var activeSaves = 0
    static private(set) var activeReads = 0
    static private(set) var activeSelections=0
    @Published private(set) var editorIdentity=UUID()
    private var selectionRequest:UUID?
    @Published private(set) var snapshot: GitCredentialSnapshot?
    @Published private(set) var files: GitConfigurationFiles?
    @Published private(set) var helpers: [String] = []
    @Published private(set) var busy = false
    @Published var selected: String?
    @Published var destination: GitConfigurationSource = .global
    @Published var draft = GitCredentialDraft()
    @Published var error: String?
    @Published var mode = "advanced"
    private var savedMode = "advanced"
    private var saved = GitCredentialDraft()
    private var savedDestination: GitConfigurationSource = .global
    var authorizeFile: ((URL) async -> Bool)?
    var confirmAction: ((String, String, String) async -> Bool)?
    var readCredentials: ((OperationCancellation?) async throws -> GitCredentialSnapshot)?
    var writeCredential: ((GitCredentialDraft, URL, GitCredentialSnapshot?) async throws -> Void)?
    var openPasswordManager: (() -> Bool)?
    private var generation = UUID()
    private var token: OperationCancellation?
    @Published private var active = false
    private var saving = false
    private var panel: NSOpenPanel?
    private var alert: NSAlert?
    private var reply: ((Bool) -> Void)?
    let repository: GitRepository
    let localAvailable: Bool
    private let access: RepositoryAccessLease?
    weak var window: NSWindow?
    init(repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool) {
        self.repository = repository; self.access = access; self.localAvailable = localAvailable
        destination = localAvailable ? .local : .global; savedDestination = destination
    }
    var modified: Bool { mode != savedMode || mode == "advanced" && (draft != saved || destination != savedDestination) }
    var group: GitCredentialGroup? { snapshot?.groups.first { $0.id == selected } }
    var target: URL? {
        if let group, group.url == draft.url,
           group.scope == destination.rawValue.lowercased() || (group.scope == "worktree" && destination == .local) { return group.file }
        switch destination { case .local: return files?.local; case .global: return files?.global; case .system: return files?.system; case .effective: return nil }
    }
    var writable: Bool { target != nil && group?.scope != "command" }
    var canManagePasswords:Bool {active && !busy}
    var canEditFields:Bool {active && !busy && snapshot != nil && mode == "advanced"}
    var displayGroups:[GitCredentialGroup] {
        (snapshot?.groups ?? []).sorted {
            let result=groupTitle($0).localizedCaseInsensitiveCompare(groupTitle($1))
            return result == .orderedSame ? $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) : result == .orderedAscending
        }
    }
    func groupTitle(_ group:GitCredentialGroup)->String {
        let prefix:String
        if group.scope == "global",let file=group.file,file == files?.xdg {prefix="X"}
        else {prefix=String(group.scope.prefix(1)).uppercased()}
        return prefix + ":" + (group.url.isEmpty ? "Default" : group.url)
    }
    func editHelper(_ text:String,identity:UUID) {
        guard canEditFields,editorIdentity==identity else {return}
        draft.helpers=[text]
    }
    func activate() { active = true; if snapshot == nil { refresh() } }
    func deactivate() {
        active = false; generation = UUID(); token?.cancel(); token = nil;editorIdentity=UUID()
        if selectionRequest != nil {selectionRequest=nil;Self.activeSelections -= 1}
        if let panel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        if let alert { window?.endSheet(alert.window, returnCode: .abort) }; alert = nil
        let reply = reply; self.reply = nil; reply?(false)
        if !saving { busy = false }
    }
    private func permission(_ file: URL) async -> Bool {
        if let authorizeFile { return await authorizeFile(file) }
        if GitConfigurationPermissions.authorized(file) { return true }
        guard active, let window, window.attachedSheet == nil else { return false }
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = true; chooser.canChooseFiles = false; chooser.canCreateDirectories = true
        chooser.directoryURL = file.deletingLastPathComponent(); chooser.message = "Authorize the folder containing " + file.path
        chooser.prompt = "Authorize"; panel = chooser
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            self.reply = reply
            chooser.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.panel === chooser else { reply(false); return }; self.panel = nil; self.reply = nil
                guard response == .OK, self.active, let directory = chooser.url else { reply(false); return }
                do { try GitConfigurationPermissions.remember(directory, for: file); reply(true) }
                catch { self.error = error.localizedDescription; reply(false) }
            }
        }
    }
    private func confirm(_ title: String, detail: String, action: String) async -> Bool {
        if let confirmAction { return await confirmAction(title, detail, action) }
        guard active, let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: action); self.alert = alert
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            self.reply = reply
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.alert === alert else { reply(false); return }; self.alert = nil; self.reply = nil
                reply(response == .alertSecondButtonReturn && self.active)
            }
        }
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && localAvailable && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func read(_ token: OperationCancellation? = nil) async throws -> GitCredentialSnapshot {
        if let readCredentials { return try await readCredentials(token) }
        return try await repository.credentialConfiguration(cancellation: token)
    }
    var validationError: String? {
        if busy || snapshot == nil { return "Finish loading the credential configuration first." }
        if mode == "advanced" { return modified && (!draft.valid || !writable) ? "Choose a writable configuration file and enter a credential helper." : nil }
        if mode == "none" { return nil }
        let parts = mode.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, helpers.contains(parts[1]),
              parts[0] == "global" || parts[0] == "local" && localAvailable || parts[0] == "system" && files?.system != nil else { return "Choose an available credential helper and configuration scope." }
        return nil
    }
    func refresh() {
        guard active,!busy,snapshot == nil || !modified else {return}
        busy = true; error = nil; let request = UUID(), token = OperationCancellation(); generation = request; self.token = token; Self.activeReads += 1
        Task { [self,access] in
            defer { Self.activeReads -= 1;withExtendedLifetime(access) {};if generation == request {busy=false;self.token=nil} }
            do {
                try checkAccess()
                let files = try await repository.gitConfigurationFiles(hasRepository: localAvailable, cancellation: token)
                guard active, generation == request else { return }
                for file in [files.global, files.xdg, files.system].compactMap({ $0 }) {
                    guard await permission(file), active, generation == request else { return }
                }
                let snapshot = try await read(token)
                guard active, generation == request, !token.isCancelled else { return }
                let configuration = try await repository.firstStartConfiguration(cancellation: token)
                guard active, generation == request, !token.isCancelled else { return }
                // No suspension while the accepted origins/list/mode/draft change.
                self.files=files;self.snapshot=snapshot;helpers=configuration.helpers.filter {!$0.isEmpty}
                mode=simpleMode(snapshot);savedMode=mode
                if let selected {
                    if let group=snapshot.groups.first(where:{$0.id==selected}) {load(group)}
                    else {clearDraft(resetDestination:true)}
                }
            } catch { if active, generation == request, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func simpleMode(_ snapshot: GitCredentialSnapshot) -> String {
        if snapshot.entries.isEmpty { return "none" }
        if snapshot.entries.count == 1, let entry = snapshot.entries.first,
           entry.key == "credential.helper", helpers.contains(entry.value),
           ["local", "global", "system"].contains(entry.scope),
           entry.file == (entry.scope == "local" ? files?.local : entry.scope == "global" ? files?.global : files?.system) {
            return entry.scope + ":" + entry.value
        }
        return "advanced"
    }
    private func load(_ group: GitCredentialGroup) {
        selected = group.id
        destination = group.scope == "local" || group.scope == "worktree" ? .local : group.scope == "system" ? .system : .global
        var draft = GitCredentialDraft(); draft.url = group.url; draft.helpers = group.helpers; draft.username = group.username; draft.useHTTPPath = group.useHTTPPath
        self.draft = draft; saved = draft; savedDestination = destination;editorIdentity=UUID()
    }
    private func clearDraft(resetDestination:Bool = false) {
        if resetDestination {destination=localAvailable ? .local:.global}
        selected=nil;draft=GitCredentialDraft();saved=draft;savedDestination=destination;editorIdentity=UUID()
    }
    func select(_ id: String?) {
        guard canEditFields,id == nil || id != selected,id == nil || snapshot?.groups.contains(where:{$0.id==id}) == true else {return}
        let request=generation,choice=UUID();selectionRequest=choice;Self.activeSelections += 1
        busy=true
        Task { [self,access] in
            defer {
                withExtendedLifetime(access) {}
                if selectionRequest==choice {selectionRequest=nil;Self.activeSelections -= 1;if generation==request {busy=false}}
            }
            if draft != saved || destination != savedDestination, !(await confirm("Discard unsaved helper changes?", detail: "Select Add New/Save or Apply to save the current fields before selecting another helper.", action: "Discard")) { return }
            guard active, generation == request else { return }
            if let group = snapshot?.groups.first(where: { $0.id == id }) { load(group) }
            else {clearDraft()}
        }
    }
    func cancelDraft() { guard !busy else { return }; draft = saved; destination = savedDestination; mode = savedMode }
    func save() { Task { _ = await apply() } }
    func applyForSettings(owner: NSWindow?) async -> Bool {
        let wasActive = active, request = generation; active = true; if window == nil { window = owner }
        defer { if generation == request { active = wasActive } }; return await apply()
    }
    func apply() async -> Bool {
        if mode != "advanced" { return await applySimple() }
        if draft == saved && destination == savedDestination { savedMode = mode; return true }
        guard active, !busy, draft.valid, writable, let file = target else { error = "Choose a configuration file and enter a credential helper."; return false }
        let value = draft, destination = destination, request = generation
        busy = true; saving = true; Self.activeSaves += 1
        defer { busy = false; saving = false; Self.activeSaves -= 1 }
        do {
            try checkAccess()
            if let existing = snapshot?.groups.first(where: { $0.file == file && $0.url == value.url }), existing.helpers != value.helpers {
                guard await confirm("Replace the credential helper?", detail: "The helper configuration for \(value.url.isEmpty ? "all URLs" : value.url) in \(file.path) will be replaced. Other credential URLs remain unchanged.", action: "Save") else { return false }
            }
            guard active, generation == request else { return false }
            guard await permission(file), active, generation == request else { return false }
            if let writeCredential { try await writeCredential(value, file, snapshot) } else { try await repository.saveCredential(value, file: file, expected: snapshot) }
            guard active, generation == request else { return true }
            let snapshot = try await read()
            guard active, generation == request else { return true }
            self.snapshot = snapshot; saved = value; savedDestination = destination; savedMode = mode
            if let group = snapshot.groups.first(where: { $0.file == file && $0.url == value.url }) { load(group) }
            return true
        } catch { if active, generation == request { self.error = error.localizedDescription }; return false }
    }
    private func applySimple() async -> Bool {
        guard active, !busy, let snapshot else { return false }
        if let validationError { error = validationError; return false }
        let mode = mode, request = generation
        let parts = mode.split(separator: ":", maxSplits: 1).map(String.init)
        let helper = mode == "none" ? nil : parts.last
        let file = parts.first == "local" ? files?.local : parts.first == "system" ? files?.system : files?.global
        busy = true; saving = true; Self.activeSaves += 1
        defer { busy = false; saving = false; Self.activeSaves -= 1 }
        do {
            try checkAccess()
            if !snapshot.entries.isEmpty {
                guard await confirm("Replace credential configuration?", detail: "Simple configuration replaces all listed credential settings, including URL-specific helpers and usernames, with the selected default. Keychain passwords remain unchanged.", action: "Replace") else { return false }
            }
            guard active, generation == request else { return false }
            var files = snapshot.groups.compactMap(\.file); if let file, helper != nil { files.append(file) }
            for file in Set(files) { guard await permission(file), active, generation == request else { return false } }
            try await repository.simplifyCredentials(expected: snapshot, helper: helper, file: file)
            guard active, generation == request else { return true }
            let result = try await read()
            guard active, generation == request else { return true }
            self.snapshot=result;savedMode=mode;clearDraft();return true
        } catch { if active, generation == request { self.error = error.localizedDescription }; return false }
    }
    func remove() {
        guard active, !busy, let group, let file = group.file else { return }
        let request = generation
        busy = true; saving = true; Self.activeSaves += 1
        Task {
            defer { busy = false; saving = false; Self.activeSaves -= 1 }
            do {
                guard await confirm("Remove this credential configuration?", detail: "Remove \(group.url.isEmpty ? "default credentials" : group.url) from \(file.path). Stored passwords in Keychain remain available.", action: "Remove"), active, generation == request else { return }
                guard await permission(file), active, generation == request else { return }
                try checkAccess(); try await repository.removeCredential(group, expected: snapshot)
                guard active, generation == request else { return }
                let snapshot = try await read()
                guard active,generation==request else {return};self.snapshot=snapshot;clearDraft()
            } catch { if active, generation == request { self.error = error.localizedDescription } }
        }
    }
    func openKeychain() {
        guard active, !busy else { return }
        if let openPasswordManager { if !openPasswordManager() { error = "Keychain Access is unavailable on this Mac." }; return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") else { error = "Keychain Access is unavailable on this Mac."; return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

struct CredentialSettingsPage: View {
    @ObservedObject var model: CredentialSettingsModel
    @Environment(\.settingsTransaction) private var transaction
    var body: some View {
        let identity=model.editorIdentity
        VStack(alignment: .leading, spacing: 14) {
            Picker("Credential helper:", selection: $model.mode) {
                Text("Advanced configuration").tag("advanced")
                Text("None").tag("none")
                ForEach(model.helpers, id: \.self) { helper in
                    if model.localAvailable { Text("Local: " + helper).tag("local:" + helper) }
                    Text("Global: " + helper).tag("global:" + helper)
                    if model.files?.system != nil { Text("System: " + helper).tag("system:" + helper) }
                }
            }.disabled(model.busy || model.snapshot == nil)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading) {
                    Text("Helpers:")
                    List(selection: Binding(get: { model.selected }, set: model.select)) {
                        ForEach(model.displayGroups) { group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.groupTitle(group)).lineLimit(2)
                                Text(group.file?.lastPathComponent ?? group.origin).font(.caption).foregroundStyle(.secondary)
                            }.help(group.file?.path ?? group.origin).tag(group.id)
                        }
                    }.frame(minWidth: 200, idealWidth: 230, maxWidth: 280, minHeight: 300)
                    Button("New helper") { model.select(nil) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Config type:", selection: $model.destination) {
                        if model.localAvailable { Text("Local").tag(GitConfigurationSource.local) }
                        Text("Global").tag(GitConfigurationSource.global)
                        if model.files?.system != nil { Text("System").tag(GitConfigurationSource.system) }
                    }
                    HStack {Text("URL:").frame(width:80,alignment:.leading);TextField("",text:$model.draft.url).accessibilityLabel("Credential URL")}
                    HStack {
                        Text("Helper:").frame(width:80,alignment:.leading)
                        CloneHistoryCombo(value:Binding(get:{model.draft.helpers.first ?? ""},set:{model.editHelper($0,identity:identity)}),choices:model.helpers,label:"Credential helper").id(identity).frame(height:26)
                    }
                    if model.draft.helpers.count > 1 {
                        Text("Helper chain (in order): " + model.draft.helpers.map { $0.isEmpty ? "Reset inherited helpers" : $0 }.joined(separator: " → ")).font(.caption)
                    }
                    HStack {Text("Username:").frame(width:80,alignment:.leading);TextField("",text:$model.draft.username).accessibilityLabel("Credential username")}
                    Toggle("Use HTTP path component", isOn: $model.draft.useHTTPPath)
                    Button("Add New/Save", action: model.save).disabled(!model.draft.valid || !model.writable)
                    Button("Remove", action: model.remove).disabled(model.group?.file == nil || model.group?.scope == "command")
                    if let file = model.target { Text(file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text("System settings require write access to their configuration folder. Credential passwords are managed by the selected helper.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength:0)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(!model.canEditFields)
            HStack {
                Spacer()
                Button("Keychain Access",action:model.openKeychain)
                Button("Saved SSH Authentication…") {SavedSSHAuthenticationService.shared.show()}
            }.disabled(!model.canManagePasswords)
            HStack { Button("Refresh", action: model.refresh).disabled(model.busy || model.modified); if model.busy { ProgressView().controlSize(.small) } }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("Add New/Save and Remove save immediately, like the source dialog. Cancel restores only unsaved field edits.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(12)
        .background(CredentialWindowCapture(model: model).frame(width: 0, height: 0))
        .onAppear {
            model.activate()
            transaction?.register("credential", participant: .init(page: .credential, modified: { model.modified }, validate: { model.validationError }, apply: { await model.applyForSettings(owner: transaction?.window) }, cancel: model.cancelDraft), registration: model.settingsRegistration)
        }
        .onChange(of: model.draft) { _ in transaction?.notify() }
        .onChange(of: model.busy) { _ in transaction?.notify() }
        .onChange(of: model.mode) { _ in transaction?.notify() }
        .onChange(of: model.destination) { _ in transaction?.notify() }
        .onDisappear { model.deactivate() }
    }
}
private struct CredentialWindowCapture: NSViewRepresentable {
    let model: CredentialSettingsModel
    func makeNSView(context: Context) -> NSView { Capture(model: model) }
    func updateNSView(_ view: NSView, context: Context) {}
    final class Capture: NSView {
        weak var model: CredentialSettingsModel?
        init(model: CredentialSettingsModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.window = window }
    }
}

@MainActor final class CredentialSettingsController: NSWindowController, NSWindowDelegate {
    let model: CredentialSettingsModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool) {
        model = CredentialSettingsModel(repository: repository, access: access, localAvailable: localAvailable)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 790, height: 580), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Credential – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        window.contentMinSize = .init(width: 760, height: 530)
        let model = model
        window.contentViewController = NSHostingController(rootView: CredentialStandaloneDialog(model: model, close: { [weak window] in window?.performClose(nil) }))
        super.init(window: window); window.delegate = self; model.window = window; window.center()
        DialogGeometry.attach(window, identifier: "SettingsCredential")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        model.deactivate()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        onClosed()
    }
}
private struct CredentialStandaloneDialog: View {
    @ObservedObject var model: CredentialSettingsModel
    let close: () -> Void
    var body: some View {
        VStack {
            CredentialSettingsPage(model: model)
            Divider()
            HStack {
                Spacer()
                Button("OK") { Task { if model.modified { guard await model.apply() else { return } }; close() } }.keyboardShortcut(.defaultAction)
                Button("Cancel") { model.cancelDraft(); close() }.keyboardShortcut(.cancelAction)
                Button("Apply") { model.save() }.disabled(!model.modified)
            }.disabled(model.busy).padding(12)
        }
    }
}
