// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import CoreFoundation
import TurtleGitCore

@MainActor enum ProjectLanguages {
    static func code(_ value: String) -> Int64? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("0x") { return Int64(text.dropFirst(2), radix: 16) }
        return Int64(text)
    }
    static func identifier(_ value: String) -> String? {
        guard let code = code(value), code > 0, code <= UInt32.max,
              let identifier = CFLocaleCreateLocaleIdentifierFromWindowsLocaleCode(kCFAllocatorDefault, UInt32(code)) else { return nil }
        return identifier.rawValue as String
    }
    static let choices: [(value: String, title: String)] = {
        var result: [UInt32: String] = [:]
        for identifier in Locale.availableIdentifiers {
            let code = CFLocaleGetWindowsLocaleCodeFromLocaleIdentifier(CFLocaleIdentifier(rawValue: identifier as CFString))
            if code != 0 { result[code] = Locale.current.localizedString(forIdentifier: identifier) ?? identifier }
        }
        return result.map { (value: String($0.key), title: $0.value) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }()
}

@MainActor final class ProjectDialogSettingsModel: ObservableObject {
    private(set) static var activeReads = 0
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    var readConfigurationFiles: (GitRepository, Bool, OperationCancellation?) async throws -> GitConfigurationFiles = { try await $0.gitConfigurationFiles(hasRepository: $1, cancellation: $2) }
    var writeSettings: (GitRepository, ProjectDialogSettings, ProjectDialogSettingsSource, Bool) async throws -> Void = { try await $0.saveProjectDialogSettings($1, destination: $2, hasRepository: $3) }
    private(set) static var activeSaves = 0
    var authorizeFile: ((URL) async -> Bool)?
    var confirmSavingTo: ((ProjectDialogSettingsSource) async -> Bool)?

