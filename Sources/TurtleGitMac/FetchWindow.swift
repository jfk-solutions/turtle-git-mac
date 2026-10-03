import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FetchWindowController: NSWindowController, NSWindowDelegate {
    let model: FetchWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = FetchWindowModel(repository: repository, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Fetch – TurtleGit"; window.minSize = NSSize(width: 660, height: 450); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FetchDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.close() }
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class FetchWindowModel: ObservableObject {
    let repository: GitRepository
    let remoteSettings: PushWindowModel
    private let access: RepositoryAccessLease?
    @Published var options = FetchOptions()
    @Published var remotes: [String] = []
    @Published var branches: [String] = []
    @Published var url = ""
    @Published var depthEnabled = false
    @Published var depth = "1"
    @Published var shallow = false
    @Published var bare = false
    @Published var launchRebase = false
    @Published var tagsDefault = ""
    @Published var pruneDefault = ""
    @Published var busy = false
    @Published var error: String?
    @Published var browsing = false
    @Published var managing = false
    var close: () -> Void = {}
    var onFetched: (String) -> Void = { _ in }
    private var generation = 0
    private var key: String { "Fetch." + repository.root.path }
    var canChooseBranch: Bool { options.arbitraryURL || (!options.namedRemoteFetchAll && !options.allRemotes) }
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        self.repository = repository; self.access = access; remoteSettings = PushWindowModel(repository: repository, access: access)
    }
    func load() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                remotes = try await repository.remoteNames(); let defaults = try await repository.fetchDefaults()
                options = FetchOptions(); options.remote = defaults.remote; options.branch = defaults.branch
                options.allRemotes = defaults.remote.isEmpty && remotes.count > 1
                options.namedRemoteFetchAll = UserDefaults.standard.object(forKey: "NamedRemoteFetchAll") as? Bool ?? true
                if let saved = UserDefaults.standard.string(forKey: key + ".remote"), remotes.contains(saved), defaults.remote.isEmpty { options.remote = saved; options.allRemotes = false }
                shallow = defaults.shallow; bare = defaults.bare; depthEnabled = shallow
                tagsDefault = defaults.tags; pruneDefault = defaults.prune
                launchRebase = false
                remoteSettings.remotes = remotes
            } catch { self.error = error.localizedDescription }
        }
    }
    func remoteChanged() {
        generation += 1; let request = generation, remote = options.remote
        Task {
            do { let defaults = try await repository.fetchDefaults(remote: remote); guard request == generation else { return }; tagsDefault = defaults.tags; pruneDefault = defaults.prune }
            catch { if request == generation { self.error = error.localizedDescription } }
        }
    }
    func browse() {
        guard !busy else { return }; busy = true
        let destination = options.arbitraryURL ? url : options.remote
        Task {
            defer { busy = false }
            do { branches = try await repository.remoteBranches(remote: destination); browsing = true }
            catch { self.error = error.localizedDescription }
        }
    }
    func reloadRemotes() {
        remotes = remoteSettings.remotes
        if !remotes.contains(options.remote) { options.remote = remotes.first ?? "" }
        remoteChanged()
    }
    func fetch() {
        guard !busy else { return }
        var snapshot = options
        if options.arbitraryURL { snapshot.remote = url; snapshot.allRemotes = false }
        if shallow && depthEnabled {
            guard let parsed = Int(depth), parsed > 0 else { error = FetchFailure.depth.localizedDescription; return }; snapshot.depth = parsed
        }
        busy = true
        if !options.arbitraryURL && !options.allRemotes { UserDefaults.standard.set(options.remote, forKey: key + ".remote") }
        Task {
            defer { busy = false }
            do {
                let output = try await repository.fetch(snapshot)
                close(); onFetched(output)
            } catch { self.error = error.localizedDescription }
        }
    }
}
private struct FetchDialog: View {
    @ObservedObject var model: FetchWindowModel
    var body: some View {
        VStack(spacing: 14) {
            GroupBox("Remote") { VStack(spacing: 10) {
                HStack { PushDestinationRadio(title: "Remote:", selected: !model.options.arbitraryURL) { model.options.arbitraryURL = false }.frame(width: 140)
                    PushRemotePopup(values: (model.remotes.count > 1 ? ["*"] : []) + (model.remotes.isEmpty ? [""] : model.remotes), selection: Binding(get: { model.options.allRemotes ? "*" : model.options.remote }, set: { model.options.allRemotes = $0 == "*"; if $0 != "*" { model.options.remote = $0 }; model.remoteChanged() })).disabled(model.options.arbitraryURL)
                }
                HStack { PushDestinationRadio(title: "Arbitrary URL:", selected: model.options.arbitraryURL) { model.options.arbitraryURL = true; model.options.allRemotes = false; model.launchRebase = false }.frame(width: 140)
                    TextField("Remote URL or path", text: $model.url).disabled(!model.options.arbitraryURL)
                }
                HStack { Text("Remote Branch:").frame(width: 140, alignment: .leading); PushRefCombo(value: $model.options.branch, choices: model.branches, local: false)
                    Button("…") { model.browse() }.accessibilityLabel("Browse remote branches")
                }.disabled(!model.canChooseBranch)
            }.padding(8) }
            GroupBox("Options") { VStack(alignment: .leading, spacing: 10) {
                HStack { Toggle("Squash", isOn: .constant(false)).disabled(true); Spacer(); Toggle("No Commit", isOn: .constant(false)).disabled(true); Spacer()
                    if model.shallow { Toggle("Depth", isOn: $model.depthEnabled); TextField("Depth", text: $model.depth).frame(width: 65).disabled(!model.depthEnabled) }
                }
                HStack { Toggle("No Fast Forward", isOn: .constant(false)); Spacer(); Toggle("Fast Forward Only", isOn: .constant(false)); Spacer() }.disabled(true)
                HStack { FetchOverrideCheckbox(title: "Tags", value: $model.options.tags).frame(width: 140, alignment: .leading); Text(model.options.allRemotes || model.options.arbitraryURL ? "Use each destination's configured default" : "Default: " + model.tagsDefault).foregroundStyle(.secondary) }
                HStack { FetchOverrideCheckbox(title: "Prune", value: $model.options.prune).frame(width: 140, alignment: .leading); Text(model.options.allRemotes || model.options.arbitraryURL ? "Use each destination's configured default" : model.pruneDefault.isEmpty ? "" : "Default: " + model.pruneDefault).foregroundStyle(.secondary) }
            }.padding(8) }
            HStack { Text("SSH uses configured Git credential helpers and SSH agent.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Manage Remotes") { model.managing = true } }
            Toggle("Launch Rebase After Fetch", isOn: $model.launchRebase).disabled(true).help("Interactive Rebase after Fetch requires the native Rebase dialog port.")
            Spacer(minLength: 0)
            HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer(); Button("OK") { model.fetch() }.keyboardShortcut(.defaultAction); Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction); Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-fetch.html")!) } }
        }.padding(16).disabled(model.busy)
        .onChange(of: model.options.remote) { _ in model.remoteChanged() }
        .alert("Fetch failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.managing, onDismiss: { model.reloadRemotes() }) { PushRemoteSettings(onClose: { model.managing = false }, model: model.remoteSettings) }
        .sheet(isPresented: $model.browsing) { FetchBranchChooser(model: model) }
    }
}
private struct FetchBranchChooser: View {
    @ObservedObject var model: FetchWindowModel
    @State private var selection: String?
    @State private var filter = ""
    var body: some View { VStack(spacing: 12) {
        Text("Select remote branch").font(.headline); TextField("Filter", text: $filter)
        List(model.branches.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, id: \.self, selection: $selection) { Text($0) }
        HStack { Spacer(); Button("Cancel") { model.browsing = false }.keyboardShortcut(.cancelAction); Button("OK") { if let selection { model.options.branch = selection; model.browsing = false } }.keyboardShortcut(.defaultAction).disabled(selection == nil) }
    }.padding(16).frame(width: 600, height: 400) }
}
private struct FetchOverrideCheckbox: NSViewRepresentable {
    let title: String
    @Binding var value: FetchOverride
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:))); button.allowsMixedState = true; return button }
    func updateNSView(_ button: NSButton, context: Context) { button.state = value == .configured ? .mixed : value == .enabled ? .on : .off; button.isEnabled = enabled; button.toolTip = "Mixed: use Git configuration; checked: enable; unchecked: disable"; context.coordinator.change = { value = $0 } }
    final class Coordinator: NSObject { var change: (FetchOverride) -> Void = { _ in }; @objc func clicked(_ sender: NSButton) { change(sender.state == .mixed ? .configured : sender.state == .on ? .enabled : .disabled) } }
}
