// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class CredentialSettingsModel: ObservableObject, SettingsLifecyclePresenting {
    enum PendingChangesDecision { case save, discard, cancel }
    let settingsRegistration = UUID()
    static var activeSaves = 0
    static private(set) var activeReads = 0
    static private(set) var activeSelections=0
    static private(set) var activeSheetReleases=0
    @Published private(set) var editorIdentity=UUID()
    private var selectionRequest:UUID?
    @Published private(set) var snapshot: GitCredentialSnapshot?
    @Published private(set) var files: GitConfigurationFiles?
    @Published private(set) var helpers: [String] = []
    @Published private(set) var busy = false
    @Published var selected: String?
    @Published var destination: GitConfigurationSource = .global { didSet { if oldValue != destination { advanceEditor() } } }
    @Published var draft = GitCredentialDraft()
    @Published var error: String?
    @Published var mode = "advanced" { didSet { if !GitReferenceName.equal(oldValue,mode) { advanceEditor() } } }
    private var savedMode = "advanced"
    private var saved = GitCredentialDraft()
    @Published private var editedFields: GitCredentialFields = []
    private var savedDestination: GitConfigurationSource = .global
    var authorizeFile: ((URL) async -> Bool)?
    var confirmAction: ((String, String, String) async -> Bool)?
    var choosePendingChanges: (() async -> PendingChangesDecision)?
    var writeCredentialFields: ((GitCredentialDraft, URL, GitCredentialSnapshot?, GitCredentialFields) async throws -> Void)?
    var readCredentials: ((OperationCancellation?) async throws -> GitCredentialSnapshot)?
    var writeCredential: ((GitCredentialDraft, URL, GitCredentialSnapshot?) async throws -> Void)?
    var openPasswordManager: (() -> Bool)?
    private var generation = UUID()
    private var token: OperationCancellation?
    private var active = false
    private var lifecycle=UUID()
    private var editorReceipt=UUID()
    private let attachments=SettingsLifecycleAttachments()
    private var saving = false
    private var acceptedWrite:UUID?
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
    var modified: Bool { !GitReferenceName.equal(mode,savedMode) || mode == "advanced" && (draft != saved || destination != savedDestination || !editedFields.isEmpty) }
    var helperIdentities:[GitReferenceName]{helpers.map{GitReferenceName($0)}}
    var modeIdentity:String{GitPathRowIdentity.encode(mode)}
    func editModeIdentity(_ id:String,identity:UUID){guard let value=GitPathRowIdentity.decode(id) else{return};editMode(value,identity:identity)}
    var group: GitCredentialGroup? { snapshot?.groups.first { $0.id == selected } }
    var target: URL? {
        if let group, GitReferenceName.equal(group.url,draft.url),
           group.scope == destination.rawValue.lowercased() || (group.scope == "worktree" && destination == .local) { return group.file }
        switch destination { case .local: return files?.local; case .global: return files?.global; case .system: return files?.system; case .effective: return nil }
    }
    var writable: Bool { target != nil && !(group?.scope == "command" && editsExistingOrigin) }
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
    var editsExistingOrigin: Bool {
        guard let group else { return false }
        return GitReferenceName.equal(group.url,draft.url) && group.file == target && destination == savedDestination
    }
    var canAdd: Bool { draft.fieldsValid && draft.helpers.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && writable }
    var advancedValid: Bool { draft.fieldsValid && writable && (editsExistingOrigin || canAdd) }
    func editHelper(_ text:String,identity:UUID) {
        guard canEditFields,editorIdentity==identity,editorReceipt==identity else {return}
        let helpers = text.isEmpty ? [] : [text]
        if !helpers.elementsEqual(draft.helpers,by:{GitReferenceName.equal($0,$1)}) { editedFields.insert(.helper) }; draft.helpers=helpers
    }
    func editURL(_ text:String,identity:UUID) { guard canEditFields,editorIdentity==identity,editorReceipt==identity else {return};draft.url=text }
    func editUsername(_ text:String,identity:UUID) { guard canEditFields,editorIdentity==identity,editorReceipt==identity else {return};if !GitReferenceName.equal(draft.username,text) {editedFields.insert(.username)};draft.username=text }
    func editHTTPPath(_ value:Bool,identity:UUID) { guard canEditFields,editorIdentity==identity,editorReceipt==identity else {return};if draft.useHTTPPath != value {editedFields.insert(.useHTTPPath)};draft.useHTTPPath=value }
    func editDestination(_ value:GitConfigurationSource,identity:UUID) { guard canEditFields,editorIdentity==identity,editorReceipt==identity else {return};destination=value }
    func editMode(_ value:String,identity:UUID) { guard active,!busy,snapshot != nil,editorIdentity==identity,editorReceipt==identity else {return};mode=value }
    private func advanceEditor() {editorReceipt=UUID();editorIdentity=editorReceipt}
    var isActive:Bool {active}
    func attachPresentation(_ owner:UUID) {window=attachments.claim(owner)}
    func detachPresentation(_ owner:UUID) {if attachments.releaseOwner(owner) {window=nil;deactivate()}}
    func attachProbe(owner:UUID,identity:UUID,window:NSWindow) {if attachments.attach(owner:owner,identity:identity,window:window) {self.window=window}}
    func detachProbe(_ identity:UUID) {if attachments.releaseProbe(identity) {window=nil;deactivate()}}
    func activate() {
        lifecycle=UUID()
        if !saving || acceptedWrite != generation {generation=UUID();token?.cancel();token=nil;selectionRequest=nil}
        active=true;advanceEditor();if !saving {busy=false};if snapshot==nil {refresh()}
    }
    func deactivate() {
        active=false;lifecycle=UUID();generation=UUID();editorReceipt=UUID();token?.cancel();token=nil
        let retirement=lifecycle,editor=editorReceipt
        selectionRequest=nil
        let panel=self.panel;self.panel=nil
        let alert=self.alert;self.alert=nil
        let reply=self.reply;self.reply=nil
        let sheets=[panel,alert?.window].compactMap {$0}
        let releasing = !sheets.isEmpty || reply != nil
        if releasing {Self.activeSheetReleases += 1}
        DispatchQueue.main.async { [self] in
            SettingsLifecycleSheetDrain.close(sheets) { [self] in
                reply?(false)
                if releasing {Self.activeSheetReleases -= 1}
                guard !active,lifecycle==retirement else {return}
                editorIdentity=editor;if !saving {busy=false}
            }
        }
    }
    private func permission(_ file: URL) async -> Bool {
        guard active else {return false}
        if let authorizeFile { return await authorizeFile(file) }
        if GitConfigurationPermissions.authorized(file) { return true }
        guard active, let window, window.attachedSheet == nil else { return false }
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = true; chooser.canChooseFiles = false; chooser.canCreateDirectories = true
        chooser.directoryURL = file.deletingLastPathComponent(); chooser.message = "Authorize the folder containing " + file.path
        chooser.prompt = "Authorize"; chooser.alphaValue = window.alphaValue; chooser.appearance = window.appearance; panel = chooser
        let request=generation,activation=lifecycle
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            self.reply = reply
            chooser.beginSheetModal(for: window) { [weak self] response in
                guard let self,self.panel===chooser else {return};self.panel=nil;self.reply=nil
                SettingsLifecycleSheetDrain.close([chooser]) { [weak self] in
                    guard let self,self.active,self.generation==request,self.lifecycle==activation,response == .OK,let directory=chooser.url else {reply(false);return}
                    do {try GitConfigurationPermissions.remember(directory,for:file);reply(true)}
                    catch {self.error=error.localizedDescription;reply(false)}
                }
            }
        }
    }
    private func confirm(_ title: String, detail: String, action: String) async -> Bool {
        guard active else {return false}
        if let confirmAction { return await confirmAction(title, detail, action) }
        guard active, let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: action); alert.window.alphaValue = window.alphaValue; alert.window.appearance = window.appearance; self.alert = alert
        let request=generation,activation=lifecycle
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            self.reply = reply
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self,self.alert===alert else {return};self.alert=nil;self.reply=nil
                SettingsLifecycleSheetDrain.close([alert.window]) { [weak self] in
                    reply(response == .alertSecondButtonReturn && self?.active == true && self?.generation==request && self?.lifecycle==activation)
                }
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
        if mode == "advanced" { return modified && !advancedValid ? "Choose a writable configuration file. A new credential URL or destination requires a helper." : nil }
        if mode == "none" { return nil }
        let parts = mode.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, helpers.contains(where:{GitReferenceName.equal($0,parts[1])}),
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
           entry.key == "credential.helper", helpers.contains(where:{GitReferenceName.equal($0,entry.value)}),
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
        self.draft = draft; saved = draft; savedDestination = destination;editedFields=[];advanceEditor()
    }
    private func clearDraft(resetDestination:Bool = false) {
        if resetDestination {destination=localAvailable ? .local:.global}
        selected=nil;draft=GitCredentialDraft();saved=draft;savedDestination=destination;editedFields=[];advanceEditor()
    }
    private func pendingChangesDecision() async -> PendingChangesDecision {
        guard active else {return .cancel}
        if let choosePendingChanges { return await choosePendingChanges() }
        // Keep the older binary confirmation seam for existing receivers. Real
        // presentation and new callers use the source Save/Discard decision.
        if confirmAction != nil {
            return await confirm("Discard unsaved helper changes?", detail: "Discard changes before selecting another helper.", action: "Discard") ? .discard : .cancel
        }
        guard active, let window, window.attachedSheet == nil else { return .cancel }
        let question = NSAlert(); question.messageText = "Save changes to credential configuration?"
        question.informativeText = "Save the edited fields before selecting another helper, or discard the unsaved changes."
        question.addButton(withTitle: "Save"); question.addButton(withTitle: "Discard"); question.addButton(withTitle: "Cancel")
        // Cancel must not trigger either source action through the Escape key.
        question.buttons[2].keyEquivalent = "\u{1b}"
        question.window.alphaValue = window.alphaValue; question.window.appearance = window.appearance
        self.alert = question
        let request=generation,activation=lifecycle
        var decision: PendingChangesDecision = .cancel
        let accepted = await withCheckedContinuation { continuation in
            var answered = false
            let reply: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            self.reply = reply
            question.beginSheetModal(for: window) { [weak self] response in
                guard let self,self.alert===question else {return}
                self.alert = nil; self.reply = nil
                if response == .alertFirstButtonReturn { decision = .save }
                else if response == .alertSecondButtonReturn { decision = .discard }
                SettingsLifecycleSheetDrain.close([question.window]) { [weak self] in
                    reply(self?.active == true && self?.generation==request && self?.lifecycle==activation)
                }
            }
        }
        return accepted ? decision : .cancel
    }
    func select(_ id: String?, identity: UUID? = nil) {
        guard identity == nil || identity == editorIdentity && identity == editorReceipt else { return }
        guard canEditFields,id == nil || id != selected,id == nil || snapshot?.groups.contains(where:{$0.id==id}) == true else {return}
        let request=generation,choice=UUID();selectionRequest=choice;Self.activeSelections += 1
        busy=true
        Task { [self,access] in
            defer {
                withExtendedLifetime(access) {}
                Self.activeSelections -= 1
                if selectionRequest==choice {selectionRequest=nil;if generation==request {busy=false}}
            }
            guard active,generation==request,selectionRequest==choice else {return}
            if draft != saved || destination != savedDestination || !editedFields.isEmpty {
                let reviewedDraft=draft,reviewedDestination=destination,reviewedMode=mode
                let decision = await pendingChangesDecision()
                guard active, generation == request, selectionRequest == choice,draft==reviewedDraft,destination==reviewedDestination,GitReferenceName.equal(mode,reviewedMode) else { return }
                switch decision {
                case .cancel: return
                case .discard: break
                case .save:
                    guard await persistAdvanced(explicit: false, selectionOwned: true),!modified else { return }
                }
            }
            guard active, generation == request, selectionRequest == choice else { return }
            if let id {
                // Saving may have refreshed the catalog; never replace a missing
                // captured target with a new/empty draft.
                guard let group = snapshot?.groups.first(where: { $0.id == id }) else { return }
                load(group)
            } else {clearDraft()}
        }
    }
    func cancelDraft() { guard !busy else { return }; draft = saved; destination = savedDestination; mode = savedMode;editedFields=[];advanceEditor() }
    func save(identity: UUID? = nil) {
        guard identity == nil || identity == editorIdentity && identity == editorReceipt else { return }
        let captured = editorIdentity
        Task { guard active,captured == editorIdentity,captured == editorReceipt else { return }; _ = await saveAdvanced() }
    }
    func saveAdvanced() async -> Bool {
        guard mode == "advanced" else { return await apply() }
        return await persistAdvanced(explicit: true)
    }
    func applyForSettings(owner: NSWindow?) async -> Bool {
        let wasActive=active,request=generation,activation=lifecycle;active=true
        if !wasActive {advanceEditor()}
        if window == nil {window=owner}
        defer {if generation==request,lifecycle==activation {active=wasActive}};return await apply()
    }
    func apply() async -> Bool {
        if mode != "advanced" { return await applySimple() }
        if draft == saved && destination == savedDestination && editedFields.isEmpty { savedMode = mode; return true }
        return await persistAdvanced(explicit: false)
    }
    private func persistAdvanced(explicit: Bool, selectionOwned: Bool = false) async -> Bool {
        guard active, (!busy || selectionOwned && selectionRequest != nil), explicit ? canAdd : advancedValid, let file = target else {
            error = "Choose a writable configuration file. A new credential URL or destination requires a helper."; return false
        }
        let value = draft, destination = destination, request = generation, expected = snapshot, identity = editorIdentity,submittedMode=mode,submittedSelection=selected
        var fields: GitCredentialFields = explicit ? .all : value.changedFields(from: saved).union(editedFields)
        // SaveSettings' URL/config-type bit writes the helper, but does not
        // turn untouched optional fields into an explicit full replacement.
        if !explicit && !editsExistingOrigin { fields.insert(.helper) }
        let existing = expected?.groups.first { $0.file == file && GitReferenceName.equal($0.url,value.url) }
        // OnBnClickedButtonAdd omits blank optional fields for a new URL.
        if explicit && existing == nil {
            if value.username.isEmpty { fields.remove(.username) }
            if !value.useHTTPPath { fields.remove(.useHTTPPath) }
        }
        busy = true; saving = true; Self.activeSaves += 1
        defer { if !selectionOwned || generation != request {busy=false}; saving = false;acceptedWrite=nil; Self.activeSaves -= 1 }
        func current() -> Bool {active && generation==request && (acceptedWrite==request || editorIdentity==identity && editorReceipt==identity && draft==value && self.destination==destination && GitReferenceName.equal(mode,submittedMode) && selected==submittedSelection)}
        do {
            try checkAccess()
            if explicit, existing != nil {
                guard await confirm("Replace the credential helper?", detail: "The helper configuration for \(value.url.isEmpty ? "all URLs" : value.url) in \(file.path) will be replaced. Other credential URLs remain unchanged.", action: "Save") else { return false }
            }
            guard current() else { return false }
            guard await permission(file), current() else { return false }
            acceptedWrite=request
            if let writeCredentialFields { try await writeCredentialFields(value, file, expected, fields) }
            else if let writeCredential { try await writeCredential(value, file, expected) }
            else { try await repository.saveCredential(value, file: file, expected: expected, fields: fields) }
            guard current() else { return true }
            let snapshot = try await read()
            guard current() else { return true }
            let unchanged=draft==value && self.destination==destination && GitReferenceName.equal(mode,submittedMode) && selected==submittedSelection
            self.snapshot = snapshot; saved = value; savedDestination = destination; savedMode = submittedMode
            let writtenGroup=snapshot.groups.first(where: { $0.file == file && GitReferenceName.equal($0.url,value.url) })
            if unchanged {
                if let writtenGroup {load(writtenGroup)}else{clearDraft()}
            }else{
                // The accepted bytes are the saved baseline; a later draft is
                // still unsaved and must survive asynchronous catalog readback.
                if selected==submittedSelection {selected=writtenGroup?.id}
                editedFields=draft.changedFields(from:value);advanceEditor()
            }
            return true
        } catch { if current() { self.error = error.localizedDescription }; return false }
    }
    private func applySimple() async -> Bool {
        guard active, !busy, let snapshot else { return false }
        if let validationError { error = validationError; return false }
        let mode = mode, request = generation,submittedDraft=draft,submittedDestination=destination,submittedSelection=selected
        let parts = mode.split(separator: ":", maxSplits: 1).map(String.init)
        let helper = mode == "none" ? nil : parts.last
        let file = parts.first == "local" ? files?.local : parts.first == "system" ? files?.system : files?.global
        busy = true; saving = true; Self.activeSaves += 1
        defer {busy=false;saving=false;acceptedWrite=nil;Self.activeSaves -= 1}
        do {
            try checkAccess()
            if !snapshot.entries.isEmpty {
                guard await confirm("Replace credential configuration?", detail: "Simple configuration replaces all listed credential settings, including URL-specific helpers and usernames, with the selected default. Keychain passwords remain unchanged.", action: "Replace") else { return false }
            }
            guard active, generation == request else { return false }
            var files = snapshot.groups.compactMap(\.file); if let file, helper != nil { files.append(file) }
            for file in Set(files) { guard await permission(file), active, generation == request else { return false } }
            guard GitReferenceName.equal(self.mode,mode),draft==submittedDraft,destination==submittedDestination,selected==submittedSelection else{return false}
            acceptedWrite=request
            try await repository.simplifyCredentials(expected: snapshot, helper: helper, file: file)
            guard active, generation == request else { return true }
            let result = try await read()
            guard active, generation == request else { return true }
            self.snapshot=result;savedMode=mode
            if GitReferenceName.equal(self.mode,mode),draft==submittedDraft,destination==submittedDestination,selected==submittedSelection{clearDraft()}
            return true
        } catch { if active, generation == request { self.error = error.localizedDescription }; return false }
    }
    func remove(identity: UUID? = nil) {
        guard identity == nil || identity == editorIdentity && identity == editorReceipt else { return }
        guard active, !busy, let group, let file = group.file else { return }
        let request = generation,submittedDraft=draft,submittedDestination=destination,submittedMode=mode,expected=snapshot
        busy = true; saving = true; Self.activeSaves += 1
        Task {
            defer {busy=false;saving=false;acceptedWrite=nil;Self.activeSaves -= 1}
            do {
                guard await confirm("Remove this credential configuration?", detail: "Remove \(group.url.isEmpty ? "default credentials" : group.url) from \(file.path). Stored passwords in Keychain remain available.", action: "Remove"), active, generation == request else { return }
                guard await permission(file), active, generation == request else { return }
                guard selected==group.id,draft==submittedDraft,destination==submittedDestination,GitReferenceName.equal(mode,submittedMode) else{return}
                try checkAccess();acceptedWrite=request;try await repository.removeCredential(group, expected: expected)
                guard active, generation == request else { return }
                let snapshot = try await read()
                guard active,generation==request else {return};self.snapshot=snapshot
                if selected==group.id,draft==submittedDraft,destination==submittedDestination,GitReferenceName.equal(mode,submittedMode){clearDraft()}
                else if selected==group.id{selected=nil;saved=GitCredentialDraft();editedFields=draft.changedFields(from:saved);advanceEditor()}
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
    @State private var presentation=UUID()
    var body: some View {
        let identity=model.editorIdentity
        VStack(alignment: .leading, spacing: 14) {
            Picker("Credential helper:", selection: Binding(get:{model.modeIdentity},set:{model.editModeIdentity($0,identity:identity)})) {
                Text("Advanced configuration").tag(GitPathRowIdentity.encode("advanced"))
                Text("None").tag(GitPathRowIdentity.encode("none"))
                ForEach(model.helperIdentities, id: \.self) { helperName in
                    let helper=helperName.rawValue
                    if model.localAvailable { Text("Local: " + helper).tag(GitPathRowIdentity.encode("local:" + helper)) }
                    Text("Global: " + helper).tag(GitPathRowIdentity.encode("global:" + helper))
                    if model.files?.system != nil { Text("System: " + helper).tag(GitPathRowIdentity.encode("system:" + helper)) }
                }
            }.disabled(model.busy || model.snapshot == nil)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading) {
                    Text("Helpers:")
                    List(selection: Binding(get: { model.selected }, set: {model.select($0,identity:identity)})) {
                        ForEach(model.displayGroups) { group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.groupTitle(group)).lineLimit(2)
                                Text(group.file?.lastPathComponent ?? group.origin).font(.caption).foregroundStyle(.secondary)
                            }.help(group.file?.path ?? group.origin).tag(group.id)
                        }
                    }.frame(minWidth: 200, idealWidth: 230, maxWidth: 280, minHeight: 300)
                    Button("New helper") { model.select(nil,identity:identity) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Config type:", selection: Binding(get:{model.destination},set:{model.editDestination($0,identity:identity)})) {
                        if model.localAvailable { Text("Local").tag(GitConfigurationSource.local) }
                        Text("Global").tag(GitConfigurationSource.global)
                        if model.files?.system != nil { Text("System").tag(GitConfigurationSource.system) }
                    }
                    HStack {Text("URL:").frame(width:80,alignment:.leading);TextField("",text:Binding(get:{model.draft.url},set:{model.editURL($0,identity:identity)})).accessibilityLabel("Credential URL")}
                    HStack {
                        Text("Helper:").frame(width:80,alignment:.leading)
                        CloneHistoryCombo(value:Binding(get:{model.draft.helpers.first ?? ""},set:{model.editHelper($0,identity:identity)}),choices:model.helpers,label:"Credential helper").id(identity).frame(height:26)
                    }
                    if model.draft.helpers.count > 1 {
                        Text("Helper chain (in order): " + model.draft.helpers.map { $0.isEmpty ? "Reset inherited helpers" : $0 }.joined(separator: " → ")).font(.caption)
                    }
                    HStack {Text("Username:").frame(width:80,alignment:.leading);TextField("",text:Binding(get:{model.draft.username},set:{model.editUsername($0,identity:identity)})).accessibilityLabel("Credential username")}
                    Toggle("Use HTTP path component", isOn: Binding(get:{model.draft.useHTTPPath},set:{model.editHTTPPath($0,identity:identity)}))
                    Button("Add New/Save") { model.save(identity:identity) }.disabled(!model.canAdd)
                    Button("Remove") { model.remove(identity:identity) }.disabled(model.group?.file == nil || model.group?.scope == "command")
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
        .background(SettingsLifecycleWindowProbe(model:model,owner:presentation).frame(width: 0, height: 0))
        .onAppear {
            model.attachPresentation(presentation);model.activate()
            transaction?.register("credential", participant: .init(page: .credential, modified: { model.modified }, validate: { model.validationError }, apply: { await model.applyForSettings(owner: transaction?.window) }, cancel: model.cancelDraft), registration: model.settingsRegistration)
        }
        .onChange(of: model.draft) { _ in transaction?.notify() }
        .onChange(of: model.busy) { _ in transaction?.notify() }
        .onChange(of: GitReferenceName(model.mode)) { _ in transaction?.notify() }
        .onChange(of: model.destination) { _ in transaction?.notify() }
        .onDisappear {model.detachPresentation(presentation)}
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
                Button("Apply") { Task { _ = await model.apply() } }.disabled(!model.modified)
            }.disabled(model.busy).padding(12)
        }
    }
}
