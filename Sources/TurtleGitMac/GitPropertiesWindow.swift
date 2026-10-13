// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

struct GitPropertiesContext {
    let repository: GitRepository, paths: [String], access: RepositoryAccessLease?
    let submodule: Bool
}
@MainActor final class GitPropertiesWindowModel: ObservableObject {
    static private(set) var activeOperations = 0
    @Published private(set) var contexts: [GitPropertiesContext]
    @Published private(set) var snapshots: [GitPropertySnapshot?] = []
    @Published var drafts: [GitPropertyDraft] = []
    @Published var selected = 0
    @Published private(set) var busy = false
    @Published private(set) var cancelling = false
    @Published var hasSettings = false
    @Published var error: String?
    private(set) var retired = false
    private let preferences: UserDefaults
    private var generation = 0
    private var task: Task<Void,Never>?
    private var cancellation: OperationCancellation?
    var close: () -> Void = {}
    var onChanged: (GitRepository) -> Void = { _ in }
    var onLog: (GitPropertiesContext) -> Void = { _ in }
    var onSettings: (GitPropertiesContext) -> Void = { _ in }
    init(contexts: [GitPropertiesContext], preferences: UserDefaults = .standard) { self.preferences = preferences; self.contexts = contexts; snapshots = contexts.map { _ in nil }; drafts = contexts.map { _ in GitPropertyDraft() } }
    var current: GitPropertySnapshot? { snapshots.indices.contains(selected) ? snapshots[selected] : nil }
    var draft: GitPropertyDraft { drafts.indices.contains(selected) ? drafts[selected] : GitPropertyDraft() }
    var changed: Bool { snapshots.indices.contains { index in snapshots[index].map { $0.allVersioned && drafts[index] != $0.draft } ?? false } }
    var canInteract: Bool { !retired && !busy && !hasSettings && error == nil }
    func date(_ date:Date) -> String {
        if date.timeIntervalSince1970 == 0 { return "" }
        let settings = HistoryDateSettings(shortDate:(preferences.object(forKey:"LogDateFormat") as? NSNumber)?.boolValue ?? false,relative:false,useSystemLocale:(preferences.object(forKey:"UseSystemLocaleForDates") as? NSNumber)?.boolValue ?? true)
        return settings.format(ISO8601DateFormatter().string(from:date),absolute:true)
    }
    var canApply: Bool { canInteract && changed }
    func set(_ key: WritableKeyPath<GitPropertyDraft,GitPropertyState>, _ value: GitPropertyState) {
        guard canInteract, current?.allVersioned == true else { return }
        if current?.hasSubmodule == true && (key == \GitPropertyDraft.executable || key == \GitPropertyDraft.symlink) { return }
        var next = draft; next[keyPath:key] = value
        if key == \GitPropertyDraft.executable && value == .on { next.symlink = .off }
        if key == \GitPropertyDraft.symlink && value == .on { next.executable = .off }
        drafts[selected] = next
    }
    func load() {
        guard !retired, !busy, !hasSettings else { return }
        generation += 1; let request = generation, token = OperationCancellation()
        cancellation = token; busy = true; error = nil; Self.activeOperations += 1
        task = Task {
            defer { Self.activeOperations -= 1; busy = false; cancelling = false; cancellation = nil; task = nil }
            do {
                var index = 0
                while index < contexts.count {
                    let context = contexts[index]
                    let snapshot = try await context.repository.gitProperties(paths:context.paths,cancellation:token)
                    guard !retired, request == generation, !token.isCancelled else { return }
                    snapshots[index] = snapshot; drafts[index] = snapshot.draft
                    // The Windows shell adds a second Git page for an initialized
                    // submodule. Only inspect an index-declared child inside the
                    // captured grant, never an arbitrary selected directory.
                    if context.paths.count == 1, snapshot.hasSubmodule, let entry = snapshot.entries.first {
                        let child = context.repository.root.appendingPathComponent(entry.path)
                        if (context.access?.contains(child) ?? !GitRuntime.isAppStoreBuild), !contexts.contains(where:{ $0.repository.root.standardizedFileURL == child.standardizedFileURL }) {
                            let repo = GitRepository(root:child,executable:context.repository.executable)
                            if let discovered = try? await repo.discoverRoot(cancellation:token), !retired, request == generation, !token.isCancelled, discovered.standardizedFileURL == child.standardizedFileURL {
                                contexts.append(GitPropertiesContext(repository:repo,paths:["."],access:context.access,submodule:false)); snapshots.append(nil); drafts.append(GitPropertyDraft())
                            }
                        }
                    }
                    index += 1
                }
            } catch { if !retired && !token.isCancelled && request == generation { self.error = error.localizedDescription } }
        }
    }
    func apply(closeAfter: Bool = false) {
        guard canInteract else { return }
        let changes = snapshots.indices.compactMap { index -> (GitPropertiesContext,GitPropertySnapshot,GitPropertyDraft)? in
            guard let snapshot = snapshots[index], snapshot.allVersioned, drafts[index] != snapshot.draft else { return nil }
            return (contexts[index],snapshot,drafts[index])
        }
        if changes.isEmpty { if closeAfter { close() }; return }
        let token = OperationCancellation(); cancellation = token; busy = true; Self.activeOperations += 1
        task = Task {
            var successful = false
            defer {
                Self.activeOperations -= 1; busy = false; cancelling = false; cancellation = nil; task = nil
                if !retired && successful { if closeAfter { close() } else { load() } }
            }
            do {
                for (context,snapshot,draft) in changes {
                    let updated = try await context.repository.applyGitProperties(draft,snapshot:snapshot,cancellation:token)
                    // Refresh live owners after a completed write, even when the
                    // property window was forced closed during the operation.
                    onChanged(context.repository)
                    if !retired, let index = contexts.firstIndex(where:{ $0.repository.root == context.repository.root }) {
                        snapshots[index] = updated; drafts[index] = updated.draft
                    }
                }
                successful = true
            } catch { if !retired { self.error = token.isCancelled ? "Operation cancelled." : error.localizedDescription } }
        }
    }
    func cancelOperation() { guard busy, !cancelling else { return }; cancelling = true; cancellation?.cancel(); task?.cancel() }
    func showLog() { guard canInteract else { return }; onLog(contexts[selected]) }
    func showSettings() { guard canInteract else { return }; onSettings(contexts[selected]) }
    func retire() {
        guard !retired else { return }; retired = true; generation += 1; cancellation?.cancel(); task?.cancel()
        close = {}; onLog = { _ in }; onSettings = { _ in }
    }
}
@MainActor final class GitPropertiesWindowController: NSWindowController, NSWindowDelegate {
    let model: GitPropertiesWindowModel
    var onClosed: () -> Void = {}
    private var settings: (window:NSWindow, navigation:SettingsNavigationController, workspace:RepositoryModel)?
    private var settingsObserver: NSObjectProtocol?
    init(contexts: [GitPropertiesContext], preferences: UserDefaults = .standard) {
        model = GitPropertiesWindowModel(contexts:contexts,preferences:preferences)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:680),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        let paths = contexts[0].paths
        let label = paths.count == 1 && paths[0] != "." ? paths[0] : paths.count > 1 ? "\(paths.count) items" : contexts[0].repository.root.lastPathComponent
        window.title = label + " – Git Properties – TurtleGit"
        window.minSize = NSSize(width:580,height:650); window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView:GitPropertiesDialog(model:model)); host.sizingOptions = []; window.contentViewController = host
        super.init(window:window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.close() }
        model.onSettings = { [weak self] in self?.showSettings($0) }
        DialogGeometry.attach(window,identifier:"GitPropertiesWindowController")
        model.load()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender:NSWindow) -> Bool { !model.busy && !model.hasSettings && sender.attachedSheet == nil }
    func windowWillClose(_ notification:Notification) {
        model.retire()
        if let child = settings { child.navigation.invalidate(); window?.endSheet(child.window); child.window.close() }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }; settingsObserver = nil; settings = nil
        onClosed()
    }
    private func showSettings(_ context:GitPropertiesContext) {
        guard model.canInteract, settings == nil, let window, window.attachedSheet == nil else { return }
        let workspace = RepositoryModel(startMonitoring:false,initializePreferences:false)
        workspace.root = context.repository.root
        workspace.settingsContextOverride = (context.repository,context.access,true)
        let navigation = SettingsNavigationController(workspace:workspace,appearance:AppAppearance())
        let child = NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        child.title = "Settings – " + context.repository.root.lastPathComponent; child.isReleasedWhenClosed = false; child.contentViewController = navigation
        settings = (child,navigation,workspace); model.hasSettings = true
        settingsObserver = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:child,queue:.main) { [weak self,weak child] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings?.window === child else { return }
                if let child { self.window?.endSheet(child); child.orderOut(nil) }
                self.settings?.navigation.invalidate(); self.settings = nil; self.model.hasSettings = false
                if let token = self.settingsObserver { NotificationCenter.default.removeObserver(token) }; self.settingsObserver = nil
            }
        }
        window.beginSheet(child)
    }
}
private struct GitPropertiesDialog: View {
    @ObservedObject var model: GitPropertiesWindowModel
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            if model.contexts.count > 1 {
                Picker("Repository",selection:$model.selected) {
                    ForEach(model.contexts.indices,id:\.self) { index in Text(model.contexts[index].submodule || model.snapshots[index]?.hasSubmodule == true ? "Git Submodule" : "Git").tag(index) }
                }.pickerStyle(.segmented).disabled(!model.canInteract)
            }
            if let info = model.current {
                field("Current Branch:",info.branch)
                field("Tracked Remote Branch:",info.trackedBranch)
                field("Tracked Remote URL:",info.trackedURL)
                Divider(); commit("HEAD:",info.head)
                if info.paths.count == 1 && info.allVersioned { Divider(); commit("Last Modified:",info.lastModified) }
                if info.allVersioned {
                    HStack {
                        property("Assume valid/unchanged",\GitPropertyDraft.assumeUnchanged)
                        if !info.hasSubmodule { property("Executable (+x)",\GitPropertyDraft.executable,enabled:model.draft.symlink != .on) }
                    }
                    HStack {
                        property("Skip worktree",\GitPropertyDraft.skipWorktree)
                        if !info.hasSubmodule { property("Symlink",\GitPropertyDraft.symlink,enabled:model.draft.executable != .on) }
                    }
                }
                GroupBox("Config") { VStack(spacing:6) {
                    field("AutoCrLf:",info.autoCRLF); field("SafeCrLf:",info.safeCRLF)
                    field("User Name:",info.userName); field("User Email:",info.userEmail)
                }.padding(5) }
            }
            Spacer(minLength:0)
            if model.busy { HStack { ProgressView(model.cancelling ? "Cancelling…" : "Loading/saving properties…").controlSize(.small); Button("Cancel operation") { model.cancelOperation() }.disabled(model.cancelling) } }
            HStack {
                Button { model.showSettings() } label: { CommandLabel(title:"Settings",icon:.settings) }
                Button { model.showLog() } label: { CommandLabel(title:"Show log",icon:.log) }
                Spacer(); Button("Refresh") { model.load() }
            }.disabled(!model.canInteract)
            Divider()
            HStack { Spacer()
                Button("OK") { model.apply(closeAfter:true) }.keyboardShortcut(.defaultAction).disabled(!model.canInteract)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction).disabled(model.busy || model.hasSettings)
                Button("Apply") { model.apply() }.disabled(!model.canApply)
            }
        }.padding(16)
        .alert("Git Properties",isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private func field(_ label:String,_ value:String) -> some View { HStack { Text(label).frame(width:168,alignment:.leading); GitPropertyReadOnlyField(value:value) }.frame(height:18) }
    private func commit(_ label:String,_ info:GitPropertyCommit?) -> some View {
        VStack(spacing:4) {
            field(label,info?.hash ?? ""); field("",info?.subject ?? ""); field("",info?.author ?? "")
            field("",info.map { model.date($0.authorDate) } ?? "")
        }
    }
    private func property(_ label:String,_ key:WritableKeyPath<GitPropertyDraft,GitPropertyState>,enabled:Bool = true) -> some View {
        GitPropertyCheckbox(title:label,state:model.draft[keyPath:key],allowsMixed:model.current?.draft[keyPath:key] == .mixed,enabled:enabled && model.canInteract) { model.set(key,$0) }.frame(maxWidth:.infinity,alignment:.leading).frame(height:18)
    }
}
private struct GitPropertyReadOnlyField: NSViewRepresentable {
    let value:String
    func makeNSView(context:Context) -> NSTextField { let field = NSTextField(); field.isEditable = false; field.isSelectable = true; field.isBordered = false; field.drawsBackground = false; field.font = .systemFont(ofSize:12); field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal); return field }
    func updateNSView(_ field:NSTextField,context:Context) { field.stringValue = value }
}
private struct GitPropertyCheckbox: NSViewRepresentable {
    let title:String,state:GitPropertyState,allowsMixed:Bool,enabled:Bool,change:(GitPropertyState)->Void
    func makeCoordinator() -> Coordinator { Coordinator(change:change) }
    func makeNSView(context:Context) -> NSButton { let button = NSButton(checkboxWithTitle:title,target:context.coordinator,action:#selector(Coordinator.clicked)); button.allowsMixedState = allowsMixed; return button }
    func updateNSView(_ button:NSButton,context:Context) { context.coordinator.change = change; button.allowsMixedState = allowsMixed; button.title = title; button.isEnabled = enabled; button.state = state == .mixed ? .mixed : state == .on ? .on : .off }
    final class Coordinator:NSObject { var change:(GitPropertyState)->Void; init(change:@escaping(GitPropertyState)->Void) { self.change = change }; @objc func clicked(_ button:NSButton) { change(button.state == .mixed ? .mixed : button.state == .on ? .on : .off) } }
}
