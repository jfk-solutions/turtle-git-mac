// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of SetHooks.cpp, SetHooksAdv.cpp and their resources.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor enum ClientHookPreferences {
    struct Decision: Codable { let identity: ClientHookApprovalIdentity; let approved: Bool }
    static func globals(_ preferences:UserDefaults) -> [ClientHook] { ClientHookConfiguration.parse(preferences.string(forKey:"hooks") ?? "") }
    static func decision(_ hook:ClientHook,preferences:UserDefaults) -> Bool? {
        guard let data = preferences.data(forKey:"ClientHooks.Approvals"), let decisions = try? JSONDecoder().decode([Decision].self,from:data) else { return nil }
        return decisions.last { $0.identity == hook.approvalIdentity }?.approved
    }
    static func remember(_ hook:ClientHook,approved:Bool?,preferences:UserDefaults) throws {
        let old = preferences.data(forKey:"ClientHooks.Approvals").flatMap { try? JSONDecoder().decode([Decision].self,from:$0) } ?? []
        var values = old.filter { $0.identity != hook.approvalIdentity }
        if let approved { values.append(Decision(identity:hook.approvalIdentity,approved:approved)) }
        preferences.set(try JSONEncoder().encode(values),forKey:"ClientHooks.Approvals")
    }
}

