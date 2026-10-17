// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of SettingsBugtraqConfig.cpp/.h.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class IssueTrackerSettingsModel: ObservableObject {
    private(set) static var activeReads = 0
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    var readConfigurationFiles: (GitRepository, Bool, OperationCancellation?) async throws -> GitConfigurationFiles = { try await $0.gitConfigurationFiles(hasRepository: $1, cancellation: $2) }
    var writeSettings: (GitRepository, IssueTrackerSettings, ProjectDialogSettingsSource, Bool) async throws -> Void = { try await $0.saveIssueTrackerSettings($1, destination: $2, hasRepository: $3) }

    private(set) static var activeSaves = 0
    @Published private(set) var hasTester = false
    private(set) var tester: IssueRegexTesterController?
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
    private(set) var localAvailable = false, bare = false
    @Published private(set) var active = false
    @Published private(set) var editRevision = UUID()
    private var ownerObserver: NSObjectProtocol?
    private var saving = false, invalidated = false
    private var request = UUID(), token: OperationCancellation?
    private var panel: NSOpenPanel?, alert: NSAlert?
    private var answer: ((Bool) -> Void)?
    weak var window: NSWindow?
    struct EditContext: Equatable { let owner: ObjectIdentifier; let revision: UUID; let request: UUID; let source: ProjectDialogSettingsSource }
    var editContext: EditContext { .init(owner: ObjectIdentifier(self), revision: editRevision, request: request, source: source) }
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
    func attach(to owner: NSWindow?) {
        guard !invalidated, let owner else { return }; guard window !== owner || ownerObserver == nil else { return }
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }
        window = owner; editRevision = UUID()
        ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } }
    }
    private static func same(_ a: IssueTrackerSettings, _ b: IssueTrackerSettings) -> Bool {
        a.append == b.append && a.number == b.number && a.warnIfNoIssue == b.warnIfNoIssue && IssueTrackerStringKey.allCases.allSatisfy {
            let x = a.fields[$0] ?? GitConfigurationIdentity(), y = b.fields[$0] ?? GitConfigurationIdentity()
            return x.inherit == y.inherit && x.value.utf8.elementsEqual(y.value.utf8)
        }
    }
    struct State: Equatable {
        let strings: [Data]; let append: GitConfigurationBoolean, number: GitConfigurationBoolean, warning: GitConfigurationBoolean
        let destination: ProjectDialogSettingsSource
    }
    var state: State { .init(strings: IssueTrackerStringKey.allCases.flatMap { key in let field = draft.fields[key] ?? GitConfigurationIdentity(); return [Data([field.inherit ? 1 : 0]), Data(field.value.utf8)] }, append: draft.append, number: draft.number, warning: draft.warnIfNoIssue, destination: destination) }
    func accepts(_ context: EditContext) -> Bool { active && !invalidated && editable && context == editContext }
    func fieldBinding(_ key: IssueTrackerStringKey, context: EditContext) -> Binding<String> {
        Binding(get: { self.draft.fields[key]?.value ?? "" }, set: {
            guard self.accepts(context), self.draft.fields[key]?.inherit == false else { return }
            self.draft.fields[key]?.value = $0
        })
    }
    func inheritBinding(_ key: IssueTrackerStringKey, context: EditContext) -> Binding<Bool> {
        Binding(get: { self.draft.fields[key]?.inherit ?? true }, set: {
            guard self.accepts(context) else { return }; self.draft.fields[key, default: GitConfigurationIdentity()].inherit = $0; self.editRevision = UUID()
        })
    }
    func booleanBinding(_ key: WritableKeyPath<IssueTrackerSettings,GitConfigurationBoolean>, context: EditContext) -> Binding<GitConfigurationBoolean> {
        Binding(get: { self.draft[keyPath: key] }, set: { if self.accepts(context) { self.draft[keyPath: key] = $0 } })
    }
    func destinationBinding(context: EditContext) -> Binding<ProjectDialogSettingsSource> {
        Binding(get: { self.destination }, set: {
            guard self.accepts(context), $0 == .global || self.localAvailable && ($0 == .local || $0 == .project && !self.bare) else { return }; self.destination = $0; self.editRevision = UUID()
        })
    }
    func chooseSource(_ source: ProjectDialogSettingsSource, context: EditContext) {
        guard active, !invalidated, !busy, !hasTester, context == editContext else { return }; load(source)
    }
    var editable: Bool { active && !invalidated && loaded && source != .effective && !busy && !hasTester }
    var modified: Bool { loaded && (!Self.same(draft,saved) || destination != savedDestination) }
    func activate(repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool) {
        guard !invalidated, !saving else { return }
        if loaded && self.repository?.root == repository.root && self.repository?.executable == repository.executable && self.localAvailable == localAvailable { active = true; editRevision = UUID(); return }
        suspend(); self.repository = repository; self.access = access; self.localAvailable = localAvailable
        destination = localAvailable ? .local : .global; active = true; load(.effective)
    }
    func suspend() {
        active = false; editRevision = UUID(); request = UUID(); token?.cancel(); token = nil
        if !saving { busy = false }
        if let tester { tester.close() }; tester = nil; hasTester = false
        if let panel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        if let alert { window?.endSheet(alert.window, returnCode: .abort) }; alert = nil
        let reply = answer; answer = nil; reply?(false)
    }
    func invalidate() { guard !invalidated else { return }; invalidated = true; suspend() }
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
        self.source = source; editRevision = UUID(); loaded = false; busy = true; error = nil
        if [.local, .project, .global].contains(source) { destination = source }
        Self.activeReads += 1
        Task { [self, access] in
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {}; if request == generation { token = nil; busy = false } }
            do {
                try checkAccess(repository)
                let files = try await readConfigurationFiles(repository, localAvailable, cancellation)
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
            } catch { if active, !invalidated, request == generation, !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    var validationError: String? {
        if busy || hasTester { return "Finish the issue-tracker operation first." }
        return draft.valid ? nil : "Configuration values cannot contain NUL characters."
    }
    private func confirmDestination(source: ProjectDialogSettingsSource, destination: ProjectDialogSettingsSource) async -> Bool {
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
        let generation = request, settings = draft, destination = destination, source = source, grant = access, local = localAvailable
        busy = true; saving = true; editRevision = UUID(); error = nil; Self.activeSaves += 1
        func current() -> Bool { !invalidated && request == generation && self.source == source && self.destination == destination && Self.same(draft,settings) }
        defer { saving = false; busy = false; Self.activeSaves -= 1; if request == generation { active = wasActive; editRevision = UUID() }; withExtendedLifetime(grant) {} }
        do {
            guard await confirmDestination(source: source, destination: destination), current() else { return false }
            try checkAccess(repository)
            if destination == .global {
                let files = try await repository.gitConfigurationFiles(hasRepository: localAvailable)
                for file in [files.global, files.xdg].compactMap({ $0 }) {
                    guard await permit(file), current() else { return false }
                }
            }
            guard current() else { return false }
            // Allow source-ordered locked writes to finish after forced closure.
            try await writeSettings(repository, settings, destination, local)
            guard !invalidated, request == generation else { return false }
            saved = settings; savedDestination = destination; return true
        } catch { if !invalidated, request == generation { self.error = error.localizedDescription }; return false }
    }
    func cancel() { guard !invalidated, !saving, !hasTester else { return }; draft = saved; destination = savedDestination; editRevision = UUID(); error = nil }
    func testRegex() { testRegex(context: editContext) }
    func testRegex(context: EditContext) {
        guard accepts(context), active, editable, draft.fields[.regex]?.inherit == false, let window, window.attachedSheet == nil else { return }
        let parts = draft.regexParts, generation = request, settings = draft, destination = destination, owner = window
        let controller = IssueRegexTesterController(model: IssueRegexTesterModel(check:parts.check,extract:parts.extract,executable:regexExecutable,preferences:preferences))
        tester = controller; hasTester = true
        controller.completed = { [weak self, weak controller] value in
            guard let self, let controller, self.tester === controller else { return }
            if let child = controller.window, let parent = child.sheetParent { parent.endSheet(child) }
            self.tester = nil; self.hasTester = false
            guard self.active, !self.invalidated, self.request == generation, self.window === owner, self.destination == destination, Self.same(self.draft,settings), let value else { return }
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
    init(workspace: RepositoryModel, globalOnly: Bool = false, model: IssueTrackerSettingsModel? = nil, contextProvider: (() throws -> (repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool))? = nil, preferences: UserDefaults = .standard) {
        self.workspace = workspace; self.globalOnly = globalOnly; self.contextProvider = contextProvider
        _model = StateObject(wrappedValue: model ?? IssueTrackerSettingsModel(preferences: preferences))
    }
    @Environment(\.settingsTransaction) private var transaction
    var body: some View {
        let context = model.editContext
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                GroupBox("Config source") {
                    let context = model.editContext
                    HStack(spacing: 6) {
                        ForEach(Array(ProjectDialogSettingsSource.allCases.enumerated()), id: \.element) { index, source in
                            if index > 0 { Text(index == 1 ? "|" : "<<").foregroundStyle(.secondary) }
                            BaseRadio(title: source.rawValue, selected: model.source == source) { model.chooseSource(source, context: context) }
                                .fixedSize().disabled(!model.active || model.busy || model.hasTester || (source == .local || source == .project) && !model.localAvailable)
                        }
                        Spacer(minLength: 0)
                    }.padding(8)
                }
                GroupBox("BugTraq") {
                    VStack(alignment:.leading,spacing:10) {
                        field(.url);boolean("bugtraq.warningifnoissue",value:model.booleanBinding(\.warnIfNoIssue,context:model.editContext))
                        field(.message);boolean("bugtraq.append",value:model.booleanBinding(\.append,context:model.editContext))
                        field(.label);boolean("bugtraq.number",value:model.booleanBinding(\.number,context:model.editContext))
                        HStack(alignment:.top) { Text("bugtraq.logregex").frame(width:180,alignment:.leading); TextEditor(text:text(.regex)).font(.system(.body,design:.monospaced)).frame(height:66).border(Color.secondary.opacity(0.3)).accessibilityLabel("bugtraq.logregex").disabled(!model.editable || identity(.regex).inherit) }
                        HStack { Spacer().frame(width:180);Toggle("inherit",isOn:inherit(.regex)).disabled(!model.editable);Spacer();Button("Test") { model.testRegex(context:context) }.disabled(!model.editable || identity(.regex).inherit) }
                    }.padding(8)
                }
                GroupBox("IBugTraqProvider") {
                    VStack(alignment:.leading,spacing:10) {field(.provider32,title:"Provider uuid win32:");field(.provider64,title:"Provider uuid x64:");field(.parameters,title:"Provider parameters:")
                        Text("Windows provider IDs are preserved for shared repositories. Configure native providers on the Issue Tracker Integration page. Windows COM providers require a native implementation.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                HStack { Text("Save to:");Picker("Save to",selection:model.destinationBinding(context:model.editContext)) {
                    if model.localAvailable {Text("Local").tag(ProjectDialogSettingsSource.local);if !model.bare {Text("Project").tag(ProjectDialogSettingsSource.project)}}
                    Text("Global").tag(ProjectDialogSettingsSource.global)
                }.labelsHidden().frame(width:200).disabled(!model.editable) }
                GroupBox("Native provider fallback") {
                    VStack(alignment: .leading, spacing: 10) { field(.nativeProvider, title: "Native provider ID:"); field(.nativeParameters, title: "Native parameters:")
                        Text("Native issue catalog ID: " + NativeIssueCatalogProvider.identifier + ". Enabled exact-path associations take priority.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                if let error=model.error {Text(error).foregroundStyle(.red).textSelection(.enabled)}
                if model.busy {ProgressView().controlSize(.small)}
            }.padding(20)
        }.background(IssueTrackerWindowProbe(model:model).frame(width:0,height:0))
        .settingsParticipant("issueTracker",page:.issueTracker,value:model.state,modified:{model.modified},validate:{model.validationError},apply:{await model.apply(owner:transaction?.window)},cancel:model.cancel)
        .onChange(of:model.destination){_ in transaction?.notify()}.onChange(of:model.busy){_ in transaction?.notify()}.onChange(of:model.hasTester){_ in transaction?.notify()}
        .onAppear(perform:activate).onDisappear{model.suspend()}
        .onChange(of:workspace.root){_ in if model.active {activate()}}
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.willCloseNotification)){notification in if let window=notification.object as? NSWindow,window === model.window {model.invalidate()} }
    }
    private func activate() {do {let context=try contextProvider?() ?? workspace.gitConfigurationContext(globalOnly:globalOnly);model.activate(repository:context.repository,access:context.access,localAvailable:context.localAvailable)}catch{model.error=error.localizedDescription}}
    private func identity(_ key:IssueTrackerStringKey)->GitConfigurationIdentity {model.draft.fields[key] ?? GitConfigurationIdentity()}
    private func text(_ key:IssueTrackerStringKey)->Binding<String> { model.fieldBinding(key,context:model.editContext) }
    private func inherit(_ key:IssueTrackerStringKey)->Binding<Bool> { model.inheritBinding(key,context:model.editContext) }
    private func field(_ key:IssueTrackerStringKey,title:String?=nil)->some View {HStack{Text(title ?? key.rawValue).frame(width:180,alignment:.leading);TextField("",text:text(key)).accessibilityLabel(title ?? key.rawValue).disabled(!model.editable || identity(key).inherit);Toggle("inherit",isOn:inherit(key)).disabled(!model.editable)}}
    private func boolean(_ title:String,value:Binding<GitConfigurationBoolean>)->some View {HStack{Text(title).frame(width:180,alignment:.leading);Picker(title,selection:value){ForEach(GitConfigurationBoolean.allCases,id:\.self){Text($0.rawValue.isEmpty ? " ":$0.rawValue).tag($0)}}.labelsHidden().frame(width:120).disabled(!model.editable);Spacer()}}
}
private struct IssueTrackerWindowProbe:NSViewRepresentable {
    let model:IssueTrackerSettingsModel
    func makeNSView(context:Context)->Probe {let view=Probe();view.model=model;return view}
    func updateNSView(_ view:Probe,context:Context){model.attach(to:view.window)}
    final class Probe:NSView {weak var model:IssueTrackerSettingsModel?;override func viewDidMoveToWindow(){super.viewDidMoveToWindow();model?.attach(to:window)}}
}
