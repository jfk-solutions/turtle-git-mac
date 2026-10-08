import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FetchWindowController: NSWindowController, NSWindowDelegate {
    let model: FetchWindowModel
    var onClosed: () -> Void = {}
    private var progressController: PullProgressWindowController?
    private var fetchProgressController: FetchProgressWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?, isPull: Bool = false) {
        model = FetchWindowModel(repository: repository, access: access, isPull: isPull)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – \(isPull ? "Pull" : "Fetch") – TurtleGit"; window.minSize = NSSize(width: 660, height: 450); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FetchDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in guard let self, !self.model.operationActive, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        model.onProgress = { [weak self] progress in
            guard let self, let window = self.window, window.attachedSheet == nil else { progress.cancel(); return }
            let controller = PullProgressWindowController(model: progress)
            controller.onClosed = { [weak self, weak progress] in guard let self, let progress else { return }; self.progressController = nil; self.model.finish(progress) }
            self.progressController = controller
            if let child = controller.window { window.beginSheet(child) }
        }
        model.onFetchProgress = { [weak self] progress in
            guard let self, let window = self.window, window.attachedSheet == nil else { progress.cancel(); return }
            let controller = FetchProgressWindowController(model: progress)
            controller.onClosed = { [weak self, weak progress] in guard let self, let progress else { return }; self.fetchProgressController = nil; self.model.finishFetch(progress) }
            self.fetchProgressController = controller
            if let child = controller.window { window.beginSheet(child) }
        }
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
    func windowWillClose(_ notification: Notification) { model.invalidate(); onClosed() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.progress != nil || model.fetchProgress != nil { if model.transportRunning { model.cancel() }; return false }
        guard model.transportRunning else { return !model.busy && sender.attachedSheet == nil }
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
    @Published private var legacyCancelling = false
    @Published private var legacyConfirmingCancellation = false
    var cancelling: Bool { progress?.cancelling ?? fetchProgress?.cancelling ?? legacyCancelling }
    var confirmingCancellation: Bool { progress?.confirmingCancellation ?? fetchProgress?.confirmingCancellation ?? legacyConfirmingCancellation }
    @Published private(set) var progress: PullProgressWindowModel?
    @Published private(set) var fetchProgress: FetchProgressWindowModel?
    var onFetchProgress: ((FetchProgressWindowModel) -> Void)?
    var onFetchPostAction: ((FetchPostAction, String) -> Void)?
    var followUp = PullFollowUp()
    var onProgress: ((PullProgressWindowModel) -> Void)?
    var onPullPostAction: ((PullPostAction, PullProgressContext) -> Void)?
    var onChanged: (String) -> Void = { _ in }
    private var invalidated = false
    var operationActive: Bool { busy || progress != nil || fetchProgress != nil }
    func invalidate() { invalidated = true }
    func finish(_ result: PullProgressWindowModel) {
        guard progress === result, !result.busy, !result.confirmingConflictHint, !result.confirmingCancellation, !result.dispatchingAction else { return }
        progress = nil; error = nil; result.invalidate(); close()
    }
    func finishFetch(_ result: FetchProgressWindowModel) {
        guard fetchProgress === result, !result.busy, !result.confirmingCancellation, !result.dispatchingAction else { return }
        fetchProgress = nil; error = nil; result.invalidate(); close()
    }
    private var cancellation: OperationCancellation?
    var transportRunning: Bool { progress?.busy ?? fetchProgress?.busy ?? (cancellation != nil) }
    var canCancel: Bool { progress?.canCancel ?? fetchProgress?.canCancel ?? (!busy || transportRunning && !cancelling && !confirmingCancellation) }
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
        guard !invalidated, !operationActive else { return }; busy = true
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
        guard !invalidated, !operationActive, let result = FetchDialogHistory.removing(index, entries: urls, preferences: preferences, key: "History.PullURLS") else { return }
        urls = result.entries; url = result.selection
    }
    func deleteBranchHistory(at index: Int) {
        guard !invalidated, !operationActive, let result = FetchDialogHistory.removing(index, entries: branchHistory, preferences: preferences, key: "History.PullRemoteBranch") else { return }
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
        guard !invalidated, !operationActive else { return }; busy = true
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
        if let progress { if progress.busy { progress.cancel() } else { progress.close() }; return }
        if let fetchProgress { if fetchProgress.busy { fetchProgress.cancel() } else { fetchProgress.close() }; return }
        guard busy else { close(); return }
        guard let token = cancellation, !cancelling, !confirmingCancellation else { return }
        func stop() { legacyCancelling = true; token.cancel() }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            legacyConfirmingCancellation = true
            confirmCancellation { [weak self] proceed in
                guard let self else { return }
                self.legacyConfirmingCancellation = false
                guard self.cancellation === token else { return }
                if proceed { self.legacyCancelling = true; token.cancel() }
            }
        } else { stop() }
    }
    func fetch() {
        guard !invalidated, !operationActive else { return }
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
        error = nil
        busy = true
        preferences.set(wantsRebase, forKey: key + ".rebase")
        if isPull { preferences.set(fastForwardOnly, forKey: key + ".ffonly") }
        if !options.arbitraryURL && !options.allRemotes { preferences.set(options.remote, forKey: key + ".remote") }
        if isPull && !wantsRebase {
            let progress = PullProgressWindowModel(repository: repository, access: access, options: pullOptions, followUp: followUp, preferences: preferences)
            self.progress = progress
            progress.confirmCancellation = { [weak self] choose in self?.confirmCancellation(choose) }
            progress.onPostAction = onPullPostAction
            progress.onCompleted = { [weak self, weak progress] in
                guard let self, let progress else { return }; self.busy = false
                self.error = progress.success ? nil : progress.output
                self.onChanged(progress.output)
                if progress.success { self.onFetched(progress.output) }
            }
            progress.close = { [weak self, weak progress] in if let progress { self?.finish(progress) } }
            onProgress?(progress); progress.start(); return
        }
        if !wantsRebase {
            let progress = FetchProgressWindowModel(repository: repository, access: access, options: snapshot, preferences: preferences)
            fetchProgress = progress
            progress.confirmCancellation = { [weak self] choose in self?.confirmCancellation(choose) }
            progress.onPostAction = onFetchPostAction
            progress.onCompleted = { [weak self, weak progress] in
                guard let self, let progress else { return }; self.busy = false
                self.error = progress.success ? nil : progress.output; self.onChanged(progress.output)
                if progress.success { self.onFetched(progress.output) }
            }
            progress.close = { [weak self, weak progress] in if let progress { self?.finishFetch(progress) } }
            onFetchProgress?(progress); progress.start(); return
        }
        let token = OperationCancellation(); cancellation = token; legacyCancelling = false
        Task {
            defer { cancellation = nil; legacyCancelling = false; legacyConfirmingCancellation = false; busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                if wantsRebase {
                    let result = try await repository.fetchForRebase(snapshot, cancellation: token)
                    guard !token.isCancelled else { throw OperationCancellationFailure.cancelled }
                    cancellation = nil; busy = false; close(); onFetched(result.output); onRebase(result.upstream, autoStart, keepMerges)
                } else {
                    let output = isPull ? try await repository.pull(pullOptions, cancellation: token) : try await repository.fetch(snapshot, cancellation: token)
                    guard !token.isCancelled else { throw OperationCancellationFailure.cancelled }
                    cancellation = nil; busy = false; close(); onFetched(output)
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
            }.disabled(model.operationActive)
            Spacer(minLength: 0)
            HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer(); Button("OK") { model.fetch() }.keyboardShortcut(.defaultAction).disabled(model.operationActive); Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel); Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-pull.html")!) } }
        }.padding(16)
        .onChange(of: model.options.remote) { _ in model.remoteChanged() }
        .alert(model.isPull ? "Pull failed" : "Fetch failed", isPresented: Binding(get: { model.progress == nil && model.fetchProgress == nil && model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil }; if model.isPull { Button("Open Working Tree") { model.error = nil; model.onShowStatus() } } } message: { Text(model.error ?? "") }
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

struct PullFollowUp: Sendable { var showPush = false; var showStashPop = false }
extension PullFollowUp {
    init(stashSave request: StashSaveFollowUp) { self.init(showPush: request.pullShowPush, showStashPop: true) }
}
struct PullProgressContext {
    let oldHead: String
    let newHead: String
    let resetRevision: String
    let followUp: PullFollowUp
}
enum PullPostAction: String, CaseIterable, Hashable {
    case resolve, commit, mergeUnrelated, pull, stash, reset, stashPop, diff, log, push, submoduleUpdate
    var title: String {
        switch self {
        case .resolve: return "Resolve…"; case .commit: return "Commit…"; case .mergeUnrelated: return "Merge unrelated history"
        case .pull: return "Pull…"; case .stash: return "Stash save…"; case .reset: return "Reset…"; case .stashPop: return "Stash pop"
        case .diff: return "Pulled Diff"; case .log: return "Pulled Log"; case .push: return "Push…"; case .submoduleUpdate: return "Submodule Update…"
        }
    }
    var icon: MenuIcon {
        switch self {
        case .resolve: return .resolve; case .commit: return .commit; case .mergeUnrelated: return .merge; case .pull: return .pull
        case .stash: return .stash; case .reset: return .reset; case .stashPop: return .stashPop; case .diff: return .compare
        case .log: return .log; case .push: return .push; case .submoduleUpdate: return .fetch
        }
    }
}
@MainActor final class PullProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let options: PullOptions
    let followUp: PullFollowUp
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    private var cancellation = OperationCancellation()
    private var started = false, invalidated = false, dispatched = false
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var confirmingConflictHint = false
    @Published private(set) var dispatchingAction = false
    @Published private(set) var output = ""
    @Published private(set) var postActions: [PullPostAction] = []
    @Published private(set) var oldHead = ""
    @Published private(set) var newHead = ""
    var canCancel: Bool { !confirmingConflictHint && !dispatchingAction && (!busy || !cancelling && !confirmingCancellation) }
    var close: () -> Void = {}
    var onCompleted: () -> Void = {}
    var onPostAction: ((PullPostAction, PullProgressContext) -> Void)?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    var presentConflictHint: (() async -> Bool)?
    var closeAfterCancellation = false
    private func completed() {
        busy = false; cancelling = false; confirmingCancellation = false; onCompleted()
        if cancelled && closeAfterCancellation { close() }
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, options: PullOptions, followUp: PullFollowUp, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.options = options; self.followUp = followUp; self.preferences = preferences
    }
    func invalidate() { invalidated = true }
    func start() { Task { await run() } }
    func run() async { guard !started, !invalidated else { return }; started = true; await execute(options) }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func execute(_ snapshot: PullOptions) async {
        busy = true; success = false; cancelled = false; cancelling = false; output = ""; postActions = []; newHead = ""
        do { try validateAccess(); if cancellation.isCancelled { throw OperationCancellationFailure.cancelled } }
        catch { output = error.localizedDescription; cancelled = cancellation.isCancelled; completed(); return }
        var beganPull = false
        do {
            oldHead = try await repository.run(["rev-parse", "--verify", "--end-of-options", "HEAD^{commit}"]).text.trimmingCharacters(in: .newlines)
            beganPull = true
            output = try await repository.pull(snapshot, cancellation: cancellation)
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }; success = true
        } catch { output = error.localizedDescription; cancelled = cancellation.isCancelled }
        guard beganPull else { completed(); return }
        if success {
            if followUp.showStashPop { postActions.append(.stashPop) }
            if let head = try? await repository.run(["rev-parse", "--verify", "--end-of-options", "HEAD^{commit}"]).text.trimmingCharacters(in: .newlines) { newHead = head; postActions += [.diff, .log] }
            if followUp.showPush { postActions.append(.push) }
            if (try? await repository.submoduleUpdatePaths().isEmpty) == false { postActions.append(.submoduleUpdate) }
        } else if (try? await repository.status(refreshIndex: false).contains { $0.state == .conflicted }) == true {
            if !preferences.bool(forKey: MergeProgressWindowModel.conflictHintPreference), let presentConflictHint {
                confirmingConflictHint = true
                let suppress = await presentConflictHint(); confirmingConflictHint = false
                if suppress { preferences.set(true, forKey: MergeProgressWindowModel.conflictHintPreference) }
            }
            postActions = [.resolve, .commit]
        } else {
            if !options.fetch.arbitraryURL, (try? await repository.remoteNames().contains(options.fetch.remote)) == true {
                var branch = options.fetch.branch, remote = options.fetch.remote
                if branch.isEmpty, (try? await repository.branch().isEmpty) == false, let defaults = try? await repository.pullDefaults(), !defaults.trackedRemote.isEmpty, !defaults.trackedBranch.isEmpty {
                    branch = defaults.trackedBranch; remote = defaults.trackedRemote
                }
                let shortBranch = branch.hasPrefix("refs/heads/") ? String(branch.dropFirst(11)) : branch
                let ref = "refs/remotes/" + remote + "/" + shortBranch
                var common = false
                if let hash = try? await repository.run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"]).text.trimmingCharacters(in: .newlines), !oldHead.isEmpty {
                    common = (try? await repository.run(["merge-base", oldHead, hash], successfulExitCodes: 0...1).stdout.isEmpty) == false
                }
                // Source offers this when its common hash remains empty, including failed ref resolution.
                if !common { postActions.append(.mergeUnrelated) }
            }
            postActions += [.pull, .stash, .reset]
        }
        completed()
    }
    func cancel() {
        guard !invalidated, busy, canCancel else { return }
        let token = cancellation
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, self.confirmingCancellation, self.cancellation === token else { return }
                self.confirmingCancellation = false
                if accepted { self.cancelling = true; token.cancel() }
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: PullPostAction) {
        guard !invalidated, !dispatched, !busy, !dispatchingAction, !confirmingConflictHint, postActions.contains(action) else { return }
        if action == .mergeUnrelated {
            var snapshot = options; snapshot.allowUnrelatedHistories = true
            cancellation = OperationCancellation(); busy = true
            Task { await execute(snapshot) }; return
        }
        guard let onPostAction else { return }
        if action == .reset {
            dispatchingAction = true
            Task {
                var revision = ""
                do {
                    try validateAccess()
                    let defaults = try await repository.pullDefaults()
                    if !defaults.trackedRemote.isEmpty && !defaults.trackedBranch.isEmpty { revision = "refs/remotes/" + defaults.trackedRemote + "/" + defaults.trackedBranch }
                } catch { output += "\n" + error.localizedDescription; dispatchingAction = false; return }
                dispatchingAction = false
                guard !invalidated else { return }; dispatched = true
                let context = PullProgressContext(oldHead: oldHead, newHead: newHead, resetRevision: revision, followUp: followUp)
                close(); onPostAction(action, context)
            }
        } else {
            dispatched = true
            let context = PullProgressContext(oldHead: oldHead, newHead: newHead, resetRevision: "", followUp: followUp)
            close(); onPostAction(action, context)
        }
    }
}
@MainActor final class PullProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: PullProgressWindowModel
    var onClosed: () -> Void = {}
    init(model: PullProgressWindowModel) {
        self.model = model; model.closeAfterCancellation = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(model.repository.root.lastPathComponent) – Pull progress – TurtleGit"; window.minSize = NSSize(width: 620, height: 340); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PullProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in
            guard let self, !self.model.busy, !self.model.dispatchingAction, !self.model.confirmingConflictHint, self.window?.attachedSheet == nil else { return }
            if let window = self.window { window.sheetParent?.endSheet(window); window.close() }
        }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
        model.presentConflictHint = { [weak window] in
            guard let window, window.attachedSheet == nil else { return false }
            return await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "TurtleGit"; alert.informativeText = MergeProgressWindowModel.conflictHint
                let okay = alert.addButton(withTitle: "OK"); okay.keyEquivalent = "\r"; alert.window.defaultButtonCell = okay.cell as? NSButtonCell
                alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Don't show this message again"
                alert.beginSheetModal(for: window) { _ in continuation.resume(returning: alert.suppressionButton?.state == .on) }
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        guard !model.dispatchingAction, sender.attachedSheet == nil else { return false }
        sender.sheetParent?.endSheet(sender); return true
    }
    func windowWillClose(_ notification: Notification) { model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
private struct PullProgressDialog: View {
    @ObservedObject var model: PullProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor))
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.busy ? model.cancelling ? "Cancelling…" : "Pulling…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Pull failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red); Spacer() }
            HStack {
                if let first = model.postActions.first {
                    Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                    Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Pull post-actions") }.menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else {
                    if !model.success { Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction) }
                    Button("Close") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.dispatchingAction)
                }
            }.disabled(model.confirmingConflictHint || model.dispatchingAction)
        }.padding(12)
    }
}

