// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of SettingsBugtraqConfig.cpp/.h.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class IssueTrackerSettingsModel: ObservableObject {
    private(set) static var activeSaves = 0
    @Published private(set) var hasTester = false
    private var tester: IssueRegexTesterController?
    var authorizeFile: ((URL) async -> Bool)?
    var confirmSavingTo: ((ProjectDialogSettingsSource) async -> Bool)?
    var presentTester: ((IssueRegexTesterController, NSWindow) -> Bool)?
    var regexExecutable: URL?
    @Published private(set) var source: ProjectDialogSettingsSource = .effective
    @Published var destination: ProjectDialogSettingsSource = .local
    @Published var draft = IssueTrackerSettings()
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var error: String?
    private var saved = IssueTrackerSettings(), savedDestination: ProjectDialogSettingsSource = .local
    private var repository: GitRepository?, access: RepositoryAccessLease?
    private(set) var localAvailable = false, bare = false, active = false
    private var saving = false, invalidated = false
    private var request = UUID(), token: OperationCancellation?
    private var panel: NSOpenPanel?, alert: NSAlert?
    private var answer: ((Bool) -> Void)?
    weak var window: NSWindow?
    var editable: Bool { loaded && source != .effective && !busy && !hasTester }
    var modified: Bool { loaded && (draft != saved || destination != savedDestination) }
    func activate(repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool) {
        guard !invalidated, !saving else { return }
        if loaded && self.repository?.root == repository.root && self.repository?.executable == repository.executable && self.localAvailable == localAvailable { active = true; return }
        suspend(); self.repository = repository; self.access = access; self.localAvailable = localAvailable
        destination = localAvailable ? .local : .global; active = true; load(.effective)
    }
    func suspend() {
        active = false; request = UUID(); token?.cancel(); token = nil
        if !saving { busy = false }
        if let tester { tester.close() }; tester = nil; hasTester = false
        if let panel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        if let alert { window?.endSheet(alert.window, returnCode: .abort) }; alert = nil
        let reply = answer; answer = nil; reply?(false)
    }
    func invalidate() { invalidated = true; suspend() }
    private func checkAccess(_ repository: GitRepository) throws {
        if GitRuntime.isAppStoreBuild && localAvailable && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func permit(_ file: URL) async -> Bool {
        if let authorizeFile { return await authorizeFile(file) }
        if GitConfigurationPermissions.authorized(file) || (access?.hasSecurityScope == true && access?.contains(file) == true) { return true }
        guard active, !invalidated, let window, window.attachedSheet == nil else { return false }
        let chooser = NSOpenPanel(); chooser.canChooseFiles = false; chooser.canChooseDirectories = true; chooser.canCreateDirectories = true
        chooser.title = "Authorize project settings configuration"; chooser.prompt = "Authorize"
        chooser.message = "Select the folder containing " + file.path + ". Git creates an adjacent lock file when saving."
        chooser.directoryURL = file.deletingLastPathComponent(); panel = chooser
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            answer = reply
            chooser.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.panel === chooser else { reply(false); return }
                self.panel = nil; self.answer = nil
                guard response == .OK, self.active, !self.invalidated, let directory = chooser.url else { reply(false); return }
                do { try GitConfigurationPermissions.remember(directory, for: file); reply(true) }
                catch { self.error = error.localizedDescription; reply(false) }
            }
        }
    }
    func load(_ source: ProjectDialogSettingsSource) {
        guard active, !saving, !hasTester, !invalidated, let repository, source != .local && source != .project || localAvailable else { return }
        token?.cancel(); let cancellation = OperationCancellation(), generation = UUID(); token = cancellation; request = generation
        self.source = source; loaded = false; busy = true; error = nil
        if [.local, .project, .global].contains(source) { destination = source }
        Task { [self, access] in
            defer { if request == generation { token = nil; busy = false } }
            do {
                try checkAccess(repository)
                let files = try await repository.gitConfigurationFiles(hasRepository: localAvailable, cancellation: cancellation)
                guard active, !invalidated, request == generation, !cancellation.isCancelled else { return }
                bare = files.bare
                if source == .effective || source == .global {
                    for file in [files.global, files.xdg].compactMap({ $0 }) {
                        guard await permit(file), active, !invalidated, request == generation, !cancellation.isCancelled else { return }
                    }
                }
                let value = try await repository.issueTrackerSettings(source: source, hasRepository: localAvailable, cancellation: cancellation)
                guard active, !invalidated, request == generation, !cancellation.isCancelled else { return }
                draft = value; saved = value; savedDestination = destination; loaded = true
                withExtendedLifetime(access) {}
            } catch { if active, !invalidated, request == generation, !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    var validationError: String? {
        if busy || hasTester { return "Finish the issue-tracker operation first." }
        return draft.valid ? nil : "Configuration values cannot contain NUL characters."
    }
    private func confirmDestination() async -> Bool {
        if source == destination { return true }
        if let confirmSavingTo { return await confirmSavingTo(destination) }
        guard let window, window.attachedSheet == nil else { return false }
        let question = NSAlert(); question.messageText = "Are you sure you want to save to \"\(destination.rawValue)\"?"
        question.informativeText = "The selected config source differs from the save destination."
        question.addButton(withTitle: "Abort"); question.addButton(withTitle: "Save"); alert = question
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            answer = reply
            question.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.alert === question else { reply(false); return }
                self.alert = nil; self.answer = nil; reply(response == .alertSecondButtonReturn && !self.invalidated && self.active)
            }
        }
    }
    func apply(owner: NSWindow?) async -> Bool {
        guard !invalidated, !hasTester else { return false }; if !modified { return true }
        guard loaded, source != .effective, !busy, validationError == nil, let repository else { return false }
        let wasActive = active; active = true; if window == nil { window = owner }
        let generation = request, settings = draft, destination = destination, grant = access
        busy = true; saving = true; error = nil; Self.activeSaves += 1
        defer { saving = false; busy = false; Self.activeSaves -= 1; if request == generation { active = wasActive }; withExtendedLifetime(grant) {} }
        do {
            guard await confirmDestination(), !invalidated, request == generation else { return false }
            try checkAccess(repository)
            if destination == .global {
                let files = try await repository.gitConfigurationFiles(hasRepository: localAvailable)
                for file in [files.global, files.xdg].compactMap({ $0 }) {
                    guard await permit(file), !invalidated, request == generation else { return false }
                }
            }
            // Allow source-ordered locked writes to finish after forced closure.
            try await repository.saveIssueTrackerSettings(settings, destination: destination, hasRepository: localAvailable)
            guard !invalidated, request == generation else { return false }
            saved = settings; savedDestination = destination; return true
        } catch { if !invalidated, request == generation { self.error = error.localizedDescription }; return false }
    }
    func cancel() { guard !saving else { return }; draft = saved; destination = savedDestination }
    func testRegex() {
        guard active, editable, draft.fields[.regex]?.inherit == false, let window, window.attachedSheet == nil else { return }
        let parts = draft.regexParts, generation = request
        let controller = IssueRegexTesterController(model: IssueRegexTesterModel(check:parts.check,extract:parts.extract,executable:regexExecutable))
        tester = controller; hasTester = true
        controller.completed = { [weak self, weak controller] value in
            guard let self, let controller, self.tester === controller else { return }
            if let child = controller.window, let parent = child.sheetParent { parent.endSheet(child) }
            self.tester = nil; self.hasTester = false
            guard self.active, !self.invalidated, self.request == generation, let value else { return }
            self.draft.fields[.regex] = GitConfigurationIdentity(value:(value.0 + "\n" + value.1).trimmingCharacters(in:.whitespacesAndNewlines),inherit:false)
        }
        if let presentTester { if !presentTester(controller,window) { controller.finish(accept:false) } }
        else if let child = controller.window { window.beginSheet(child,completionHandler:nil) }
    }
}

