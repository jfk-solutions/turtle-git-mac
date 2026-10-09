import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FetchWindowController: NSWindowController, NSWindowDelegate {
    let model: FetchWindowModel
    var onClosed: () -> Void = {}
    var presentPullProgress: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    private(set) var progressController: PullProgressWindowController?
    var presentFetchProgress: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    private(set) var fetchProgressController: FetchProgressWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?, isPull: Bool = false, preferences: UserDefaults = .standard) {
        model = FetchWindowModel(repository: repository, access: access, isPull: isPull, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – \(isPull ? "Pull" : "Fetch") – TurtleGit"; window.minSize = NSSize(width: 660, height: 450); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FetchDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in guard let self, !self.model.operationActive, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        model.onProgress = { [weak self] progress in
            guard let self else { progress.invalidate(); return }
            guard let window = self.window, window.attachedSheet == nil else { self.model.abandonPullPresentation(progress); return }
            let controller = PullProgressWindowController(model: progress)
            controller.onClosed = { [weak self, weak progress, weak controller] in
                guard let self, let progress, let controller, self.progressController === controller else { return }
                self.progressController = nil; self.model.finish(progress)
            }
            self.progressController = controller
            guard let child = controller.window, self.presentPullProgress(window, child) else { self.progressController = nil; self.model.abandonPullPresentation(progress); controller.close(); return }
        }
        model.onFetchProgress = { [weak self] progress in
            guard let self else { progress.invalidate(); return }
            guard let window = self.window, window.attachedSheet == nil else { self.model.abandonFetchPresentation(progress); return }
            let controller = FetchProgressWindowController(model: progress)
            controller.onClosed = { [weak self, weak progress, weak controller] in
                guard let self, let progress, let controller, self.fetchProgressController === controller else { return }
                self.fetchProgressController = nil; self.model.finishFetch(progress)
            }
            self.fetchProgressController = controller
            guard let child = controller.window, self.presentFetchProgress(window, child) else {
                self.fetchProgressController = nil; self.model.abandonFetchPresentation(progress); controller.close(); return
            }
        }
        model.sshSettings.present = { [weak self] controller in
            guard let self, let owner = self.fetchProgressController?.window ?? self.progressController?.window ?? self.window,
                  owner.attachedSheet == nil, let child = controller.window else { return false }
            owner.makeFirstResponder(nil); owner.beginSheet(child); return true
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

        DialogGeometry.attach(window, identifier: "FetchWindowController")
    }
    func windowWillClose(_ notification: Notification) {
        model.invalidate()
        let fetch = fetchProgressController; fetchProgressController = nil; fetch?.close()
        let pull = progressController; progressController = nil; pull?.close()
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }
        onClosed()
    }
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
    let sshSettings: SSHTransportSettings
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
    var cancelling: Bool { progress?.cancelling ?? fetchProgress?.cancelling ?? false }
    var confirmingCancellation: Bool { progress?.confirmingCancellation ?? fetchProgress?.confirmingCancellation ?? false }
    @Published private(set) var progress: PullProgressWindowModel?
    @Published private(set) var fetchProgress: FetchProgressWindowModel?
    var onFetchProgress: ((FetchProgressWindowModel) -> Void)?
    var onFetchPostAction: ((FetchPostAction, String) -> Void)?
    var followUp = PullFollowUp()
    var onProgress: ((PullProgressWindowModel) -> Void)?
    var onPullPostAction: ((PullPostAction, PullProgressContext) -> Void)?
    var onChanged: (String) -> Void = { _ in }
    private var metadataToken: OperationCancellation?
    private var remoteToken: OperationCancellation?
    private var invalidated = false
    var closed: Bool { invalidated }
    var operationActive: Bool { busy || progress != nil || fetchProgress != nil }
    func invalidate() {
        invalidated = true; generation += 1; metadataToken?.cancel(); metadataToken = nil; remoteToken?.cancel(); remoteToken = nil
        fetchProgress?.invalidate(); fetchProgress = nil; progress?.invalidate(); progress = nil; busy = false; browsing = false; managing = false
    }
    func abandonPullPresentation(_ result: PullProgressWindowModel) { guard progress === result else { return }; result.invalidate(); progress = nil; busy = false }
    func abandonFetchPresentation(_ result: FetchProgressWindowModel) { guard fetchProgress === result else { return }; result.invalidate(); fetchProgress = nil; busy = false }
    func finish(_ result: PullProgressWindowModel) {
        guard !invalidated, progress === result, !result.busy, !result.confirmingConflictHint, !result.confirmingCancellation, !result.dispatchingAction else { return }
        progress = nil; error = nil; result.invalidate(); close()
    }
    func finishFetch(_ result: FetchProgressWindowModel) {
        guard !invalidated, fetchProgress === result, !result.busy, !result.confirmingCancellation, !result.confirmingRebaseDecision, !result.dispatchingAction else { return }
        fetchProgress = nil; error = nil; result.invalidate(); close()
    }
    var transportRunning: Bool { progress?.busy ?? fetchProgress?.busy ?? false }
    var canCancel: Bool { progress?.canCancel ?? fetchProgress?.canCancel ?? !busy }
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
        self.isPull = isPull; self.repository = repository; self.access = access; self.preferences = preferences; sshSettings = SSHTransportSettings(repository: repository); remoteSettings = PushWindowModel(repository: repository, access: access, preferences: preferences)
    }
    private func validateRepositoryAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load(remote presetRemote: String? = nil, allRemotes presetAllRemotes: Bool? = nil) {
        guard !invalidated, !operationActive else { return }; busy = true; let token = OperationCancellation(); metadataToken = token
        Task {
            defer { if metadataToken === token { metadataToken = nil; busy = false } }
            do {
                try validateRepositoryAccess()
                let names = try await repository.remoteNames(cancellation: token), defaults = try await repository.fetchDefaults(cancellation: token)
                guard !invalidated, metadataToken === token, !token.isCancelled else { return }
                remotes = names
                urls = FetchDialogHistory.load(preferences, key: "History.PullURLS", caseSensitive: true)
                branchHistory = FetchDialogHistory.load(preferences, key: "History.PullRemoteBranch", caseSensitive: false)
                options = FetchOptions(); options.remote = defaults.remote
                sshSettings.load(preferences, key: key + ".autoload")
                options.branch = branchHistory.first ?? ""
                selectBranch(defaults.branch, atFront: false)
                options.allRemotes = !isPull && defaults.remote.isEmpty && remotes.count > 1
                if isPull && options.remote.isEmpty { options.remote = remotes.first ?? "" }
                options.namedRemoteFetchAll = preferences.object(forKey: "NamedRemoteFetchAll") as? Bool ?? true
                if let saved = preferences.string(forKey: key + ".remote"), remotes.contains(saved), defaults.remote.isEmpty { options.remote = saved; options.allRemotes = false }
                shallow = defaults.shallow; bare = defaults.bare; depthEnabled = shallow
                tagsDefault = defaults.tags; pruneDefault = defaults.prune
                let pullDefaults = try await repository.pullDefaults(cancellation: token)
                guard !invalidated, metadataToken === token, !token.isCancelled else { return }
                rebaseRequired = isPull && pullDefaults.rebase
                preserveMerges = isPull && pullDefaults.preserveMerges
                launchRebase = !bare && !options.allRemotes && (rebaseRequired || preferences.bool(forKey: key + ".rebase"))
                fastForwardOnly = isPull && preferences.bool(forKey: key + ".ffonly")
                squash = false; noCommit = false; noFastForward = false
                if let presetRemote, !presetRemote.isEmpty {
                    if remotes.contains(presetRemote) {
                        options.remote = presetRemote; options.arbitraryURL = false; options.allRemotes = false
                        let preset = try await repository.fetchDefaults(remote: presetRemote, cancellation: token)
                        guard !invalidated, metadataToken === token, !token.isCancelled else { return }
                        tagsDefault = preset.tags; pruneDefault = preset.prune
                    } else { options.arbitraryURL = true; options.allRemotes = false; url = presetRemote; launchRebase = false }
                }
                if !isPull, let presetAllRemotes { options.allRemotes = presetAllRemotes; if presetAllRemotes { options.arbitraryURL = false; launchRebase = false } }
                remoteSettings.remotes = remotes
            } catch { if !invalidated, metadataToken === token, !token.isCancelled { self.error = error.localizedDescription } }
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
        guard !invalidated, !operationActive else { return }
        generation += 1; let request = generation, remote = options.remote
        remoteToken?.cancel(); let token = OperationCancellation(); remoteToken = token
        Task {
            defer { if remoteToken === token { remoteToken = nil } }
            do { try validateRepositoryAccess(); let defaults = try await repository.fetchDefaults(remote: remote, cancellation: token); guard !invalidated, remoteToken === token, !token.isCancelled, request == generation else { return }; tagsDefault = defaults.tags; pruneDefault = defaults.prune }
            catch { if !invalidated, remoteToken === token, !token.isCancelled, request == generation { self.error = error.localizedDescription } }
        }
    }
    func browse() {
        guard !invalidated, !operationActive else { return }; busy = true
        let destination = options.arbitraryURL ? url : options.remote, token = OperationCancellation(); metadataToken = token
        Task {
            defer { if metadataToken === token { metadataToken = nil; busy = false } }
            do { let coordinator = sshSettings.capture()?(); defer { coordinator?.close() }; try validateRepositoryAccess(); let values = try await repository.remoteBranches(remote: destination, cancellation: token, prepareTransport: coordinator?.preparation); guard !invalidated, metadataToken === token, !token.isCancelled else { return }; branches = values; browsing = true }
            catch { if !invalidated, metadataToken === token, !token.isCancelled { self.error = error.localizedDescription } }
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
        if !busy { close() }
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
        let sshFactory = sshSettings.capture(); sshSettings.save(preferences, key: key + ".autoload")
        preferences.set(wantsRebase, forKey: key + ".rebase")
        if isPull { preferences.set(fastForwardOnly, forKey: key + ".ffonly") }
        if !options.arbitraryURL && !options.allRemotes { preferences.set(options.remote, forKey: key + ".remote") }
        if isPull && !wantsRebase {
            let progress = PullProgressWindowModel(repository: repository, access: access, options: pullOptions, followUp: followUp, preferences: preferences)
            progress.makeSSHCoordinator = sshFactory
            self.progress = progress
            progress.confirmCancellation = { [weak self] choose in self?.confirmCancellation(choose) }
            progress.onPostAction = onPullPostAction
            progress.onCompleted = { [weak self, weak progress] in
                guard let self, let progress, !self.invalidated, self.progress === progress else { return }; self.busy = false
                self.error = progress.success ? nil : progress.output
                self.onChanged(progress.output)
                if progress.success { self.onFetched(progress.output) }
            }
            progress.close = { [weak self, weak progress] in if let progress { self?.finish(progress) } }
            onProgress?(progress); progress.start(); return
        }
        let progress = FetchProgressWindowModel(repository: repository, access: access, options: snapshot, preferences: preferences, rebaseMode: wantsRebase ? (autoStart ? .automatic : .manual) : .none, preserveMerges: keepMerges)
        progress.makeSSHCoordinator = sshFactory
        fetchProgress = progress
        progress.confirmCancellation = { [weak self] choose in self?.confirmCancellation(choose) }
        progress.onPostAction = onFetchPostAction
        progress.onRebase = onRebase
        progress.onCompleted = { [weak self, weak progress] in
            guard let self, let progress, !self.invalidated, self.fetchProgress === progress else { return }; self.busy = false
            self.error = progress.success ? nil : progress.output; self.onChanged(progress.rawOutput)
            if progress.success { self.onFetched(progress.output) }
        }
        progress.close = { [weak self, weak progress] in if let progress { self?.finishFetch(progress) } }
        onFetchProgress?(progress); progress.start()

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
            HStack { SSHAutoloadToggle(settings: model.sshSettings); Spacer(); Button("Manage Remotes") { model.managing = true } }
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
    private let autoClosePolicy: GitProgressAutoClose
    private var cancellation = OperationCancellation()
    private var inspectionToken: OperationCancellation?
    private var started = false, invalidated = false, dispatched = false
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var confirmingConflictHint = false
    @Published private(set) var dispatchingAction = false
    @Published private(set) var output = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var currentWork = ""
    private(set) var rawOutput = ""
    private var outputState: GitProgressOutputState
    var outputLimit: Int { outputState.limit }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        guard !invalidated else { return }
        outputState.consume(emission, parser: parser)
        output = outputState.output; percentage = outputState.percentage; currentWork = outputState.currentWork
    }
    private func resetOutput() {
        outputState.reset(); output = ""; rawOutput = ""; percentage = nil; currentWork = ""
    }
    private func displayFailure(_ error: Error, transport: String) {
        if let failure = error as? GitCommandCancellationFailure { rawOutput = failure.result.text + "\n" + failure.localizedDescription }
        else { rawOutput += (rawOutput.isEmpty ? "" : "\n") + error.localizedDescription }
        let message: String
        if let failure = error as? GitFailure, failure.arguments.first == transport, outputState.hasOutput { message = "Git command failed (\(failure.code))." }
        else if let failure = error as? FetchRebaseExecutionFailure, outputState.hasOutput { message = "Preparing Rebase failed.\n" + (failure.commandFailure.map { "Git command failed (\($0.code))." } ?? failure.details) }
        else { message = error.localizedDescription }
        output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + message
    }
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
    private func finishCompletion() {
        guard !invalidated, !busy, !confirmingCancellation, !confirmingConflictHint, !dispatchingAction else { return }
        if autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) || cancelled && closeAfterCancellation { close() }
    }
    private func completed() { guard !invalidated else { return }; busy = false; cancelling = false; onCompleted(); finishCompletion() }
    init(repository: GitRepository, access: RepositoryAccessLease?, options: PullOptions, followUp: PullFollowUp, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.options = options; self.followUp = followUp; self.preferences = preferences; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences); self.outputState = GitProgressOutputState(preferences: preferences)
    }
    func invalidate() { invalidated = true; cancellation.cancel(); inspectionToken?.cancel(); inspectionToken = nil; busy = false; confirmingCancellation = false; confirmingConflictHint = false; dispatchingAction = false }
    func start() { Task { await run() } }
    func run() async { guard !started, !invalidated else { return }; started = true; await execute(options) }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func execute(_ snapshot: PullOptions) async {
        guard !invalidated else { return }
        busy = true; success = false; cancelled = false; cancelling = false; resetOutput(); postActions = []; newHead = ""
        do { try validateAccess(); if cancellation.isCancelled { throw OperationCancellationFailure.cancelled } }
        catch { guard !invalidated else { return }; output = error.localizedDescription; cancelled = cancellation.isCancelled; completed(); return }
        var beganPull = false
        do {
            let head = try await repository.run(["rev-parse", "--verify", "--end-of-options", "HEAD^{commit}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            guard !invalidated else { return }; oldHead = head; beganPull = true
            let result = try await streamPull(snapshot)
            guard !invalidated else { return }; rawOutput = result
            if !outputState.hasOutput { output = rawOutput }
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }; success = true
        } catch { guard !invalidated else { return }; displayFailure(error, transport: "pull"); cancelled = cancellation.isCancelled }
        guard !invalidated else { return }; guard beganPull else { completed(); return }
        // Normal Cancel inspects recovery with a fresh token; forced closure stops it.
        let token = OperationCancellation(); inspectionToken = token
        defer { if inspectionToken === token { inspectionToken = nil } }
        var actions: [PullPostAction] = []
        if success {
            if followUp.showStashPop { actions.append(.stashPop) }
            let head = try? await repository.run(["rev-parse", "--verify", "--end-of-options", "HEAD^{commit}"], cancellation: token).text.trimmingCharacters(in: .newlines)
            guard !invalidated else { return }; if let head { newHead = head; actions += [.diff, .log] }
            if followUp.showPush { actions.append(.push) }
            let modules = try? await repository.submoduleUpdatePaths(cancellation: token)
            guard !invalidated else { return }; if modules?.isEmpty == false { actions.append(.submoduleUpdate) }
        } else {
            let conflicts = (try? await repository.status(refreshIndex: false, cancellation: token).contains { $0.state == .conflicted }) == true
            guard !invalidated else { return }
            if conflicts {
                if !preferences.bool(forKey: MergeProgressWindowModel.conflictHintPreference), let presentConflictHint {
                    confirmingConflictHint = true
                    let suppress = await presentConflictHint()
                    guard !invalidated else { return }; confirmingConflictHint = false
                    if suppress { preferences.set(true, forKey: MergeProgressWindowModel.conflictHintPreference) }
                }
                actions = [.resolve, .commit]
            } else {
                let known = (try? await repository.remoteNames(cancellation: token).contains(options.fetch.remote)) == true
                guard !invalidated else { return }
                if !options.fetch.arbitraryURL, known {
                    var branch = options.fetch.branch, remote = options.fetch.remote
                    if branch.isEmpty, (try? await repository.branch(cancellation: token).isEmpty) == false, let defaults = try? await repository.pullDefaults(cancellation: token), !defaults.trackedRemote.isEmpty, !defaults.trackedBranch.isEmpty { branch = defaults.trackedBranch; remote = defaults.trackedRemote }
                    guard !invalidated else { return }
                    let shortBranch = branch.hasPrefix("refs/heads/") ? String(branch.dropFirst(11)) : branch
                    let ref = "refs/remotes/" + remote + "/" + shortBranch
                    var common = false
                    if let hash = try? await repository.run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], cancellation: token).text.trimmingCharacters(in: .newlines), !oldHead.isEmpty { common = (try? await repository.run(["merge-base", oldHead, hash], successfulExitCodes: 0...1, cancellation: token).stdout.isEmpty) == false }
                    guard !invalidated else { return }; if !common { actions.append(.mergeUnrelated) }
                }
                actions += [.pull, .stash, .reset]
            }
        }
        guard !invalidated else { return }; postActions = actions; completed()
    }
    var makeSSHCoordinator: SSHTransportFactory?
    private func streamPull(_ snapshot: PullOptions) async throws -> String {
        let coordinator = makeSSHCoordinator?(); defer { coordinator?.close() }; let preparation = coordinator?.preparation
        let parser = GitCliOutputParser(limit: outputState.limit)
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let operation = Task {
            defer { continuation.finish() }
            return try await repository.pull(snapshot, cancellation: cancellation, onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }, prepareTransport: preparation)
        }
        for await _ in updates { consume(parser.processPending(), parser: parser) }
        consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser)
        return try await operation.value
    }
    func cancel() {
        guard !invalidated, busy, canCancel else { return }
        let token = cancellation
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, !self.invalidated, self.confirmingCancellation, self.cancellation === token else { return }
                self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; token.cancel() }; self.finishCompletion()
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: PullPostAction) {
        guard !invalidated, !dispatched, !busy, !confirmingCancellation, !dispatchingAction, !confirmingConflictHint, postActions.contains(action) else { return }
        if action == .mergeUnrelated {
            ProgressActionLog.nextAttempt(self);
            var snapshot = options; snapshot.allowUnrelatedHistories = true
            cancellation = OperationCancellation(); busy = true
            Task { await execute(snapshot) }; return
        }
        guard let onPostAction else { return }
        if action == .reset {
            dispatchingAction = true; let token = OperationCancellation(); inspectionToken = token
            Task {
                defer { if inspectionToken === token { inspectionToken = nil } }
                var revision = ""
                do {
                    try validateAccess()
                    let defaults = try await repository.pullDefaults(cancellation: token)
                    guard !invalidated, inspectionToken === token, !token.isCancelled else { return }
                    if !defaults.trackedRemote.isEmpty && !defaults.trackedBranch.isEmpty { revision = "refs/remotes/" + defaults.trackedRemote + "/" + defaults.trackedBranch }
                } catch { guard !invalidated, inspectionToken === token, !token.isCancelled else { return }; output += "\n" + error.localizedDescription; dispatchingAction = false; return }
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
            guard let self, !self.model.busy, !self.model.confirmingCancellation, !self.model.dispatchingAction, !self.model.confirmingConflictHint, self.window?.attachedSheet == nil else { return }
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

        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        guard !model.confirmingCancellation, !model.confirmingConflictHint, !model.dispatchingAction, sender.attachedSheet == nil else { return false }
        sender.sheetParent?.endSheet(sender); return true
    }
    func windowWillClose(_ notification: Notification) { model.saveActionLog(); model.invalidate(); if let window { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }; window.sheetParent?.endSheet(window) }; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
struct PullProgressDialog: View {
    @ObservedObject var model: PullProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { reader in
                ScrollView { VStack(alignment: .leading, spacing: 0) { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading); Color.clear.frame(height: 1).id("transport-output-end") } }
                    .onChange(of: model.output) { _ in reader.scrollTo("transport-output-end", anchor: .bottom) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor))
            if model.busy, let percentage = model.percentage { ProgressView(value: Double(percentage), total: 100).tint(.green) }
            if !model.currentWork.isEmpty { Text(model.currentWork).font(.caption).lineLimit(2) }
            HStack { if model.busy && model.percentage == nil { ProgressView().controlSize(.small) }; Text(model.busy ? model.cancelling ? "Cancelling…" : "Pulling…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Pull failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red); Spacer() }
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

// Command-line DoFetch result and its manual/automatic Rebase post-execution choices.
enum FetchPostAction: String, CaseIterable, Hashable {
    case retry, log, reset, fetch, rebase, switchBranch, resolve
    var title: String {
        switch self { case .retry: return "Retry"; case .log: return "Show log"; case .reset: return "Reset…"; case .fetch: return "Fetch…"; case .rebase: return "Rebase…"; case .switchBranch: return "Switch/Checkout…"; case .resolve: return "Resolve" }
    }
    var icon: MenuIcon {
        switch self { case .retry: return .refresh; case .log: return .log; case .reset: return .reset; case .fetch: return .fetch; case .rebase: return .rebase; case .switchBranch: return .checkout; case .resolve: return .resolve }
    }
}
enum FetchRebaseMode { case none, manual, automatic }
enum FetchRebasePrompt: String, CaseIterable {
    case upToDate = "OpenRebaseRemoteBranchEqualsHEAD"
    case unchanged = "OpenRebaseRemoteBranchUnchanged"
    case fastForward = "OpenRebaseRemoteBranchFastForwards"
    var message: String {
        switch self {
        case .upToDate: return "Current branch is up to date or newer than the fetched branch. Open rebase anyway?"
        case .unchanged: return "The remote branch has not changed.\n\nOpen the rebase dialog anyway?"
        case .fastForward: return "The fetched branch fast-forwards upon the current branch.\n\nMerge or open the rebase dialog anyway?"
        }
    }
    var buttons: [String] { self == .fastForward ? ["Merge", "Rebase", "Abort"] : ["Yes", "No"] }
    var answers: [Int] { self == .fastForward ? [1, 2, 3] : [6, 7] }
    var defaultIndex: Int { 1 }
}
struct FetchRebaseAnswer { let value: Int; let suppress: Bool }
@MainActor final class FetchProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let options: FetchOptions
    let rebaseMode: FetchRebaseMode
    let preserveMerges: Bool
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private var cancellation = OperationCancellation()
    private var inspectionToken: OperationCancellation?
    private var started = false, invalidated = false, dispatched = false
    private var explicitCloseRequested = false
    private var deferredRebase: (() -> Void)?
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var dispatchingAction = false
    @Published private(set) var output = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var currentWork = ""
    private(set) var rawOutput = ""
    private var outputState: GitProgressOutputState
    var outputLimit: Int { outputState.limit }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser, prefix: String = "") {
        guard !invalidated else { return }
        outputState.consume(emission, parser: parser)
        output = prefix + outputState.output; percentage = outputState.percentage; currentWork = outputState.currentWork
    }
    private func resetOutput() {
        outputState.reset(); output = ""; rawOutput = ""; percentage = nil; currentWork = ""
    }
    private func displayFailure(_ error: Error, transport: String) {
        if let failure = error as? GitCommandCancellationFailure { rawOutput += (rawOutput.isEmpty ? "" : "\n") + failure.result.text + "\n" + failure.localizedDescription }
        else { rawOutput += (rawOutput.isEmpty ? "" : "\n") + error.localizedDescription }
        let message: String
        if let failure = error as? GitFailure, failure.arguments.first == transport, outputState.hasOutput { message = "Git command failed (\(failure.code))." }
        else if let failure = error as? FetchRebaseExecutionFailure, outputState.hasOutput { message = "Preparing Rebase failed.\n" + (failure.commandFailure.map { "Git command failed (\($0.code))." } ?? failure.details) }
        else { message = error.localizedDescription }
        output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + message
    }
    @Published private(set) var postActions: [FetchPostAction] = []
    @Published private(set) var confirmingRebaseDecision = false
    @Published private(set) var merging = false
    var canCancel: Bool { !dispatchingAction && !confirmingRebaseDecision && (!busy || !cancelling && !confirmingCancellation) }
    var closeAfterCancellation = false
    var close: () -> Void = {}
    var onCompleted: () -> Void = {}
    var onPostAction: ((FetchPostAction, String) -> Void)?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    var onRebase: (String, Bool, Bool) -> Void = { _, _, _ in }
    var presentRebasePrompt: (FetchRebasePrompt) async -> FetchRebaseAnswer = { prompt in FetchRebaseAnswer(value: prompt.answers[prompt.defaultIndex], suppress: false) }
    init(repository: GitRepository, access: RepositoryAccessLease?, options: FetchOptions, preferences: UserDefaults = .standard, rebaseMode: FetchRebaseMode = .none, preserveMerges: Bool = false) {
        self.repository = repository; self.access = access; self.options = options; self.preferences = preferences; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences); self.outputState = GitProgressOutputState(preferences: preferences)
        self.rebaseMode = rebaseMode; self.preserveMerges = preserveMerges
    }
    private func answer(_ prompt: FetchRebasePrompt) async -> Int {
        guard !invalidated else { return prompt.answers[prompt.defaultIndex] }
        if let saved = preferences.object(forKey: prompt.rawValue) as? Int, prompt.answers.contains(saved) { return saved }
        confirmingRebaseDecision = true
        let result = await presentRebasePrompt(prompt)
        guard !invalidated else { return prompt.answers[prompt.defaultIndex] }
        confirmingRebaseDecision = false
        let value = prompt.answers.contains(result.value) ? result.value : prompt.answers[prompt.defaultIndex]
        if result.suppress { preferences.set(value, forKey: prompt.rawValue) }
        return value
    }
    private func finishCompletion() {
        guard !busy, !invalidated, !confirmingCancellation else { return }
        if let deferredRebase { self.deferredRebase = nil; deferredRebase(); return }
        if explicitCloseRequested || autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) || cancelled && closeAfterCancellation { close() }
    }
    func invalidate() { invalidated = true; cancellation.cancel(); inspectionToken?.cancel(); inspectionToken = nil; deferredRebase = nil; busy = false; confirmingCancellation = false; confirmingRebaseDecision = false; dispatchingAction = false }
    func start() { Task { await run() } }
    func run() async { guard !started, !invalidated else { return }; started = true; await execute() }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func execute() async {
        guard !invalidated else { return }
        busy = true; success = false; cancelled = false; cancelling = false; merging = false; explicitCloseRequested = false; deferredRebase = nil; resetOutput(); postActions = []
        do {
            try validateAccess()
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            let transport = try await streamFetch()
            guard !invalidated else { return }
            let fetched = transport.1; rawOutput = transport.0
            if !outputState.hasOutput { output = rawOutput }
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            if let fetched {
                var openRebase = true
                if rebaseMode == .manual {
                    if fetched.currentIsUpToDate { if await answer(.upToDate) == 7 { openRebase = false }; guard !invalidated else { return } }
                    if openRebase && fetched.unchangedAtHEAD { if await answer(.unchanged) == 7 { openRebase = false }; guard !invalidated else { return } }
                    if openRebase && fetched.canFastForward {
                        let choice = await answer(.fastForward)
                        guard !invalidated else { return }
                        if choice == 3 { openRebase = false }
                        if choice == 1 {
                            merging = true; percentage = nil; currentWork = ""
                            var merge = MergeOptions(); merge.revision = fetched.upstream; merge.fastForwardOnly = true
                            let mergeOutput = try await streamMerge(merge)
                            guard !invalidated else { return }
                            rawOutput += "\n" + mergeOutput
                            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                            success = true; busy = false; explicitCloseRequested = true; onCompleted(); finishCompletion(); return
                        }
                    }
                }
                if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                if openRebase {
                    success = true; busy = false
                    deferredRebase = { [weak self] in guard let self else { return }; self.close(); self.onRebase(fetched.upstream, self.rebaseMode == .automatic, self.preserveMerges) }
                    onCompleted(); finishCompletion(); return
                }
            }
            success = true
            postActions = [.log, .reset, .fetch]
            if rebaseMode == .none { if (try? await repository.isBare(cancellation: cancellation)) == false { postActions.append(.rebase) } }
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            postActions.append(.switchBranch)
        } catch {
            guard !invalidated else { return }
            displayFailure(error, transport: merging ? "merge" : "fetch"); cancelled = cancellation.isCancelled; success = false
            if merging {
                let token = OperationCancellation(); inspectionToken = token
                let conflicts = (try? await repository.status(refreshIndex: false, cancellation: token).contains(where: { $0.state == .conflicted })) ?? false
                guard !invalidated else { return }; inspectionToken = nil; postActions = conflicts ? [.resolve] : []
            }
            else { postActions = [.retry]; if options.allRemotes { postActions.append(.log) } }
        }
        guard !invalidated else { return }
        busy = false; cancelling = false; onCompleted(); finishCompletion()
    }
    var makeSSHCoordinator: SSHTransportFactory?
    private func streamFetch() async throws -> (String, FetchRebaseResult?) {
        let coordinator = makeSSHCoordinator?(); defer { coordinator?.close() }; let preparation = coordinator?.preparation
        let parser = GitCliOutputParser(limit: outputState.limit)
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let operation = Task<(String, FetchRebaseResult?), Error> {
            defer { continuation.finish() }
            let observer: @Sendable (GitOutputChunk) -> Void = { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }
            if rebaseMode == .none { return (try await repository.fetch(options, cancellation: cancellation, onOutput: observer, prepareTransport: preparation), nil) }
            let result = try await repository.fetchForRebase(options, cancellation: cancellation, onOutput: observer, prepareTransport: preparation)
            return (result.output, result)
        }
        for await _ in updates { consume(parser.processPending(), parser: parser) }
        consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser)
        return try await operation.value
    }
    private func streamMerge(_ options: MergeOptions) async throws -> String {
        // Upstream creates a new Merge progress dialog. Keep the retained Fetch
        // log here, but start an independent captured-limit presentation phase.
        let prefix = output + "\n"; outputState.reset(); percentage = nil; currentWork = ""
        let parser = GitCliOutputParser(limit: outputState.limit)
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let operation = Task {
            defer { continuation.finish() }
            return try await repository.merge(options, cancellation: cancellation, onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) })
        }
        for await _ in updates { consume(parser.processPending(), parser: parser, prefix: prefix) }
        consume(parser.processPending(), parser: parser, prefix: prefix); consume(parser.finish(), parser: parser, prefix: prefix)
        return try await operation.value
    }
    func cancel() {
        guard !invalidated, busy, canCancel else { return }
        let token = cancellation
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, !self.invalidated, self.confirmingCancellation, self.cancellation === token else { return }
                self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; token.cancel() }
                self.finishCompletion()
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: FetchPostAction) {
        guard !invalidated, !dispatched, !busy, !confirmingCancellation, !confirmingRebaseDecision, !dispatchingAction, postActions.contains(action) else { return }
        if action == .retry {
            ProgressActionLog.nextAttempt(self); cancellation = OperationCancellation(); busy = true; Task { await execute() }; return }
        guard let onPostAction else { return }
        if action == .reset {
            dispatchingAction = true; let token = OperationCancellation(); inspectionToken = token
            Task {
                defer { if inspectionToken === token { inspectionToken = nil } }
                var revision = ""
                do {
                    try validateAccess(); let defaults = try await repository.pullDefaults(cancellation: token)
                    guard !invalidated, inspectionToken === token, !token.isCancelled else { return }
                    if !defaults.trackedRemote.isEmpty && !defaults.trackedBranch.isEmpty { revision = "refs/remotes/" + defaults.trackedRemote + "/" + defaults.trackedBranch }
                } catch { guard !invalidated, inspectionToken === token, !token.isCancelled else { return }; output += "\n" + error.localizedDescription; dispatchingAction = false; return }
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
            guard let self, !self.model.busy, !self.model.confirmingCancellation, !self.model.dispatchingAction, !self.model.confirmingRebaseDecision, self.window?.attachedSheet == nil else { return }
            if let window = self.window { window.sheetParent?.endSheet(window); window.close() }
        }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
        model.presentRebasePrompt = { [weak window] prompt in
            guard let window, window.attachedSheet == nil else { return FetchRebaseAnswer(value: prompt.answers[prompt.defaultIndex], suppress: false) }
            return await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "TurtleGit"; alert.informativeText = prompt.message
                for (index, title) in prompt.buttons.enumerated() {
                    let button = alert.addButton(withTitle: title)
                    button.keyEquivalent = index == prompt.defaultIndex ? "\r" : ""
                    if index == prompt.defaultIndex { alert.window.defaultButtonCell = button.cell as? NSButtonCell }
                }
                if prompt == .fastForward { alert.buttons.last?.keyEquivalent = "\u{1b}" }
                alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Don't show this message again"
                alert.beginSheetModal(for: window) { response in
                    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    let value = prompt.answers.indices.contains(index) ? prompt.answers[index] : prompt.answers[prompt.defaultIndex]
                    continuation.resume(returning: FetchRebaseAnswer(value: value, suppress: alert.suppressionButton?.state == .on))
                }
            }
        }


        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        guard !model.confirmingCancellation, !model.dispatchingAction, !model.confirmingRebaseDecision, sender.attachedSheet == nil else { return false }
        sender.sheetParent?.endSheet(sender); return true
    }
    func windowWillClose(_ notification: Notification) { model.saveActionLog(); model.invalidate(); if let window { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }; window.sheetParent?.endSheet(window) }; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
