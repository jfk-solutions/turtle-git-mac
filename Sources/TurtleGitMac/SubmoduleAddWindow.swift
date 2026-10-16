// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SubmoduleAddWindowController: NSWindowController, NSWindowDelegate {
    let model: SubmoduleAddWindowModel
    var onClosed: () -> Void = {}
    private(set) var panel: NSOpenPanel?
    private var pickerID=UUID()
    var presentOpenPanel:(NSOpenPanel,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Void = {panel,owner,reply in panel.beginSheetModal(for:owner,completionHandler:reply)}
    var selectedPanelURL:(NSOpenPanel)->URL? = {$0.url}
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String = "", preferences: UserDefaults = .standard,clipboardText:String? = nil) {
        model = SubmoduleAddWindowModel(repository: repository, access: access, path: path, preferences: preferences,clipboardText:clipboardText)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 310), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Submodule Add – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 670, height: 310)
        window.contentViewController = NSHostingController(rootView: SubmoduleAddDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in self?.window?.makeFirstResponder(nil); self?.window?.close() }
        model.pick = { [weak self] kind in self?.pick(kind) }
        DialogGeometry.attach(window, identifier: "SubmoduleAddDlg")
    }
    private func pick(_ kind: SubmoduleAddWindowModel.Picker) {
        guard model.canEdit, let window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(nil)
        let snapshot=model.inputIdentity,identity=UUID();pickerID=identity
        let panel = NSOpenPanel(); self.panel = panel; model.picking = true
        panel.canChooseFiles = kind == .key; panel.canChooseDirectories = kind != .key
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = kind == .path
        panel.directoryURL = kind == .path ? model.repository.root : nil
        panel.prompt = kind == .key ? "Select OpenSSH key" : "Select folder"
        presentOpenPanel(panel,window) { [weak self, weak panel] response in
            guard let self,let panel,self.pickerID==identity,self.panel === panel else { return }
            self.panel = nil; self.model.picking = false
            if response == .OK,self.model.inputIdentity.elementsEqual(snapshot,by:{$0.utf16.elementsEqual($1.utf16)}),let url=self.selectedPanelURL(panel) {self.model.acceptSelection(url,kind:kind)}
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.activeOperation && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        model.invalidate();pickerID=UUID();let owned=panel;panel=nil;model.picking=false
        if let owned {owned.sheetParent?.endSheet(owned,returnCode:.cancel);owned.orderOut(nil);owned.cancel(nil)}
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
    @Published private(set) var sources: [String]
    @Published private(set) var paths: [String]
    @Published private(set) var keys: [String]
    var identities = SSHIdentityAccessStore()
    var makeSSHCoordinator: SSHCloneTransportFactory?
    var pick: (Picker) -> Void = { _ in }
    var close: () -> Void = {}
    var onSubmit: ((SubmoduleAddProgressWindowModel) -> Void)?
    var sshAvailable: Bool { makeSSHCoordinator != nil || (try? SSHAgentRuntime.resolve())?.askpass != nil }
    var activeOperation: Bool { picking || confirmingQuit }
    var canEdit:Bool {!activeOperation && !invalidated && !submitted}
    var inputIdentity:[String] {[source,path,key,branch,String(useBranch),String(force),String(useKey)]}
    var canApply: Bool {canEdit && onSubmit != nil}
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, preferences: UserDefaults = .standard,clipboardText:String? = nil) {
        self.repository = repository; self.access = access; self.preferences = preferences; basePath = path == "." ? "" : path
        let savedSources=FetchDialogHistory.load(preferences,key:"SubmoduleAdd.URLHistory",caseSensitive:true)
        sources=savedSources
        paths = FetchDialogHistory.load(preferences,key:"SubmoduleAdd.PathHistory",caseSensitive:true)
        keys = FetchDialogHistory.load(preferences,key:"Clone.KeyHistory",caseSensitive:true)
        source = clipboardText.flatMap(FetchClipboardInput.cloneSource) ?? savedSources.first ?? ""; self.path = basePath; key = keys.first ?? ""; useKey = sshAvailable
    }
    func sourceEndedEditing() {
        guard !activeOperation, !invalidated, !submitted else { return }
        let name=SubmoduleAddOptions.moduleName(from:source)
        path=basePath.isEmpty ? name:basePath + "/" + name
    }
    func deleteHistory(_ kind:Picker,at index:Int) {
        guard canEdit else {return}
        let field:String,entries:[String]
        switch kind {case .repository:field="SubmoduleAdd.URLHistory";entries=sources;case .path:field="SubmoduleAdd.PathHistory";entries=paths;case .key:field="Clone.KeyHistory";entries=keys}
        guard let result=FetchDialogHistory.removing(index,entries:entries,preferences:preferences,key:field) else {return}
        switch kind {case .repository:sources=result.entries;source=result.selection;case .path:paths=result.entries;path=result.selection;case .key:keys=result.entries;key=result.selection}
    }
    func acceptSelection(_ url: URL, kind: Picker) {
        guard !activeOperation, !invalidated, !submitted else { return }
        do {
            switch kind {
            case .repository: sourceAccess = RepositoryAccessLease(url: url); source = url.path
            case .path:
                var options = SubmoduleAddOptions(); options.path = url.path
                var selected = url.standardizedFileURL.path == repository.root.path ? "" : try options.relativePath(root: repository.root)
                let component=SubmoduleAddOptions.moduleName(from:source)
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
    private func saveHistory(_ field:String,_ value:String) {
        let current=field=="SubmoduleAdd.URLHistory" ? sources:field=="SubmoduleAdd.PathHistory" ? paths:keys
        let result=FetchDialogHistory.save(value,entries:current,preferences:preferences,key:field,caseSensitive:true)
        switch field {case "SubmoduleAdd.URLHistory":sources=result;case "SubmoduleAdd.PathHistory":paths=result;default:keys=result}
    }
}

private struct SubmoduleAddDialog: View {
    @ObservedObject var model: SubmoduleAddWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Submodule of Project: " + model.repository.root.path) {
                VStack(spacing: 12) {
                    HStack { Text("Repository:").frame(width: 80, alignment: .leading); CloneHistoryCombo(value: $model.source, choices: model.sources, label: "Submodule repository", onEndEditing: { model.sourceEndedEditing() },onDelete:{model.deleteHistory(.repository,at:$0)}); Button("…") { model.pick(.repository) } }
                    HStack { Text("Path:").frame(width: 80, alignment: .leading); CloneHistoryCombo(value: $model.path, choices: model.paths, label: "Submodule path",onDelete:{model.deleteHistory(.path,at:$0)}); Button("…") { model.pick(.path) } }
                }.padding(8)
            }
            HStack { Toggle("Branch", isOn: $model.useBranch).frame(width: 100, alignment: .leading); if model.useBranch { TextField("Branch", text: $model.branch) }; Spacer(minLength: 0) }
            Toggle("Force", isOn: $model.force)
            HStack { Toggle("Auto-load SSH key", isOn: $model.useKey).disabled(!model.sshAvailable); CloneHistoryCombo(value: $model.key, choices: model.keys, label: "OpenSSH private key",onDelete:{model.deleteHistory(.key,at:$0)}).disabled(!model.useKey); Button("…") { model.pick(.key) }.disabled(!model.useKey) }
            HStack { Spacer(); Button("OK") { model.apply() }.keyboardShortcut(.defaultAction).disabled(!model.canApply); Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction); Button { TurtleGitHelp.show(.submodules) } label: { CommandLabel(title: "Help", icon: .help) } }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(12).disabled(model.picking || model.confirmingQuit)
    }
}