    @Published private(set) var source: ProjectDialogSettingsSource = .effective { didSet { if oldValue != source { formRevision = UUID() } } }
    @Published var destination: ProjectDialogSettingsSource = .local { didSet { if oldValue != destination { formRevision = UUID() } } }
    @Published var draft = ProjectDialogSettings() {
        didSet {
            if oldValue.minimumMessageLength.inherit != draft.minimumMessageLength.inherit ||
                oldValue.messageWidthMarker.inherit != draft.messageWidthMarker.inherit ||
                oldValue.icon.inherit != draft.icon.inherit || oldValue.language.inherit != draft.language.inherit {
                formRevision = UUID()
            }
        }
    }
    @Published private(set) var loaded = false
    @Published private(set) var busy = false { didSet { if oldValue != busy { formRevision = UUID() } } }
    @Published private(set) var selectingIcon = false { didSet { if oldValue != selectingIcon { formRevision = UUID() } } }
    @Published private var formRevision = UUID()
    @Published var error: String?
    private var saved = ProjectDialogSettings(), savedDestination: ProjectDialogSettingsSource = .local
    private var repository: GitRepository?, access: RepositoryAccessLease?
    private(set) var localAvailable = false, bare = false, active = false
    private var hintShown = false
    private var saving = false, invalidated = false
    private var request = UUID(), token: OperationCancellation?
    private var panel: NSOpenPanel?, alert: NSAlert?
    private var answer: ((Bool) -> Void)?
    weak var window: NSWindow?
    // Each field/action belongs to the source and dependency state that rendered it.
    struct FormContext: Equatable {
        let owner: ObjectIdentifier
        let revision: UUID
        let source: ProjectDialogSettingsSource
    }
    enum IdentityField { case minimum, border, icon }
    var formContext: FormContext { .init(owner: ObjectIdentifier(self), revision: formRevision, source: source) }
    var editable: Bool { active && !invalidated && loaded && source != .effective && !busy && !selectingIcon && panel == nil && alert == nil }
    var canSelectSource: Bool { active && !invalidated && !busy && !saving && !selectingIcon && panel == nil && alert == nil }
    private func accepts(_ context: FormContext) -> Bool { editable && context == formContext }
    func sourceAvailable(_ value: ProjectDialogSettingsSource) -> Bool {
        switch value {
        case .local: return localAvailable
        case .project: return localAvailable
        default: return true
        }
    }
    func destinationAvailable(_ value: ProjectDialogSettingsSource) -> Bool {
        value == .global || localAvailable && (value == .local || value == .project && !bare)
    }
    private func identity(_ field: IdentityField) -> GitConfigurationIdentity {
        switch field { case .minimum: return draft.minimumMessageLength; case .border: return draft.messageWidthMarker; case .icon: return draft.icon }
    }
    private func replaceIdentity(_ field: IdentityField, _ value: GitConfigurationIdentity) {
        switch field { case .minimum: draft.minimumMessageLength = value; case .border: draft.messageWidthMarker = value; case .icon: draft.icon = value }
    }
    func text(_ field: IdentityField, context: FormContext) -> Binding<String> {
        Binding(get: { self.identity(field).value }, set: { value in
            guard self.accepts(context), !self.identity(field).inherit else { return }
            var identity = self.identity(field); identity.value = value; self.replaceIdentity(field, identity)
        })
    }
    func inherit(_ field: IdentityField, context: FormContext) -> Binding<Bool> {
        Binding(get: { self.identity(field).inherit }, set: { value in
            guard self.accepts(context) else { return }
            var identity = self.identity(field); identity.inherit = value; self.replaceIdentity(field, identity)
        })
    }
    func language(context: FormContext) -> Binding<String> {
        Binding(get: { self.draft.language.inherit ? "" : self.draft.language.value }, set: { value in
            guard self.accepts(context) else { return }
            self.draft.language = .init(value: value, inherit: value.isEmpty)
        })
    }
    func signedOff(context: FormContext) -> Binding<GitConfigurationBoolean> {
        Binding(get: { self.draft.warnNoSignedOffBy }, set: { value in
            guard self.accepts(context) else { return }; self.draft.warnNoSignedOffBy = value
        })
    }
    func sourceSelection(context: FormContext) -> Binding<ProjectDialogSettingsSource> {
        Binding(get: { self.source }, set: { value in
            guard self.canSelectSource, context == self.formContext, self.sourceAvailable(value) else { return }
            self.load(value)
        })
    }
    func destinationSelection(context: FormContext) -> Binding<ProjectDialogSettingsSource> {
        Binding(get: { self.destination }, set: { value in
            guard self.accepts(context), self.destinationAvailable(value) else { return }
            self.destination = value
        })
    }
    // Injectable picker boundary; production always uses an owned native sheet.
    var chooseIcon: ((URL, @escaping (URL?) -> Void) -> Void)?
    var rememberIcon: (URL) throws -> Void = { try ProjectDialogIcons.remember($0) }
    private var iconRequest: UUID?
    struct State: Equatable {
        let strings: [Data]
        let signedOff: GitConfigurationBoolean
        let destination: ProjectDialogSettingsSource
    }
    private static func strings(_ value: ProjectDialogSettings) -> [Data] {
        [value.language, value.minimumMessageLength, value.messageWidthMarker, value.icon].flatMap {
            [Data([$0.inherit ? 1 : 0]), Data($0.value.utf8)]
        }
    }
    var state: State { .init(strings: Self.strings(draft), signedOff: draft.warnNoSignedOffBy, destination: destination) }
    var modified: Bool { loaded && state != State(strings: Self.strings(saved), signedOff: saved.warnNoSignedOffBy, destination: savedDestination) }
    private var ownerObserver: NSObjectProtocol?
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
    func attach(to owner: NSWindow?) {
        guard !invalidated, let owner, window !== owner || ownerObserver == nil else { return }
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }
        if let previous = window, previous !== owner { suspend() }
        window = owner; formRevision = UUID()
        ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        }
    }
    func activate(repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool) {
        guard !invalidated, !saving else { return }
        if loaded && self.repository?.root == repository.root && self.repository?.executable == repository.executable && self.localAvailable == localAvailable { active = true; formRevision = UUID(); showHierarchyHint(); return }
        suspend(); self.repository = repository; self.access = access; self.localAvailable = localAvailable
        destination = localAvailable ? .local : .global; active = true; load(.effective)
    }
    func suspend() {
        active = false; formRevision = UUID(); iconRequest = nil; selectingIcon = false; request = UUID(); token?.cancel(); token = nil
        if !saving { busy = false }
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
        guard active, !saving, !selectingIcon, panel == nil, alert == nil, !invalidated, let repository, sourceAvailable(source) else { return }
        token?.cancel(); let cancellation = OperationCancellation(), generation = UUID(); token = cancellation; request = generation
        self.source = source; loaded = false; busy = true; error = nil
        if [.local, .project, .global].contains(source) { destination = source }
        Self.activeReads += 1
        Task { [self, access] in
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {}; if request == generation { token = nil; busy = false } }
            do {
                try checkAccess(repository)
                let files = try await readConfigurationFiles(repository, localAvailable, cancellation)
                guard active, !invalidated, request == generation, !cancellation.isCancelled else { return }
                bare = files.bare
                if !destinationAvailable(destination) { destination = localAvailable ? .local : .global }
                if source == .effective || source == .global {
                    for file in [files.global, files.xdg].compactMap({ $0 }) {
                        guard await permit(file), active, !invalidated, request == generation, !cancellation.isCancelled else { return }
                    }
                }
                let value = try await repository.projectDialogSettings(source: source, hasRepository: localAvailable, cancellation: cancellation)
                guard active, !invalidated, request == generation, !cancellation.isCancelled else { return }
                draft = value; saved = value; savedDestination = destination; loaded = true
                showHierarchyHint()
            } catch { if active, !invalidated, request == generation, !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func showHierarchyHint() {
        guard active, loaded, !hintShown, !preferences.bool(forKey: "HintHierarchicalConfig"), let window, window.attachedSheet == nil else { return }
        hintShown = true; formRevision = UUID()
        let question = NSAlert(); question.messageText = "Git configuration"
        question.informativeText = "Git uses hierarchical configuration: settings in higher levels override lower levels. Effective shows the read-only values for the current scope. Select a level to see its stored values. To change settings, select a level, enter the values and choose where to save them."
        question.addButton(withTitle: "OK"); question.showsSuppressionButton = true
        question.suppressionButton?.title = "Do not show this message again"; alert = question
        question.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.alert === question else { return }; self.alert = nil; self.formRevision = UUID()
            if response == .alertFirstButtonReturn && question.suppressionButton?.state == .on {
                self.preferences.set(true, forKey: "HintHierarchicalConfig")
            }
        }
    }
    var validationError: String? {
        for (label, value) in [("Limit", draft.minimumMessageLength), ("Border", draft.messageWidthMarker)] where !value.inherit && !value.value.isEmpty {
            guard let number = Int32(value.value), number >= 0 else { return "Enter a nonnegative number for " + label + "." }
        }
        if !draft.language.inherit {
            guard let code = ProjectLanguages.code(draft.language.value), code == -1 || (0...Int64(UInt32.max)).contains(code) else { return "Choose a project language." }
        }
        if !draft.icon.inherit && draft.icon.value.utf8.contains(0) { return "The overlay icon path contains a null character." }
        return nil
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
        guard !invalidated else { return false }; if !modified { return true }
        guard loaded, source != .effective, !busy, !selectingIcon, panel == nil, alert == nil, destinationAvailable(destination), validationError == nil, let repository else { return false }
        let wasActive = active; active = true; if window == nil { window = owner }
        let generation = request, settings = draft, destination = destination, source = source, grant = access, local = localAvailable
        busy = true; saving = true; error = nil; Self.activeSaves += 1
        defer { saving = false; busy = false; Self.activeSaves -= 1; if request == generation { active = wasActive }; withExtendedLifetime(grant) {} }
        do {
            guard await confirmDestination(source: source, destination: destination), !invalidated, request == generation else { return false }
            try checkAccess(repository)
            if destination == .global {
                let files = try await repository.gitConfigurationFiles(hasRepository: localAvailable)
                for file in [files.global, files.xdg].compactMap({ $0 }) {
                    guard await permit(file), !invalidated, request == generation else { return false }
                }
            }
            // Allow source-ordered locked writes to finish after forced closure.
            try await writeSettings(repository, settings, destination, local)
            guard !invalidated, request == generation else { return false }
            saved = settings; savedDestination = destination; return true
        } catch { if !invalidated, request == generation { self.error = error.localizedDescription }; return false }
    }
    func cancel() {
        guard !saving else { return }
        iconRequest = nil; selectingIcon = false; formRevision = UUID()
        if let panel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        draft = saved; destination = savedDestination
    }
    func browseIcon() { browseIcon(context: formContext) }
    func browseIcon(context: FormContext) {
        guard accepts(context), !draft.icon.inherit, let window, window.attachedSheet == nil, let repository else { return }
        let original = draft.icon, source = source, root = repository.root, generation = UUID()
        let current = original.value.isEmpty ? root : original.value.hasPrefix("/") ? URL(fileURLWithPath: original.value) : root.appendingPathComponent(original.value)
        iconRequest = generation; selectingIcon = true
        let finish: (URL?) -> Void = { [weak self] file in
            guard let self, self.iconRequest == generation else { return }
            self.iconRequest = nil; self.selectingIcon = false
            guard self.active, !self.invalidated, self.source == source, self.repository?.root == root,
                  self.draft.icon.inherit == original.inherit, self.draft.icon.value.utf8.elementsEqual(original.value.utf8), let file else { return }
            do {
                try self.rememberIcon(file)
                let base = root.standardizedFileURL.path + "/", path = file.standardizedFileURL.path
                self.draft.icon.value = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            } catch { self.error = error.localizedDescription }
        }
        if let chooseIcon { chooseIcon(current, finish); return }
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = false; chooser.allowsMultipleSelection = false
        chooser.title = "Select project overlay icon"; chooser.prompt = "Select"
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: current.path, isDirectory: &directory), directory.boolValue { chooser.directoryURL = current }
        else { chooser.directoryURL = current.deletingLastPathComponent() }
        // NSOpenPanel does not use NSSavePanel.nameFieldStringValue (AppKit SDK).
        // Keep the current choice visible while browsing its containing folder.
        if !original.value.isEmpty { chooser.message = "Current overlay icon: " + original.value }
        panel = chooser
        chooser.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.panel === chooser else { return }; self.panel = nil
            finish(response == .OK ? chooser.url : nil)
        }
    }
}

