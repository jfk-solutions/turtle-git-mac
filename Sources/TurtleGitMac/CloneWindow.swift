import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class CloneWindowController: NSWindowController, NSWindowDelegate {
    let model: CloneWindowModel
    var onClosed: () -> Void = {}
    private var progressController: CloneProgressWindowController?
    init(directory: URL?, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, executable: URL? = nil) {
        model = CloneWindowModel(directory: directory, access: access, preferences: preferences, executable: executable)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Git Clone – TurtleGit"
        window.minSize = NSSize(width: 780, height: 452)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 452)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CloneDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 820, height: 420)); window.center()
        model.close = { [weak self] in guard let self, !self.model.activeOperation, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        model.onExplore = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        model.onProgress = { [weak self] result in
            guard let self, let window = self.window, window.attachedSheet == nil else { result.abandonPresentation(); return }
            let controller = CloneProgressWindowController(model: result); self.progressController = controller
            if let child = controller.window { window.beginSheet(child) { [weak self, weak result] _ in guard let self, let result else { return }; self.progressController = nil; self.model.finish(result) } }
            else { self.progressController = nil; result.abandonPresentation() }
        }

        DialogGeometry.attach(window, identifier: "CloneWindowController")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.activeOperation && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class CloneWindowModel: ObservableObject {
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
    @Published var error: String?
    private let preferences: UserDefaults
    private let executable: URL?
    private var invalidated = false, finished = false
    @Published private(set) var granting = false
    @Published private(set) var progress: CloneProgressWindowModel?
    var activeOperation: Bool { busy || granting || progress != nil }
    var onProgress: ((CloneProgressWindowModel) -> Void)?
    var onExplore: (URL) -> Void = { _ in }
    func invalidate() { invalidated = true; progress?.invalidate() }
    func finish(_ result: CloneProgressWindowModel) {
        guard progress === result, !result.busy, !result.confirmingCancellation else { return }
        progress = nil; result.invalidate(); busy = false
        guard !invalidated else { return }; if result.success { finished = true; close() }
    }
    private var destinationAccess: RepositoryAccessLease?
    private var sourceAccess: RepositoryAccessLease?
    private var keyAccess: RepositoryAccessLease?
    private var automaticDirectory: String?
    let urls: [String]
    let keys: [String]
    var close: () -> Void = {}
    var onCloned: (GitRepository, RepositoryAccessLease, RepositoryAccessLease?, Bool, String) -> Void = { _, _, _, _, _ in }
    var onLog: (GitRepository, RepositoryAccessLease) -> Void = { _, _ in }
    private var clonedRepository: GitRepository?
    init(directory: URL?, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, executable: URL? = nil) {
        self.preferences = preferences; self.executable = executable
        let defaults = preferences
        self.directory = directory?.path ?? defaults.string(forKey: "Clone.Directory") ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        recursive = defaults.bool(forKey: "Clone.Recursive")
        urls = defaults.stringArray(forKey: "Clone.URLHistory") ?? []
        keys = defaults.stringArray(forKey: "Clone.KeyHistory") ?? []
        destinationAccess = access
    }
    var supportsKey: Bool {
        let url = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return url.hasPrefix("ssh://") || (!url.contains("://") && !url.hasPrefix("/") && url.contains(":"))
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
        if !supportsKey { useKey = false }
    }
    func svnChanged() {
        if svn {
            let hasLayout = !source.trimmingCharacters(in: CharacterSet(charactersIn: "/\\").union(.whitespacesAndNewlines)).lowercased().hasSuffix("trunk")
            useTrunk = hasLayout; useTags = hasLayout; useBranches = hasLayout
            useDepth = false; bare = false; recursive = false; useBranch = false; noCheckout = false
        }
    }
    func browseSource() {
        guard !activeOperation, !invalidated, !finished else { return }; granting = true; defer { granting = false }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Select repository"
        if panel.runModal() == .OK, let url = panel.url { sourceAccess = RepositoryAccessLease(url: url); source = url.path; sourceChanged() }
    }
    func browseDirectory() {
        guard !activeOperation, !invalidated, !finished else { return }; granting = true; defer { granting = false }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Select destination"; panel.directoryURL = URL(fileURLWithPath: directory)
        if panel.runModal() == .OK, let url = panel.url { destinationAccess = RepositoryAccessLease(url: url); directory = url.path; automaticDirectory = "" }
    }
    func browseKey() {
        guard !activeOperation, !invalidated, !finished else { return }; granting = true; defer { granting = false }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.prompt = "Select OpenSSH key"
        if panel.runModal() == .OK, let url = panel.url { keyAccess = RepositoryAccessLease(url: url); key = url.path }
    }
    private func grant(_ target: URL, current: RepositoryAccessLease?, message: String, file: Bool = false) -> RepositoryAccessLease? {
        if let current, current.contains(target), !GitRuntime.isAppStoreBuild || current.hasSecurityScope { return current }
        if !GitRuntime.isAppStoreBuild { return RepositoryAccessLease(url: target) }
        let panel = NSOpenPanel(); panel.canChooseDirectories = !file; panel.canChooseFiles = file
        panel.message = message; panel.prompt = "Authorize"; panel.directoryURL = file ? target.deletingLastPathComponent() : target
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let lease = RepositoryAccessLease(url: url)
        guard lease.hasSecurityScope, lease.contains(target) else { error = "The selected permission does not cover “\(target.path)”."; return nil }
        return lease
    }
    func clone() {
        guard !activeOperation, completed == nil, !invalidated, !finished else { return }; granting = true; defer { granting = false }
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
            if useKey { guard key.hasPrefix("/"), supportsKey else { throw CloneFailure.value }; options.sshKey = URL(fileURLWithPath: key) }
            _ = try options.arguments(destination: destination)
            guard let access = grant(cwd, current: destinationAccess, message: "Authorize the destination or an existing parent folder so TurtleGit can create the clone.") else { return }
            guard access.contains(destination) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(destination.path) }
            destinationAccess = access
            let localSource = options.source.hasPrefix("/") ? URL(fileURLWithPath: options.source) : URL(string: options.source).flatMap { $0.isFileURL ? $0 : nil }
            if let localSource {
                guard let lease = grant(localSource, current: sourceAccess, message: "Authorize the local source repository.") else { return }; sourceAccess = lease
            }
            if let key = options.sshKey {
                guard FileManager.default.fileExists(atPath: key.path) else { throw CloneFailure.value }
                guard let lease = grant(key, current: keyAccess, message: "Authorize this OpenSSH private key.", file: true) else { return }; keyAccess = lease
            }
            let executable = try self.executable ?? GitRuntime.executable(), snapshot = options
            let capturedSourceAccess = sourceAccess, capturedKeyAccess = keyAccess
            busy = true; output = nil; error = nil
            if let onProgress {
                let result = CloneProgressWindowModel(options: snapshot, destination: destination, executable: executable, destinationAccess: access, sourceAccess: capturedSourceAccess, keyAccess: capturedKeyAccess, preferences: preferences)
                result.onCloned = { [weak self] repo, output in self?.recordClone(repo, output: output, options: snapshot, destination: destination, access: access, keyAccess: capturedKeyAccess) }
                result.onPostAction = { [weak self] action, repo in guard let self else { return }; if action == .log { self.onLog(repo, access) } else if action == .explore { self.onExplore(repo.root) } }
                result.close = { [weak self, weak result] in guard let self, let result else { return }; self.finish(result) }
                progress = result; onProgress(result); result.start()
            } else {
                Task {
                    defer { busy = false }
                    do {
                        let runner = GitRepository(root: cwd, executable: executable)
                        if snapshot.svn { _ = try await runner.run(["svn", "--version"]) }
                        let output = try await runner.clone(snapshot, to: destination)
                        let candidate = GitRepository(root: destination, executable: executable)
                        let repo = snapshot.bare ? candidate : GitRepository(root: try await candidate.discoverRoot(), executable: executable)
                        guard !invalidated else { return }
                        recordClone(repo, output: output, options: snapshot, destination: destination, access: access, keyAccess: capturedKeyAccess)
                    } catch { self.output = error.localizedDescription; self.error = error.localizedDescription }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func recordClone(_ repo: GitRepository, output: String, options: CloneOptions, destination: URL, access: RepositoryAccessLease, keyAccess: RepositoryAccessLease?) {
        guard !invalidated else { return }
        clonedRepository = repo; completed = repo.root; self.output = output
        preferences.set(destination.deletingLastPathComponent().path, forKey: "Clone.Directory")
        preferences.set(options.recursive, forKey: "Clone.Recursive")
        preferences.set(([options.source] + urls.filter { $0 != options.source }).prefix(25).map { $0 }, forKey: "Clone.URLHistory")
        if let key = options.sshKey { preferences.set(([key.path] + keys.filter { $0 != key.path }).prefix(25).map { $0 }, forKey: "Clone.KeyHistory") }
        onCloned(repo, access, keyAccess, options.bare, output)
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
                OutputView(text: model.output ?? "").frame(maxHeight: .infinity)
                HStack {
                    Button { model.showLog() } label: { CommandLabel(title: "Show Log", icon: .log) }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([destination]) } label: { CommandLabel(title: "Show in Finder", icon: .explore) }
                    Spacer(); Button("Close") { model.close() }.keyboardShortcut(.defaultAction)
                }
            } else {
                GroupBox("Clone Existing Repository") {
                    VStack(spacing: 12) {
                        HStack { Text("URL:").frame(width: 70, alignment: .leading); CloneHistoryCombo(value: $model.source, choices: model.urls, label: "Repository URL")
                            Button("Browse…") { model.browseSource() }
                            Menu {
                                Button { if let url = URL(string: model.source), ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) } } label: { CommandLabel(title: "Open URL", icon: .open) }
                                Button { model.browseSource() } label: { CommandLabel(title: "Browse local repository…", icon: .explore) }
                            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).frame(width: 18)
                        }
                        HStack { Text("Directory:").frame(width: 70, alignment: .leading); TextField("Destination directory", text: $model.directory); Button("Browse…") { model.browseDirectory() } }
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
                    Toggle("Use SSH key", isOn: $model.useKey).disabled(!model.supportsKey)
                    CloneHistoryCombo(value: $model.key, choices: model.keys, label: "OpenSSH private key").disabled(!model.useKey)
                    Button("…") { model.browseKey() }.disabled(!model.useKey).help("Select an OpenSSH private key.")
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
                    Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-clone.html")!) }
                }
            }
        }.padding(16).textFieldStyle(.roundedBorder).toggleStyle(.checkbox).disabled(model.activeOperation)
        .onChange(of: model.source) { _ in model.sourceChanged() }
        .onChange(of: model.svn) { _ in model.svnChanged() }
        .onChange(of: model.bare) { value in if value { model.recursive = false; model.noCheckout = false; model.useOrigin = false } }
        .alert("Clone failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

private struct CloneHistoryCombo: NSViewRepresentable {
    @Binding var value: String
    let choices: [String]
    let label: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox(); combo.delegate = context.coordinator; combo.completes = true
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal); return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        let coordinator = context.coordinator; coordinator.updating = true; defer { coordinator.updating = false }
        coordinator.change = { value = $0 }
        if coordinator.choices != choices { combo.removeAllItems(); combo.addItems(withObjectValues: choices); coordinator.choices = choices }
        if combo.stringValue != value { combo.stringValue = value }
        combo.isEnabled = enabled; combo.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var choices: [String] = []; var updating = false; var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) { guard !updating, let combo = notification.object as? NSComboBox else { return }; change(combo.stringValue) }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard !updating, let combo = notification.object as? NSComboBox, choices.indices.contains(combo.indexOfSelectedItem) else { return }; change(choices[combo.indexOfSelectedItem]) }
    }
}

