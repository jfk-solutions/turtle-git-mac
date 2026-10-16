import AppKit
import SwiftUI
import TurtleGitCore

typealias SSHCloneTransportFactory = @MainActor (GitRepository) -> SSHTransportCoordinator

@MainActor final class CloneWindowController: NSWindowController, NSWindowDelegate {
    let model: CloneWindowModel
    var onClosed: () -> Void = {}
    private var progressController: CloneProgressWindowController?
    init(directory: URL?, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, executable: URL? = nil, clipboardText:String? = nil) {
        model = CloneWindowModel(directory: directory, access: access, preferences: preferences, executable: executable,clipboardText:clipboardText)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Git Clone – TurtleGit"
        window.minSize = NSSize(width: 780, height: 452)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 452)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CloneDialog(model: model))
        super.init(window: window); TurtleGitHelp.attach(window, topic: .clone); window.delegate = self; model.window = window
        window.setContentSize(NSSize(width: 820, height: 420)); window.center()
        model.close = { [weak self] in guard let self, !self.model.activeOperation, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        model.onExplore = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        model.onProgress = { [weak self] result in
            guard let self, let window = self.window, window.attachedSheet == nil else { result.abandonPresentation(); return }
            let controller = CloneProgressWindowController(model: result); self.progressController = controller
            if let child = controller.window { window.beginSheet(child) { [weak self, weak result] _ in guard let self, let result else { return }; self.progressController = nil; self.model.finish(result) } }
            else { self.progressController = nil; result.abandonPresentation() }
        }

        model.presentSSH = { [weak self] prompt in
            guard let owner = self?.progressController?.window ?? self?.window, owner.attachedSheet == nil, let child = prompt.window else { return false }
            owner.makeFirstResponder(nil); owner.beginSheet(child); return true
        }
        DialogGeometry.attach(window, identifier: "CloneWindowController")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.activeOperation && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); progressController?.close(); progressController = nil; if let window, let child = window.attachedSheet { window.endSheet(child, returnCode: .abort); child.close() }; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class CloneWindowModel: ObservableObject {
    static var activeOperations = 0
    weak var window: NSWindow?
    private(set) var openPanel: NSOpenPanel?
    private var panelReply: CheckedContinuation<URL?, Never>?
    private var panelGeneration = UUID()
    var presentOpenPanel: (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { panel, owner, completion in panel.beginSheetModal(for: owner, completionHandler: completion) }
    var selectedPanelURL: (NSOpenPanel) -> URL? = { $0.url }
    private func choose(_ panel: NSOpenPanel) async -> URL? {
        guard !invalidated, openPanel == nil, let window, window.attachedSheet == nil else { return nil }
        let identity = UUID(); panelGeneration = identity; openPanel = panel
        return await withCheckedContinuation { continuation in
            panelReply = continuation
            presentOpenPanel(panel, window) { [weak self, panel] response in
                guard let self, !self.invalidated, self.panelGeneration == identity, self.openPanel === panel else { return }
                let value = response == .OK ? self.selectedPanelURL(panel) : nil
                self.openPanel = nil; let reply = self.panelReply; self.panelReply = nil; reply?.resume(returning: value)
            }
        }
    }
    private func browse(_ panel: NSOpenPanel, selected: @escaping (URL) -> Void) {
        guard !activeOperation, !invalidated, !finished else { return }
        granting = true; Self.activeOperations += 1
        Task { [self] in
            defer { granting = false; Self.activeOperations -= 1 }
            if let url = await choose(panel), !invalidated, !finished { selected(url) }
        }
    }
    @Published var source = ""
    @Published var directory: String
    @Published var recursive: Bool
    @Published var bare = false
    @Published var noCheckout = false
    @Published var useDepth = false
    @Published var depth = "1"
    @Published var useBranch = false
    @Published var branch = ""
    @Published var useOrigin = false
    @Published var origin = ""
    @Published var useKey = false
    @Published var key = ""
    @Published var svn = false
    @Published var useTrunk = false
    @Published var trunk = "trunk"
    @Published var useTags = false
    @Published var tags = "tags"
    @Published var useBranches = false
    @Published var branches = "branches"
    @Published var useFrom = false
    @Published var from = "0"
    @Published var useUsername = false
    @Published var username = ""
    @Published var busy = false
    @Published var output: String?
    @Published var completed: URL?
    @Published private(set) var completionWarning:String?
    private var pendingInspection:(CloneOutcome,CloneOptions,URL,RepositoryAccessLease,RepositoryAccessLease?)?
    var canShowLog:Bool {clonedRepository != nil}
    @Published var error: String?
    var identities = SSHIdentityAccessStore()
    var makeSSHCoordinator: SSHCloneTransportFactory?
    var presentSSH: (SSHKeyPassphraseWindowController) -> Bool = { _ in false }
    var sshAvailable: Bool { makeSSHCoordinator != nil || (try? SSHAgentRuntime.resolve())?.askpass != nil }
    private var operationCancellation: OperationCancellation?
    private let preferences: UserDefaults
    private let executable: URL?
    private var invalidated = false, finished = false
    @Published private(set) var granting = false
    @Published private(set) var progress: CloneProgressWindowModel?
    var activeOperation: Bool { busy || granting || progress != nil }
    var onProgress: ((CloneProgressWindowModel) -> Void)?
    var onExplore: (URL) -> Void = { _ in }
    func invalidate() {
        invalidated = true; panelGeneration = UUID(); operationCancellation?.cancel(); progress?.invalidate(); keyAccess = nil
        if let panel = openPanel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }
        openPanel = nil; let reply = panelReply; panelReply = nil; reply?.resume(returning: nil)
    }
    func finish(_ result: CloneProgressWindowModel) {
        guard progress === result, !result.busy, !result.confirmingCancellation else { return }
        progress = nil; result.invalidate(); busy = false
        guard !invalidated else { return }; if result.commandCompleted { finished = true; close() }
    }
    private var destinationAccess: RepositoryAccessLease?
    private var sourceAccess: RepositoryAccessLease?
    private var keyAccess: RepositoryAccessLease?
    private var automaticDirectory: String?
    @Published private(set) var urls: [String]
    @Published private(set) var keys: [String]
    var close: () -> Void = {}
    var onCloned: (GitRepository, RepositoryAccessLease, RepositoryAccessLease?, Bool, String) -> Void = { _, _, _, _, _ in }
    var onLog: (GitRepository, RepositoryAccessLease) -> Void = { _, _ in }
    private var clonedRepository: GitRepository?
    init(directory: URL?, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, executable: URL? = nil, clipboardText:String? = nil) {
        self.preferences = preferences; self.executable = executable
        let defaults = preferences
        self.directory = directory?.path ?? defaults.string(forKey: "Clone.Directory") ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        recursive = defaults.bool(forKey: "Clone.Recursive")
        urls = FetchDialogHistory.load(defaults,key:"Clone.URLHistory",caseSensitive:true)
        keys = FetchDialogHistory.load(defaults,key:"Clone.KeyHistory",caseSensitive:true)
        source=clipboardText.flatMap(FetchClipboardInput.cloneSource) ?? urls.first ?? ""
        destinationAccess = access
        key = keys.first ?? ""; useKey = supportsKey && sshAvailable && (defaults.object(forKey: "Clone.UseSSHKey") as? Bool ?? true)
    }
    var pathCompletionPreferences: UserDefaults { preferences }
    var pathCompletionAvailable: Bool { !invalidated && !finished && !activeOperation }
    var pathCompletionPermissions: [RepositoryAccessLease] { [destinationAccess].compactMap { $0 } }
    var supportsKey: Bool {
        let url = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return url.hasPrefix("svn+ssh://") || url.hasPrefix("ssh://") || (!url.contains("://") && !url.hasPrefix("/") && url.contains(":"))
    }
    func deleteURLHistory(at index:Int) {
        guard pathCompletionAvailable,let result=FetchDialogHistory.removing(index,entries:urls,preferences:preferences,key:"Clone.URLHistory") else {return}
        urls=result.entries;source=result.selection;sourceChanged()
    }
    func deleteKeyHistory(at index:Int) {
        guard pathCompletionAvailable,let result=FetchDialogHistory.removing(index,entries:keys,preferences:preferences,key:"Clone.KeyHistory") else {return}
        keys=result.entries;key=result.selection
    }
    private func recordSubmission(_ options:CloneOptions,destination:URL,keyText:String) {
        urls=FetchDialogHistory.save(options.source,entries:urls,preferences:preferences,key:"Clone.URLHistory",caseSensitive:true)
        keys=FetchDialogHistory.save(keyText,entries:keys,preferences:preferences,key:"Clone.KeyHistory",caseSensitive:true)
        preferences.set(destination.deletingLastPathComponent().path,forKey:"Clone.Directory")
        preferences.set(options.recursive,forKey:"Clone.Recursive")
        preferences.set(options.sshKey != nil,forKey:"Clone.UseSSHKey")
    }
    func sourceChanged() {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        var name = value.components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? ""
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        if !name.isEmpty, name != ".", name != "..", !name.contains("\0") {
            if let old = automaticDirectory, directory == old {
                directory = URL(fileURLWithPath: old).deletingLastPathComponent().appendingPathComponent(name).path
                automaticDirectory = directory
            } else if automaticDirectory == nil {
                directory = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                automaticDirectory = directory
            }
        }
        useKey = supportsKey && sshAvailable && (preferences.object(forKey: "Clone.UseSSHKey") as? Bool ?? true)
    }
    func svnChanged() {
        if svn {
            let hasLayout = !source.trimmingCharacters(in: CharacterSet(charactersIn: "/\\").union(.whitespacesAndNewlines)).lowercased().hasSuffix("trunk")
            useTrunk = hasLayout; useTags = hasLayout; useBranches = hasLayout
            useDepth = false; bare = false; recursive = false; useBranch = false; noCheckout = false
        }
    }
    func browseSource() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Select repository"
        browse(panel) { [weak self] url in self?.sourceAccess = RepositoryAccessLease(url: url); self?.source = url.path; self?.sourceChanged() }
    }
    func browseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Select destination"; panel.directoryURL = URL(fileURLWithPath: directory)
        browse(panel) { [weak self] url in self?.destinationAccess = RepositoryAccessLease(url: url); self?.directory = url.path; self?.automaticDirectory = "" }
    }
    func browseKey() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.prompt = "Select OpenSSH key"
        browse(panel) { [weak self] url in self?.acceptKeySelection(url) }
    }
    func acceptKeySelection(_ url: URL) {
        guard !invalidated, !finished, !busy, progress == nil else { return }
        do { try identities.remember(url, requireSecurityScope: GitRuntime.isAppStoreBuild); key = url.path; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func captureSSHFactory() -> SSHCloneTransportFactory {
        if let makeSSHCoordinator { return makeSSHCoordinator }
        let identities = identities, present = presentSSH
        return { repo in let value = SSHTransportCoordinator(repository: repo, identities: identities); value.present = present; return value }
    }
    private func grant(_ target: URL, current: RepositoryAccessLease?, message: String, file: Bool = false) async -> RepositoryAccessLease? {
        guard !invalidated else { return nil }
        if let current, current.contains(target), !GitRuntime.isAppStoreBuild || current.hasSecurityScope { return current }
        if !GitRuntime.isAppStoreBuild { return RepositoryAccessLease(url: target) }
        let panel = NSOpenPanel(); panel.canChooseDirectories = !file; panel.canChooseFiles = file
        panel.message = message; panel.prompt = "Authorize"; panel.directoryURL = file ? target.deletingLastPathComponent() : target
        guard let url = await choose(panel), !invalidated else { return nil }
        let lease = RepositoryAccessLease(url: url)
        guard lease.hasSecurityScope, lease.contains(target) else { error = "The selected permission does not cover “\(target.path)”."; return nil }
        return lease
    }
    func clone() {
        guard !activeOperation, completed == nil, !invalidated, !finished else { return }; granting = true
        do {
            let path = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { throw CloneFailure.destination }
            let destination = URL(fileURLWithPath: path, isDirectory: true)
            let cwd = try CloneOptions.workingDirectory(for: destination)
            var options = CloneOptions(); options.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
            options.recursive = recursive; options.bare = bare; options.noCheckout = noCheckout; options.svn = svn
            if useDepth { guard let value = Int(depth), value > 0 else { throw CloneFailure.number }; options.depth = value }
            if useBranch { options.branch = branch.trimmingCharacters(in: .whitespacesAndNewlines) }
            if useOrigin { options.origin = origin.trimmingCharacters(in: .whitespacesAndNewlines) }
            if svn {
                options.trunk = useTrunk ? trunk : nil; options.tags = useTags ? tags : nil; options.branches = useBranches ? branches : nil
                options.username = useUsername ? username : nil
                if useFrom { guard let value = Int(from), value >= 0 else { throw CloneFailure.number }; options.fromRevision = value }
            }
            if useKey { guard key.hasPrefix("/"), supportsKey else { throw CloneFailure.value }; guard sshAvailable else { throw CloneFailure.keyRuntime }; options.sshKey = URL(fileURLWithPath: key); options.loadSSHKeyWithAgent = true }
            _ = try options.arguments(destination: destination)
            let capturedOptions = options,capturedKeyText=key,preparationToken=OperationCancellation()
            operationCancellation=preparationToken
            Self.activeOperations += 1
            Task { [self] in
                defer { granting = false; Self.activeOperations -= 1;if operationCancellation === preparationToken {operationCancellation=nil} }
                guard !invalidated, !finished else { return }
                do {
                    let options = capturedOptions
            guard let access = await grant(cwd, current: destinationAccess, message: "Authorize the destination or an existing parent folder so TurtleGit can create the clone.") else { return }
            guard !invalidated else { return }
            guard access.contains(destination) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(destination.path) }
            destinationAccess = access
            let localSource = options.source.hasPrefix("/") ? URL(fileURLWithPath: options.source) : URL(string: options.source).flatMap { $0.isFileURL ? $0 : nil }
            if let localSource {
                guard let lease = await grant(localSource, current: sourceAccess, message: "Authorize the local source repository.") else { return }; sourceAccess = lease
            }
            if let key = options.sshKey {
                keyAccess = try identities.acquire(path: key.path, requireSecurityScope: GitRuntime.isAppStoreBuild).permission
            }
            let executable = try self.executable ?? GitRuntime.executable(), snapshot = options
            let capturedSourceAccess = sourceAccess, capturedKeyAccess = keyAccess
            let sshFactory = options.loadSSHKeyWithAgent ? captureSSHFactory() : nil
            let preflight=GitRepository(root:cwd,executable:executable)
            try await preflight.validateClone(snapshot,to:destination,cancellation:preparationToken)
            try preparationToken.check();guard !invalidated,!finished else {return}
            recordSubmission(snapshot,destination:destination,keyText:capturedKeyText)
            busy = true; output = nil; error = nil
            if let onProgress {
                let result = CloneProgressWindowModel(options: snapshot, destination: destination, executable: executable, destinationAccess: access, sourceAccess: capturedSourceAccess, keyAccess: capturedKeyAccess, preferences: preferences)
                result.makeSSHCoordinator = sshFactory
                result.onCloned = { [weak self] repo, output in self?.recordClone(repo, output: output, options: snapshot, destination: destination, access: access, keyAccess: capturedKeyAccess) }
                result.onPostAction = { [weak self] action, repo in guard let self else { return }; if action == .log { self.onLog(repo, access) } else if action == .explore { self.onExplore(repo.root) } }
                result.close = { [weak self, weak result] in guard let self, let result else { return }; self.finish(result) }
                progress = result; onProgress(result); result.start()
            } else {
                let token = OperationCancellation(); operationCancellation = token
                Self.activeOperations += 1
                Task { [self, access, capturedSourceAccess, capturedKeyAccess] in
                    defer { Self.activeOperations -= 1; withExtendedLifetime((access, capturedSourceAccess, capturedKeyAccess)) {} }
                    defer { if operationCancellation === token { operationCancellation = nil; busy = false } }
                    do {
                        let runner = GitRepository(root: cwd, executable: executable)
                        let coordinator = sshFactory?(runner); defer { coordinator?.close() }
                        if snapshot.svn { _ = try await runner.run(["svn", "--version"], cancellation: token) }
                        let outcome = try await runner.cloneOutcome(snapshot,to:destination,cancellation:token,prepareTransport:snapshot.sshKey.flatMap {coordinator?.explicitPreparation(path:$0.path)})
                        guard !invalidated else {return}
                        output=outcome.summary;pendingInspection=(outcome,snapshot,destination,access,capturedKeyAccess)
                        try await finishDirectInspection(cancellation:token)
                    } catch { if !invalidated {
                        if pendingInspection != nil {completed=destination;completionWarning="Clone completed, but the repository could not be opened.\n" + error.localizedDescription}
                        else if !token.isCancelled {self.output=error.localizedDescription;self.error=error.localizedDescription}
                    } }
                }
            }
                } catch { if !invalidated { self.error = error.localizedDescription } }
            }
        } catch { granting = false; if !invalidated { self.error = error.localizedDescription } }
    }
    private func finishDirectInspection(cancellation token:OperationCancellation) async throws {
        guard let (outcome,options,destination,access,keyAccess)=pendingInspection else {return}
        let candidate=GitRepository(root:destination,executable:try executable ?? GitRuntime.executable())
        let repo=options.bare ? candidate:GitRepository(root:try await candidate.discoverRoot(cancellation:token),executable:candidate.executable)
        try token.check();guard !invalidated else {return}
        if GitRuntime.isAppStoreBuild && !access.contains(repo.root) {throw RepositoryAccessFailure.repositoryRootOutsidePermission(repo.root.path)}
        pendingInspection=nil;completionWarning=outcome.warnings.isEmpty ? nil:outcome.warnings.joined(separator:"\n")
        recordClone(repo,output:outcome.summary,options:options,destination:destination,access:access,keyAccess:keyAccess)
    }
    func retryOpeningRepository() {
        guard !invalidated,!activeOperation,pendingInspection != nil else {return}
        let token=OperationCancellation();operationCancellation=token;busy=true;Self.activeOperations += 1
        Task { [self] in
            defer {Self.activeOperations -= 1;if operationCancellation === token {operationCancellation=nil;busy=false}}
            do {try await finishDirectInspection(cancellation:token)}
            catch {if !invalidated {completionWarning="Clone completed, but the repository could not be opened.\n" + error.localizedDescription}}
        }
    }
    private func recordClone(_ repo: GitRepository, output: String, options: CloneOptions, destination: URL, access: RepositoryAccessLease, keyAccess: RepositoryAccessLease?) {
        guard !invalidated else { return }
        clonedRepository = repo; completed = repo.root; self.output = output
        onCloned(repo, access, options.loadSSHKeyWithAgent ? nil : keyAccess, options.bare, output)
    }
    func showLog() { if let repo = clonedRepository, let access = destinationAccess { onLog(repo, access) } }
}

