// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FirstStartWizardModel: ObservableObject {
    static var activeWrites = 0
    enum Page: Int, CaseIterable { case language, welcome, git, user, authentication }
    @Published var page = Page.language
    @Published private(set) var busy = false
    @Published var name = ""
    @Published var email = ""
    @Published var helper = ""
    @Published var skipUser = false
    @Published var skipHelper = false
    @Published var helpers = [String]()
    @Published var advanced = false
    @Published private(set) var hasCredentialSheet = false
    private var credentialController: CredentialSettingsController?
    @Published var error: String?
    let git = GeneralGitSettingsModel()
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
    func activate() { git.activate() }
    func retire() {
        retired = true; git.suspend()
        credentialController?.model.deactivate(); credentialController?.window?.close(); credentialController = nil; hasCredentialSheet = false
        if let panel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        let reply = permissionReply; permissionReply = nil; reply?(false); finish = {}
    }
    func configureCredentials() {
        guard !busy, !hasCredentialSheet, !retired, let repository, let window, window.attachedSheet == nil else { return }
        let controller = CredentialSettingsController(repository: repository, access: nil, localAvailable: false)
        credentialController = controller; hasCredentialSheet = true
        controller.onClosed = { [weak self, weak controller] in
            guard let self, self.credentialController === controller else { return }
            self.credentialController = nil; self.hasCredentialSheet = false
            guard !self.retired else { return }
            self.busy = true
            Task {
                defer { self.busy = false }
                do {
                    let configuration = try await repository.firstStartConfiguration()
                    guard !self.retired else { return }
                    self.helpers = configuration.helpers; self.helper = configuration.selectedHelper
                    self.advanced = configuration.advancedCredentials; self.skipHelper = configuration.advancedCredentials
                } catch { if !self.retired { self.error = error.localizedDescription } }
            }
        }
        if let sheet = controller.window { window.beginSheet(sheet) }
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
    private func prepareConfiguration() async throws -> GitRepository? {
        let repository = try GitRepository(root: TurtleGitTemporaryStorage.root, executable: GitRuntime.executable())
        let files = try await repository.gitConfigurationFiles(hasRepository: false)
        for file in [files.global, files.xdg].compactMap({ $0 }) { guard await authorize(file), !retired else { return nil } }
        return repository
    }
    func next() {
        guard !busy, !git.busy, !hasCredentialSheet, !retired else { return }
        error = nil
        if page == .language || page == .welcome { page = Page(rawValue: page.rawValue + 1)!; return }
        let current = page; busy = true; Self.activeWrites += 1
        Task {
            defer { busy = false; Self.activeWrites -= 1 }
            do {
                if current == .git {
                    guard await git.apply(validateUnchanged: true), !retired else { error = git.error; return }
                    guard let repository = try await prepareConfiguration(), !retired else { return }
                    let configuration = try await repository.firstStartConfiguration()
                    guard !retired else { return }
                    let reloadFields = self.repository == nil || self.repository?.executable != repository.executable
                    self.repository = repository
                    if reloadFields { name = configuration.name; email = configuration.email; helper = configuration.selectedHelper; skipHelper = configuration.advancedCredentials }
                    helpers = configuration.helpers; advanced = configuration.advancedCredentials
                    if advanced { skipHelper = true }; page = .user
                } else if current == .user {
                    guard let repository else { return }
                    if !skipUser { try await repository.saveFirstStartIdentity(name: name, email: email) }
                    guard !retired else { return }; page = .authentication
                } else {
                    guard let repository else { return }
                    if !skipHelper && !advanced { try await repository.saveFirstStartCredentialHelper(helper) }
                    guard !retired else { return }
                    UserDefaults.standard.set(true, forKey: "TurtleGit.FirstStartComplete"); finish()
                }
            } catch { if !retired { self.error = error.localizedDescription } }
        }
    }
    func back() { guard !busy, !git.busy, !hasCredentialSheet, page != .language else { return }; page = Page(rawValue: page.rawValue - 1)!; error = nil }
}
@MainActor final class FirstStartWizardController: NSWindowController, NSWindowDelegate {
    let model = FirstStartWizardModel()
    var onClosed: () -> Void = {}
    init() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 530), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "First Start Wizard – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FirstStartWizardDialog(model: model, git: model.git))
        super.init(window: window); window.delegate = self; window.center()
        model.window = window; model.git.window = window; model.activate()
        model.finish = { [weak window] in window?.close() }
        DialogGeometry.attach(window, identifier: "FirstStartWizard")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && !model.git.busy && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.retire(); onClosed() }
}
private struct FirstStartWizardDialog: View {
    @ObservedObject var model: FirstStartWizardModel
    @ObservedObject var git: GeneralGitSettingsModel
    private var blocked: Bool { model.busy || git.busy || model.hasCredentialSheet }
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
                    Link("Read the TurtleGit documentation", destination: URL(string: "https://jfk-solutions.github.io/turtle-git-mac/")!)
                    Text("Changes saved with Next remain saved if you cancel a later step. Git user and credential settings are stored globally and provide defaults for your repositories.")
                case .git:
                    Picker("Git engine:", selection: $git.draft.choice) {
                        Text("Automatic (bundled when available)").tag(GitEngineChoice.automatic)
                        Text("System Git").tag(GitEngineChoice.system); Text("Custom Git").tag(GitEngineChoice.custom)
                    }.disabled(GitRuntime.isAppStoreBuild)
                    HStack { TextField("Git executable", text: Binding(get: { git.draft.path }, set: { git.draft.path = $0; git.draft.bookmark = nil })); Button("Browse…", action: git.browse) }.disabled(GitRuntime.isAppStoreBuild || git.draft.choice != .custom)
                    TextField("Extra PATH:", text: $git.draft.extraPath).disabled(GitRuntime.isAppStoreBuild)
                    HStack { Text(git.version); Spacer(); Button("Check now", action: git.check) }
                    Text(GitRuntime.isAppStoreBuild ? "Git and OpenSSH are included in this App Store build." : "Next checks and saves the selected engine. Existing repository windows keep their captured engine until reopened.").foregroundStyle(.secondary)
                    if let error = git.error { Text(error).foregroundStyle(.red) }
                case .user:
                    TextField("Name:", text: $model.name).disabled(model.skipUser)
                    TextField("Email:", text: $model.email).disabled(model.skipUser)
                    Toggle("Don’t store these settings now.", isOn: $model.skipUser)
                    Text("This information identifies your commits. It does not change the authentication account used by your Git server.").foregroundStyle(.secondary)
                case .authentication:
                    GroupBox("SSH (URLs look like git@example.com)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("SSH client:", selection: .constant("openssh")) { Text("OpenSSH").tag("openssh") }
                            Text("TurtleGit uses OpenSSH and honors your SSH config, agent and repository command overrides. Configure each remote’s key file in Remote settings.")
                        }.padding(8)
                    }
                    GroupBox("HTTP (URLs start with http:// or https://)") {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.advanced { Text("Existing URL-specific, multiple or custom credential helpers are preserved.") }
                            else { Picker("Credential helper:", selection: $model.helper) { ForEach(model.helpers, id: \.self) { Text($0.isEmpty ? "None" : $0).tag($0) } }.disabled(model.skipHelper) }
                            Toggle("Don’t store these settings now.", isOn: $model.skipHelper).disabled(model.advanced)
                            Button("Advanced configuration…", action: model.configureCredentials)
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
                Button("Cancel") { model.window?.performClose(nil) }.keyboardShortcut(.cancelAction).disabled(blocked)
            }
        }.padding(24)
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