struct FetchProgressDialog: View {
    @ObservedObject var model: FetchProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { reader in
                ScrollView { VStack(alignment: .leading, spacing: 0) { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading); Color.clear.frame(height: 1).id("transport-output-end") } }
                    .onChange(of: model.output) { _ in reader.scrollTo("transport-output-end", anchor: .bottom) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor))
            if model.busy, let percentage = model.percentage { ProgressView(value: Double(percentage), total: 100).tint(.green) }
            if !model.currentWork.isEmpty { Text(model.currentWork).font(.caption).lineLimit(2) }
            HStack { if model.busy && model.percentage == nil { ProgressView().controlSize(.small) }; Text(model.busy ? model.cancelling ? "Cancelling…" : model.confirmingRebaseDecision ? "Waiting for your choice…" : model.merging ? "Merging…" : "Fetching…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : model.merging ? "Merge failed" : "Fetch failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red); Spacer() }
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

/// CProgressDlg's constructor mapping and successful END-message close condition.
enum GitProgressAutoClose: Int, CaseIterable, Sendable {
    case manual = 0, noOptions = 1, noErrors = 2
    init(preferences: UserDefaults = .standard) { self = Self(rawValue: preferences.integer(forKey: "AutoCloseGitProgress")) ?? .manual }
    var title: String {
        switch self {
        case .manual: return "Close manually"
        case .noOptions: return "Auto-close if no further options are available"
        case .noErrors: return "Auto-close if no errors"
        }
    }
    func shouldClose(success: Bool, postActionCount: Int) -> Bool {
        success && (self == .noErrors || self == .noOptions && postActionCount == 0)
    }
}