@MainActor final class HookSettingsModel: ObservableObject {
    private(set) static var activeSaves = 0
    @Published var hooks:[ClientHook] = []
    @Published var selection = Set<String>()
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var hasEditor = false
    @Published var error:String?
    let preferences:UserDefaults
    private var saved:[ClientHook] = []
    private var repository:GitRepository?, access:RepositoryAccessLease?
    private(set) var localAvailable = false
    private var invalidated = false, generation = UUID()
    private var cancellation:OperationCancellation?
    private var editor:HookConfigurationController?
    weak var window:NSWindow?
    init(preferences:UserDefaults = .standard) { self.preferences = preferences }
    var modified:Bool { loaded && hooks != saved }
    var editable:Bool { loaded && !busy && !hasEditor && !invalidated }
    var selected:[ClientHook] { hooks.filter { selection.contains($0.id) } }
    var validationError:String? {
        do { try ClientHookConfiguration.validate(hooks); return nil } catch { return error.localizedDescription }
    }
    func activate(repository:GitRepository?,access:RepositoryAccessLease?) {
        guard !invalidated, !busy else { return }
        if loaded { return }
        self.repository = repository; self.access = access
        let request = UUID(), token = OperationCancellation(); generation = request; cancellation = token; busy = true
        Task {
            defer { if generation == request { busy = false; cancellation = nil } }
            do {
                var values = ClientHookPreferences.globals(preferences), local = false
                if let repository {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    local = !(try await repository.isBare(cancellation:token))
                    var project = try await repository.projectClientHooks(cancellation:token)
                    for index in project.indices { project[index].enabled = ClientHookPreferences.decision(project[index],preferences:preferences) ?? true }
                    values += project
                }
                guard !invalidated, generation == request, !token.isCancelled else { return }
                hooks = ClientHookConfiguration.sorted(values); saved = hooks; loaded = true; localAvailable = local; error = nil
            } catch { if !invalidated, generation == request, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func apply() async -> Bool {
        guard loaded, !busy, !hasEditor, !invalidated else { return false }
        if let validationError { error = validationError; return false }
        let snapshot = hooks, prior = saved, repository = repository, access = access, request = generation
        let token = OperationCancellation(); cancellation = token; busy = true; Self.activeSaves += 1
        defer { Self.activeSaves -= 1; busy = false; cancellation = nil; withExtendedLifetime(access) {} }
        do {
            let globals = try ClientHookConfiguration.serialize(snapshot)
            if snapshot.filter(\.local) != prior.filter(\.local) {
                guard let repository, localAvailable else { throw ClientHookFailure.configuration("Local hooks require a working-tree repository.") }
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                // Enabling/disabling is per-user; only command/wait/show live in .tgitconfig.
                func shared(_ values:[ClientHook]) -> [ClientHook] { values.filter(\.local).map { var value = $0; value.enabled = true; return value } }
                if shared(snapshot) != shared(prior) { try await repository.saveProjectClientHooks(shared(snapshot),cancellation:token) }
                guard !invalidated, generation == request, !token.isCancelled else { return false }
                for hook in snapshot where hook.local {
                    if !hook.enabled { try ClientHookPreferences.remember(hook,approved:false,preferences:preferences) }
                    else if ClientHookPreferences.decision(hook,preferences:preferences) == false { try ClientHookPreferences.remember(hook,approved:nil,preferences:preferences) }
                }
            }
            guard !invalidated, generation == request, !token.isCancelled else { return false }
            preferences.set(globals,forKey:"hooks"); saved = snapshot; error = nil; return true
        } catch { if !invalidated, generation == request { self.error = error.localizedDescription }; return false }
    }
    func cancel() { guard !busy else { return }; closeEditor(); hooks = saved; selection = []; error = nil }
    func invalidate() { invalidated = true; generation = UUID(); cancellation?.cancel(); closeEditor() }
    func suspend() { closeEditor() }
    func setEnabled(_ id:String,_ enabled:Bool) { guard editable, let index = hooks.firstIndex(where:{ $0.id == id }) else { return }; hooks[index].enabled = enabled }
    func remove() { guard editable else { return }; hooks.removeAll { selection.contains($0.id) }; selection = [] }
    func configure(copy:Bool = false,add:Bool = false) {
        guard editable, let window, window.attachedSheet == nil, add || selected.count == 1 else { return }
        let original = add ? nil : selected.first
        let draft = original ?? ClientHook(path:repository?.root.path ?? "*")
        let controller = HookConfigurationController(hook:draft,repositoryRoot:localAvailable ? repository?.root:nil,preferences:preferences)
        let request = generation
        editor = controller; hasEditor = true
        controller.completed = { [weak self,weak controller] value in
            guard let self, let controller, self.editor === controller else { return }
            if let sheet = controller.window { self.window?.endSheet(sheet) }
            self.editor = nil; self.hasEditor = false
            guard !self.invalidated, self.generation == request, let value else { return }
            if !copy, let original { self.hooks.removeAll { $0.id == original.id } }
            // Source Add/Edit overwrite an existing map key.
            self.hooks.removeAll { $0.id == value.id }; self.hooks.append(value)
            self.hooks = ClientHookConfiguration.sorted(self.hooks); self.selection = [value.id]
        }
        if let sheet = controller.window { window.beginSheet(sheet) }
    }
    private func closeEditor() { let controller = editor; controller?.finish(nil); editor = nil; hasEditor = false }
}

@MainActor final class HookConfigurationDraft: ObservableObject {
    @Published var hook:ClientHook
    @Published var error:String?
    let root:URL?
    init(hook:ClientHook,root:URL?) { self.hook = hook; self.root = root }
    func setLocal(_ local:Bool) { hook.local = local; if local, let root { hook.path = root.path } }
}

@MainActor final class HookConfigurationController: NSWindowController, NSWindowDelegate {
    let draft:HookConfigurationDraft
    var completed:(ClientHook?) -> Void = { _ in }
    private var answered = false
    private var panel:NSOpenPanel?
    private let preferences:UserDefaults
    init(hook:ClientHook,repositoryRoot:URL?,preferences:UserDefaults = .standard) {
        self.preferences = preferences
        draft = HookConfigurationDraft(hook:hook,root:repositoryRoot)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:750,height:360),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Configure Hook Scripts – TurtleGit for Mac"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width:690,height:350)
        super.init(window:window); window.delegate = self
        window.contentViewController = NSHostingController(rootView:HookConfigurationDialog(draft:draft,accept:{[weak self] in self?.accept()},cancel:{[weak self] in self?.finish(nil)},browse:{[weak self] command in self?.browse(command:command)}))
        window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func accept() { guard !answered, panel == nil else { return }; if let error = draft.hook.validationError { draft.error = error; return }; finish(draft.hook) }
    func finish(_ value:ClientHook?) {
        guard !answered else { return }; answered = true
        if let panel { window?.endSheet(panel,returnCode:.cancel); panel.orderOut(nil) }; panel = nil
        completed(value); window?.close()
    }
    func windowWillClose(_ notification:Notification) { finish(nil) }
    func browse(command:Bool) {
        guard !answered, panel == nil, let window, window.attachedSheet == nil else { return }
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = !command; chooser.canChooseFiles = command
        chooser.title = command ? "Select hook executable or script" : "Select working tree parent"; panel = chooser
        chooser.beginSheetModal(for:window) { [weak self] response in
            guard let self, self.panel === chooser, !self.answered else { return }; self.panel = nil
            guard response == .OK, let url = chooser.url else { return }
            if command {
                do { try ClientHookScriptAccess.remember(url,preferences:self.preferences) }
                catch { self.draft.error = error.localizedDescription; return }
                self.draft.hook.command = "'" + url.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
            }
            else { self.draft.hook.path = url.path }
        }
    }
}

private struct HookConfigurationDialog: View {
    @ObservedObject var draft:HookConfigurationDraft
    let accept:() -> Void, cancel:() -> Void, browse:(Bool) -> Void
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Toggle("Enable",isOn:$draft.hook.enabled)
            HStack { Text("Hook Type:"); Spacer(); Picker("Hook Type",selection:$draft.hook.type) { ForEach(ClientHookType.allCases,id:\.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width:230) }
            Toggle("Run for this repository",isOn:Binding(get:{draft.hook.local},set:draft.setLocal)).disabled(draft.root == nil)
            Text("Run when working tree path is under:")
            HStack { TextField("",text:$draft.hook.path).accessibilityLabel("Working tree path"); Button("…") { browse(false) } }.disabled(draft.hook.local)
            Text("Command Line To Execute:")
            HStack { TextField("",text:$draft.hook.command).accessibilityLabel("Command line to execute"); Button("…") { browse(true) } }
            Toggle("Wait for the script to finish",isOn:$draft.hook.wait)
            HStack {
                Toggle("Hide the script while running",isOn:Binding(get:{!draft.hook.show},set:{draft.hook.show = !$0}))
                Spacer(); Button("OK",action:accept).keyboardShortcut(.defaultAction); Button("Cancel",action:cancel).keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string:"https://tortoisegit.org/docs/tortoisegit/tgit-dug-settings.html#tgit-dug-settings-hooks")!) }
            }
            if let error = draft.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(16)
    }
}