struct CloneDialog: View {
    @ObservedObject var model: CloneWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let destination = model.completed {
                Text("Clone completed").font(.headline)
                Text(destination.path).textSelection(.enabled)
                if let warning=model.completionWarning {Label(warning,systemImage:"exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)}
                OutputView(text: model.output ?? "").frame(maxHeight: .infinity)
                HStack {
                    Button { model.showLog() } label: { CommandLabel(title: "Show Log", icon: .log) }.disabled(!model.canShowLog)
                    if !model.canShowLog {Button("Retry opening repository") {model.retryOpeningRepository()}}
                    Button { NSWorkspace.shared.activateFileViewerSelecting([destination]) } label: { CommandLabel(title: "Show in Finder", icon: .explore) }
                    Spacer(); Button("Close") { model.close() }.keyboardShortcut(.defaultAction)
                }
            } else {
                GroupBox("Clone Existing Repository") {
                    VStack(spacing: 12) {
                        HStack { Text("URL:").frame(width: 70, alignment: .leading); CloneHistoryCombo(value: $model.source, choices: model.urls, label: "Repository URL",onDelete:model.deleteURLHistory)
                            Button("Browse…") { model.browseSource() }
                            Menu {
                                Button { if let url = URL(string: model.source), ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) } } label: { CommandLabel(title: "Open URL", icon: .open) }
                                Button { model.browseSource() } label: { CommandLabel(title: "Browse local repository…", icon: .explore) }
                            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).frame(width: 18)
                        }
                        HStack { Text("Directory:").frame(width: 70, alignment: .leading); PathEntryField(text: $model.directory, label: "Destination directory", permissions: model.pathCompletionPermissions, preferences: model.pathCompletionPreferences, mayEdit: { model.pathCompletionAvailable }).frame(height: 22); Button("Browse…") { model.browseDirectory() } }
                        HStack {
                            Toggle("Depth", isOn: $model.useDepth).disabled(model.svn); TextField("Depth", text: $model.depth).frame(width: 48).disabled(!model.useDepth || model.svn)
                            Toggle("Recursive", isOn: $model.recursive).disabled(model.svn || model.bare)
                            Toggle("Clone into Bare Repo", isOn: $model.bare).disabled(model.svn || model.recursive || model.noCheckout || model.useOrigin)
                            Toggle("No Checkout", isOn: $model.noCheckout).disabled(model.svn || model.bare)
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Toggle("Branch", isOn: $model.useBranch).disabled(model.svn); TextField("Branch", text: $model.branch).disabled(!model.useBranch || model.svn)
                            Toggle("Origin Name", isOn: $model.useOrigin).disabled(model.bare); TextField("Origin name", text: $model.origin).disabled(!model.useOrigin || model.bare)
                        }
                    }.padding(8)
                }
                HStack {
                    Toggle("Auto-load SSH key", isOn: $model.useKey).disabled(!model.supportsKey || !model.sshAvailable).help(model.sshAvailable ? "Load an OpenSSH key into a private agent for this clone." : "SSH key loading is unavailable in this build.")
                    CloneHistoryCombo(value: $model.key, choices: model.keys, label: "OpenSSH private key",onDelete:model.deleteKeyHistory).disabled(!model.useKey || !model.supportsKey || !model.sshAvailable)
                    Button("…") { model.browseKey() }.disabled(!model.useKey || !model.supportsKey || !model.sshAvailable).help("Select an OpenSSH private key.")
                }
                GroupBox("From SVN Repository") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("From SVN Repository", isOn: $model.svn)
                        HStack {
                            Toggle("Trunk", isOn: $model.useTrunk).disabled(!model.svn); TextField("Trunk", text: $model.trunk).disabled(!model.svn || !model.useTrunk)
                            Toggle("Tags", isOn: $model.useTags).disabled(!model.svn); TextField("Tags", text: $model.tags).disabled(!model.svn || !model.useTags)
                            Toggle("Branch", isOn: $model.useBranches).disabled(!model.svn); TextField("SVN branches", text: $model.branches).disabled(!model.svn || !model.useBranches)
                        }
                        HStack {
                            Toggle("From", isOn: $model.useFrom).disabled(!model.svn); TextField("Starting revision", text: $model.from).frame(width: 80).disabled(!model.svn || !model.useFrom)
                            Toggle("Username", isOn: $model.useUsername).disabled(!model.svn); TextField("SVN username", text: $model.username).disabled(!model.svn || !model.useUsername)
                        }
                    }.padding(8)
                }
                Spacer(minLength: 0)
                HStack {
                    if model.busy { ProgressView().controlSize(.small); Text("Cloning…") }
                    Spacer(); Button(model.output == nil ? "OK" : "Retry") { model.clone() }.keyboardShortcut(.defaultAction)
                    Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                    Button("Help") { TurtleGitHelp.show(.clone) }
                }
            }
        }.padding(16).textFieldStyle(.roundedBorder).toggleStyle(.checkbox).disabled(model.activeOperation)
        .onChange(of: model.source) { _ in model.sourceChanged() }
        .onChange(of: model.svn) { _ in model.svnChanged() }
        .onChange(of: model.bare) { value in if value { model.recursive = false; model.noCheckout = false; model.useOrigin = false } }
        .alert("Clone failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

struct CloneHistoryCombo: NSViewRepresentable {
    @Binding var value: String
    let choices: [String]
    let label: String
    var onEndEditing: () -> Void = {}
    var onDelete: ((Int)->Void)? = nil
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox {
        let combo: NSComboBox = onDelete == nil ? NSComboBox():EditableHistoryCombo(); combo.delegate = context.coordinator; combo.completes = true
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal); return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        let coordinator = context.coordinator; coordinator.updating = true; defer { coordinator.updating = false }
        coordinator.change = { value = $0 }; coordinator.endEditing = onEndEditing
        (combo as? EditableHistoryCombo)?.deleteHistory=onDelete
        if !coordinator.choices.elementsEqual(choices,by:{$0.utf16.elementsEqual($1.utf16)}) {
            if let editable=combo as? EditableHistoryCombo {editable.replaceHistory(choices)} else {combo.removeAllItems();combo.addItems(withObjectValues:choices)}
            coordinator.choices=choices
        }
        if combo.stringValue != value { combo.stringValue = value }
        combo.isEnabled = enabled; combo.setAccessibilityLabel(label)
    }
    static func dismantleNSView(_ combo:NSComboBox,coordinator:Coordinator) {combo.delegate=nil;(combo as? EditableHistoryCombo)?.deleteHistory=nil}
    final class Coordinator: NSObject, NSComboBoxDelegate {
        func comboBoxWillPopUp(_ notification:Notification) {(notification.object as? EditableHistoryCombo)?.historyPopupOpen=true}
        func comboBoxWillDismiss(_ notification:Notification) {(notification.object as? EditableHistoryCombo)?.historyPopupOpen=false}
        var endEditing: () -> Void = {}
        func controlTextDidEndEditing(_ notification: Notification) { guard !updating else { return }; endEditing() }
        var choices: [String] = []; var updating = false; var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) { guard !updating, let combo = notification.object as? NSComboBox else { return }; change(combo.stringValue) }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard !updating, let combo = notification.object as? NSComboBox, choices.indices.contains(combo.indexOfSelectedItem) else { return }; change(choices[combo.indexOfSelectedItem]) }
    }
}

