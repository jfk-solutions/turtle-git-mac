import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class VersionPickerCoordinator {
    private weak var window: NSWindow?
    private let model: SwitchWindowModel
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    private let allowed: () -> Bool
    private var invalidated = false
    var onSelection: () -> Void = {}
    private(set) var referencePicker: ReferenceBrowserWindowController?
    private(set) var commitPicker: LogWindowController?
    private var pickerRequest: UUID?
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var presentPicker: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void, UserDefaults) -> LogWindowController = { repository, access, choose, preferences in
        LogWindowController(repository: repository, access: access, onChoose: choose, labelDefaults: preferences)
    }
    init(window: NSWindow, model: SwitchWindowModel, access: RepositoryAccessLease?, preferences: UserDefaults, allowed: @escaping () -> Bool = { true }) {
        self.window = window; self.model = model; self.access = access; self.preferences = preferences; self.allowed = allowed
        model.onBrowsePicker = { [weak self] target in self?.showPicker(target) }
    }
    private func showPicker(_ target: CheckoutTarget) {
        guard !invalidated, allowed(), let owner = window, owner.attachedSheet == nil, referencePicker == nil, commitPicker == nil, model.beginPicker(target) else { return }
        let request = UUID(); pickerRequest = request
        if target == .branch {
            let child = ReferenceBrowserWindowController(repository: model.repository, access: access, initial: model.revision, preferences: preferences) { [weak self] name in
                guard let self, self.pickerRequest == request else { return }
                self.model.acceptReferenceSelection(name) { [weak self] in if let self, self.pickerRequest == request { self.pickerRequest = nil; if self.model.error == nil { self.onSelection() } } }
            }
            referencePicker = child; configureReferencePicker(child.model)
            child.onClosed = { [weak self, weak child] in
                guard let self, let child, self.referencePicker === child else { return }
                if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }; self.referencePicker = nil
            }
            guard let window = child.window, presentPicker(owner, window) else { child.abandonPresentation(); referencePicker = nil; pickerRequest = nil; model.finishPicker(); return }
            child.model.load()
        } else {
            let child = makeCommitPicker(model.repository, access, { [weak self] entry in
                guard let self, self.pickerRequest == request else { return }; self.pickerRequest = nil; self.model.acceptCommitSelection(entry); if entry != nil { self.onSelection() }
            }, preferences)
            commitPicker = child
            child.onClosed = { [weak self, weak child] in
                guard let self, let child, self.commitPicker === child else { return }
                if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }; self.commitPicker = nil
            }
            child.model.endRevision = model.commitRevision.isEmpty ? nil : model.commitRevision
            guard let window = child.window, presentPicker(owner, window) else { child.close(); commitPicker = nil; pickerRequest = nil; model.finishPicker(); return }
            child.model.reload()
        }
    }
    func invalidate() { invalidated = true; pickerRequest = nil; model.invalidate(); referencePicker?.close(); referencePicker = nil; commitPicker?.close(); commitPicker = nil }
}

