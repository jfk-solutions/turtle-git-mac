// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class GitConfigurationSettingsModel: ObservableObject {
    private(set) static var activeSaves = 0
    private(set) static var activeReads = 0
    private(set) static var activeFolderChoosers=0
    private(set) static var activeSheetReleases=0
    @Published private(set) var authorizingFolder=false
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    var authorizeFile: ((URL) async -> Bool)?
    var readConfigurationFiles: (GitRepository, Bool, OperationCancellation?) async throws -> GitConfigurationFiles = { try await $0.gitConfigurationFiles(hasRepository: $1, cancellation: $2) }
    var readSettings:(GitRepository,GitConfigurationSource,OperationCancellation?)async throws->GitConfigurationSettings = {try await $0.gitConfiguration(source:$1,cancellation:$2)}
    typealias EditorReply = @MainActor @Sendable (String?)->Void
    var openEditor:(URL,UserDefaults,[RepositoryAccessLease],@escaping EditorReply)->Void = {AlternativeEditor.open($0,preferences:$1,permissions:$2,completion:$3)}
    @Published private(set) var editorIdentity=UUID()
    @Published private(set) var loadingSource:GitConfigurationSource?
    var writeSettings: (GitRepository, GitConfigurationSettings, GitConfigurationSource) async throws -> Void = { try await $0.saveGitConfiguration($1, destination: $2) }
    @Published private(set) var source: GitConfigurationSource = .effective
    @Published var destination: GitConfigurationSource = .local
    private var savedDestination: GitConfigurationSource = .local
    @Published var draft = GitConfigurationSettings()
    @Published private(set) var saved = GitConfigurationSettings()
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published var error: String?
    @Published var configurationText: String?
    @Published private(set) var files: GitConfigurationFiles?
    private var permissionPanel: NSOpenPanel?
    private var permissionAnswer: ((Bool) -> Void)?
    private(set) var repository: GitRepository?
    private var access: RepositoryAccessLease?
    private var hasRepository = false
    // Authoritative command gates must never publish during SwiftUI graph teardown.
    private var active = false
    private var editorReceipt = UUID()
    private var presentationOwner: UUID?
    private var probeIdentity: UUID?
    private var probes: [UUID: GitConfigurationProbeAttachment] = [:]
    private var folderChooser: GitConfigurationFolderChoice?
    private var hintShown = false
    private var needsInitialLoad=true
    var isActive: Bool { active }
    private var saving = false
    private var acceptedWrite:UUID?
    private var pendingContext: (GitRepository, RepositoryAccessLease?, Bool)?
    private var generation = UUID()
    private var activationIdentity=UUID()
    private var readToken: OperationCancellation?
    private var alert: NSAlert?
    private var answer: ((Bool) -> Void)?
    weak var window: NSWindow?
    var localAvailable: Bool { hasRepository }
    var editable: Bool {active && loaded && source != .effective && !busy}
    var changed: Bool { loaded && (draft != saved || destination != savedDestination) }
    fileprivate static func beginFolderChoice() {activeFolderChoosers += 1}
    fileprivate static func endFolderChoice() {activeFolderChoosers -= 1}
    func acceptsSourceSelection(_ receipt: UUID) -> Bool {active && !busy && editorReceipt==receipt && editorIdentity==receipt}
    func acceptsEditor(_ receipt: UUID) -> Bool { editable && editorReceipt == receipt && editorIdentity == receipt }
    private func advanceEditor() { editorReceipt = UUID(); editorIdentity = editorReceipt }
    func attachPresentation(_ owner: UUID) {
        presentationOwner = owner
        if let attachment = probes.values.filter({ $0.owner == owner }).max(by: { $0.order < $1.order }) {
            probeIdentity = attachment.identity; window = attachment.window
        } else { probeIdentity = nil; window = nil }
    }
    func detachPresentation(_ owner: UUID) {
        guard presentationOwner == owner else { return }
        presentationOwner = nil; probeIdentity = nil; window = nil; deactivate()
    }
    func attachProbe(owner: UUID, identity: UUID, window: NSWindow) {
        let attachment = GitConfigurationProbeAttachment(owner: owner, identity: identity, window: window)
        probes[identity] = attachment
        guard presentationOwner == nil || presentationOwner == owner else { return }
        presentationOwner = owner; probeIdentity = identity; self.window = window
    }
    func detachProbe(_ identity: UUID) {
        probes.removeValue(forKey: identity)
        guard probeIdentity == identity else { return }
        probeIdentity = nil; presentationOwner = nil; window = nil; deactivate()
    }
    func activate(repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool) {
        activationIdentity=UUID();editorReceipt=UUID()
        let sameContext=self.repository?.root==repository.root && self.repository?.executable==repository.executable && hasRepository==localAvailable
        if saving,sameContext,acceptedWrite==generation {
            // Presentation/editor authority changes, but an already accepted
            // write to this exact context keeps its operation receipt.
            active=true;editorIdentity=editorReceipt;pendingContext=nil;return
        }
        generation=UUID();readToken?.cancel();readToken=nil
        if saving {pendingContext=(repository,access,localAvailable);return}
        if loaded && self.repository?.root == repository.root && self.repository?.executable == repository.executable && hasRepository == localAvailable {
            active = true;busy=false;loadingSource=nil;configurationText=nil;authorizingFolder=false;editorIdentity=editorReceipt;return
        }
        deactivate()
        self.repository = repository; self.access = access; hasRepository = localAvailable
        active=true;source = .effective;destination=localAvailable ? .local:.global;savedDestination=destination
        busy=false;authorizingFolder=false;configurationText=nil;loadingSource=nil
        files=nil;draft=GitConfigurationSettings();saved=draft;loaded=false;needsInitialLoad=true
        load(.effective, initial: true)
    }
    func deactivate() {
        // Revoke all authority synchronously. This is called by dismantleNSView
        // while SwiftUI holds exclusive graph access: no Published setter here.
        active = false;activationIdentity=UUID();pendingContext=nil;generation=UUID();editorReceipt=UUID()
        let retirement=activationIdentity,editor=editorReceipt
        readToken?.cancel();readToken=nil
        let panel=permissionPanel;permissionPanel=nil
        let folder=folderChooser;folderChooser=nil
        let permission=permissionAnswer;permissionAnswer=nil
        let alert=self.alert;self.alert=nil
        let pending=answer;answer=nil
        let sheets=[panel,alert?.window].compactMap {$0}
        let ownsRelease = !sheets.isEmpty || permission != nil || pending != nil || folder != nil
        if ownsRelease {Self.activeSheetReleases += 1}
        DispatchQueue.main.async { [self] in
            SettingsLifecycleSheetDrain.close(sheets) { [self] in
                folder?.release()
                // Resume each retired continuation after actual captured sheets
                // detach, regardless of a newer presentation's activation.
                permission?(false);pending?(false)
                if ownsRelease {Self.activeSheetReleases -= 1}
                guard !active,activationIdentity==retirement else {return}
                editorIdentity=editor;loadingSource=nil;configurationText=nil;authorizingFolder=false
                if !saving {busy=false}
            }
        }
    }
    func dismissDisplayedConfiguration() {guard active else {return};configurationText=nil}
    private func checkAccess(_ repository: GitRepository, access: RepositoryAccessLease?, local: Bool) throws {
        if GitRuntime.isAppStoreBuild && local && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load(_ source: GitConfigurationSource, initial: Bool = false) {
        guard active, let repository, (!busy || readToken != nil), source != .local || hasRepository else { return }
        let firstAccepted=needsInitialLoad,initialize=initial || (needsInitialLoad && source == .effective)
        readToken?.cancel(); let token = OperationCancellation(), request = UUID(); generation = request; readToken = token
        advanceEditor();loadingSource=source;loaded=false;busy=true;error=nil
        let destination=(source == .local || source == .global) ? source:self.destination
        Self.activeReads += 1
        Task { [self, access] in
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {}; if self.generation == request { self.readToken = nil; self.busy = false;self.loadingSource=nil } }
            do {
                try self.checkAccess(repository, access: access, local: self.hasRepository)
                let files = try await self.readConfigurationFiles(repository, self.hasRepository, token)
                guard self.active, self.generation == request, !token.isCancelled else { return }
                if source == .effective || source == .global {
                    for file in [files.global, files.xdg].compactMap({ $0 }) {
                        guard await self.ensurePermission(for: file), self.active, self.generation == request, !token.isCancelled else { return }
                    }
                }
                var value=try await self.readSettings(repository,source,token)
                var acceptedSource=source,acceptedDestination=destination
                guard self.active, self.generation == request, !token.isCancelled else { return }
                if initialize && value.name.value.isEmpty && value.email.value.isEmpty {
                    value=try await self.readSettings(repository,.global,token)
                    guard self.active, self.generation == request, !token.isCancelled else { return }
                    acceptedSource = .global;acceptedDestination = .global
                    value.name.inherit = false; value.email.inherit = false
                }
                // Publish one accepted level, origin set, destination and draft.
                self.files=files;self.source=acceptedSource;self.destination=acceptedDestination
                self.draft=value;self.saved=value;self.savedDestination=acceptedDestination;self.loaded=true;self.advanceEditor();self.needsInitialLoad=false
                if initial || firstAccepted {self.showHierarchyHint()}
            } catch { if self.active, self.generation == request, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func showHierarchyHint() {
        guard active, !hintShown, !preferences.bool(forKey: "HintHierarchicalConfig"), let window, window.attachedSheet == nil else { return }
        hintShown = true
        let alert = NSAlert(); alert.messageText = "Git configuration"
        alert.informativeText = "Git uses hierarchical configuration: settings in higher levels override lower levels. Effective shows the read-only values for the current scope. Select a level to see its stored values. To change settings, select a level, enter the values and choose where to save them."
        alert.addButton(withTitle: "OK"); alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not show this message again"; self.alert = alert
        alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
        let request=generation,activation=activationIdentity
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self,self.alert===alert else {return};self.alert=nil
            Self.activeSheetReleases += 1
            SettingsLifecycleSheetDrain.close([alert.window]) { [weak self] in
                Self.activeSheetReleases -= 1
                guard let self,self.active,self.generation==request,self.activationIdentity==activation else {return}
                if response == .alertFirstButtonReturn,alert.suppressionButton?.state == .on {self.preferences.set(true,forKey:"HintHierarchicalConfig")}
            }
        }
    }

    private func confirmSave(to destination: GitConfigurationSource) async -> Bool {
        guard active, let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = "Are you sure you want to save to \"\(destination.rawValue)\"?"
        alert.informativeText = "The selected config source differs from the save destination."
        alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Save")
        self.alert = alert
        alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
        let request=generation,activation=activationIdentity
        return await withCheckedContinuation { continuation in
            var answered = false
            let answer: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            self.answer = answer
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.alert === alert else { return }
                self.alert=nil;self.answer=nil
                SettingsLifecycleSheetDrain.close([alert.window]) { [weak self] in
                    answer(response == .alertSecondButtonReturn && self?.active == true && self?.generation==request && self?.activationIdentity==activation)
                }
            }
        }
    }
    func apply() { performApply { _ in } }
    func applyForSettings(owner: NSWindow?) async -> Bool {
        if !changed { return true }
        let wasActive=active,activation=activationIdentity
        active = true
        if window == nil { window = owner }
        let success = await withCheckedContinuation { continuation in performApply { continuation.resume(returning: $0) } }
        if !wasActive,activationIdentity==activation {active=false}
        return success
    }
    func cancelDraft() { guard !saving else { return }; draft = saved; destination = savedDestination }
    private func performApply(completion: @escaping (Bool) -> Void) {
        guard active, editable, changed, window?.attachedSheet == nil, let repository, destination != .local || hasRepository else { completion(false); return }
        let value = draft, destination = destination, source = source, request = generation, access = access
        busy = true; saving = true; error = nil
        Self.activeSaves += 1
        Task { [weak self] in
            var success = false
            defer { Self.activeSaves -= 1; withExtendedLifetime(access) {}; completion(success) }
            guard let self else { return }
            defer {
                self.saving = false;self.acceptedWrite=nil
                if self.generation == request || !self.active { self.busy = false }
                if let pending = self.pendingContext {
                    self.pendingContext = nil
                    self.activate(repository: pending.0, access: pending.1, localAvailable: pending.2)
                }
            }
            do {
                if source != destination { guard await self.confirmSave(to: destination) else { return } }
                guard self.active, self.generation == request else { return }
                try self.checkAccess(repository, access: access, local: self.hasRepository)
                if destination == .global, let files = self.files {
                    for file in [files.global, files.xdg].compactMap({ $0 }) {
                        guard await self.ensurePermission(for: file), self.active, self.generation == request else { return }
                    }
                }
                guard self.draft==value,self.destination==destination,self.source==source else {
                    self.error="The Git configuration draft changed while awaiting confirmation or permission. Review it and apply again.";return
                }
                // Each Git config write holds its own lock. Retain the grant and
                // allow this source-ordered batch to finish after owner closure.
                self.acceptedWrite=request
                try await self.writeSettings(repository, value, destination)
                guard self.active, self.generation == request else { return }
                self.saved = value; self.savedDestination = destination; success = true
            } catch { if self.active, self.generation == request { self.error = error.localizedDescription } }
        }
    }
    private func ensurePermission(for file: URL) async -> Bool {
        guard active else {return false}
        if let authorizeFile { return await authorizeFile(file) }
        if GitConfigurationPermissions.authorized(file) || access?.contains(file) == true && access?.hasSecurityScope == true { return true }
        guard active, let window, window.attachedSheet == nil, permissionPanel == nil else { return false }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.title = "Authorize Git configuration"; panel.prompt = "Authorize"
        panel.message = "Select the folder containing " + file.path + ". Git also needs permission to create its adjacent lock file."
        var directory = file.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" { directory.deleteLastPathComponent() }
        panel.directoryURL = directory; permissionPanel = panel
        panel.alphaValue=window.alphaValue;panel.appearance=window.appearance
        let request=generation,activation=activationIdentity
        return await withCheckedContinuation { continuation in
            var answered = false
            let answer: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            permissionAnswer = answer
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self,self.permissionPanel===panel else {return};self.permissionPanel=nil;self.permissionAnswer=nil
                SettingsLifecycleSheetDrain.close([panel]) { [weak self] in
                    guard let self,self.active,self.generation==request,self.activationIdentity==activation,response == .OK,let directory=panel.url else {answer(false);return}
                    do {try GitConfigurationPermissions.remember(directory,for:file);answer(true)}
                    catch {self.error=error.localizedDescription;answer(false)}
                }
            }
        }
    }
    func authorizeConfigurationFolder() {
        guard active, !busy, let window, window.attachedSheet == nil, permissionPanel == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.title = "Authorize Git configuration folder"; panel.prompt = "Authorize"
        panel.message = "Choose a folder containing your Git config files. This permission is remembered for future Git operations."
        let chooser=GitConfigurationFolderChoice();folderChooser=chooser
        permissionPanel=panel;busy=true;authorizingFolder=true
        panel.alphaValue=window.alphaValue;panel.appearance=window.appearance
        let request=generation,activation=activationIdentity
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self,self.permissionPanel===panel,self.folderChooser===chooser else {return}
            self.permissionPanel=nil;self.folderChooser=nil
            SettingsLifecycleSheetDrain.close([panel]) { [weak self] in
                chooser.release()
                guard let self,self.active,self.generation==request,self.activationIdentity==activation else {return}
                self.authorizingFolder=false;self.busy=false
                guard response == .OK,let directory=panel.url else {return}
                do {try GitConfigurationPermissions.remember(directory,for:directory);self.load(self.source)}
                catch {self.error=error.localizedDescription}
            }
        }
    }
    func editConfiguration(_ kind: GitConfigurationFile) {
        guard active, loaded, !busy, let repository, let files, let file = files[kind] else { return }
        let request = UUID(), token = OperationCancellation(), access = access
        generation = request; readToken = token; busy = true; error = nil
        Self.activeReads += 1
        Task { [self] in
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {}; if self.generation == request { self.readToken = nil; self.busy = false } }
            do {
                try self.checkAccess(repository, access: access, local: self.hasRepository)
                let target: URL
                if kind == .project && files.bare {
                    let bytes = try await repository.projectConfigurationFromHEAD(cancellation: token)
                    guard self.active, self.generation == request, !token.isCancelled else { return }
                    target = try GitConfigurationPreviewFiles.create(bytes, name: ".tgitconfig")
                } else {
                    guard await self.ensurePermission(for: file), self.active, self.generation == request, !token.isCancelled else { return }
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        do { try Data().write(to: file, options: .withoutOverwriting) }
                        catch { if !FileManager.default.fileExists(atPath: file.path) { throw error } }
                    }
                    target = file
                }
                guard self.active, self.generation == request, !token.isCancelled else { return }
                self.openEditor(target,self.preferences,access.map { [$0] } ?? []) { [weak self] error in
                    guard let self, self.active, self.generation == request else { return }
                    self.error = error
                }
            } catch { if self.active, self.generation == request, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func openDisplayedConfiguration() {
        guard active,let text=configurationText else {return}
        let request=generation
        do {
            let file=try GitConfigurationPreviewFiles.create(Data(text.utf8),name:"gitconfig.txt")
            openEditor(file,preferences,[]) { [weak self] error in
                guard let self,self.active,self.generation==request,self.configurationText.map({Data($0.utf8)})==Data(text.utf8) else {return};self.error=error
            }
        } catch {if active,generation==request {self.error=error.localizedDescription}}
    }
    func viewConfiguration(_ source: GitConfigurationSource) {
        guard active, loaded, !busy, let repository else { return }
        let token = OperationCancellation(), request = UUID(); generation = request; readToken = token; busy = true; error = nil
        Self.activeReads += 1
        Task { [self, access] in
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {}; if self.generation == request { self.readToken = nil; self.busy = false } }
            do {
                try self.checkAccess(repository, access: access, local: self.hasRepository)
                let text: String
                if source == .system, let file = self.files?.system {
                    guard await self.ensurePermission(for: file), self.active, self.generation == request, !token.isCancelled else { return }
                    guard let value = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw GitConfigurationFailure.output }
                    text = value
                } else {
                    text = try await repository.gitConfigurationText(source: source, cancellation: token)
                }
                guard self.active, self.generation == request, !token.isCancelled else { return }
                self.configurationText = text
            } catch { if self.active, self.generation == request, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
struct GitConfigurationSettingsPage: View {
    @ObservedObject var workspace: RepositoryModel
    var globalOnly = false
    @Environment(\.settingsTransaction) private var transaction
    @StateObject private var model: GitConfigurationSettingsModel
    @State private var presentation=UUID()
    init(workspace: RepositoryModel, globalOnly: Bool = false, preferences: UserDefaults = .standard, model: GitConfigurationSettingsModel? = nil) {
        self.workspace = workspace; self.globalOnly = globalOnly
        _model = StateObject(wrappedValue: model ?? GitConfigurationSettingsModel(preferences: preferences))
    }
    var body: some View {
        let identity=model.editorIdentity
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Config source") {
                HStack {
                    ForEach(Array(GitConfigurationSource.allCases.enumerated()),id:\.offset) {index,source in
                        if index>0 {Text(index==1 ? "|":"<<").foregroundStyle(.secondary)}
                        BaseRadio(title:source.rawValue,selected:model.source==source) {
                            guard model.acceptsSourceSelection(identity) else {return};model.load(source)
                        }.frame(height:24).disabled(source == .local && !model.localAvailable)
                    }
                }.padding(8).disabled(model.busy || !model.isActive)
            }
            if let source=model.loadingSource {Text("Loading "+source.rawValue+" configuration…").font(.caption).foregroundStyle(.secondary)}
            GroupBox("User Info") {
                VStack(spacing: 10) {
                    self.identity("Name:", field: $model.draft.name,identity:identity)
                    self.identity("Email:", field: $model.draft.email,identity:identity)
                    self.identity("Signing key ID:", field: $model.draft.signingKey,identity:identity)
                }.padding(8)
            }
            GroupBox("Auto CrLf convert") {
                HStack {
                    Picker("AutoCrLf:", selection: guarded($model.draft.autoCRLF,identity:identity)) { ForEach(["", "false", "true", "input"], id: \.self) { Text($0.isEmpty ? " " : $0).tag($0) } }
                    Picker("SafeCrLf:", selection: guarded($model.draft.safeCRLF,identity:identity)) { ForEach(["", "false", "true", "warn"], id: \.self) { Text($0.isEmpty ? " " : $0).tag($0) } }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(8).disabled(!model.editable)
            }
            HStack {
                GitConfigurationCheckbox(title: "QuotePath", value: guarded($model.draft.quotePath,identity:identity), enabled: model.editable).frame(height:24)
                GitConfigurationCheckbox(title: "Prune", value: guarded($model.draft.prune,identity:identity), enabled: model.editable).frame(height:24)
            }
            HStack {
                Text("Save to:")
                Picker("Save to", selection: guarded($model.destination,identity:identity)) {
                    if model.localAvailable { Text("Local").tag(GitConfigurationSource.local) }
                    Text("Global").tag(GitConfigurationSource.global)
                }.labelsHidden().frame(width: 190).disabled(!model.editable)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading) {
                    Button("Edit local .git/config") { model.editConfiguration(.local) }.disabled(!model.localAvailable)
                    Button(model.files?.bare == true ? "View .tgitconfig" : "Edit .tgitconfig") { model.editConfiguration(.project) }.disabled(!model.localAvailable)
                    Button("View effective config") { model.viewConfiguration(.effective) }
                }.frame(maxWidth:.infinity,alignment:.leading)
                VStack(alignment: .leading) {
                    Button("Edit global .gitconfig") { model.editConfiguration(.global) }.disabled(model.files?.global == nil)
                    if let xdg = model.files?.xdg, FileManager.default.fileExists(atPath: xdg.deletingLastPathComponent().path) {
                        Button("Edit global XDG git/config") { model.editConfiguration(.xdg) }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
                VStack(alignment: .leading) {
                    Button("Edit systemwide gitconfig") { model.editConfiguration(.system) }.disabled(model.files?.system == nil)
                    Button("View systemwide gitconfig") { model.viewConfiguration(.system) }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.disabled(model.busy || !model.loaded || !model.isActive)
            if GitRuntime.isAppStoreBuild {
                Button("Authorize configuration folder…", action: model.authorizeConfigurationFolder).disabled(model.busy)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                if transaction == nil {
                    Button("Cancel") { model.deactivate(); model.window?.performClose(nil) }.disabled(model.busy)
                    Button("Apply", action: model.apply).disabled(!model.editable || !model.changed)
                }
            }
        }.padding(20)
        .background(GitConfigurationWindowProbe(model: model,owner:presentation).frame(width: 0, height: 0))
        .settingsParticipant("git", page: .git, value: model.draft, modified: { model.changed },
            validate: { model.repository == nil ? "Choose a repository or global configuration." : nil },
            apply: { await model.applyForSettings(owner: transaction?.window) }, cancel: model.cancelDraft)
        .onChange(of: model.destination) { _ in transaction?.notify() }
        .onAppear {model.attachPresentation(presentation);activate()}.onChange(of: workspace.root) { _ in if model.isActive { activate() } }.onDisappear {model.detachPresentation(presentation)}
        .sheet(isPresented: Binding(get: { model.configurationText != nil }, set: { if !$0 { model.dismissDisplayedConfiguration() } })) {
            VStack(alignment: .leading) {
                ScrollView([.horizontal, .vertical]) { Text(model.configurationText ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).padding() }
                HStack { Button("Open in editor", action: model.openDisplayedConfiguration); Spacer(); Button("Close") { model.dismissDisplayedConfiguration() }.keyboardShortcut(.cancelAction) }.padding()
            }.frame(minWidth: 680, minHeight: 420)
        }
    }
    private func activate() {
        do { let context = try workspace.gitConfigurationContext(globalOnly: globalOnly); model.activate(repository: context.repository, access: context.access, localAvailable: context.localAvailable) }
        catch { model.error = error.localizedDescription }
    }
    private func guarded<Value>(_ value:Binding<Value>,identity:UUID)->Binding<Value> {
        Binding(get:{value.wrappedValue},set:{if model.acceptsEditor(identity) {value.wrappedValue=$0}})
    }
    private func identity(_ label:String,field:Binding<GitConfigurationIdentity>,identity:UUID)->some View {
        let field=guarded(field,identity:identity)
        return HStack {
            Text(label).frame(width:105,alignment:.leading)
            TextField("",text:field.value).accessibilityLabel(label).disabled(!model.editable || field.wrappedValue.inherit)
            Toggle("inherit",isOn:field.inherit).toggleStyle(.checkbox).disabled(!model.editable)
        }
    }
}
private struct GitConfigurationCheckbox: NSViewRepresentable {
    let title: String
    @Binding var value: GitConfigurationBoolean
    let enabled: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        button.allowsMixedState = true; button.toolTip = "Mixed inherits the value from another config source."; return button
    }
    static func dismantleNSView(_ button:NSButton,coordinator:Coordinator) {coordinator.retired=true;button.target=nil;button.action=nil}
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self; button.isEnabled = enabled
        button.state = value == .inherit ? .mixed : value == .enabled ? .on : .off
    }
    final class Coordinator: NSObject {
        var retired=false
        var parent: GitConfigurationCheckbox
        init(_ parent: GitConfigurationCheckbox) { self.parent = parent }
        @objc func changed(_ sender: NSButton) {guard !retired,parent.enabled,sender.isEnabled,sender.window != nil else {return}; parent.value = sender.state == .mixed ? .inherit : sender.state == .on ? .enabled : .disabled }
    }
}
private struct GitConfigurationWindowProbe: NSViewRepresentable {
    let model: GitConfigurationSettingsModel
    let owner: UUID
    func makeNSView(context: Context) -> Probe {let view=Probe();view.model=model;view.owner=owner;return view}
    func updateNSView(_ view:Probe,context:Context) {view.synchronizeAttachment()}
    static func dismantleNSView(_ view:Probe,coordinator:()) {view.retire()}
    final class Probe:NSView {
        weak var model:GitConfigurationSettingsModel?
        var owner=UUID()
        private var receipt:UUID?
        private weak var attachedWindow:NSWindow?
        private var retired=false
        private var ownerObserver:NSObjectProtocol?
        private func releaseAttachment() {
            if let ownerObserver {NotificationCenter.default.removeObserver(ownerObserver)};ownerObserver=nil
            if let receipt {model?.detachProbe(receipt)};receipt=nil;attachedWindow=nil
        }
        func synchronizeAttachment() {
            guard !retired else {return}
            if window===attachedWindow,receipt != nil {return}
            releaseAttachment();attachedWindow=window
            if let window {
                let identity=UUID();receipt=identity
                model?.attachProbe(owner:owner,identity:identity,window:window)
                ownerObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in MainActor.assumeIsolated {self?.releaseAttachment()} }
            }
        }
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();synchronizeAttachment()}
        func retire() {
            guard !retired else {return};retired=true
            releaseAttachment();model=nil
        }
    }
}