@MainActor struct HookSettingsPage: View {
    @ObservedObject var model:HookSettingsModel
    let repository:GitRepository?, access:RepositoryAccessLease?
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Table(model.hooks,selection:$model.selection) {
                TableColumn("Hook Type") { hook in HStack { Toggle("",isOn:Binding(get:{model.hooks.first { $0.id == hook.id }?.enabled ?? hook.enabled},set:{model.setEnabled(hook.id,$0)})).labelsHidden().accessibilityLabel("Enable " + hook.type.title); Text(hook.type.rawValue).onTapGesture(count:2) { model.selection = [hook.id]; model.configure() } } }
                TableColumn("Working Tree Path") { Text($0.local ? "local" : $0.path) }
                TableColumn("Command Line") { Text($0.command) }
                TableColumn("Wait") { Text($0.wait ? "true" : "false") }.width(55)
                TableColumn("Show") { Text($0.show ? "show" : "hide") }.width(55)
            }.disabled(!model.editable)
            HStack { Spacer(); Button("Remove",action:model.remove).disabled(model.selected.isEmpty); Button("Edit…") { model.configure() }.disabled(model.selected.count != 1); Button("Copy") { model.configure(copy:true) }.disabled(model.selected.count != 1); Button("Add…") { model.configure(add:true) } }.disabled(!model.editable)
            if model.busy { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
        }.padding(16)
        .background(HookSettingsWindowCapture(model:model).frame(width:0,height:0))
        .onAppear { model.activate(repository:repository,access:access) }
        .onDisappear { model.suspend() }
        .settingsParticipant("hooks",page:.hooks,value:model.hooks,modified:{model.modified},validate:{model.validationError},apply:model.apply,cancel:model.cancel)
    }
}

private struct HookSettingsWindowCapture:NSViewRepresentable {
    let model:HookSettingsModel
    func makeNSView(context:Context) -> NSView { Capture(model:model) }
    func updateNSView(_ view:NSView,context:Context) {}
    final class Capture:NSView {
        weak var model:HookSettingsModel?
        init(model:HookSettingsModel) { self.model = model; super.init(frame:.zero) }
        required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.window = window }
    }
}
