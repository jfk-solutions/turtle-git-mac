// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor final class FirstStartWizardModel: ObservableObject {
    static var activeWrites = 0
    enum Page: Int, CaseIterable { case language, welcome, git, user, authentication }
    @Published var page = Page.language {didSet {if oldValue != page {formRevision=UUID();pageGeneration=UUID()}}}
    @Published private(set) var busy = false {didSet {if oldValue != busy {formRevision=UUID()}}}
    @Published private(set) var writing = false
    @Published var name = ""
    @Published var email = ""
    @Published var helper = ""
    @Published var skipUser = false {didSet {if oldValue != skipUser {formRevision=UUID()}}}
    @Published var skipHelper = false {didSet {if oldValue != skipHelper {formRevision=UUID()}}}
    @Published var helpers = [String]()
    @Published var advanced = false
    @Published private(set) var hasCredentialSheet = false {didSet {if oldValue != hasCredentialSheet {formRevision=UUID()}}}
    private(set) var credentialController: CredentialSettingsController?
    private(set) var keyGenerationController: SSHKeyGenerationWindowController?
    @Published var error: String?
    let git: GeneralGitSettingsModel
    enum SSHChoice: String { case automatic, custom }
    @Published private(set) var ssh: SSHClientPreferences
    @Published private(set) var sshChoice: SSHChoice
    @Published private(set) var sshVersion = ""
    @Published private(set) var checkingSSH = false
    @Published private(set) var cancellingSSH = false
    @Published private(set) var selectingSSH = false
    private var savedSSH: SSHClientPreferences
    private var customSSH: SSHClientPreferences
    private var sshPanel: NSOpenPanel?
    private var sshChoiceID: UUID?
    private var sshCheckToken: OperationCancellation?
    var presentSSHPanel: (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { $0.beginSheetModal(for: $1, completionHandler: $2) }
    var selectedSSHURL: (NSOpenPanel) -> URL? = { $0.url }
    var bookmarkSSH: (URL) throws -> Data = { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
    var readSSHVersion: (SSHClientPreferences, OperationCancellation) async throws -> String = { value, token in
        try await Task.detached { try value.version(cancellation: token) }.value
    }
    private let preferences: UserDefaults
    private let makeRepository: (URL, OperationCancellation) async throws -> GitRepository
    private var task: Task<Void, Never>?
    private var token: OperationCancellation?
    private var formRevision=UUID()
    private(set) var pageGeneration=UUID()
    private var finished=false
    private var gitTransitions:AnyCancellable?
    init(preferences: UserDefaults = .standard, makeRepository: @escaping (URL, OperationCancellation) async throws -> GitRepository = { engine, token in
        try token.check(); return try GitRepository(root: TurtleGitTemporaryStorage.root, executable: engine)
    }) {
        self.preferences = preferences; self.makeRepository = makeRepository; git = GeneralGitSettingsModel(preferences: preferences)
        let currentSSH = SSHClientPreferences.load(from: preferences)
        savedSSH = currentSSH; customSSH = currentSSH
        ssh = GitRuntime.isAppStoreBuild ? SSHClientPreferences() : currentSSH
        sshChoice = GitRuntime.isAppStoreBuild || currentSSH.path.isEmpty ? .automatic : .custom
        gitTransitions=Publishers.CombineLatest3(git.$busy,git.$selecting,git.$confirmingUpdates).dropFirst().sink { [weak self] _ in self?.formRevision=UUID() }
    }
    var canNavigate: Bool { !busy && !git.busy && !git.selecting && !git.confirmingUpdates && !hasCredentialSheet && !checkingSSH && !selectingSSH && !retired && !finished }
    var canCancel: Bool { !writing && !hasCredentialSheet && !git.selecting && !git.confirmingUpdates && !selectingSSH && !retired && !finished }
    struct FormContext:Equatable {let owner:ObjectIdentifier;let revision:UUID;let page:Page}
    var formContext:FormContext {.init(owner:ObjectIdentifier(self),revision:formRevision,page:page)}
    private func accepts(_ context:FormContext)->Bool {canNavigate && context==formContext}
    func field<Value>(_ key:ReferenceWritableKeyPath<FirstStartWizardModel,Value>,context:FormContext)->Binding<Value> {
        Binding(get:{self[keyPath:key]},set:{value in
            guard self.accepts(context) else{return}
            if key == \FirstStartWizardModel.name || key == \FirstStartWizardModel.email {guard self.page == .user,!self.skipUser else{return}}
            if key == \FirstStartWizardModel.skipUser {guard self.page == .user else{return}}
            if key == \FirstStartWizardModel.helper {guard self.page == .authentication,!self.skipHelper,!self.advanced else{return}}
            if key == \FirstStartWizardModel.skipHelper {guard self.page == .authentication,!self.advanced else{return}}
            self[keyPath:key]=value
        })
    }
    func language(context: FormContext) -> Binding<String> {
        Binding(get: { self.git.language }, set: { id in
            guard self.accepts(context), self.page == .language, AppLanguageChoice.isAvailable(id) else { return }
            self.git.chooseLanguage(id); self.formRevision = UUID()
        })
    }
    func gitChoice(context:FormContext)->Binding<GitEngineChoice> {
        Binding(get:{GitRuntime.isAppStoreBuild ? .automatic:self.git.draft.choice},set:{value in
            guard self.accepts(context),self.page == .git,self.git.canEditEngine else{return}
            self.git.draft.choice=value;self.formRevision=UUID()
        })
    }
    func gitText(_ path:Bool,context:FormContext)->Binding<String> {
        Binding(get:{path ? self.git.draft.path:self.git.draft.extraPath},set:{value in
            guard self.accepts(context),self.page == .git,self.git.canEditEngine else{return}
            if path {guard self.git.draft.choice == .custom else{return};self.git.draft.path=value;self.git.draft.bookmark=nil}
            else {self.git.draft.extraPath=value}
        })
    }
    func browseGit(context:FormContext) {guard accepts(context),page == .git,git.draft.choice == .custom else{return};git.browse()}
    func checkGit(context:FormContext) {guard accepts(context),page == .git else{return};git.check()}
    func cancelGitCheck() {guard !retired,page == .git else{return};git.cancelCheck()}
    func next(context:FormContext) {guard accepts(context) else{return};next()}
    func back(context:FormContext) {guard accepts(context) else{return};back()}
    func generateSSHKey(context:FormContext) {guard accepts(context) else{return};generateSSHKey()}
    func configureCredentials(context:FormContext) {guard accepts(context) else{return};configureCredentials()}
    func focusAllowed(page:Page,generation:UUID)->Bool {canNavigate && self.page==page && pageGeneration==generation}

    var canEditSSH: Bool { canNavigate && page == .authentication && !GitRuntime.isAppStoreBuild }
    func sshChoiceBinding(context: FormContext) -> Binding<SSHChoice> {
        Binding(get: { self.sshChoice }, set: { self.chooseSSH($0, context: context) })
    }
    func chooseSSH(_ choice: SSHChoice, context: FormContext) {
        guard accepts(context), canEditSSH else { return }
        if sshChoice == .custom { customSSH = ssh }
        sshChoice = choice; ssh = choice == .automatic ? SSHClientPreferences() : customSSH
        sshVersion = ""; error = nil; formRevision = UUID()
    }
    func sshPathBinding(context: FormContext) -> Binding<String> {
        Binding(get: { self.ssh.path }, set: { self.editSSHPath($0, context: context) })
    }
    func editSSHPath(_ value: String, context: FormContext) {
        guard accepts(context), canEditSSH, sshChoice == .custom else { return }
        ssh.path = value; ssh.bookmark = nil; customSSH = ssh; sshVersion = ""; error = nil
    }
    private func checkedSSH(_ value: SSHClientPreferences, choice: SSHChoice, token: OperationCancellation) async throws -> String {
        try token.check()
        if choice == .custom, value.path.isEmpty { throw NetworkSettingsFailure.ssh }
        let version = try await readSSHVersion(value, token)
        try token.check(); return version
    }
    func checkSSH(context: FormContext) {
        guard accepts(context), canEditSSH, let window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        let submitted = ssh, choice = sshChoice, token = OperationCancellation(), pageVisit = pageGeneration
        sshCheckToken = token; checkingSSH = true; cancellingSSH = false; formRevision = UUID(); error = nil
        Self.activeWrites += 1
        Task { [self] in
            defer { Self.activeWrites -= 1; if sshCheckToken === token { sshCheckToken = nil; checkingSSH = false; cancellingSSH = false; formRevision = UUID() } }
            do {
                let version = try await checkedSSH(submitted, choice: choice, token: token)
                guard !retired, page == .authentication, pageGeneration == pageVisit, self.window === window, ssh == submitted, sshChoice == choice else { return }
                sshVersion = version
            } catch { if !retired, !token.isCancelled, pageGeneration == pageVisit, self.window === window, ssh == submitted, sshChoice == choice { self.error = error.localizedDescription } }
        }
    }
    func cancelSSHCheck() {
        guard !retired, checkingSSH, !cancellingSSH else { return }
        cancellingSSH = true; sshCheckToken?.cancel()
    }
    func browseSSH(context: FormContext) {
        guard accepts(context), canEditSSH, sshChoice == .custom, sshPanel == nil,
              let window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        let chooser = NSOpenPanel(), request = UUID(), submitted = ssh, visit = pageGeneration
        chooser.canChooseFiles = true; chooser.canChooseDirectories = false
        chooser.title = "Choose OpenSSH client"; chooser.prompt = "Select SSH"
        chooser.directoryURL = URL(fileURLWithPath: ssh.path.isEmpty ? "/usr/bin" : (ssh.path as NSString).deletingLastPathComponent)
        chooser.alphaValue = window.alphaValue; chooser.appearance = window.appearance
        sshPanel = chooser; sshChoiceID = request; selectingSSH = true; formRevision = UUID(); Self.activeWrites += 1
        presentSSHPanel(chooser, window) { [weak self, weak chooser] response in
            guard let self, let chooser, self.sshPanel === chooser, self.sshChoiceID == request else { return }
            self.sshPanel = nil; self.sshChoiceID = nil
            SettingsLifecycleSheetDrain.close([chooser]) { [self] in
                Self.activeWrites -= 1
                guard !self.retired else { return }
                self.selectingSSH = false; self.formRevision = UUID()
                guard self.page == .authentication, self.pageGeneration == visit, self.window === window, self.ssh == submitted,
                      self.sshChoice == .custom, response == .OK, let file = self.selectedSSHURL(chooser) else { return }
                do {
                    var directory: ObjCBool = false
                    guard file.isFileURL, FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue,
                          FileManager.default.isExecutableFile(atPath: file.path) else { throw NetworkSettingsFailure.ssh }
                    var selected = submitted; selected.bookmark = try self.bookmarkSSH(file); selected.path = file.path
                    self.ssh = selected; self.customSSH = selected; self.sshVersion = ""; self.error = nil
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private var repository: GitRepository?
    private var panel: NSOpenPanel?
    private var permissionReply: ((Bool) -> Void)?
    private var retired = false
    weak var window: NSWindow?
    var finish: () -> Void = {}
    var title: String {
        switch page {
        case .language: return "Select language"
        case .welcome: return "Welcome to TurtleGit for Mac!"
        case .git: return "Configure Git"
        case .user: return "Configure user information"
        case .authentication: return "Authentication and credential store"
        }
    }
    func activate() {
        guard !retired else { return }; git.activate()
        guard repository == nil, page == .user || page == .authentication, !busy else { return }
        let token = OperationCancellation(); self.token = token; busy = true; Self.activeWrites += 1
        task = Task {
            defer { busy = false; self.token = nil; task = nil; Self.activeWrites -= 1 }
            do {
                guard let repository = try await prepareConfiguration(token) else { if !retired { page = .git }; return }
                let configuration = try await repository.firstStartConfiguration(cancellation: token)
                try token.check(); guard !retired else { return }
                self.repository = repository; name = configuration.name; email = configuration.email
                helpers = configuration.helpers; helper = configuration.selectedHelper; advanced = configuration.advancedCredentials
                if advanced { skipHelper = true }
            } catch { if !retired, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func retire() {
        guard !retired else { return }; retired = true; token?.cancel(); task?.cancel(); sshCheckToken?.cancel(); git.suspend()
        if let chooser = sshPanel {
            sshPanel = nil; sshChoiceID = nil
            SettingsLifecycleSheetDrain.close([chooser]) { Self.activeWrites -= 1 }
        }
        credentialController?.model.deactivate(); credentialController?.window?.close(); credentialController = nil; hasCredentialSheet = false
        keyGenerationController?.model.retire(); keyGenerationController?.window?.close(); keyGenerationController = nil
        if let panel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        let reply = permissionReply; permissionReply = nil; reply?(false); finish = {}
    }
    func generateSSHKey() {
        guard canNavigate, page == .authentication, let window, window.attachedSheet == nil else { return }
        let controller = SSHKeyGenerationWindowController(); keyGenerationController = controller; hasCredentialSheet = true
        controller.onClosed = { [weak self, weak controller] in
            guard let self, self.keyGenerationController === controller else { return }
            self.keyGenerationController = nil; self.hasCredentialSheet = false
        }
        if let sheet = controller.window { sheet.alphaValue = window.alphaValue; sheet.appearance = window.appearance; window.beginSheet(sheet) }
    }
    func configureCredentials() {
        guard canNavigate, page == .authentication, let repository, let window, window.attachedSheet == nil else { return }
        skipHelper = true // Upstream Advanced explicitly selects Don’t store.
        let controller = CredentialSettingsController(repository: repository, access: nil, localAvailable: false)
        credentialController = controller; hasCredentialSheet = true
        controller.onClosed = { [weak self, weak controller] in
            guard let self, self.credentialController === controller else { return }
            self.credentialController = nil; self.hasCredentialSheet = false
            guard !self.retired else { return }
            self.reloadAuthentication(repository)
        }
        if let sheet = controller.window { sheet.alphaValue = window.alphaValue; sheet.appearance = window.appearance; window.beginSheet(sheet) }
    }
    private func reloadAuthentication(_ repository: GitRepository) {
        guard !retired, !busy else { return }
        let token = OperationCancellation(); self.token = token; busy = true; Self.activeWrites += 1
        task = Task {
            defer { Self.activeWrites -= 1; busy = false; self.token = nil; task = nil }
            do {
                let configuration = try await repository.firstStartConfiguration(cancellation: token)
                guard !retired, !token.isCancelled else { return }
                helpers = configuration.helpers; helper = configuration.selectedHelper
                advanced = configuration.advancedCredentials
                if advanced { skipHelper = true }
            } catch { if !retired && !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func authorize(_ file: URL) async -> Bool {
        if GitConfigurationPermissions.authorized(file) { return true }
        guard !retired, let window, window.attachedSheet == nil else { return false }
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = true; chooser.canChooseFiles = false; chooser.canCreateDirectories = true
        chooser.directoryURL = file.deletingLastPathComponent(); chooser.prompt = "Authorize"
        chooser.message = "Select the folder containing " + file.path + " to read and save Git configuration."
        panel = chooser
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            permissionReply = reply
            chooser.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.panel === chooser else { reply(false); return }; self.panel = nil; self.permissionReply = nil
                guard response == .OK, !self.retired, let directory = chooser.url else { reply(false); return }
                do { try GitConfigurationPermissions.remember(directory, for: file); reply(true) }
                catch { self.error = error.localizedDescription; reply(false) }
            }
        }
    }
    private func prepareConfiguration(_ token: OperationCancellation) async throws -> GitRepository? {
        let repository = try await makeRepository(GitRuntime.executable(preferences: preferences), token)
        try token.check()
        let files = try await repository.gitConfigurationFiles(hasRepository: false, cancellation: token)
        for file in [files.global, files.xdg].compactMap({ $0 }) { guard await authorize(file), !retired else { return nil } }
        return repository
    }
    func next() {
        guard canNavigate else { return }
        error = nil
        if page == .language {
            guard git.applyLanguage() else { error = git.error; return }
            page = .welcome; return
        }
        if page == .welcome { page = .git; return }
        let current = page, submittedName = name, submittedEmail = email, submittedHelper = helper
        let skipIdentity = skipUser, skipCredentials = skipHelper || advanced, token = OperationCancellation()
        let submittedSSH = ssh, submittedSSHChoice = sshChoice
        self.token = token; busy = true; Self.activeWrites += 1
        task = Task {
            defer { busy = false; writing = false; self.token = nil; task = nil; Self.activeWrites -= 1 }
            do {
                try token.check()
                if current == .git {
                    guard await git.apply(validateUnchanged: true, cancellation: token), !retired else { if !retired && !token.isCancelled { error = git.error }; return }
                    guard let repository = try await prepareConfiguration(token), !retired else { return }
                    let configuration = try await repository.firstStartConfiguration(cancellation: token)
                    guard !retired else { return }
                    let reloadFields = self.repository == nil || self.repository?.executable != repository.executable
                    self.repository = repository
                    if reloadFields { name = configuration.name; email = configuration.email; helper = configuration.selectedHelper }
                    helpers = configuration.helpers; advanced = configuration.advancedCredentials
                    if advanced { skipHelper = true }; page = .user
                } else if current == .user {
                    guard let repository else { return }
                    if !skipIdentity {
                        writing = true
                        try await repository.saveFirstStartIdentity(name: submittedName, email: submittedEmail)
                        writing = false
                    }
                    guard !retired else { return }; page = .authentication
                } else {
                    guard let repository else { return }
                    // Source saves the SSH choice before attempting credential-helper writes.
                    // Validate only a changed choice: existing custom clients remain repairable
                    // from Network settings and are never replaced by opening this wizard.
                    if !GitRuntime.isAppStoreBuild, submittedSSH != savedSSH {
                        let version = try await checkedSSH(submittedSSH, choice: submittedSSHChoice, token: token)
                        try token.check(); guard !retired, ssh == submittedSSH, sshChoice == submittedSSHChoice else { return }
                        writing = true; try submittedSSH.save(to: preferences); savedSSH = submittedSSH; sshVersion = version; writing = false
                    } else if !GitRuntime.isAppStoreBuild, submittedSSHChoice == .custom, submittedSSH.path.isEmpty {
                        throw NetworkSettingsFailure.ssh
                    }
                    if !skipCredentials {
                        writing = true
                        try await repository.saveFirstStartCredentialHelper(submittedHelper)
                        writing = false
                    }
                    guard !retired else { return }
                    finished=true;formRevision=UUID();preferences.set(true, forKey: "TurtleGit.FirstStartComplete"); finish()
                }
            } catch { if !retired && !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func back() { guard canNavigate, page != .language else { return }; page = Page(rawValue: page.rawValue - 1)!; error = nil }
}
@MainActor final class FirstStartWizardController: NSWindowController, NSWindowDelegate {
    let model: FirstStartWizardModel
    var onClosed: () -> Void = {}
    init(preferences: UserDefaults = .standard, initialPage: Int = 0, makeRepository: @escaping (URL, OperationCancellation) async throws -> GitRepository = { engine, token in
        try token.check(); return try GitRepository(root: TurtleGitTemporaryStorage.root, executable: engine)
    }) {
        model = FirstStartWizardModel(preferences: preferences, makeRepository: makeRepository)
        model.page = FirstStartWizardModel.Page(rawValue: initialPage) ?? .language
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "First Start Wizard – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: FirstStartWizardDialog(model: model, git: model.git).defaultAppStorage(preferences)); host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 700, height: 560))
        super.init(window: window); window.delegate = self; window.center()
        model.window = window; model.git.window = window; model.activate()
        model.finish = { [weak window] in window?.close() }
        DialogGeometry.attach(window, identifier: "FirstStartWizard")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.canCancel && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.retire(); onClosed() }
}
private struct FirstStartWizardDialog: View {
    @ObservedObject var model: FirstStartWizardModel
    @ObservedObject var git: GeneralGitSettingsModel
    @FocusState private var focused: Field?
    private enum Field { case gitPath, name, email }
    private var blocked: Bool { !model.canNavigate }
    var body: some View {
        let context=model.formContext
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(LocalizedStringKey(model.title)).font(.title2)
                Spacer(); if let image = MenuIcon.turtle.image(size: 40) { Image(nsImage: image).frame(width: 40, height: 40) }
            }
            Divider()
            ScrollView {VStack(alignment: .leading, spacing: 14) {
                switch model.page {
                case .language:
                    Text("Select the language used by TurtleGit for Mac.")
                    Picker("Language:", selection: model.language(context: context)) {
                        ForEach(AppLanguageChoice.choices) { AppLanguageLabel(choice: $0).tag($0.id) }
                    }
                    Text("Restart TurtleGit to apply a language change. Some text is still in English.").foregroundStyle(.secondary)
                    Button("Language help") { TurtleGitHelp.show(.languages) }.buttonStyle(.link)
                case .welcome:
                    Text("This wizard configures your Git engine, user information and authentication defaults.")
                    Button("Read the TurtleGit documentation") { TurtleGitHelp.show(.overview) }.buttonStyle(.link)
                    Text("Changes saved with Next remain saved if you cancel a later step. Git user and credential settings are stored globally and provide defaults for your repositories.")
                case .git:
                    Text("TurtleGit requires Git for its operations. Use the bundled engine, or choose an installed Git executable.").fixedSize(horizontal: false, vertical: true)
                    Picker("Git engine:", selection: model.gitChoice(context:context)) {
                        Text("Automatic (bundled when available)").tag(GitEngineChoice.automatic)
                        Text("System Git").tag(GitEngineChoice.system); Text("Custom Git").tag(GitEngineChoice.custom)
                    }.disabled(GitRuntime.isAppStoreBuild)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Git executable:")
                            HStack {
                                TextField("Git executable", text: model.gitText(true,context:context)).focused($focused, equals: .gitPath).accessibilityIdentifier("FirstStart.GitPath")
                                Button("Browse…") {model.browseGit(context:context)}
                            }.disabled(GitRuntime.isAppStoreBuild || git.draft.choice != .custom)
                        }
                        GridRow { Text("Extra PATH:"); TextField("Extra PATH", text: model.gitText(false,context:context)).disabled(GitRuntime.isAppStoreBuild).accessibilityIdentifier("FirstStart.ExtraPath") }
                    }
                    HStack { Text(git.version).textSelection(.enabled); Spacer(); Button("Check now") {model.checkGit(context:context)} }
                    Text("Recommended: bundled Git for macOS").foregroundStyle(.secondary)
                    Button("Git runtime and installation help") {TurtleGitHelp.show(.settings)}.buttonStyle(.link)
                    Text(GitRuntime.isAppStoreBuild ? "Git and OpenSSH are included in this App Store build." : "Next checks and saves the selected engine. Existing repository windows keep their captured engine until reopened.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error = git.error { Text(error).foregroundStyle(.red) }
                case .user:
                    Text("Git requires a user name and email address. Both identify your commits; they are not your server authentication account.").fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow { Text("Name:"); TextField("Name", text: model.field(\.name,context:context)).focused($focused, equals: .name).accessibilityIdentifier("FirstStart.Name") }
                        GridRow { Text("Email:"); TextField("Email", text: model.field(\.email,context:context)).focused($focused, equals: .email).accessibilityIdentifier("FirstStart.Email") }
                    }.disabled(model.skipUser)
                    Text("These settings are stored in your global Git configuration and provide defaults for all your repositories.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Don’t store these settings now.", isOn: model.field(\.skipUser,context:context))
                case .authentication:
                    GroupBox("SSH (URLs look like git@example.com)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TurtleGit uses OpenSSH and honors your SSH config, agent and repository command overrides. Configure each remote’s key file in Remote settings.").fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Picker("SSH client:", selection: model.sshChoiceBinding(context: context)) {
                                    Text("Automatic OpenSSH").tag(FirstStartWizardModel.SSHChoice.automatic)
                                    Text("Custom OpenSSH").tag(FirstStartWizardModel.SSHChoice.custom)
                                }.disabled(GitRuntime.isAppStoreBuild).accessibilityIdentifier("FirstStart.SSHChoice")
                                Button("Generate SSH key…") {model.generateSSHKey(context:context)}
                            }
                            if model.sshChoice == .custom {
                                HStack {
                                    TextField("SSH client", text: model.sshPathBinding(context: context)).accessibilityIdentifier("FirstStart.SSHPath")
                                    Button("Browse…") { model.browseSSH(context: context) }
                                }
                            }
                            HStack { Text(model.sshVersion).textSelection(.enabled); Spacer(); Button("Check now") { model.checkSSH(context: context) }.disabled(GitRuntime.isAppStoreBuild) }
                            if GitRuntime.isAppStoreBuild { Text("Git and OpenSSH are included in this App Store build.").font(.caption) }
                        }.padding(8)
                    }
                    Button("OpenSSH setup and FAQ") {TurtleGitHelp.show(.ssh)}.buttonStyle(.link)
                    GroupBox("HTTP (URLs start with http:// or https://)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("By default Git does not save or cache credentials. Choose an installed credential helper, or use Advanced configuration.").fixedSize(horizontal: false, vertical: true)
                            if model.advanced { Text("Existing URL-specific, multiple or custom credential helpers are preserved.") }
                            else { Picker("Credential helper:", selection: model.field(\.helper,context:context)) { ForEach(model.helpers, id: \.self) { Text($0.isEmpty ? "None" : $0).tag($0) } }.disabled(model.skipHelper) }
                            HStack {
                                Toggle("Don’t store these settings now.", isOn: model.field(\.skipHelper,context:context)).disabled(model.advanced)
                                Spacer(); Button("Advanced…") {model.configureCredentials(context:context)}
                            }
                            Text("The selected helper is stored globally. Keychain helpers store credentials in the macOS Keychain; store saves them in a plaintext file.").font(.caption)
                        }.padding(8)
                    }
                }
            }.frame(maxWidth:.infinity,alignment:.leading)}.disabled(blocked)
            if model.checkingSSH { Button(model.cancellingSSH ? "Cancelling check…" : "Cancel check", action: model.cancelSSHCheck).disabled(model.cancellingSSH) }
            if git.checking {Button(git.cancellingCheck ? "Cancelling check…":"Cancel check",action:model.cancelGitCheck).disabled(git.cancellingCheck)}
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("Step \(model.page.rawValue + 1) of 5").foregroundStyle(.secondary)
                if blocked { ProgressView().controlSize(.small) }
                Spacer(); Button("Back") {model.back(context:context)}.disabled(blocked || model.page == .language)
                Button {model.next(context:context)} label: {Text(LocalizedStringKey(model.page == .authentication ? "Finish" : "Next"))}.keyboardShortcut(.defaultAction).disabled(blocked)
                Button("Cancel") { model.window?.performClose(nil) }.keyboardShortcut(.cancelAction).disabled(!model.canCancel)
            }
        }.padding(24)
        .onChange(of: model.page) { _ in scheduleFocus() }
        .onChange(of: model.canNavigate) { ready in if ready {scheduleFocus()} }
    }
    private func scheduleFocus() {
        let page=model.page,generation=model.pageGeneration
        DispatchQueue.main.async {
            guard model.focusAllowed(page:page,generation:generation) else{return}
            focused = page == .user && !model.skipUser ? .name : page == .git && git.draft.choice == .custom ? .gitPath : nil
        }
    }
}
@MainActor final class FirstStartWizardService {
    static let shared = FirstStartWizardService()
    private(set) var controller: FirstStartWizardController?
    var create: (UserDefaults, Int) -> FirstStartWizardController = { FirstStartWizardController(preferences: $0, initialPage: $1) }
    var present: (FirstStartWizardController) -> Void = { $0.showWindow(nil); $0.window?.makeKeyAndOrderFront(nil) }
    private var consideredFirstRun = false
    func install() {
        if (try? MergeToolInvocation.parse(arguments: Array(CommandLine.arguments.dropFirst()), currentDirectory: FileManager.default.currentDirectoryPath)) != nil { return }
        guard !consideredFirstRun else { return }
        consideredFirstRun = true
        // An explicit wizard page must not race the automatic first-run page.
        if let invocation = try? PrimaryCommandInvocation.parse(arguments: Array(CommandLine.arguments.dropFirst()), currentDirectory: FileManager.default.currentDirectoryPath), invocation.request.action == .firstStartWizard { return }
        guard !UserDefaults.standard.bool(forKey: "TurtleGit.FirstStartComplete"),
              Bundle.main.bundleIdentifier?.hasPrefix("org.turtlegit.macos.documentation-preview") != true,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Wait until SwiftUI has attached the main window before presenting setup.
        Task { @MainActor in await Task.yield(); self.show() }
    }
    func show(initialPage: Int = 0, preferences: UserDefaults = .standard) {
        if let controller { present(controller); return }
        let controller = create(preferences, initialPage); self.controller = controller
        controller.onClosed = { [weak self, weak controller] in if self?.controller === controller { self?.controller = nil } }
        present(controller)
    }
}