struct ProjectDialogSettingsPage: View {
    @ObservedObject var workspace: RepositoryModel
    var globalOnly = false
    @Environment(\.settingsTransaction) private var transaction
    @StateObject private var model: ProjectDialogSettingsModel
    var contextProvider: (() throws -> (repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool))?
    init(workspace: RepositoryModel, globalOnly: Bool = false, preferences: UserDefaults = .standard, model: ProjectDialogSettingsModel? = nil,
         contextProvider: (() throws -> (repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool))? = nil) {
        self.workspace = workspace; self.globalOnly = globalOnly; self.contextProvider = contextProvider
        _model = StateObject(wrappedValue: model ?? ProjectDialogSettingsModel(preferences: preferences))
    }
    var body: some View {
        let context = model.formContext
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            GroupBox("Config source") {
                VStack(alignment: .leading, spacing: 8) {
                SettingsSourceChoices(values:ProjectDialogSettingsSource.allCases,selected:model.source,title:{$0.rawValue},available:model.sourceAvailable) {source in
                    model.sourceSelection(context:context).wrappedValue=source
                }.disabled(!model.canSelectSource)
                Text("Local overrides Project; Project overrides Global; Global overrides System. Effective shows the combined result.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
            GroupBox("Commit") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Select the language this project is using. This setting affects the spell checker used for commit messages.")
                    Picker("Language:", selection: model.language(context: context)) {
                        Text(" ").tag(""); Text("(auto)").tag("0"); Text("(disable)").tag("-1")
                        if !model.draft.language.value.isEmpty && !["0", "-1"].contains(model.draft.language.value) && !ProjectLanguages.choices.contains(where: { $0.value == model.draft.language.value }) {
                            Text(ProjectLanguages.identifier(model.draft.language.value) ?? model.draft.language.value).tag(model.draft.language.value)
                        }
                        ForEach(ProjectLanguages.choices, id: \.value) { choice in Text(choice.title).tag(choice.value) }
                    }.disabled(!model.editable)
                    Text("Minimum number of chars for a commit message:")
                    inherited("Limit:", identity: model.draft.minimumMessageLength, text: model.text(.minimum, context: context), inherit: model.inherit(.minimum, context: context))
                    Text("Char position where to show a border line in commit text boxes:")
                    inherited("Border:", identity: model.draft.messageWidthMarker, text: model.text(.border, context: context), inherit: model.inherit(.border, context: context))
                    Picker("Warn on missing Signed-Off-By on commit", selection: model.signedOff(context: context)) {
                        ForEach(GitConfigurationBoolean.allCases, id: \.self) { Text($0.rawValue.isEmpty ? " " : $0.rawValue).tag($0) }
                    }.disabled(!model.editable)
                }.padding(8)
            }
            GroupBox("Dialogs") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Overlay Icon:").frame(width:95,alignment:.leading)
                        TextField("Overlay Icon", text: model.text(.icon, context: context)).disabled(!model.editable || model.draft.icon.inherit)
                        Button("Browse…") { model.browseIcon(context: context) }.disabled(!model.editable || model.draft.icon.inherit)
                        Toggle("inherit", isOn: model.inherit(.icon, context: context)).disabled(!model.editable)
                    }
                }.padding(8)
            }
            HStack {
                Text("Save to:")
                Picker("Save to", selection: model.destinationSelection(context: context)) {
                    if model.localAvailable { Text("Local").tag(ProjectDialogSettingsSource.local) }
                    if model.localAvailable && !model.bare { Text("Project").tag(ProjectDialogSettingsSource.project) }
                    Text("Global").tag(ProjectDialogSettingsSource.global)
                }.labelsHidden().frame(width: 200).disabled(!model.editable)
            }
            if let error = model.error ?? model.validationError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if model.busy { ProgressView().controlSize(.small) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading) }.groupBoxStyle(SourceSettingsGroupBoxStyle()).background(ProjectDialogWindowProbe(model: model).frame(width: 0, height: 0))
        .settingsParticipant("dialogs3", page: .dialogs3, value: model.state, modified: { model.modified }, validate: { model.validationError },
            apply: { await model.apply(owner: transaction?.window) }, cancel: model.cancel)
        .onChange(of: model.destination) { _ in transaction?.notify() }
        .onAppear(perform: activate).onDisappear { model.suspend() }
        .onChange(of: workspace.root) { _ in if model.active { activate() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window === model.window { model.invalidate() }
        }
    }
    private func activate() {
        do { let context = try contextProvider?() ?? workspace.gitConfigurationContext(globalOnly: globalOnly); model.activate(repository: context.repository, access: context.access, localAvailable: context.localAvailable) }
        catch { model.error = error.localizedDescription }
    }
    private func inherited(_ label: String, identity: GitConfigurationIdentity, text: Binding<String>, inherit: Binding<Bool>) -> some View {
        HStack {
            Text(label).frame(width: 95, alignment: .leading)
            TextField(label, text: text).frame(width: 90).disabled(!model.editable || identity.inherit)
            Toggle("inherit", isOn: inherit).disabled(!model.editable).help("Use the value from a lower configuration level.")
            Spacer()
        }
    }
}
private struct ProjectDialogWindowProbe: NSViewRepresentable {
    let model: ProjectDialogSettingsModel
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.model = model; return view }
    func updateNSView(_ view: Probe, context: Context) { model.attach(to: view.window) }
    final class Probe: NSView {
        weak var model: ProjectDialogSettingsModel?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.attach(to: window); model?.showHierarchyHint() }
    }
}