@MainActor final class SwitchWindowController: NSWindowController, NSWindowDelegate {
    let model: SwitchWindowModel
    var onClosed: () -> Void = {}
    private(set) var progressController: SwitchProgressWindowController?
    var presentProgress: (NSWindow, NSWindow, @escaping () -> Void) -> Bool = { owner, child, completed in
        guard owner.attachedSheet == nil else { return false }
        owner.beginSheet(child) { _ in completed() }; return true
    }
    private var pickers: VersionPickerCoordinator!
    var referencePicker: ReferenceBrowserWindowController? { pickers.referencePicker }
    var commitPicker: LogWindowController? { pickers.commitPicker }
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void { get { pickers.configureReferencePicker } set { pickers.configureReferencePicker = newValue } }
    var presentPicker: (NSWindow, NSWindow) -> Bool { get { pickers.presentPicker } set { pickers.presentPicker = newValue } }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void, UserDefaults) -> LogWindowController { get { pickers.makeCommitPicker } set { pickers.makeCommitPicker = newValue } }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, preferences: UserDefaults = .standard) {
        model = SwitchWindowModel(repository: repository, access: access, revision: revision, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 370),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Switch/Checkout – TurtleGit"
        window.minSize = NSSize(width: 600, height: 390); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SwitchDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        pickers = VersionPickerCoordinator(window: window, model: model, access: access, preferences: preferences)
        window.setContentSize(NSSize(width: 620, height: 370)); window.center()
        model.close = { [weak self] in guard let self, !self.model.busy, self.model.progress == nil, !self.model.hasPendingTagConflict, self.model.browser == nil, self.model.pickerTarget == nil, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        model.onProgress = { [weak self] result in
            guard let self else { result.abandonPresentation(); return }
            guard let window = self.window, window.attachedSheet == nil else { self.model.abandonProgressPresentation(result); return }
            let controller = SwitchProgressWindowController(model: result)
            self.progressController = controller
            if let child = controller.window, self.presentProgress(window, child, { [weak self, weak result, weak controller] in
                guard let self, let result, let controller, self.progressController === controller else { return }
                self.progressController = nil; self.model.finish(result)
            }) { return }
            self.progressController = nil; self.model.abandonProgressPresentation(result)
            controller.close()
        }

        DialogGeometry.attach(window, identifier: "SwitchWindowController")
    }
    func windowWillClose(_ notification: Notification) { model.invalidate(); pickers.invalidate(); onClosed() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && model.progress == nil && model.browser == nil && model.pickerTarget == nil && !model.hasPendingTagConflict && sender.attachedSheet == nil }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class SwitchWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let initialRevision: String?
    private let preferences: UserDefaults
    private var invalidated = false, finished = false
    private var initialLoadToken: OperationCancellation?
    private var conflictSnapshot: CheckoutOptions?
    var hasPendingTagConflict: Bool { tagConflict || conflictSnapshot != nil }
    @Published private(set) var progress: SwitchProgressWindowModel?
    var onProgress: ((SwitchProgressWindowModel) -> Void)?
    var onChanged: (String) -> Void = { _ in }
    var onPostAction: ((SwitchPostAction, String) -> Void)?
    func abandonProgressPresentation(_ result: SwitchProgressWindowModel) {
        guard progress === result else { return }
        // A controller that was never presented must release its owner without
        // starting Git or waiting for an acknowledgement from its closed window.
        result.abandonPresentation(); result.invalidate(); progress = nil; busy = false
    }
    func invalidate() { invalidated = true; if initialLoadToken != nil { initialLoadToken?.cancel(); initialLoadToken = nil; busy = false }; conflictSnapshot = nil; finishPicker(); referenceFocusRequest = 0; progress?.invalidate() }
    func abortTagConflict() { tagConflict = false; conflictSnapshot = nil }
    func finish(_ result: SwitchProgressWindowModel) {
        guard progress === result, !result.busy, !result.confirmingCancellation else { return }
        progress = nil; result.invalidate(); busy = false
        guard !invalidated else { return }
        if result.success { finished = true; close(); onSwitched(result.output) }
    }
    @Published var references: [CheckoutReference] = []
    @Published var options = CheckoutOptions()
    @Published var branchRevision = ""
    @Published var tagRevision = ""
    @Published var commitRevision = "HEAD"
    @Published var busy = false
    @Published var error: String?
    @Published var tagConflict = false
    @Published var browser: CheckoutTarget?
    @Published var commits: [LogEntry] = []
    @Published private(set) var pickerTarget: CheckoutTarget?
    @Published private(set) var referenceFocusRequest = 0
    private var appliedReferenceFocusRequest = 0
    private var referenceSelectionToken: OperationCancellation?
    var onBrowsePicker: ((CheckoutTarget) -> Void)?
    func canBrowse(_ target: CheckoutTarget) -> Bool { !busy && progress == nil && !hasPendingTagConflict && browser == nil && pickerTarget == nil && !invalidated && !finished && options.target == target && target != .tag }
    func beginPicker(_ target: CheckoutTarget) -> Bool { guard canBrowse(target) else { return false }; pickerTarget = target; return true }
    func finishPicker() { if referenceSelectionToken != nil { referenceSelectionToken?.cancel(); referenceSelectionToken = nil; busy = false }; pickerTarget = nil }
    func focusReference(_ control: NSControl, target: CheckoutTarget) {
        guard !invalidated, !finished, referenceFocusRequest > appliedReferenceFocusRequest, options.target == target,
              !busy, pickerTarget == nil, browser == nil, progress == nil, !hasPendingTagConflict, error == nil,
              control.isEnabled, let window = control.window, window.attachedSheet == nil else { return }
        if window.makeFirstResponder(control) { appliedReferenceFocusRequest = referenceFocusRequest }
    }
    func acceptReferenceSelection(_ name: String?, completion: @escaping () -> Void) {
        guard !invalidated, !finished, pickerTarget == .branch else { return }
        referenceSelectionToken?.cancel(); let token = OperationCancellation(); referenceSelectionToken = token; busy = true
        let requested = name ?? revision, draft = commitRevision
        Task {
            var applied = false
            defer { if referenceSelectionToken === token { referenceSelectionToken = nil; busy = false; pickerTarget = nil; if applied { referenceFocusRequest += 1 }; completion() } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let catalog = try await repository.checkoutReferences(cancellation: token)
                guard !invalidated, !finished, referenceSelectionToken === token, !token.isCancelled else { return }
                references = catalog
                if let reference = catalog.first(where: { GitReferenceName.equal($0.name, requested) }), let target = reference.target {
                    options.target = target
                    if target == .branch { branchRevision = requested } else { tagRevision = requested }; commitRevision = draft
                } else { options.target = .commit; commitRevision = requested }
                defaults(); applied = true
            } catch { if !invalidated, referenceSelectionToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func acceptCommitSelection(_ entry: LogEntry?) {
        guard !invalidated, !finished, pickerTarget == .commit else { return }
        if let entry { commitRevision = entry.hash; defaults(); referenceFocusRequest += 1 }; finishPicker()
    }
    var close: () -> Void = {}
    var onSwitched: (String) -> Void = { _ in }
    var branches: [CheckoutReference] { references.filter { $0.target == .branch && ($0.symbolicTarget == nil || GitReferenceName.equal($0.name, branchRevision)) } }
    var tags: [CheckoutReference] { references.filter { $0.target == .tag } }
    var revision: String { switch options.target { case .branch: return branchRevision; case .tag: return tagRevision; case .commit: return commitRevision } }
    var remote: Bool { options.target == .branch && references.first { $0.name.utf8.elementsEqual(branchRevision.utf8) }?.remote == true }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; initialRevision = revision; self.preferences = preferences }
    func load(revision preset: String? = nil) {
        guard !busy, pickerTarget == nil, progress == nil, !hasPendingTagConflict, !invalidated, !finished else { return }; busy = true
        let token = OperationCancellation(); initialLoadToken = token
        let revision = preset ?? initialRevision
        Task {
            defer { if initialLoadToken === token { initialLoadToken = nil; busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let catalog = try await repository.checkoutReferences(cancellation: token)
                let current = try await repository.branch(cancellation: token)
                guard !invalidated, !finished, initialLoadToken === token, !token.isCancelled else { return }
                references = catalog
                branchRevision = branches.first { GitReferenceName.equal($0.name, "refs/heads/" + current) }?.name ?? branches.first?.name ?? ""
                tagRevision = tags.first?.name ?? ""
                commitRevision = revision ?? "HEAD"; options = CheckoutOptions()
                if let revision, references.contains(where: { GitReferenceName.equal($0.name, revision) }) {
                    if GitReferenceName.removingPrefix("refs/tags/", from: revision) != nil { options.target = .tag; tagRevision = revision }
                    else { options.target = .branch; branchRevision = revision }
                } else { options.target = revision == nil ? .branch : .commit }
                defaults()
            } catch { if !invalidated, initialLoadToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func defaults() {
        options.overrideBranch = false
        options.tracking = remote ? .automatic : .noTrack
        let reference = references.first { GitReferenceName.equal($0.name, revision) }
        options.branchName = reference?.suggestedBranch ?? "Branch_" + String(commitRevision.prefix(7))
        switch options.target {
        case .branch: options.createBranch = remote
        case .tag: options.createBranch = preferences.object(forKey: "SwitchToTagNewBranch") as? Bool ?? true
        case .commit: options.createBranch = preferences.object(forKey: "SwitchToCommitNewBranch") as? Bool ?? true
        }
    }
    func browse(_ target: CheckoutTarget) {
        if let onBrowsePicker { guard canBrowse(target) else { return }; onBrowsePicker(target); return }
        guard !busy else { return }
        if target != .commit { browser = target; return }
        busy = true
        Task {
            defer { busy = false }
            do { var history = HistoryOptions(); history.allBranches = true; history.limit = 200
                commits = try await repository.history(options: history); browser = target
            } catch { self.error = error.localizedDescription }
        }
    }
    func checkout(allowTagConflict: Bool = false) {
        guard !busy, pickerTarget == nil, progress == nil, browser == nil, !invalidated, !finished else { return }
        var snapshot = options; snapshot.revision = revision; snapshot.allowTagNameConflict = allowTagConflict
        if allowTagConflict, let captured = conflictSnapshot { snapshot = captured; snapshot.allowTagNameConflict = true }
        else if hasPendingTagConflict { return }
        conflictSnapshot = nil; tagConflict = false
        if snapshot.target == .tag { preferences.set(snapshot.createBranch, forKey: "SwitchToTagNewBranch") }
        if snapshot.target == .commit { preferences.set(snapshot.createBranch, forKey: "SwitchToCommitNewBranch") }
        busy = true; error = nil
        Task {
            defer { if progress == nil { busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                if let onProgress {
                    try await repository.validateCheckout(snapshot)
                    guard !invalidated else { return }
                    let result = SwitchProgressWindowModel(repository: repository, access: access, options: snapshot, preferences: preferences)
                    result.onFinished = { [weak self] output, _ in self?.onChanged(output) }
                    result.onPostAction = { [weak self] action, branch in self?.onPostAction?(action, branch) }
                    result.close = { [weak self, weak result] in guard let self, let result else { return }; self.finish(result) }
                    progress = result; onProgress(result); result.start()
                } else {
                    let output = try await repository.checkout(snapshot)
                    guard !invalidated else { return }; busy = false; finished = true; onSwitched(output); close()
                }
            } catch CheckoutFailure.tagNameConflict { conflictSnapshot = snapshot; tagConflict = true }
            catch { self.error = error.localizedDescription }
        }
    }

}

struct SwitchDialog: View {
    @ObservedObject var model: SwitchWindowModel
    var body: some View {
        VStack(spacing: 16) {
            GroupBox("Switch To") {
                VStack(spacing: 6) {
                    HStack {
                        SwitchRadio(title: "Branch", target: .branch, selection: $model.options.target).frame(width: 100)
                        ReferencePopup(references: model.branches, selection: $model.branchRevision, accessibilityLabel: "Switch branch revision", focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .branch) }).disabled(model.options.target != .branch)
                        Button("…") { model.browse(.branch) }.accessibilityLabel("Browse references").disabled(model.options.target != .branch)
                    }.frame(height: 26)
                    HStack {
                        SwitchRadio(title: "Tag", target: .tag, selection: $model.options.target).frame(width: 100)
                        ReferencePopup(references: model.tags, selection: $model.tagRevision, accessibilityLabel: "Switch tag revision", focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .tag) }).disabled(model.options.target != .tag)
                        Color.clear.frame(width: 29)
                    }.frame(height: 26)
                    HStack {
                        SwitchRadio(title: "Commit", target: .commit, selection: $model.options.target).frame(width: 100)
                        VersionRevisionField(text: $model.commitRevision, focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .commit) }).disabled(model.options.target != .commit)
                        Button("…") { model.browse(.commit) }.accessibilityLabel("Choose commit").disabled(model.options.target != .commit)
                    }.frame(height: 26)
                }.padding(8)
            }
            GroupBox("Option") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("Create New Branch", isOn: $model.options.createBranch).frame(width: 180, alignment: .leading)
                        TextField("New branch name", text: $model.options.branchName).disabled(!model.options.createBranch)
                    }
                    HStack {
                        Toggle("Overwrite working tree changes (force)", isOn: $model.options.overwriteChanges)
                        Spacer(); Toggle("Merge", isOn: $model.options.merge)
                    }
                    TrackingCheckbox(value: $model.options.tracking, enabled: model.remote && model.options.createBranch)
                        .frame(height: 18).help("Mixed: use Git's automatic tracking configuration. Checked: track this remote branch. Unchecked: no tracking.")
                    Toggle("Override branch if exists", isOn: $model.options.overrideBranch).disabled(!model.options.createBranch)
                }.padding(8)
            }
            Spacer(minLength: 0)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.checkout() }.keyboardShortcut(.defaultAction).disabled(model.revision.isEmpty)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-switch.html")!) }
            }
        }.padding(16).disabled(model.busy || model.pickerTarget != nil)
        .onChange(of: model.options.target) { _ in model.defaults() }
        .onChange(of: model.branchRevision) { _ in if model.options.target == .branch { model.defaults() } }
        .onChange(of: model.tagRevision) { _ in if model.options.target == .tag { model.defaults() } }
        .onChange(of: model.commitRevision) { _ in if model.options.target == .commit { model.defaults() } }
        .onChange(of: model.options.branchName) { name in
            if model.remote, let reference = model.references.first(where: { $0.name == model.branchRevision }), name != reference.suggestedBranch { model.options.tracking = .noTrack }
        }
        .onChange(of: model.options.createBranch) { create in
            if !create { model.options.overrideBranch = false; model.options.tracking = .noTrack }
        }
        .alert("Switch/Checkout failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Branch and tag share a name", isPresented: $model.tagConflict) {
            Button("Continue") { model.checkout(allowTagConflict: true) }; Button("Abort", role: .cancel) { model.abortTagConflict() }
        } message: { Text(CheckoutFailure.tagNameConflict.localizedDescription) }
        .sheet(item: $model.browser) { target in SwitchReferenceChooser(model: model, target: target) }
    }
}