enum ClonePostAction: String, Hashable {
    case retry, inspect, log, explore
    var title: String { switch self { case .retry: return "Retry"; case .inspect: return "Retry opening repository"; case .log: return "Show Log"; case .explore: return "Show in Finder" } }
    var icon: MenuIcon { switch self { case .retry,.inspect: return .refresh; case .log: return .log; case .explore: return .explore } }
}
@MainActor final class CloneProgressWindowModel: ObservableObject {
    static var activeOperations = 0
    let progressPresentation: GitCommandPresentation
    let options: CloneOptions
    let destination: URL
    private let executable: URL
    private let destinationAccess: RepositoryAccessLease
    private let sourceAccess: RepositoryAccessLease?, keyAccess: RepositoryAccessLease?
    private let preferences: UserDefaults, autoClosePolicy: GitProgressAutoClose
    private var cancellation = OperationCancellation()
    private var started = false, invalidated = false, dispatched = false, abandoned = false
    private var repository: GitRepository?
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var commandCompleted=false
    @Published private(set) var warnings:[String]=[]
    private var completedOutcome:CloneOutcome?
    private var adopted=false
    var inspectRepository:(GitRepository,Bool,OperationCancellation) async throws -> GitRepository = {candidate,bare,token in
        try token.check()
        return bare ? candidate:GitRepository(root:try await candidate.discoverRoot(cancellation:token),executable:candidate.executable)
    }
    var statusText:String {busy ? cancelling ? "Cancelling…":commandCompleted ? "Opening cloned repository…":"Cloning…" : success ? warnings.isEmpty ? "Finished":"Clone completed with warnings" : commandCompleted ? "Clone completed; repository could not be opened" : cancelled ? "Cancelled":"Clone failed"}
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var percentage: Int?
    @Published private(set) var currentWork = ""
    private let outputLimit: Int
    private var displayedBytes = Data()
    private var displayTruncated = false
    @Published private(set) var output = ""
    @Published private(set) var postActions: [ClonePostAction] = []
    var close: () -> Void = {}
    var onCloned: (GitRepository, String) -> Void = { _,_ in }
    var onPostAction: ((ClonePostAction, GitRepository) -> Void)?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { busy && !cancelling && !confirmingCancellation }
    init(options: CloneOptions, destination: URL, executable: URL, destinationAccess: RepositoryAccessLease, sourceAccess: RepositoryAccessLease?, keyAccess: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.options = options; self.destination = destination; self.executable = executable; self.destinationAccess = destinationAccess; self.sourceAccess = sourceAccess; self.keyAccess = keyAccess; self.preferences = preferences; autoClosePolicy = GitProgressAutoClose(preferences: preferences); progressPresentation = GitCommandPresentation(defaults: preferences); outputLimit = progressPresentation.outputLimit
    }
    var makeSSHCoordinator: SSHCloneTransportFactory?
    func invalidate() { invalidated = true; cancellation.cancel() }
    func abandonPresentation() { abandoned = true; cancellation.cancel() }
    func start() { Task { await run() } }
    func run() async { guard !started, !invalidated else { return }; started = true; await execute() }
    private func execute() async {
        guard !invalidated else { busy = false; return }
        if abandoned { busy = false; finishAutomaticClose(); return }
        Self.activeOperations += 1; defer { Self.activeOperations -= 1; withExtendedLifetime((destinationAccess, sourceAccess, keyAccess)) {} }
        do {
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            let cwd = try CloneOptions.workingDirectory(for: destination)
            if GitRuntime.isAppStoreBuild {
                guard destinationAccess.hasSecurityScope, destinationAccess.contains(cwd), destinationAccess.contains(destination) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                let source = options.source.hasPrefix("/") ? URL(fileURLWithPath: options.source) : URL(string: options.source).flatMap { $0.isFileURL ? $0 : nil }
                if let source { guard sourceAccess?.hasSecurityScope == true, sourceAccess?.contains(source) == true else { throw RepositoryAccessFailure.securityScopeUnavailable } }
                if let key = options.sshKey { guard keyAccess?.hasSecurityScope == true, keyAccess?.contains(key) == true else { throw RepositoryAccessFailure.securityScopeUnavailable } }
            }
            let runner = GitRepository(root: cwd, executable: executable)
            let coordinator = makeSSHCoordinator?(runner); defer { coordinator?.close() }
            let preparation = options.sshKey.flatMap { coordinator?.explicitPreparation(path: $0.path) }
            if options.svn { _ = try await runner.run(["svn", "--version"], cancellation: cancellation) }
            let parser = GitCliOutputParser(limit: outputLimit)
            let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let operation = Task {
                defer { continuation.finish() }
                return try await runner.cloneOutcome(options, to: destination, cancellation: cancellation, onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }, prepareTransport: preparation)
            }
            for await _ in updates { if !invalidated { consume(parser.processPending(), parser: parser) } }
            consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser)
            let outcome=try await operation.value
            guard !invalidated,!abandoned else {busy=false;cancelling=false;return}
            completedOutcome=outcome;commandCompleted=true;warnings=outcome.warnings
            try await inspectCompletedRepository(outcome)
        } catch {
            guard !invalidated else { busy = false; cancelling = false; return }
            let message: String
            if let failure = error as? GitFailure, !displayedBytes.isEmpty, (failure.arguments.first == "clone" || failure.arguments.starts(with: ["svn", "clone"])) { message = "Git command failed (\(failure.code))." }
            else { message = error.localizedDescription }
            output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + message;postActions=commandCompleted ? [.inspect,.explore]:[.retry]
        }
        cancelled = cancellation.isCancelled; busy = false; cancelling = false
        finishAutomaticClose()
    }
    private func inspectCompletedRepository(_ outcome:CloneOutcome) async throws {
        currentWork="Opening cloned repository…";percentage=nil
        let repo=try await inspectRepository(GitRepository(root:destination,executable:executable),options.bare,cancellation)
        try cancellation.check()
        if GitRuntime.isAppStoreBuild && !destinationAccess.contains(repo.root) {throw RepositoryAccessFailure.repositoryRootOutsidePermission(repo.root.path)}
        guard !invalidated,!abandoned else {return}
        repository=repo;success=true;postActions=[.log,.explore];currentWork=""
        if !adopted {adopted=true;onCloned(repo,outcome.summary)}
    }
    private func retryInspection() {
        guard let outcome=completedOutcome,!busy,!invalidated else {return}
        cancellation=OperationCancellation();busy=true;cancelled=false;cancelling=false;postActions=[]
        Self.activeOperations += 1
        Task { [self] in
            defer {Self.activeOperations -= 1;withExtendedLifetime((destinationAccess,sourceAccess,keyAccess)){}}
            do {try await inspectCompletedRepository(outcome)}
            catch {if !invalidated {output += "\n" + error.localizedDescription;postActions=[.inspect,.explore]}}
            guard !invalidated else {busy=false;return}
            cancelled=cancellation.isCancelled;busy=false;cancelling=false;finishAutomaticClose()
        }
    }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        guard !invalidated, !displayTruncated else { return }
        if emission.erasePreviousLineBytes > 0 { displayedBytes.removeLast(min(displayedBytes.count, emission.erasePreviousLineBytes)) }
        displayedBytes.append(emission.data)
        output = String(decoding: displayedBytes, as: UTF8.self).replacingOccurrences(of: "\u{1b}\\[[0-9;]*m|\u{1b}\\[K", with: "", options: .regularExpression)
        let emitted = String(decoding: emission.data, as: UTF8.self)
        for line in emitted.split(separator: "\n") {
            guard let colon = line.lastIndex(of: ":"), let percent = line.firstIndex(of: "%") else { continue }
            currentWork = String(line[..<colon])
            let digits = line[..<percent].reversed().prefix { $0.isASCII && $0.isNumber }.reversed()
            if let value = Int(String(digits)), value > 0 { percentage = min(value, 100) }
        }
        if emission.limited || displayedBytes.count >= outputLimit {
            displayTruncated = true; parser.activateDropMode()
            currentWork = "[Output truncated at about \(displayedBytes.count / 1024) KiB]"; percentage = nil
            output += "\n\n...\n" + currentWork
        }
    }
    private func finishAutomaticClose() { if !busy, !confirmingCancellation, !invalidated, abandoned || warnings.isEmpty && autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() } }
    func cancel() {
        guard canCancel, !invalidated else { return }; let token = cancellation
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true; var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.invalidated, self.cancellation === token else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; token.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: ClonePostAction) {
        guard !busy, !confirmingCancellation, !invalidated, !dispatched, postActions.contains(action) else { return }
        if action == .inspect {retryInspection();return}
        if action == .retry {
            ProgressActionLog.nextAttempt(self);
            busy = true; success = false;commandCompleted=false;completedOutcome=nil;warnings=[];adopted=false; cancelled = false; cancelling = false; output = ""; displayedBytes.removeAll(); displayTruncated = false; percentage = nil; currentWork = ""; postActions = []; repository = nil; cancellation = OperationCancellation()
            Task { await execute() }; return
        }
        guard let target=repository ?? (action == .explore && commandCompleted ? GitRepository(root:destination,executable:executable):nil),let onPostAction else {return};dispatched=true;close();onPostAction(action,target)
    }
}
@MainActor final class CloneProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: CloneProgressWindowModel
    init(model: CloneProgressWindowModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:760,height:430), styleMask: [.titled,.closable,.resizable], backing:.buffered, defer:false)
        window.title = "Clone – TurtleGit"; window.contentMinSize = NSSize(width:600,height:320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:CloneProgressDialog(model:model)); super.init(window:window); window.delegate = self
        model.close = { [weak self] in guard let self, !self.model.busy, !self.model.confirmingCancellation, self.window?.attachedSheet == nil else { return }; if let window = self.window { window.sheetParent?.endSheet(window); window.close() } }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle:"Yes"); alert.addButton(withTitle:"No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for:window) { choose($0 == .alertFirstButtonReturn) }
        }

        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; guard !model.confirmingCancellation, sender.attachedSheet == nil else { return false }; sender.sheetParent?.endSheet(sender); return true }
    func windowWillClose(_ notification: Notification) { model.saveActionLog(); model.invalidate() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
struct CloneProgressDialog: View {
    @ObservedObject var model: CloneProgressWindowModel
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Clone to \(model.destination.path)").font(.headline).textSelection(.enabled)
            ScrollViewReader { reader in
                ScrollView { VStack(alignment: .leading, spacing: 0) { Text(model.output).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading); Color.clear.frame(height: 1).id("clone-output-end") } }
                    .onChange(of: model.output) { _ in reader.scrollTo("clone-output-end", anchor: .bottom) }
            }.frame(maxWidth:.infinity,maxHeight:.infinity).padding(8).background(Color(nsColor:.textBackgroundColor))
            ForEach(Array(model.warnings.enumerated()),id:\.offset) { _,warning in Label(warning,systemImage:"exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled) }
            if model.busy, let percentage = model.percentage { ProgressView(value: Double(percentage), total: 100).tint(.green) }
            if !model.currentWork.isEmpty { Text(model.currentWork).font(.caption).lineLimit(2) }
            HStack { if model.busy && model.percentage == nil { GitCommandActivity(animate: model.progressPresentation.animateActivity) }; Text(model.statusText).foregroundStyle(model.busy ? Color.primary : model.success ? model.warnings.isEmpty ? Color.green:Color.orange : model.commandCompleted ? Color.orange:Color.red); Spacer() }
            HStack { if let first = model.postActions.first { Button { model.perform(first) } label: { CommandLabel(title:first.title,icon:first.icon) }; Menu { ForEach(model.postActions,id:\.self) { action in Button { model.perform(action) } label: { CommandLabel(title:action.title,icon:action.icon) } } } label: { Image(systemName:"chevron.down").accessibilityLabel("Clone post-actions") }.menuStyle(.borderlessButton).fixedSize() }; Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.confirmingCancellation)
        }.padding(12)
        .gitDockProgress(.command(busy: model.busy, success: model.success, waiting: model.confirmingCancellation, percentage: model.percentage))
    }
}