@MainActor enum ProjectDialogIcons {
    private static var leases: [RepositoryAccessLease] = []
    private static var restored = false
    private static let key = "TurtleGit.ProjectIconBookmarks"
    static func remember(_ file: URL) throws {
        restore()
        let provider = SystemRepositoryBookmarkProvider(), grant = RepositoryAccessLease(url: file)
        let data = try provider.create(for: file)
        let path = file.standardizedFileURL.path
        var bookmarks = (UserDefaults.standard.array(forKey: key) as? [Data] ?? []).filter {
            (try? provider.resolve($0).url.standardizedFileURL.path) != path
        }
        bookmarks.append(data); UserDefaults.standard.set(bookmarks, forKey: key)
        leases.removeAll { $0.url.standardizedFileURL.path == path }; leases.append(grant)
    }
    private static func restore() {
        guard !restored else { return }; restored = true
        let provider = SystemRepositoryBookmarkProvider()
        let bookmarks = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        var renewed = bookmarks
        for (index, data) in bookmarks.enumerated() {
            guard let resolved = try? provider.resolve(data) else { continue }
            let grant = RepositoryAccessLease(url: resolved.url); leases.append(grant)
            if resolved.stale, let replacement = try? provider.create(for: resolved.url) { renewed[index] = replacement }
        }
        if renewed != bookmarks { UserDefaults.standard.set(renewed, forKey: key) }
    }
    static func image(_ path: String, repository: URL, access: RepositoryAccessLease?) -> NSImage? {
        guard !path.isEmpty else { return nil }; restore()
        let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repository.appendingPathComponent(path)
        if GitRuntime.isAppStoreBuild && !((access?.hasSecurityScope == true && access?.contains(file) == true) || leases.contains(where: { $0.hasSecurityScope && $0.contains(file) })) { return nil }
        return NSImage(contentsOf: file)
    }
}