struct SwitchReferenceChooser: View {
    @ObservedObject var model: SwitchWindowModel
    let target: CheckoutTarget
    @State private var search = ""
    @State private var selected: String?
    var choices: [(String, String)] {
        let choices = target == .commit ? model.commits.map { ($0.hash, String($0.hash.prefix(8)) + "  " + $0.subject) } : model.branches.map { ($0.name, $0.label) }
        return choices.filter { search.isEmpty || $0.1.localizedCaseInsensitiveContains(search) || $0.0.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target == .commit ? "Choose commit" : "Browse references").font(.headline)
            TextField("Filter", text: $search)
            List(selection: $selected) { ForEach(choices, id: \.0) { choice in Text(choice.1).tag(choice.0) } }
            HStack { Spacer(); Button("Cancel") { model.browser = nil }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    guard let selected else { return }
                    if target == .commit { model.commitRevision = selected } else { model.branchRevision = selected }
                    model.defaults(); model.browser = nil
                }.keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }.padding(16).frame(width: 650, height: 430)
    }
}

struct TrackingCheckbox: NSViewRepresentable {
    @Binding var value: CheckoutTracking
    let enabled: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "Track", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true; return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = value == .automatic ? .mixed : (value == .track ? .on : .off); button.isEnabled = enabled
        context.coordinator.change = { value = $0 }; context.coordinator.value = value
    }
    final class Coordinator: NSObject {
        var change: (CheckoutTracking) -> Void = { _ in }; var value = CheckoutTracking.automatic
        @objc func clicked(_ sender: NSButton) { change(value == .automatic ? .noTrack : (value == .noTrack ? .track : .automatic)) }
    }
}