enum ClonePostAction: String, Hashable {
    case retry, log, explore
    var title: String { switch self { case .retry: return "Retry"; case .log: return "Show Log"; case .explore: return "Show in Finder" } }
    var icon: MenuIcon { switch self { case .retry: return .refresh; case .log: return .log; case .explore: return .explore } }
}
@MainActor final class CloneProgressWindowModel: ObservableObject {
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
        self.options = options; self.destination = destination; self.executable = executable; self.destinationAccess = destinationAccess; self.sourceAccess = sourceAccess; self.keyAccess = keyAccess; self.preferences = preferences; autoClosePolicy = GitProgressAutoClose(preferences: preferences); outputLimit = max(16, min(preferences.object(forKey: "GitOutputLimitinKiB") as? Int ?? 2048, 100 * 1024)) * 1024
    }
    func invalidate() { invalidated = true }
    func abandonPresentation() { abandoned = true; cancellation.cancel() }
    func start() { Task { await run() } }
    func run() async { guard !started, !invalidated else { return }; started = true; await execute() }
    private func execute() async {
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
            if options.svn { _ = try await runner.run(["svn", "--version"], cancellation: cancellation) }
            let parser = GitCliOutputParser(limit: outputLimit)
            let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let operation = Task {
                defer { continuation.finish() }
                return try await runner.clone(options, to: destination, cancellation: cancellation, onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) })
            }
            for await _ in updates { if !invalidated { consume(parser.processPending(), parser: parser) } }
            consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser)
            let resultOutput = try await operation.value
            let candidate = GitRepository(root: destination, executable: executable)
            let repo = options.bare ? candidate : GitRepository(root: try await candidate.discoverRoot(), executable: executable)
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            if GitRuntime.isAppStoreBuild && !destinationAccess.contains(repo.root) { throw RepositoryAccessFailure.repositoryRootOutsidePermission(repo.root.path) }
            repository = repo; success = true; postActions = [.log, .explore]
            if !invalidated { onCloned(repo, resultOutput) }
        } catch {
            let message: String
            if let failure = error as? GitFailure, !displayedBytes.isEmpty, (failure.arguments.first == "clone" || failure.arguments.starts(with: ["svn", "clone"])) { message = "Git command failed (\(failure.code))." }
            else { message = error.localizedDescription }
            output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + message; postActions = [.retry]
        }
        cancelled = cancellation.isCancelled; busy = false; cancelling = false
        finishAutomaticClose()
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
    private func finishAutomaticClose() { if !busy, !confirmingCancellation, !invalidated, abandoned || autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() } }
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
        if action == .retry {
            ProgressActionLog.nextAttempt(self);
            busy = true; success = false; cancelled = false; cancelling = false; output = ""; displayedBytes.removeAll(); displayTruncated = false; percentage = nil; currentWork = ""; postActions = []; repository = nil; cancellation = OperationCancellation()
            Task { await execute() }; return
        }
        guard let repository, let onPostAction else { return }; dispatched = true; close(); onPostAction(action, repository)
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
            if model.busy, let percentage = model.percentage { ProgressView(value: Double(percentage), total: 100).tint(.green) }
            if !model.currentWork.isEmpty { Text(model.currentWork).font(.caption).lineLimit(2) }
            HStack { if model.busy && model.percentage == nil { ProgressView().controlSize(.small) }; Text(model.busy ? model.cancelling ? "Cancelling…" : "Cloning…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Clone failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red); Spacer() }
            HStack { if let first = model.postActions.first { Button { model.perform(first) } label: { CommandLabel(title:first.title,icon:first.icon) }; Menu { ForEach(model.postActions,id:\.self) { action in Button { model.perform(action) } label: { CommandLabel(title:action.title,icon:action.icon) } } } label: { Image(systemName:"chevron.down").accessibilityLabel("Clone post-actions") }.menuStyle(.borderlessButton).fixedSize() }; Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.confirmingCancellation)
        }.padding(12)
    }
}
