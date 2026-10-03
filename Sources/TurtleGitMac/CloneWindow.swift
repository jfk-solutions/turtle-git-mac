import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class CloneWindowController: NSWindowController, NSWindowDelegate {
    let model: CloneWindowModel
    var onClosed: () -> Void = {}
    init(directory: URL?, access: RepositoryAccessLease?) {
        model = CloneWindowModel(directory: directory, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Git Clone – TurtleGit"
        window.minSize = NSSize(width: 780, height: 452)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 452)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CloneDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 820, height: 420)); window.center()
        model.close = { [weak window] in window?.close() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
    func windowWillClose(_ notification: Notification) { onClosed() }
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
    init(directory: URL?, access: RepositoryAccessLease?) {
        let defaults = UserDefaults.standard
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
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Select repository"
        if panel.runModal() == .OK, let url = panel.url { sourceAccess = RepositoryAccessLease(url: url); source = url.path; sourceChanged() }
    }
    func browseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Select destination"; panel.directoryURL = URL(fileURLWithPath: directory)
        if panel.runModal() == .OK, let url = panel.url { destinationAccess = RepositoryAccessLease(url: url); directory = url.path; automaticDirectory = "" }
    }
    func browseKey() {
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
        guard !busy, completed == nil else { return }
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
            let executable = try GitRuntime.executable(), snapshot = options
            busy = true; output = nil; error = nil
            Task {
                defer { busy = false }
                do {
                    let runner = GitRepository(root: cwd, executable: executable)
                    if snapshot.svn { _ = try await runner.run(["svn", "--version"]) }
                    let result = try await runner.clone(snapshot, to: destination)
                    let candidate = GitRepository(root: destination, executable: executable)
                    let repo: GitRepository
                    if snapshot.bare { repo = candidate }
                    else { repo = GitRepository(root: try await candidate.discoverRoot(), executable: executable) }
                    clonedRepository = repo; completed = repo.root; output = result
                    let defaults = UserDefaults.standard
                    defaults.set(destination.deletingLastPathComponent().path, forKey: "Clone.Directory")
                    defaults.set(recursive, forKey: "Clone.Recursive")
                    defaults.set(([snapshot.source] + urls.filter { $0 != snapshot.source }).prefix(25).map { $0 }, forKey: "Clone.URLHistory")
                    if let key = snapshot.sshKey { defaults.set(([key.path] + keys.filter { $0 != key.path }).prefix(25).map { $0 }, forKey: "Clone.KeyHistory") }
                    onCloned(repo, access, keyAccess, snapshot.bare, result)
                } catch { self.output = error.localizedDescription; self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func showLog() { if let repo = clonedRepository, let access = destinationAccess { onLog(repo, access) } }
}

private struct CloneDialog: View {
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
        }.padding(16).textFieldStyle(.roundedBorder).toggleStyle(.checkbox).disabled(model.busy)
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