// Ordinary Fetch keeps the command-line DoFetch result; configured Fetch/Rebase
// has its separate post-execution workflow and is not silently replaced here.
enum FetchPostAction: String, CaseIterable, Hashable {
    case retry, log, reset, fetch, rebase, switchBranch
    var title: String {
        switch self { case .retry: return "Retry"; case .log: return "Show log"; case .reset: return "Reset…"; case .fetch: return "Fetch…"; case .rebase: return "Rebase…"; case .switchBranch: return "Switch/Checkout…" }
    }
    var icon: MenuIcon {
        switch self { case .retry: return .refresh; case .log: return .log; case .reset: return .reset; case .fetch: return .fetch; case .rebase: return .rebase; case .switchBranch: return .checkout }
    }
}
@MainActor final class FetchProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let options: FetchOptions
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    private var cancellation = OperationCancellation()
    private var started = false, invalidated = false, dispatched = false
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var dispatchingAction = false
    @Published private(set) var output = ""
    @Published private(set) var postActions: [FetchPostAction] = []
    var canCancel: Bool { !dispatchingAction && (!busy || !cancelling && !confirmingCancellation) }
    var closeAfterCancellation = false
    var close: () -> Void = {}
    var onCompleted: () -> Void = {}
    var onPostAction: ((FetchPostAction, String) -> Void)?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    init(repository: GitRepository, access: RepositoryAccessLease?, options: FetchOptions, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.options = options; self.preferences = preferences
    }
    func invalidate() { invalidated = true }
    func start() { Task { await run() } }
    func run() async { guard !started, !invalidated else { return }; started = true; await execute() }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func execute() async {
        busy = true; success = false; cancelled = false; cancelling = false; output = ""; postActions = []
        do {
            try validateAccess()
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            output = try await repository.fetch(options, cancellation: cancellation)
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            success = true
            postActions = [.log, .reset, .fetch]
            if (try? await repository.isBare()) == false { postActions.append(.rebase) }
            postActions.append(.switchBranch)
        } catch {
            output = error.localizedDescription; cancelled = cancellation.isCancelled
            postActions = [.retry]; if options.allRemotes { postActions.append(.log) }
        }
        busy = false; cancelling = false; confirmingCancellation = false; onCompleted()
        if cancelled && closeAfterCancellation { close() }
    }
    func cancel() {
        guard !invalidated, busy, canCancel else { return }
        let token = cancellation
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, self.confirmingCancellation, self.cancellation === token else { return }
                self.confirmingCancellation = false
                if accepted { self.cancelling = true; token.cancel() }
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: FetchPostAction) {
        guard !invalidated, !dispatched, !busy, !dispatchingAction, postActions.contains(action) else { return }
        if action == .retry { cancellation = OperationCancellation(); busy = true; Task { await execute() }; return }
        guard let onPostAction else { return }
        if action == .reset {
            dispatchingAction = true
            Task {
                var revision = ""
                do {
                    try validateAccess(); let defaults = try await repository.pullDefaults()
                    if !defaults.trackedRemote.isEmpty && !defaults.trackedBranch.isEmpty { revision = "refs/remotes/" + defaults.trackedRemote + "/" + defaults.trackedBranch }
                } catch { output += "\n" + error.localizedDescription; dispatchingAction = false; return }
                dispatchingAction = false; guard !invalidated else { return }; dispatched = true
                close(); onPostAction(action, revision)
            }
        } else { dispatched = true; close(); onPostAction(action, "") }
    }
}
@MainActor final class FetchProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: FetchProgressWindowModel
    var onClosed: () -> Void = {}
    init(model: FetchProgressWindowModel) {
        self.model = model; model.closeAfterCancellation = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(model.repository.root.lastPathComponent) – Fetch progress – TurtleGit"; window.minSize = NSSize(width: 620, height: 340); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FetchProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in
            guard let self, !self.model.busy, !self.model.dispatchingAction, self.window?.attachedSheet == nil else { return }
            if let window = self.window { window.sheetParent?.endSheet(window); window.close() }
        }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        guard !model.dispatchingAction, sender.attachedSheet == nil else { return false }
        sender.sheetParent?.endSheet(sender); return true
    }
    func windowWillClose(_ notification: Notification) { model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
private struct FetchProgressDialog: View {
    @ObservedObject var model: FetchProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor))
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.busy ? model.cancelling ? "Cancelling…" : "Fetching…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Fetch failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red); Spacer() }
            HStack {
                if let first = model.postActions.first {
                    Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                    Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Fetch post-actions") }.menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { if !model.success { Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction) }; Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.dispatchingAction)
        }.padding(12)
    }
}