@MainActor private final class GitConfigurationProbeAttachment {
    static private var nextOrder:UInt64=0
    let owner:UUID,identity:UUID,order:UInt64
    weak var window:NSWindow?
    init(owner:UUID,identity:UUID,window:NSWindow) {
        Self.nextOrder &+= 1;order=Self.nextOrder;self.owner=owner;self.identity=identity;self.window=window
    }
}
@MainActor private final class GitConfigurationFolderChoice {
    private var released=false
    init() {GitConfigurationSettingsModel.beginFolderChoice()}
    func release() {guard !released else {return};released=true;GitConfigurationSettingsModel.endFolderChoice()}
}
@MainActor enum SettingsLifecycleSheetDrain {
    static func close(_ windows:[NSWindow],completion:@escaping ()->Void) {
        for window in windows {
            if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)}
            window.orderOut(nil)
        }
        func finish() {
            if windows.contains(where:{$0.sheetParent != nil || $0.isVisible}) {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.01,execute:finish)
            } else {completion()}
        }
        // Even an already detached window's reply must leave graph teardown.
        DispatchQueue.main.async(execute:finish)
    }
}

@MainActor enum GitConfigurationPreviewFiles {
    private static var directories: [URL] = []
    static func create(_ bytes: Data, name: String) throws -> URL {
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("git-config-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let file = directory.appendingPathComponent(name)
            try bytes.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            directories.append(directory); return file
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    static func discardAll() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; directories.removeAll() }
}

@MainActor final class SettingsLifecycleAttachments {
    private var owner:UUID?,identity:UUID?
    private var attachments:[UUID:Attachment]=[:]
    private var order:UInt64=0
    private final class Attachment {
        let owner:UUID,identity:UUID,order:UInt64
        weak var window:NSWindow?
        init(owner:UUID,identity:UUID,order:UInt64,window:NSWindow) {self.owner=owner;self.identity=identity;self.order=order;self.window=window}
    }
    func claim(_ owner:UUID)->NSWindow? {
        self.owner=owner
        let latest=attachments.values.filter {$0.owner==owner}.max {$0.order<$1.order}
        identity=latest?.identity;return latest?.window
    }
    func attach(owner:UUID,identity:UUID,window:NSWindow)->Bool {
        order &+= 1;attachments[identity]=Attachment(owner:owner,identity:identity,order:order,window:window)
        guard self.owner==nil || self.owner==owner else {return false}
        self.owner=owner;self.identity=identity;return true
    }
    func releaseOwner(_ owner:UUID)->Bool {guard self.owner==owner else {return false};self.owner=nil;identity=nil;return true}
    func releaseProbe(_ identity:UUID)->Bool {attachments.removeValue(forKey:identity);guard self.identity==identity else {return false};owner=nil;self.identity=nil;return true}
}
@MainActor protocol SettingsLifecyclePresenting:AnyObject {
    func attachProbe(owner:UUID,identity:UUID,window:NSWindow)
    func detachProbe(_ identity:UUID)
}
struct SettingsLifecycleWindowProbe<Model:SettingsLifecyclePresenting>:NSViewRepresentable {
    let model:Model,owner:UUID
    func makeNSView(context:Context)->Probe {let view=Probe();view.model=model;view.owner=owner;return view}
    func updateNSView(_ view:Probe,context:Context) {view.synchronizeAttachment()}
    static func dismantleNSView(_ view:Probe,coordinator:()) {view.retire()}
    final class Probe:NSView {
        weak var model:Model?
        var owner=UUID()
        private var receipt:UUID?
        private weak var attachedWindow:NSWindow?
        private var retired=false
        private var ownerObserver:NSObjectProtocol?
        private func releaseAttachment() {
            if let ownerObserver {NotificationCenter.default.removeObserver(ownerObserver)};ownerObserver=nil
            if let receipt {model?.detachProbe(receipt)};receipt=nil;attachedWindow=nil
        }
        func synchronizeAttachment() {
            guard !retired else {return}
            if window===attachedWindow,receipt != nil {return}
            releaseAttachment();attachedWindow=window
            if let window {
                let identity=UUID();receipt=identity;model?.attachProbe(owner:owner,identity:identity,window:window)
                ownerObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in MainActor.assumeIsolated {self?.releaseAttachment()} }
            }
        }
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();synchronizeAttachment()}
        func retire() {guard !retired else {return};retired=true;releaseAttachment();model=nil}
    }
}