/// SciEdit's project language and margin are shared by Commit, Merge and Rebase.
enum MessageEditorZoomAction: String, CaseIterable, Hashable {
    case zoomIn, zoomOut, actualSize
    var title: String {
        switch self { case .zoomIn: return "Zoom In"; case .zoomOut: return "Zoom Out"; case .actualSize: return "Actual Size" }
    }
    var icon: MenuIcon {
        switch self { case .zoomIn: return .imageZoomIn; case .zoomOut: return .imageZoomOut; case .actualSize: return .imageOriginal }
    }
    var keyEquivalent: String {
        switch self { case .zoomIn: return "+"; case .zoomOut: return "-"; case .actualSize: return "0" }
    }
    static func action(for event: NSEvent) -> Self? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == .command || flags == [.command, .shift] else { return nil }
        switch event.charactersIgnoringModifiers {
        case "+", "=": return .zoomIn
        case "-" where flags == .command: return .zoomOut
        case "0" where flags == .command: return .actualSize
        default: return nil
        }
    }
}
@MainActor private final class MessageEditorZoomReceipt: NSObject {
    let session: UUID, editor: ObjectIdentifier, window: ObjectIdentifier
    let context: AnyHashable?
    let action: MessageEditorZoomAction
    init(editor: ProjectMessageTextView, window: NSWindow, action: MessageEditorZoomAction) {
        session = editor.messagePresentationSessionID; self.editor = ObjectIdentifier(editor)
        self.window = ObjectIdentifier(window); self.action = action
        context = editor.messageCommandContext
    }
}
class ProjectMessageTextView: NSTextView {
    private(set) var messagePresentationSessionID = UUID()
    var messageCommandContext: AnyHashable?
    /// Native receivers inject their private focus owner without activating the
    /// desktop. Shipping editors always use the actual AppKit key window.
    var messageCommandKeyWindow: () -> NSWindow? = { NSApp.keyWindow }
    private var messageZoom = GitBlameZoom()
    private var configuredMessageFont: NSFont?
    private var cachedMessageStyles: [IssueMessageStyle] = []
    var messageZoomOffset: Int { messageZoom.offset }
    /// Source Scintilla zoom is transient (-10...60 points); configured font
    /// preferences remain the unzoomed base, including delayed style replies.
    func resetMessagePresentationSession() {
        messagePresentationSessionID = UUID(); messageZoom = GitBlameZoom()
        breakUndoCoalescing(); undoManager?.removeAllActions()
        messagePresentationWillChange()
        if let base = configuredMessageFont { applyIssueStyles(currentMessageStyles, base: base) }
        sourceStyling?.refresh()
    }
    func messagePresentationWillChange() { dismissSpellingSuggestions() }
    var messageZoomCommandsAvailable: Bool { messageLayoutAvailable && messageCommandKeyWindow() === window && window?.firstResponder === self && !hasMarkedText() }
    func canPerformMessageZoom(_ action: MessageEditorZoomAction) -> Bool {
        guard messageZoomCommandsAvailable else { return false }
        switch action {
        case .zoomIn: return messageZoom.canIncrease
        case .zoomOut: return messageZoom.canDecrease
        case .actualSize: return messageZoom.offset != 0
        }
    }
    @discardableResult func performMessageZoom(_ action: MessageEditorZoomAction) -> Bool {
        guard canPerformMessageZoom(action) else { return false }
        messagePresentationWillChange(); sourceLinks.invalidate()
        switch action {
        case .zoomIn: messageZoom = messageZoom.stepping(1)
        case .zoomOut: messageZoom = messageZoom.stepping(-1)
        case .actualSize: messageZoom = GitBlameZoom()
        }
        let base = configuredMessageFont ?? font ?? MessageEditorFont.resolve(name: MessageEditorFont.defaultName, size: MessageEditorFont.defaultSize)
        applyIssueStyles(currentMessageStyles, base: base)
        needsDisplay = true
        return true
    }
    @discardableResult func handleMessageZoomKey(_ event: NSEvent) -> Bool {
        guard messageCommandKeyWindow() === window, window?.firstResponder === self, event.window === window,
              let action = MessageEditorZoomAction.action(for: event) else { return false }
        _ = performMessageZoom(action)
        // Own the recognized shortcut even at a limit or while blocked; falling
        // through must not invoke a different font-size command on this editor.
        return true
    }
    @objc private func dispatchMessageZoom(_ sender: NSMenuItem) {
        guard let receipt = sender.representedObject as? MessageEditorZoomReceipt,
              receipt.session == messagePresentationSessionID, receipt.editor == ObjectIdentifier(self),
              receipt.context == messageCommandContext,
              let window, receipt.window == ObjectIdentifier(window) else { return }
        _ = performMessageZoom(receipt.action)
    }
    private func appendMessageZoomMenu(to menu: NSMenu) {
        guard let window else { return }
        let item = NSMenuItem(title: String(localized: "Message Text Size"), action: nil, keyEquivalent: "")
        item.image = MenuIcon.imageZoomIn.contextImage(defaults: spellingPreferences)
        let zoom = NSMenu(title: item.title); zoom.autoenablesItems = false
        for action in MessageEditorZoomAction.allCases {
            let entry = NSMenuItem(title: NSLocalizedString(action.title, comment: "Message editor zoom"), action: #selector(dispatchMessageZoom(_:)), keyEquivalent: action.keyEquivalent)
            entry.keyEquivalentModifierMask = .command; entry.target = self
            entry.image = action.icon.contextImage(defaults: spellingPreferences)
            entry.representedObject = MessageEditorZoomReceipt(editor: self, window: window, action: action)
            entry.isEnabled = canPerformMessageZoom(action); zoom.addItem(entry)
        }
        item.submenu = zoom; menu.addItem(.separator()); menu.addItem(item)
    }
    private var currentMessageStyles: [IssueMessageStyle] { string.utf8.elementsEqual(styledText.utf8) ? cachedMessageStyles : [] }
    func applyMessageBaseFont(_ base: NSFont) { applyIssueStyles(currentMessageStyles, base: base) }
    private func effectiveMessageFont(_ base: NSFont) -> NSFont {
        NSFontManager.shared.convert(base, toSize: max(1, base.pointSize + CGFloat(messageZoom.offset)))
    }
    private var sourceStyling: MessageEditorStylingSession?
    var sourceLinkAvailable: () -> Bool = { true }
    lazy var sourceLinks: SourceMessageLinkInteraction = {
        let links = SourceMessageLinkInteraction(editor:self)
        links.preferences = { [weak self] in self?.spellingPreferences ?? .standard }
        links.canInteract = { [weak self] in
            guard let self else { return false }
            return self.isEditable && !self.hasMarkedText() && self.sourceLinkAvailable() && self.string.utf8.elementsEqual(self.styledText.utf8)
        }
        return links
    }()
    override func clicked(onLink link: Any, at charIndex: Int) { sourceLinks.clicked(link,at:charIndex) }
    func followSourceLink(_ link: Any, at index: Int) { sourceLinks.clicked(link,at:index) }

    func configureSourceStyling(properties: IssueTrackerProperties = IssueTrackerProperties(), preferences: UserDefaults, font: NSFont) {
        spellingPreferences = preferences
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        if sourceStyling == nil { sourceStyling = MessageEditorStylingSession(editor: self) }
        sourceStyling?.configure(properties: properties, preferences: preferences, font: font)
    }
    func retireSourceStyling() { messagePresentationSessionID = UUID(); messageZoom = GitBlameZoom(); messageEditingRetired = true; pendingLineEdit = nil; deferredCompositionRange = nil; sourceStyling?.retire(); sourceStyling = nil; sourceLinks.retire() }
    private var pendingLineEdit: NSRange?
    private var applyingLineEdits = false
    private var messageEditingRetired = false
    private var deferredCompositionRange: NSRange?
    private var messageOwnerObserver: NSObjectProtocol?
    private weak var messageOwner: NSWindow?
    private var messageOwnerClosed = false
    deinit { if let messageOwnerObserver { NotificationCenter.default.removeObserver(messageOwnerObserver) } }
    var messageLayoutAvailable: Bool {
        !messageEditingRetired && window != nil && isEditable && sourceLinkAvailable() && window?.attachedSheet == nil && NSApp.modalWindow == nil
    }
    var messageBorderWidth: CGFloat {
        CGFloat(projectSettings.borderColumn) * (" " as NSString).size(withAttributes: [.font: styledBaseFont ?? font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
    }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard messageLayoutAvailable else { return false }
        let accepted = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if accepted, !applyingLineEdits, !messageEditingRetired {
            pendingLineEdit = NSRange(location: affectedCharRange.location, length: (replacementString as NSString?)?.length ?? 0)
        }
        return accepted
    }
    override func didChangeText() {
        guard !applyingLineEdits else { return }
        let edited = pendingLineEdit; pendingLineEdit = nil
        if hasMarkedText() {
            let changed = edited ?? selectedRange()
            deferredCompositionRange = deferredCompositionRange.map { NSUnionRange($0, changed) } ?? changed
        } else {
            let changed = edited ?? deferredCompositionRange
            deferredCompositionRange = nil
            if let changed, undoManager?.isUndoing != true, undoManager?.isRedoing != true { splitEditedLines(changed) }
        }
        sourceLinks.invalidate(); super.didChangeText(); sourceStyling?.refresh()
        updateMessageWidthMode()
    }
    func didChangeMessageLines(in range: NSRange) {
        pendingLineEdit = range
        didChangeText()
    }
    override func unmarkText() {
        super.unmarkText()
        if let range = deferredCompositionRange {
            deferredCompositionRange = nil
            if splitEditedLines(range) { sourceLinks.invalidate(); super.didChangeText() }
        }
        if let base = configuredMessageFont {
            applyIssueStyles(string.utf8.elementsEqual(styledText.utf8) ? cachedMessageStyles : [], base: base)
        }
        sourceStyling?.refresh()
    }
    @discardableResult private func applyLineEdits(_ edits: [MessageEditorLineLayout.Edit]) -> Bool {
        guard !edits.isEmpty, messageLayoutAvailable, !hasMarkedText() else { return false }
        let ranges = selectedRanges.map(\.rangeValue)
        let affinity = selectionAffinity
        applyingLineEdits = true; defer { applyingLineEdits = false }
        for edit in edits.reversed() { super.insertText(edit.text, replacementRange: edit.range) }
        setSelectedRanges(ranges.map { NSValue(range: MessageEditorLineLayout.mapped($0, through: edits)) }, affinity: affinity, stillSelecting: false)
        return true
    }
    @discardableResult private func splitEditedLines(_ edit: NSRange) -> Bool {
        guard messageLayoutAvailable, !hasMarkedText(), messageBorderWidth > 0 else { return false }
        let length = (string as NSString).length
        guard edit.location <= length else { return false }
        var range = NSRange(location: edit.location, length: min(edit.length, length - edit.location))
        if let layoutManager, let textContainer {
            let glyphs = layoutManager.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: textContainer)
            let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            range = NSUnionRange(range, visible)
        }
        return applyLineEdits(MessageEditorLineLayout.edits(text: string, range: range, width: messageBorderWidth, font: styledBaseFont ?? font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize), join: false))
    }
    @objc func splitMessageLines(_ sender: Any?) {
        guard messageLayoutAvailable, !hasMarkedText(), selectedRanges.count == 1, selectedRange().length > 0, messageBorderWidth > 0 else { return }
        breakUndoCoalescing(); undoManager?.beginUndoGrouping()
        let base = styledBaseFont ?? font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let joined = applyLineEdits(MessageEditorLineLayout.edits(text: string, range: selectedRange(), width: messageBorderWidth, font: base, join: true))
        let split = applyLineEdits(MessageEditorLineLayout.edits(text: string, range: selectedRange(), width: messageBorderWidth, font: base, join: false))
        undoManager?.endUndoGrouping(); breakUndoCoalescing()
        if joined || split { sourceLinks.invalidate(); super.didChangeText(); sourceStyling?.refresh(); updateMessageWidthMode() }
    }
    func updateMessageWidthMode() {
        guard let scroll = enclosingScrollView, let textContainer else { return }
        let unwrapped = projectSettings.borderColumn > 0
        scroll.hasHorizontalScroller = unwrapped; isHorizontallyResizable = unwrapped
        textContainer.widthTracksTextView = !unwrapped
        if unwrapped {
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            layoutManager?.ensureLayout(for: textContainer)
            let extent = (layoutManager?.usedRect(for: textContainer).maxX ?? 0) + textContainerInset.width * 2
            setFrameSize(NSSize(width: max(scroll.contentSize.width, extent), height: frame.height))
            autoresizingMask = []
        } else {
            autoresizingMask = [.width]
            setFrameSize(NSSize(width: scroll.contentSize.width, height: frame.height))
            textContainer.containerSize = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }
    private var appliedStyles: [IssueMessageStyle] = []
    private var styledText = ""
    private var styledBaseFont: NSFont?
    func applyIssueStyles(_ styles: [IssueMessageStyle], base configuredBase: NSFont) {
        configuredMessageFont = configuredBase
        guard !hasMarkedText() else { return }
        let base = effectiveMessageFont(configuredBase)
        guard styles != appliedStyles || !string.utf8.elementsEqual(styledText.utf8) || styledBaseFont != base, let storage = textStorage else { return }
        sourceLinks.invalidate()
        appliedStyles = styles; styledText = string; styledBaseFont = base
        cachedMessageStyles = styles
        let selection = selectedRanges, affinity = selectionAffinity
        let undoEnabled = undoManager?.isUndoRegistrationEnabled == true
        if undoEnabled { undoManager?.disableUndoRegistration() }
        storage.beginEditing()
        let whole = NSRange(location: 0, length: storage.length)
        for key in [NSAttributedString.Key.link, .toolTip, .underlineStyle] { storage.removeAttribute(key, range: whole) }
        let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []; paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: base]).width * 8
        storage.addAttributes([.font: base, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph], range: whole)
        for style in styles where style.range.location >= 0 && style.range.location <= storage.length && style.range.length <= storage.length - style.range.location {
            var styledFont = base
            if [.context, .identifier, .bold].contains(style.kind) { styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .boldFontMask) }
            if [.identifier, .italic].contains(style.kind) { styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .italicFontMask) }
            let color = [.bold, .italic, .underlined].contains(style.kind) ? NSColor.textColor : NSColor.linkColor
            var attributes: [NSAttributedString.Key: Any] = [.font: styledFont, .foregroundColor: color]
            if style.kind == .underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if let url = style.url { attributes[.link] = url; attributes[.toolTip] = url }
            storage.addAttributes(attributes, range: style.range)
        }
        storage.endEditing()
        if undoEnabled { undoManager?.enableUndoRegistration() }
        setSelectedRanges(selection, affinity: affinity, stillSelecting: false)
        typingAttributes = [.font: base, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        updateMessageWidthMode()
    }
    var spellingPreferences = UserDefaults.standard
    var spellingSuggestions: ((String, String?) -> [String])?
    private let spellingPopup = CommitCompletionPopup()
    private(set) var spellingChoices: [String] = []
    var spellingPopupShown: Bool { spellingPopup.isShown }
    func dismissSpellingSuggestions() { spellingPopup.close(); spellingChoices = [] }
    @discardableResult func handleSpellingKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.control, .option, .command])
        if modifiers == .control, event.keyCode == 48 { showSpellingSuggestions(); return true }
        guard spellingPopup.isShown else { return false }
        switch event.keyCode {
        case 53: dismissSpellingSuggestions(); return true
        case 125, 126: spellingPopup.move(event.keyCode == 125 ? 1 : -1); return true
        case 36, 48: spellingPopup.choose(); return true
        default: dismissSpellingSuggestions(); return false
        }
    }
    override func keyDown(with event: NSEvent) {
        if handleSpellingKey(event) { return }
        if handleMessageZoomKey(event) { return }
        if handleMessageLineCommandKey(event) { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleMessageZoomKey(event) || handleMessageLineCommandKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let valid = validateMessageLineCommandItem(menuItem) { return valid }
        return super.validateMenuItem(menuItem)
    }
    @objc func showSpellingSuggestions() {
        dismissSpellingSuggestions()
        guard isEditable, !hasMarkedText(), selectedRanges.count == 1,
              ProjectLanguages.code(projectSettings.language.value) != -1,
              spellingPreferences.object(forKey: "Spellchecker") as? Bool ?? true,
              let range = MessageSpellingPolicy.suggestionRange(message: string, selection: selectedRange(), styling: spellingPreferences.object(forKey: "StyleCommitMessages") as? Bool ?? true), window?.attachedSheet == nil else { return }
        let original = string, word = (original as NSString).substring(with: range)
        let language = ProjectLanguages.identifier(projectSettings.language.value)
        let guesses = spellingSuggestions?(word, language) ?? NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word, language: language, inSpellDocumentWithTag: spellCheckerDocumentTag) ?? []
        var seen = Set<[UInt16]>()
        spellingChoices = guesses.filter { !$0.isEmpty && !$0.contains("\0") && seen.insert(Array($0.utf16)).inserted }
        setSelectedRange(range)
        guard !spellingChoices.isEmpty else { return }
        spellingPopup.accept = { [weak self] value in
            guard let self else { return }; self.spellingChoices = []
            guard self.isEditable, !self.hasMarkedText(), self.window?.attachedSheet == nil,
                  self.string.utf8.elementsEqual(original.utf8), self.selectedRange() == range else { return }
            self.breakUndoCoalescing(); self.insertText(value, replacementRange: range); self.breakUndoCoalescing()
            self.spellingChoices = []; self.window?.makeFirstResponder(self)
        }
        spellingPopup.show(spellingChoices, catalog: MessageCompletionCatalog(), icon: .completionSpelling, in: self)
    }
    override func resignFirstResponder() -> Bool { dismissSpellingSuggestions(); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); sourceLinks.attachOwner()
        if let window, messageOwner !== window {
            if let messageOwnerObserver { NotificationCenter.default.removeObserver(messageOwnerObserver) }
            messageOwner = window; messageOwnerClosed = false
            messageOwnerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.messageOwnerClosed = true; self?.retireSourceStyling() }
            }
            updateMessageWidthMode()
        }
        if window != nil, !messageOwnerClosed { messageEditingRetired = false }
        if window == nil { dismissSpellingSuggestions(); retireSourceStyling() }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        // SciEdit uses the clicked point for spelling/link inspection, then
        // restores its original anchor/caret before dispatching edit actions.
        // NSTextView's menu builder otherwise selects the clicked word and
        // turns a current-line Duplicate into an unrelated word Duplicate.
        let ranges = selectedRanges, affinity = selectionAffinity
        let menu = super.menu(for: event)
        setSelectedRanges(ranges, affinity: affinity, stillSelecting: false)
        if let menu {
            let point = convert(event.locationInWindow,from:nil)
            sourceLinks.prepareMenu(menu,at:characterIndexForInsertion(at:point))
        }
        if let menu { appendMessageZoomMenu(to: menu) }
        if isEditable, let menu {
            appendMessageLineCommands(to: menu)
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Spelling suggestions", action: #selector(showSpellingSuggestions), keyEquivalent: "")
            item.target = self; item.image = MenuIcon.completionSpelling.contextImage(defaults:spellingPreferences)
            item.isEnabled = ProjectLanguages.code(projectSettings.language.value) != -1 && (spellingPreferences.object(forKey: "Spellchecker") as? Bool ?? true)
            menu.addItem(item)
            if projectSettings.borderColumn > 0 {
                menu.addItem(.separator())
                let split = NSMenuItem(title: String(localized: "Split lines"), action: #selector(splitMessageLines(_:)), keyEquivalent: "")
                split.target = self; split.isEnabled = messageLayoutAvailable && !hasMarkedText() && selectedRange().length > 0
                split.image = MenuIcon.mergeWrap.contextImage(defaults: spellingPreferences)
                menu.addItem(split)
            }
        }
        return menu
    }

    private var projectSettings = ProjectDialogSettings()
    private var spellingPolicy = MessageSpellingPolicy()
    var spellingDictionary: ((String, String?) -> Bool)?
    func setSpellingCandidates(_ values: [String]) {
        let policy = MessageSpellingPolicy(candidates: values)
        guard policy != spellingPolicy else { return }
        spellingPolicy = policy
        if isContinuousSpellCheckingEnabled && isEditable {
            checkText(in: NSRange(location: 0, length: (string as NSString).length), types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: [:])
        }
    }
    func applyProjectSettings(_ settings: ProjectDialogSettings) {
        // Spelling only suggests corrections; disable automatic spelling and
        // typography substitutions independently of source hard line wrapping.
        isAutomaticSpellingCorrectionEnabled = false; isAutomaticTextReplacementEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false; isAutomaticDashSubstitutionEnabled = false
        isContinuousSpellCheckingEnabled = ProjectLanguages.code(settings.language.value) != -1 && (spellingPreferences.object(forKey: "Spellchecker") as? Bool ?? true)
        guard projectSettings != settings else { updateMessageWidthMode(); return }
        projectSettings = settings; needsDisplay = true
        updateMessageWidthMode()
    }
    override func checkText(in range: NSRange, types checkingTypes: NSTextCheckingTypes, options: [NSSpellChecker.OptionKey: Any] = [:]) {
        var options = options, types = checkingTypes
        let language = projectSettings.language.value
        if ProjectLanguages.code(language) == -1 || !(spellingPreferences.object(forKey: "Spellchecker") as? Bool ?? true) {
            types &= ~(NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue)
        } else if let identifier = ProjectLanguages.identifier(language) {
            options[.orthography] = NSOrthography.defaultOrthography(forLanguage: identifier)
        }
        super.checkText(in: range, types: types, options: options)
    }
    func filteredSpellingResults(_ results: [NSTextCheckingResult]) -> [NSTextCheckingResult] {
        let language = ProjectLanguages.identifier(projectSettings.language.value)
        let enabled = ProjectLanguages.code(projectSettings.language.value) != -1 && (spellingPreferences.object(forKey: "Spellchecker") as? Bool ?? true)
        let urls = MessageURLFinder.ranges(in: string)
        return results.filter { result in
            guard result.resultType == .spelling else { return true }
            guard enabled, isEditable else { return false }
            let range = result.range, length = (string as NSString).length
            guard range.location != NSNotFound, range.location >= 0, range.length > 0, range.location <= length, range.length <= length - range.location else { return false }
            if urls.contains(where: { NSIntersectionRange($0, range).length == range.length }) { return false }
            return !spellingPolicy.suppresses(message: string, range: range) { word in
                if let spellingDictionary { return spellingDictionary(word, language) }
                return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: spellCheckerDocumentTag, wordCount: nil).location != NSNotFound
            }
        }
    }
    override func handleTextCheckingResults(_ results: [NSTextCheckingResult], forRange range: NSRange, types checkingTypes: NSTextCheckingTypes, options: [NSSpellChecker.OptionKey: Any], orthography: NSOrthography, wordCount: Int) {
        super.handleTextCheckingResults(filteredSpellingResults(results), forRange: range, types: checkingTypes, options: options, orthography: orthography, wordCount: wordCount)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let column = projectSettings.borderColumn
        guard column > 0, let font = styledBaseFont ?? font else { return }
        let width = (" " as NSString).size(withAttributes: [.font: font]).width
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) + CGFloat(column) * width
        guard x >= dirtyRect.minX, x <= dirtyRect.maxX else { return }
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath(); line.lineWidth = 1
        line.move(to: NSPoint(x: x, y: dirtyRect.minY)); line.line(to: NSPoint(x: x, y: dirtyRect.maxY)); line.stroke()
    }
}