@MainActor struct IssueTrackerSettingsPage: View {
    @ObservedObject var workspace: RepositoryModel
    var globalOnly = false
    @StateObject private var model: IssueTrackerSettingsModel
    private let contextProvider: (() throws -> (repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool))?
    init(workspace: RepositoryModel, globalOnly: Bool = false, model: IssueTrackerSettingsModel? = nil, contextProvider: (() throws -> (repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool))? = nil) {
        self.workspace = workspace; self.globalOnly = globalOnly; self.contextProvider = contextProvider
        _model = StateObject(wrappedValue: model ?? IssueTrackerSettingsModel())
    }
    @Environment(\.settingsTransaction) private var transaction
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                GroupBox("Config source") {
                    Picker("Config source",selection:Binding(get:{model.source},set:model.load)) {
                        ForEach(ProjectDialogSettingsSource.allCases,id:\.self) { source in Text(source.rawValue).tag(source).disabled((source == .local || source == .project) && !model.localAvailable) }
                    }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().padding(8).disabled(model.busy || model.hasTester)
                }
                GroupBox("BugTraq") {
                    VStack(alignment:.leading,spacing:10) {
                        field(.url);boolean("bugtraq.warningifnoissue",value:$model.draft.warnIfNoIssue)
                        field(.message);boolean("bugtraq.append",value:$model.draft.append)
                        field(.label);boolean("bugtraq.number",value:$model.draft.number)
                        HStack(alignment:.top) { Text("bugtraq.logregex").frame(width:180,alignment:.leading); TextEditor(text:text(.regex)).font(.system(.body,design:.monospaced)).frame(height:66).border(Color.secondary.opacity(0.3)).accessibilityLabel("bugtraq.logregex").disabled(!model.editable || identity(.regex).inherit) }
                        HStack { Spacer().frame(width:180);Toggle("inherit",isOn:inherit(.regex)).disabled(!model.editable);Spacer();Button("Test",action:model.testRegex).disabled(!model.editable || identity(.regex).inherit) }
                    }.padding(8)
                }
                GroupBox("IBugTraqProvider") {
                    VStack(alignment:.leading,spacing:10) {field(.provider32,title:"Provider uuid win32:");field(.provider64,title:"Provider uuid x64:");field(.parameters,title:"Provider parameters:")
                        Text("Windows provider IDs are preserved for shared repositories. Native tracker providers are not yet available.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                HStack { Text("Save to:");Picker("Save to",selection:$model.destination) {
                    if model.localAvailable {Text("Local").tag(ProjectDialogSettingsSource.local);if !model.bare {Text("Project").tag(ProjectDialogSettingsSource.project)}}
                    Text("Global").tag(ProjectDialogSettingsSource.global)
                }.labelsHidden().frame(width:200).disabled(!model.editable) }
                if let error=model.error {Text(error).foregroundStyle(.red).textSelection(.enabled)}
                if model.busy {ProgressView().controlSize(.small)}
            }.padding(20)
        }.background(IssueTrackerWindowProbe(model:model).frame(width:0,height:0))
        .settingsParticipant("issueTracker",page:.issueTracker,value:model.draft,modified:{model.modified},validate:{model.validationError},apply:{await model.apply(owner:transaction?.window)},cancel:model.cancel)
        .onChange(of:model.destination){_ in transaction?.notify()}.onChange(of:model.busy){_ in transaction?.notify()}.onChange(of:model.hasTester){_ in transaction?.notify()}
        .onAppear(perform:activate).onDisappear{model.suspend()}
        .onChange(of:workspace.root){_ in if model.active {activate()}}
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.willCloseNotification)){notification in if let window=notification.object as? NSWindow,window === model.window {model.invalidate()} }
    }
    private func activate() {do {let context=try contextProvider?() ?? workspace.gitConfigurationContext(globalOnly:globalOnly);model.activate(repository:context.repository,access:context.access,localAvailable:context.localAvailable)}catch{model.error=error.localizedDescription}}
    private func identity(_ key:IssueTrackerStringKey)->GitConfigurationIdentity {model.draft.fields[key] ?? GitConfigurationIdentity()}
    private func text(_ key:IssueTrackerStringKey)->Binding<String> {Binding(get:{identity(key).value},set:{var value=identity(key);value.value=$0;model.draft.fields[key]=value})}
    private func inherit(_ key:IssueTrackerStringKey)->Binding<Bool> {Binding(get:{identity(key).inherit},set:{var value=identity(key);value.inherit=$0;model.draft.fields[key]=value})}
    private func field(_ key:IssueTrackerStringKey,title:String?=nil)->some View {HStack{Text(title ?? key.rawValue).frame(width:180,alignment:.leading);TextField("",text:text(key)).accessibilityLabel(title ?? key.rawValue).disabled(!model.editable || identity(key).inherit);Toggle("inherit",isOn:inherit(key)).disabled(!model.editable)}}
    private func boolean(_ title:String,value:Binding<GitConfigurationBoolean>)->some View {HStack{Text(title).frame(width:180,alignment:.leading);Picker(title,selection:value){ForEach(GitConfigurationBoolean.allCases,id:\.self){Text($0.rawValue.isEmpty ? " ":$0.rawValue).tag($0)}}.labelsHidden().frame(width:120).disabled(!model.editable);Spacer()}}
}
private struct IssueTrackerWindowProbe:NSViewRepresentable {
    let model:IssueTrackerSettingsModel
    func makeNSView(context:Context)->Probe {let view=Probe();view.model=model;return view}
    func updateNSView(_ view:Probe,context:Context){model.window=view.window}
    final class Probe:NSView {weak var model:IssueTrackerSettingsModel?;override func viewDidMoveToWindow(){super.viewDidMoveToWindow();model?.window=window}}
}
