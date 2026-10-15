// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FirstStartWizardModel: ObservableObject {
    static var activeWrites = 0
    enum Page: Int, CaseIterable { case language, welcome, git, user, authentication }
    @Published var page = Page.language
    @Published private(set) var busy = false
    @Published private(set) var writing = false
    @Published var name = ""
    @Published var email = ""
    @Published var helper = ""
    @Published var skipUser = false
    @Published var skipHelper = false
    @Published var helpers = [String]()
    @Published var advanced = false
    @Published private(set) var hasCredentialSheet = false
    private(set) var credentialController: CredentialSettingsController?
    private(set) var keyGenerationController: SSHKeyGenerationWindowController?
    @Published var error: String?
    let git: GeneralGitSettingsModel
    private let preferences: UserDefaults
    private let makeRepository: (URL, OperationCancellation) async throws -> GitRepository
    private var task: Task<Void, Never>?
    private var token: OperationCancellation?
    init(preferences: UserDefaults = .standard, makeRepository: @escaping (URL, OperationCancellation) async throws -> GitRepository = { engine, token in
        try token.check(); return try GitRepository(root: TurtleGitTemporaryStorage.root, executable: engine)
    }) {
        self.preferences = preferences; self.makeRepository = makeRepository; git = GeneralGitSettingsModel(preferences: preferences)
    }
    var canNavigate: Bool { !busy && !git.busy && !hasCredentialSheet && !retired }
    var canCancel: Bool { !writing && !hasCredentialSheet && !retired }

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
    func activate() { guard !retired else { return }; git.activate() }
    func retire() {
        guard !retired else { return }; retired = true; token?.cancel(); task?.cancel(); git.suspend()
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
        if page == .language || page == .welcome { page = Page(rawValue: page.rawValue + 1)!; return }
        let current = page, submittedName = name, submittedEmail = email, submittedHelper = helper
        let skipIdentity = skipUser, skipCredentials = skipHelper || advanced, token = OperationCancellation()
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
                    if !skipCredentials {
                        writing = true
                        try await repository.saveFirstStartCredentialHelper(submittedHelper)
                        writing = false
                    }
                    guard !retired else { return }
                    preferences.set(true, forKey: "TurtleGit.FirstStartComplete"); finish()
                }
            } catch { if !retired && !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func back() { guard canNavigate, page != .language else { return }; page = Page(rawValue: page.rawValue - 1)!; error = nil }
}
@MainActor final class FirstStartWizardController: NSWindowController, NSWindowDelegate {
    let model: FirstStartWizardModel
    var onClosed: () -> Void = {}
    init(preferences: UserDefaults = .standard, makeRepository: @escaping (URL, OperationCancellation) async throws -> GitRepository = { engine, token in
        try token.check(); return try GitRepository(root: TurtleGitTemporaryStorage.root, executable: engine)
    }) {
        model = FirstStartWizardModel(preferences: preferences, makeRepository: makeRepository)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "First Start Wizard – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: FirstStartWizardDialog(model: model, git: model.git)); host.sizingOptions = []
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(model.title).font(.title2)
                Spacer(); if let image = MenuIcon.turtle.image(size: 40) { Image(nsImage: image).frame(width: 40, height: 40) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                switch model.page {
                case .language:
                    Text("Select the language used by TurtleGit for Mac.")
                    Picker("Language:", selection: .constant("en")) { Text("English").tag("en") }
                    Text("English is the installed translation. Additional native translations will appear when available.").foregroundStyle(.secondary)
                case .welcome:
                    Text("This wizard configures your Git engine, user information and authentication defaults.")
                    Button("Read the TurtleGit documentation") { TurtleGitHelp.show(.overview) }.buttonStyle(.link)
                    Text("Changes saved with Next remain saved if you cancel a later step. Git user and credential settings are stored globally and provide defaults for your repositories.")
                case .git:
                    Text("TurtleGit requires Git for its operations. Use the bundled engine, or choose an installed Git executable.").fixedSize(horizontal: false, vertical: true)
                    Picker("Git engine:", selection: Binding(get: { GitRuntime.isAppStoreBuild ? .automatic : git.draft.choice }, set: { git.draft.choice = $0 })) {
                        Text("Automatic (bundled when available)").tag(GitEngineChoice.automatic)
                        Text("System Git").tag(GitEngineChoice.system); Text("Custom Git").tag(GitEngineChoice.custom)
                    }.disabled(GitRuntime.isAppStoreBuild)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Git executable:")
                            HStack {
                                TextField("Git executable", text: Binding(get: { git.draft.path }, set: { git.draft.path = $0; git.draft.bookmark = nil })).focused($focused, equals: .gitPath).accessibilityIdentifier("FirstStart.GitPath")
                                Button("Browse…", action: git.browse)
                            }.disabled(GitRuntime.isAppStoreBuild || git.draft.choice != .custom)
                        }
                        GridRow { Text("Extra PATH:"); TextField("Extra PATH", text: $git.draft.extraPath).disabled(GitRuntime.isAppStoreBuild).accessibilityIdentifier("FirstStart.ExtraPath") }
                    }
                    HStack { Text(git.version).textSelection(.enabled); Spacer(); Button("Check now", action: git.check) }
                    Text(GitRuntime.isAppStoreBuild ? "Git and OpenSSH are included in this App Store build." : "Next checks and saves the selected engine. Existing repository windows keep their captured engine until reopened.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error = git.error { Text(error).foregroundStyle(.red) }
                case .user:
                    Text("Git requires a user name and email address. Both identify your commits; they are not your server authentication account.").fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow { Text("Name:"); TextField("Name", text: $model.name).focused($focused, equals: .name).accessibilityIdentifier("FirstStart.Name") }
                        GridRow { Text("Email:"); TextField("Email", text: $model.email).focused($focused, equals: .email).accessibilityIdentifier("FirstStart.Email") }
                    }.disabled(model.skipUser)
                    Text("These settings are stored in your global Git configuration and provide defaults for all your repositories.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Don’t store these settings now.", isOn: $model.skipUser)
                case .authentication:
                    GroupBox("SSH (URLs look like git@example.com)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TurtleGit uses OpenSSH and honors your SSH config, agent and repository command overrides. Configure each remote’s key file in Remote settings.").fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Picker("SSH client:", selection: .constant("openssh")) { Text("OpenSSH").tag("openssh") }
                                Button("Generate SSH key…", action: model.generateSSHKey)
                            }
                        }.padding(8)
                    }
                    GroupBox("HTTP (URLs start with http:// or https://)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("By default Git does not save or cache credentials. Choose an installed credential helper, or use Advanced configuration.").fixedSize(horizontal: false, vertical: true)
                            if model.advanced { Text("Existing URL-specific, multiple or custom credential helpers are preserved.") }
                            else { Picker("Credential helper:", selection: $model.helper) { ForEach(model.helpers, id: \.self) { Text($0.isEmpty ? "None" : $0).tag($0) } }.disabled(model.skipHelper) }
                            HStack {
                                Toggle("Don’t store these settings now.", isOn: $model.skipHelper).disabled(model.advanced)
                                Spacer(); Button("Advanced…", action: model.configureCredentials)
                            }
                            Text("The selected helper is stored globally. Keychain helpers store credentials in the macOS Keychain; store saves them in a plaintext file.").font(.caption)
                        }.padding(8)
                    }
                }
            }.disabled(blocked)
            Spacer()
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("Step \(model.page.rawValue + 1) of 5").foregroundStyle(.secondary)
                if blocked { ProgressView().controlSize(.small) }
                Spacer(); Button("Back", action: model.back).disabled(blocked || model.page == .language)
                Button(model.page == .authentication ? "Finish" : "Next", action: model.next).keyboardShortcut(.defaultAction).disabled(blocked)
                Button("Cancel") { model.window?.performClose(nil) }.keyboardShortcut(.cancelAction).disabled(!model.canCancel)
            }
        }.padding(24)
        .onChange(of: model.page) { page in
            DispatchQueue.main.async { focused = page == .user && !model.skipUser ? .name : page == .git && git.draft.choice == .custom ? .gitPath : nil }
        }
    }
}
@MainActor final class FirstStartWizardService {
    static let shared = FirstStartWizardService()
    private var controller: FirstStartWizardController?
    private var consideredFirstRun = false
    func install() {
        guard !consideredFirstRun else { return }
        consideredFirstRun = true
        guard !UserDefaults.standard.bool(forKey: "TurtleGit.FirstStartComplete"),
              Bundle.main.bundleIdentifier?.hasPrefix("org.turtlegit.macos.documentation-preview") != true,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Wait until SwiftUI has attached the main window before presenting setup.
        Task { @MainActor in await Task.yield(); self.show() }
    }
    func show() {
        if let controller { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        let controller = FirstStartWizardController(); self.controller = controller
        controller.onClosed = { [weak self, weak controller] in if self?.controller === controller { self?.controller = nil } }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
}