struct ProjectMessageEditor: NSViewRepresentable {
    @Binding var text: String
    let settings: ProjectDialogSettings
    let label: String
    var preferences: UserDefaults = .standard
    var issueProperties = IssueTrackerProperties()
    var sourceAvailable: () -> Bool = { true }
    var sourceSession: AnyHashable? = nil
    var sourceCommandContext: AnyHashable? = nil
    @AppStorage("LogFontName") private var fontName = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize = MessageEditorFont.defaultSize
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let editor = ProjectMessageTextView(frame: .init(x: 0, y: 0, width: 600, height: 120))
        editor.isRichText = false; editor.allowsUndo = true
        editor.textContainerInset = .init(width: 5, height: 5)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator; scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ProjectMessageTextView else { return }
        editor.messageCommandContext = sourceCommandContext
        if context.coordinator.sourceSession != sourceSession {
            context.coordinator.sourceSession = sourceSession
            editor.resetMessagePresentationSession()
            editor.undoManager?.removeAllActions()
        }
        context.coordinator.text = $text
        editor.isEditable = enabled; editor.setAccessibilityLabel(label)
        editor.sourceLinkAvailable = sourceAvailable
        let font = MessageEditorFont.resolve(name: preferences.string(forKey: "LogFontName") ?? MessageEditorFont.defaultName, size: preferences.object(forKey: "LogFontSize") as? Int ?? MessageEditorFont.defaultSize)
        if editor.string != text {
            let selected = editor.selectedRange(); editor.string = text
            editor.setSelectedRange(.init(location: min(selected.location, (text as NSString).length), length: 0))
        }
        editor.spellingPreferences = preferences
        editor.applyProjectSettings(settings)
        editor.configureSourceStyling(properties: issueProperties, preferences: preferences, font: font)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? ProjectMessageTextView)?.dismissSpellingSuggestions()
        (scroll.documentView as? ProjectMessageTextView)?.retireSourceStyling()
        (scroll.documentView as? NSTextView)?.delegate = nil
    }
    func makeCoordinator() -> Coordinator { Coordinator($text) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var sourceSession: AnyHashable?
        init(_ text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? ProjectMessageTextView, editor.messageLayoutAvailable { text.wrappedValue = editor.string }
        }
    }
}
