import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FetchWindowController: NSWindowController, NSWindowDelegate {
    let model: FetchWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, isPull: Bool = false) {
        model = FetchWindowModel(repository: repository, access: access, isPull: isPull)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – \(isPull ? "Pull" : "Fetch") – TurtleGit"; window.minSize = NSSize(width: 660, height: 450); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FetchDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.close() }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "The process is still running."
            alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.transportRunning else { return true }
        model.cancel(); return false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class FetchWindowModel: ObservableObject {
    let repository: GitRepository
    let isPull: Bool
    let remoteSettings: PushWindowModel
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    @Published var urls: [String] = []
    @Published var branchHistory: [String] = []
    @Published var options = FetchOptions()
    @Published var squash = false
    @Published var noCommit = false
    @Published var noFastForward = false
    @Published var fastForwardOnly = false
    @Published var rebaseRequired = false
    private var preserveMerges = false
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
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    private var cancellation: OperationCancellation?
    var transportRunning: Bool { cancellation != nil }
    var canCancel: Bool { !busy || transportRunning && !cancelling && !confirmingCancellation }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    @Published var error: String?
    @Published var browsing = false
    @Published var managing = false
    var clipboardText: () -> String? = { NSPasteboard.general.string(forType: .string) ?? NSPasteboard.general.string(forType: .fileURL) }
    var close: () -> Void = {}
    var onShowStatus: () -> Void = {}
    var onFetched: (String) -> Void = { _ in }
    var onRebase: (String, Bool, Bool) -> Void = { _, _, _ in }
    private var generation = 0
    private var key: String { (isPull ? "Pull." : "Fetch.") + repository.root.path }
    var configuredRebase: Bool { isPull && rebaseRequired && !options.arbitraryURL }
    var canChooseBranch: Bool { launchRebase || isPull || options.arbitraryURL || (!options.namedRemoteFetchAll && !options.allRemotes) }
    init(repository: GitRepository, access: RepositoryAccessLease?, isPull: Bool, preferences: UserDefaults = .standard) {
        self.isPull = isPull; self.repository = repository; self.access = access; self.preferences = preferences; remoteSettings = PushWindowModel(repository: repository, access: access)
    }
    func load() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                remotes = try await repository.remoteNames(); let defaults = try await repository.fetchDefaults()
                urls = FetchDialogHistory.load(preferences, key: "History.PullURLS", caseSensitive: true)
                branchHistory = FetchDialogHistory.load(preferences, key: "History.PullRemoteBranch", caseSensitive: false)
                options = FetchOptions(); options.remote = defaults.remote
                options.branch = branchHistory.first ?? ""
                selectBranch(defaults.branch, atFront: false)
                options.allRemotes = !isPull && defaults.remote.isEmpty && remotes.count > 1
                if isPull && options.remote.isEmpty { options.remote = remotes.first ?? "" }
                options.namedRemoteFetchAll = preferences.object(forKey: "NamedRemoteFetchAll") as? Bool ?? true
                if let saved = preferences.string(forKey: key + ".remote"), remotes.contains(saved), defaults.remote.isEmpty { options.remote = saved; options.allRemotes = false }
                shallow = defaults.shallow; bare = defaults.bare; depthEnabled = shallow
                tagsDefault = defaults.tags; pruneDefault = defaults.prune
                let pullDefaults = try await repository.pullDefaults()
                rebaseRequired = isPull && pullDefaults.rebase
                preserveMerges = isPull && pullDefaults.preserveMerges
                launchRebase = !bare && !options.allRemotes && (rebaseRequired || preferences.bool(forKey: key + ".rebase"))
                fastForwardOnly = isPull && preferences.bool(forKey: key + ".ffonly")
                squash = false; noCommit = false; noFastForward = false
                remoteSettings.remotes = remotes
            } catch { self.error = error.localizedDescription }
        }
    }
    func selectBranch(_ branch: String, atFront: Bool = true) {
        let branch = FetchDialogHistory.trim(branch)
        guard !branch.isEmpty else { return }
        branchHistory = FetchDialogHistory.inserting(branch, into: branchHistory, atFront: atFront, caseSensitive: false)
        options.branch = branchHistory.first { $0.compare(branch, options: .caseInsensitive) == .orderedSame } ?? branch
    }
    func deleteURLHistory(at index: Int) {
        guard !busy, let result = FetchDialogHistory.removing(index, entries: urls, preferences: preferences, key: "History.PullURLS") else { return }
        urls = result.entries; url = result.selection
    }
    func deleteBranchHistory(at index: Int) {
        guard !busy, let result = FetchDialogHistory.removing(index, entries: branchHistory, preferences: preferences, key: "History.PullRemoteBranch") else { return }
        branchHistory = result.entries; options.branch = result.selection
    }
    func selectArbitraryURL() {
        options.arbitraryURL = true; options.allRemotes = false; launchRebase = false
        let selection = FetchClipboardInput.selection(clipboardText() ?? "", isPull: isPull)
        url = selection?.url ?? urls.first ?? ""
        if let branch = selection?.branch { options.branch = branch }
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
    func cancel() {
        guard busy else { close(); return }
        guard let token = cancellation, !cancelling, !confirmingCancellation else { return }
        func stop() { cancelling = true; token.cancel() }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] proceed in
                guard let self else { return }
                self.confirmingCancellation = false
                guard self.cancellation === token else { return }
                if proceed { self.cancelling = true; token.cancel() }
            }
        } else { stop() }
    }
    func fetch() {
        guard !busy else { return }
        if options.arbitraryURL {
            urls = FetchDialogHistory.save(url, entries: urls, preferences: preferences, key: "History.PullURLS", caseSensitive: true)
        }
        let wantsRebase = launchRebase && !bare && !options.arbitraryURL
        let autoStart = configuredRebase
        let keepMerges = preserveMerges
        if wantsRebase && (options.allRemotes || options.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { error = FetchRebaseFailure.destination.localizedDescription; return }
        var snapshot = options
        snapshot.branch = FetchDialogHistory.trim(snapshot.branch)
        if options.arbitraryURL { snapshot.remote = FetchDialogHistory.trim(url); snapshot.allRemotes = false }
        if shallow && depthEnabled {
            guard let parsed = Int(depth), parsed > 0 else { error = FetchFailure.depth.localizedDescription; return }; snapshot.depth = parsed
        }
        var pullOptions = PullOptions(); pullOptions.fetch = snapshot; pullOptions.squash = squash; pullOptions.noCommit = noCommit; pullOptions.noFastForward = noFastForward; pullOptions.fastForwardOnly = fastForwardOnly
        branchHistory = FetchDialogHistory.save(options.branch, entries: branchHistory, preferences: preferences, key: "History.PullRemoteBranch", caseSensitive: false)
        let token = OperationCancellation(); cancellation = token; cancelling = false; error = nil
        busy = true
        preferences.set(wantsRebase, forKey: key + ".rebase")
        if isPull { preferences.set(fastForwardOnly, forKey: key + ".ffonly") }
        if !options.arbitraryURL && !options.allRemotes { preferences.set(options.remote, forKey: key + ".remote") }
        Task {
            defer { cancellation = nil; cancelling = false; confirmingCancellation = false; busy = false }
            do {
                if wantsRebase {
                    let result = try await repository.fetchForRebase(snapshot, cancellation: token)
                    guard !token.isCancelled else { throw OperationCancellationFailure.cancelled }
                    close(); onFetched(result.output); onRebase(result.upstream, autoStart, keepMerges)
                } else {
                    let output = isPull ? try await repository.pull(pullOptions, cancellation: token) : try await repository.fetch(snapshot, cancellation: token)
                    guard !token.isCancelled else { throw OperationCancellationFailure.cancelled }
                    close(); onFetched(output)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
private struct FetchDialog: View {
    @ObservedObject var model: FetchWindowModel
    var body: some View {
        VStack(spacing: 14) {
            Group {
            GroupBox("Remote") { VStack(spacing: 10) {
                HStack { PushDestinationRadio(title: "Remote:", selected: !model.options.arbitraryURL) { model.options.arbitraryURL = false; model.launchRebase = model.rebaseRequired }.frame(width: 140)
                    PushRemotePopup(values: (!model.isPull && model.remotes.count > 1 ? ["*"] : []) + (model.remotes.isEmpty ? [""] : model.remotes), selection: Binding(get: { model.options.allRemotes ? "*" : model.options.remote }, set: { model.options.allRemotes = $0 == "*"; if model.options.allRemotes { model.launchRebase = false }; if $0 != "*" { model.options.remote = $0 }; model.remoteChanged() })).disabled(model.options.arbitraryURL)
                }
                HStack { PushDestinationRadio(title: "Arbitrary URL:", selected: model.options.arbitraryURL) { model.selectArbitraryURL() }.frame(width: 140)
                    FetchHistoryCombo(value: $model.url, choices: model.urls, label: "Remote URL or path", onDelete: model.deleteURLHistory).disabled(!model.options.arbitraryURL)
                }
                HStack { Text("Remote Branch:").frame(width: 140, alignment: .leading); FetchHistoryCombo(value: $model.options.branch, choices: model.branchHistory, label: "Remote branch", onDelete: model.deleteBranchHistory)
                    Button("…") { model.browse() }.accessibilityLabel("Browse remote branches")
                }.disabled(!model.canChooseBranch)
            }.padding(8) }
            GroupBox("Options") { VStack(alignment: .leading, spacing: 10) {
                HStack { Toggle("Squash", isOn: $model.squash).disabled(!model.isPull || model.launchRebase); Spacer(); Toggle("No Commit", isOn: $model.noCommit).disabled(!model.isPull || model.launchRebase); Spacer()
                    if model.shallow { Toggle("Depth", isOn: $model.depthEnabled); TextField("Depth", text: $model.depth).frame(width: 65).disabled(!model.depthEnabled) }
                }
                HStack { Toggle("No Fast Forward", isOn: $model.noFastForward).disabled(model.fastForwardOnly); Spacer(); Toggle("Fast Forward Only", isOn: $model.fastForwardOnly).disabled(model.noFastForward); Spacer() }.disabled(!model.isPull || model.launchRebase)
                HStack { FetchOverrideCheckbox(title: "Tags", value: $model.options.tags).frame(width: 140, alignment: .leading); Text(model.options.allRemotes || model.options.arbitraryURL ? "Use each destination's configured default" : "Default: " + model.tagsDefault).foregroundStyle(.secondary) }
                HStack { FetchOverrideCheckbox(title: "Prune", value: $model.options.prune).frame(width: 140, alignment: .leading); Text(model.options.allRemotes || model.options.arbitraryURL ? "Use each destination's configured default" : model.pruneDefault.isEmpty ? "" : "Default: " + model.pruneDefault).foregroundStyle(.secondary) }
            }.padding(8) }
            HStack { Text("SSH uses configured Git credential helpers and SSH agent.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Manage Remotes") { model.managing = true } }
            Toggle("Launch Rebase After Fetch", isOn: $model.launchRebase).disabled(model.bare || model.options.allRemotes || model.options.arbitraryURL || model.configuredRebase).help("Fetch the selected branch and open its native Rebase plan.")
            if model.rebaseRequired && !model.options.arbitraryURL { Text("Git configuration requires Rebase. Fetch will open and start its native Rebase plan.").font(.caption).foregroundStyle(.secondary) }
            }.disabled(model.busy)
            Spacer(minLength: 0)
            HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer(); Button("OK") { model.fetch() }.keyboardShortcut(.defaultAction).disabled(model.busy); Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel); Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-pull.html")!) } }
        }.padding(16)
        .onChange(of: model.options.remote) { _ in model.remoteChanged() }
        .alert(model.isPull ? "Pull failed" : "Fetch failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil }; if model.isPull { Button("Open Working Tree") { model.error = nil; model.onShowStatus() } } } message: { Text(model.error ?? "") }
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
        HStack { Spacer(); Button("Cancel") { model.browsing = false }.keyboardShortcut(.cancelAction); Button("OK") { if let selection { model.selectBranch(selection); model.browsing = false } }.keyboardShortcut(.defaultAction).disabled(selection == nil) }
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

struct FetchHistoryCombo: NSViewRepresentable {
    @Binding var value: String
    let choices: [String]
    let label: String
    var onDelete: ((Int) -> Void)? = nil
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = EditableHistoryCombo(); combo.delegate = context.coordinator; combo.completes = true
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal); return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        let coordinator = context.coordinator; coordinator.updating = true; defer { coordinator.updating = false }
        coordinator.change = { value = $0 }
        (combo as? EditableHistoryCombo)?.deleteHistory = onDelete
        if !coordinator.choices.elementsEqual(choices, by: { $0.utf16.elementsEqual($1.utf16) }) { (combo as? EditableHistoryCombo)?.replaceHistory(choices); coordinator.choices = choices }
        if let index = choices.firstIndex(where: { $0.utf16.elementsEqual(value.utf16) }) { combo.selectItem(at: index) }
        else if combo.indexOfSelectedItem >= 0 { combo.deselectItem(at: combo.indexOfSelectedItem) }
        if !combo.stringValue.utf16.elementsEqual(value.utf16) { combo.stringValue = value }
        combo.isEnabled = enabled; combo.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var choices: [String] = []; var updating = false; var change: (String) -> Void = { _ in }
        func comboBoxWillPopUp(_ notification: Notification) { (notification.object as? EditableHistoryCombo)?.historyPopupOpen = true }
        func comboBoxWillDismiss(_ notification: Notification) { (notification.object as? EditableHistoryCombo)?.historyPopupOpen = false }
        func controlTextDidChange(_ notification: Notification) { guard !updating, let combo = notification.object as? NSComboBox else { return }; change(combo.stringValue) }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard !updating, let combo = notification.object as? NSComboBox, choices.indices.contains(combo.indexOfSelectedItem) else { return }; change(choices[combo.indexOfSelectedItem]) }
    }
}

/// PullFetchDlg shares these histories between Pull, Fetch and repositories.
/// HistoryCombo loads 25 but can save 26: truncation occurs before insertion.
enum FetchDialogHistory {
    static func removing(_ index: Int, entries: [String], preferences: UserDefaults, key: String) -> (entries: [String], selection: String)? {
        guard entries.indices.contains(index) else { return nil }
        var result = entries; result.remove(at: index)
        let selection = result.isEmpty ? "" : result[min(index, result.count - 1)]
        // Save without reinserting the selected item, preserving source list order.
        preferences.set(Array(result.prefix(26)), forKey: key)
        return (result, selection)
    }
    static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\u{0B}\u{0C}"))
    }
    static func inserting(_ value: String, into entries: [String], atFront: Bool, caseSensitive: Bool) -> [String] {
        let value = trim(value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))
        guard !value.isEmpty else { return entries }
        var result = entries
        if let index = result.firstIndex(where: { caseSensitive ? $0.utf16.elementsEqual(value.utf16) : $0.compare(value, options: .caseInsensitive) == .orderedSame }) {
            if !atFront || index == 0 { return result }
            result.remove(at: index)
        }
        result = Array(result.prefix(25))
        result.insert(value, at: atFront ? 0 : result.count)
        return result
    }
    static func load(_ preferences: UserDefaults, key: String, caseSensitive: Bool) -> [String] {
        var result: [String] = []
        for value in (preferences.stringArray(forKey: key) ?? []).prefix(25) {
            if value.isEmpty { break }
            result = inserting(value, into: result, atFront: false, caseSensitive: caseSensitive)
        }
        return result
    }
    static func save(_ value: String, entries: [String], preferences: UserDefaults, key: String, caseSensitive: Bool) -> [String] {
        let result = inserting(value, into: entries, atFront: true, caseSensitive: caseSensitive)
        preferences.set(Array(result.prefix(26)), forKey: key)
        return result
    }
}

/// Scoped local event handling; only an open, enabled history popup owns deletion.
final class EditableHistoryCombo: NSComboBox {
    var historyPopupOpen = false
    var deleteHistory: ((Int) -> Void)?
    private var eventMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        historyPopupOpen = false
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            return self.handleHistoryKey(event) ? nil : event
        }
    }
    func replaceHistory(_ entries: [String]) {
        let previous = (0..<numberOfItems).compactMap { itemObjectValue(at: $0) as? String }
        if previous.count == entries.count + 1,
           let removed = previous.indices.first(where: { index in
               var candidate = previous; candidate.remove(at: index)
               return candidate.elementsEqual(entries, by: { $0.utf16.elementsEqual($1.utf16) })
           }) { removeItem(at: removed) }
        else { removeAllItems(); addItems(withObjectValues: entries) }
    }
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
    /// Testable native event receiver; does not send synthetic events to the app.
    func handleHistoryKey(_ event: NSEvent) -> Bool {
        guard isEnabled, historyPopupOpen, event.type == .keyDown, event.modifierFlags.contains(.shift), [UInt16(51), 117].contains(event.keyCode) else { return false }
        if indexOfSelectedItem >= 0 { deleteHistory?(indexOfSelectedItem) }
        return true
    }
}