struct SwitchRadio: NSViewRepresentable {
    let title: String
    let target: CheckoutTarget
    @Binding var selection: CheckoutTarget
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = selection == target ? .on : .off; button.isEnabled = enabled
        context.coordinator.change = { selection = target }
    }
    final class Coordinator: NSObject {
        var change: () -> Void = {}
        @objc func clicked(_ sender: NSButton) { change() }
    }
}

struct ReferencePopup: NSViewRepresentable {
    let references: [CheckoutReference]
    @Binding var selection: String
    var accessibilityLabel: String? = nil
    var focusRequest = 0
    var onFocus: ((NSPopUpButton) -> Void)? = nil
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        if let accessibilityLabel { button.setAccessibilityLabel(accessibilityLabel) }
        button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let names = references.map(\.name)
        if context.coordinator.names.map({ GitReferenceName($0) }) != names.map({ GitReferenceName($0) }) || button.numberOfItems == 0 {
            button.removeAllItems()
            // addItems(withTitles:) replaces canonically equivalent titles, but Git refs are byte-distinct.
            for title in references.isEmpty ? ["No references"] : references.map(\.label) {
                button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        context.coordinator.names = names
        if let index = names.firstIndex(where: { GitReferenceName.equal($0, selection) }) { button.selectItem(at: index) }
        button.isEnabled = enabled && !references.isEmpty
        context.coordinator.change = { selection = $0 }
        if focusRequest > 0, let onFocus { DispatchQueue.main.async { [weak button] in if let button { onFocus(button) } } }
    }
    final class Coordinator: NSObject {
        var names: [String] = []; var change: (String) -> Void = { _ in }
        @MainActor @objc func changed(_ sender: NSPopUpButton) {
            guard names.indices.contains(sender.indexOfSelectedItem) else { return }; change(names[sender.indexOfSelectedItem])
        }
    }
}

// PerformSwitch's immediate branch command and its progress/post-command choices.
enum SwitchPostAction: String, CaseIterable, Hashable {
    case submoduleUpdate, mergePreviousBranch, pull, commit, resolve, stash, retry, switchWithMerge
    var title: String {
        switch self {
        case .submoduleUpdate: return "Submodule Update…"
        case .mergePreviousBranch: return "Merge…"
        case .pull: return "Pull…"
        case .commit: return "Commit…"
        case .resolve: return "Resolve…"
        case .stash: return "Stash Save…"
        case .retry: return "Retry"
        case .switchWithMerge: return "Switch with Merge"
        }
    }
    var icon: MenuIcon {
        switch self {
        case .submoduleUpdate: return .fetch
        case .mergePreviousBranch: return .merge
        case .pull: return .pull
        case .commit: return .commit
        case .resolve: return .resolve
        case .stash: return .stash
        case .retry: return .mergeReload
        case .switchWithMerge: return .checkout
        }
    }
}
@MainActor final class SwitchProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: SwitchProgressWindowModel
    var onClosed: () -> Void = {}
    convenience init(repository: GitRepository, access: RepositoryAccessLease?, reference: String) {
        self.init(model: SwitchProgressWindowModel(repository: repository, access: access, reference: reference))
    }
    init(model: SwitchProgressWindowModel) {
        self.model = model
        let repository = model.repository
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Switch Progress – TurtleGit"
        window.contentMinSize = NSSize(width: 560, height: 300); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SwitchProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in
            guard let self, !self.model.busy, !self.model.confirmingCancellation, self.window?.attachedSheet == nil else { return }
            if let window = self.window { window.sheetParent?.endSheet(window); window.close() }
        }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }

        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        guard !model.confirmingCancellation, sender.attachedSheet == nil else { return false }
        sender.sheetParent?.endSheet(sender); return true
    }
    func windowWillClose(_ notification: Notification) { model.saveActionLog(); model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class SwitchProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let reference: String
    private let access: RepositoryAccessLease?
    private var cancellation = OperationCancellation()
    private var started = false, invalidated = false, dispatched = false, abandoned = false
    private var merging = false
    let options: CheckoutOptions
    private let preferences: UserDefaults
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { busy && !cancelling && !confirmingCancellation }
    func invalidate() { invalidated = true }
    func abandonPresentation() { abandoned = true; cancellation.cancel() }
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var output = ""
    @Published private(set) var previousBranch = ""
    @Published private(set) var postActions: [SwitchPostAction] = []
    var onFinished: (String, Bool) -> Void = { _, _ in }
    var onPostAction: ((SwitchPostAction, String) -> Void)?
    private let autoClosePolicy: GitProgressAutoClose
    var close: () -> Void = {}
    convenience init(repository: GitRepository, access: RepositoryAccessLease?, reference: String, preferences: UserDefaults = .standard) {
        var options = CheckoutOptions(); options.revision = reference
        self.init(repository: repository, access: access, options: options, preferences: preferences)
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, options: CheckoutOptions, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.options = options; self.reference = options.revision; self.preferences = preferences; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences)
    }
    func start() { Task { await run() } }
    func run() async { guard !started, !invalidated else { return }; started = true; await execute(merge: options.merge) }
    private func finishAutomaticClose() {
        if !busy, !confirmingCancellation, !invalidated, abandoned || autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() }
    }
    func cancel() {
        guard canCancel, !invalidated else { return }
        let token = cancellation
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, self.cancellation === token, !self.invalidated else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; token.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: SwitchPostAction) {
        guard !busy, !confirmingCancellation, !invalidated, !dispatched, postActions.contains(action) else { return }
        if action == .retry || action == .switchWithMerge {
            ProgressActionLog.nextAttempt(self);
            let merge = action == .switchWithMerge || merging
            busy = true; cancellation = OperationCancellation()
            Task { await execute(merge: merge) }
        } else if let onPostAction { dispatched = true; let branch = previousBranch; close(); onPostAction(action, branch) }
    }
    private func execute(merge: Bool) async {
        busy = true; success = false; cancelled = false; cancelling = false; postActions = []; output = ""; merging = merge
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            guard try await !repository.isBare() else { throw CheckoutFailure.invalidRevision }
            previousBranch = try await repository.branch()
            var options = self.options; options.merge = merge
            output = try await repository.checkout(options, cancellation: cancellation)
            let conflicts = try await repository.status(refreshIndex: false).contains { $0.state == .conflicted }
            if merge && conflicts { output += "\nHas merge conflict" }
            else {
                if FileManager.default.fileExists(atPath: repository.root.appendingPathComponent(".gitmodules").path) { postActions.append(.submoduleUpdate) }
                if !previousBranch.isEmpty { postActions.append(.mergePreviousBranch) }
                if try await !repository.branch().isEmpty { postActions.append(.pull) }
                postActions.append(.commit)
                success = true
            }
        } catch { output += (output.isEmpty ? "" : "\n") + error.localizedDescription }
        cancelled = cancellation.isCancelled
        if !success {
            postActions = []
            let conflicts = merge ? ((try? await repository.status(refreshIndex: false).contains { $0.state == .conflicted }) == true) : false
            if conflicts { postActions.append(.resolve) }
            if !merge { postActions.append(.stash) }
            postActions.append(.retry)
            if !merge { postActions.append(.switchWithMerge) }
        }
        busy = false; onFinished(output, success)
        finishAutomaticClose()
    }
}
struct SwitchProgressDialog: View {
    @ObservedObject var model: SwitchProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch to \(model.reference)").font(.headline)
            ScrollView { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor))
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text(model.cancelling ? "Cancelling…" : "Switching…") }
                else { Text(model.cancelled ? "Cancelled" : model.success ? "Finished" : "Switch failed").foregroundStyle(model.success ? Color.green : Color.red) }
                Spacer()
            }
            HStack {
                if let first = model.postActions.first {
                    HStack(spacing: 2) {
                        Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                        Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Switch post-actions") }.menuStyle(.borderlessButton).fixedSize()
                    }.disabled(model.busy)
                }
                Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.confirmingCancellation)
        }.padding(12)
    }
}

struct VersionRevisionField: NSViewRepresentable {
    @Binding var text: String
    var accessibilityLabel = "Switch commit revision"
    let focusRequest: Int
    let onFocus: (NSTextField) -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(); field.isBezeled = true; field.bezelStyle = .squareBezel; field.drawsBackground = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize); field.placeholderString = "Commit"; field.setAccessibilityLabel(accessibilityLabel)
        field.delegate = context.coordinator; return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        if !field.stringValue.utf8.elementsEqual(text.utf8) { field.stringValue = text }
        field.isEnabled = enabled; context.coordinator.change = { text = $0 }
        if focusRequest > 0 { DispatchQueue.main.async { [weak field] in if let field { onFocus(field) } } }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) { field.delegate = nil; coordinator.change = { _ in } }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSTextField, field.isEnabled { change(field.stringValue) } }
    }
}
