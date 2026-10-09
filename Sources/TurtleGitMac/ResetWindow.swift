import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class ResetWindowController: NSWindowController, NSWindowDelegate {
    let model: ResetWindowModel
    var onClosed: () -> Void = {}
    private var progressController: ResetProgressWindowController?
    private(set) var modifiedComparison: RevisionComparisonWindowController?
    private var closed = false
    private(set) var commitPicker: LogWindowController?
    private var commitPickerRequest: UUID?
    private(set) var referencePicker: ReferenceBrowserWindowController?
    private var referencePickerRequest: UUID?
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var presentReferencePicker: (NSWindow, NSWindow) -> Bool = { owner, child in
        guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true
    }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void, UserDefaults) -> LogWindowController = { repository, access, choose, preferences in
        LogWindowController(repository: repository, access: access, onChoose: choose, labelDefaults: preferences)
    }
    var presentCommitPicker: (NSWindow, NSWindow) -> Bool = { owner, child in
        guard owner.attachedSheet == nil else { return false }
        owner.beginSheet(child); return true
    }
    var configureModifiedComparison: (RevisionComparisonWindowModel) -> Void = { _ in }
    var presentModifiedComparison: (NSWindow, NSWindow) -> Bool = { owner, child in
        guard owner.attachedSheet == nil else { return false }
        owner.beginSheet(child); return true
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, preferences: UserDefaults = .standard) {
        model = ResetWindowModel(repository: repository, access: access, revision: revision, preferences: preferences)
        let size = NSSize(width: 690, height: 405)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Reset – TurtleGit"
        window.contentMinSize = size; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ResetDialog(model: model, chooser: model.chooser).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        window.setContentSize(size); window.center()
        model.close = { [weak self] in guard let self, !self.model.busy, !self.model.showingModifiedFiles, !self.model.showingCommitPicker, !self.model.showingReferencePicker, self.model.progress == nil, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        model.onShowReferencePicker = { [weak self] in self?.showReferencePicker(preferences: preferences) }
        model.onShowCommitPicker = { [weak self] in self?.showCommitPicker(preferences: preferences) }
        model.onShowModified = { [weak self] in self?.showModifiedFiles() }
        model.onProgress = { [weak self] result in
            guard let self, let window = self.window, window.attachedSheet == nil else { result.abandonPresentation(); return }
            let controller = ResetProgressWindowController(model: result)
            controller.onClosed = { [weak self, weak result] in guard let self, let result else { return }; self.progressController = nil; self.model.finish(result) }
            self.progressController = controller; if let child = controller.window { window.beginSheet(child) } else { result.abandonPresentation() }
        }
        model.confirmHard = { [weak self] plan, choose in
            guard let self, let window = self.window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Discard all local changes?"
            alert.informativeText = "Hard reset replaces the index and tracked working files with \(plan.revision). Untracked files that obstruct checkout can also be removed."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Reset")
            alert.beginSheetModal(for: window) { response in choose(response == .alertSecondButtonReturn) }
        }

        DialogGeometry.attach(window, identifier: "ResetDialog", legacyName: "ResetDialog")
    }
    private func showReferencePicker(preferences: UserDefaults) {
        guard !closed, let owner = window, owner.attachedSheet == nil,
              referencePicker == nil, model.beginReferencePicker() else { return }
        let request = UUID(); referencePickerRequest = request
        let picker = ReferenceBrowserWindowController(repository: model.chooser.repository, access: model.access, initial: model.chooser.revision, preferences: preferences) { [weak self] name in
            guard let self, !self.closed, self.referencePickerRequest == request else { return }
            self.model.acceptReferenceSelection(name) { [weak self] in if self?.referencePickerRequest == request { self?.referencePickerRequest = nil } }
        }
        referencePicker = picker; configureReferencePicker(picker.model)
        picker.onClosed = { [weak self, weak picker] in
            guard let self, let picker, self.referencePicker === picker else { return }
            if let child = picker.window, child.sheetParent === self.window { self.window?.endSheet(child) }
            self.referencePicker = nil
        }
        guard let child = picker.window, presentReferencePicker(owner, child) else {
            picker.abandonPresentation(); referencePicker = nil; referencePickerRequest = nil; model.finishReferencePicker(); return
        }
        picker.model.load()
    }
    private func showCommitPicker(preferences: UserDefaults) {
        guard !closed, let owner = window, owner.attachedSheet == nil,
              commitPicker == nil, model.beginCommitPicker() else { return }
        let request = UUID(); commitPickerRequest = request
        let picker = makeCommitPicker(model.chooser.repository, model.access, { [weak self] entry in
            guard let self, self.commitPickerRequest == request else { return }
            if !self.closed, let entry { self.model.chooser.commitRevision = entry.hash }
            self.commitPickerRequest = nil; self.model.finishCommitPicker()
        }, preferences)
        commitPicker = picker
        picker.onClosed = { [weak self, weak picker] in
            guard let self, let picker, self.commitPicker === picker else { return }
            if let child = picker.window, child.sheetParent === self.window { self.window?.endSheet(child) }
            self.commitPicker = nil
        }
        let revision = model.chooser.commitRevision
        picker.model.endRevision = revision.isEmpty ? nil : revision
        guard let child = picker.window, presentCommitPicker(owner, child) else {
            picker.close(); commitPicker = nil; commitPickerRequest = nil; model.finishCommitPicker(); return
        }
        picker.model.reload()
    }
    private func showModifiedFiles() {
        guard !closed, let owner = window, owner.attachedSheet == nil,
              modifiedComparison == nil, model.beginModifiedFiles() else { return }
        let controller = RevisionComparisonWindowController(repository: model.chooser.repository, access: model.access, from: .revision("HEAD"), to: .workingTree)
        modifiedComparison = controller
        configureModifiedComparison(controller.model)
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller, self.modifiedComparison === controller else { return }
            if let child = controller.window, child.sheetParent === self.window { self.window?.endSheet(child) }
            self.modifiedComparison = nil; self.model.finishModifiedFiles()
        }
        guard let child = controller.window, presentModifiedComparison(owner, child) else {
            controller.close(); modifiedComparison = nil; model.finishModifiedFiles(); return
        }
        controller.model.load()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.showingModifiedFiles && !model.showingCommitPicker && !model.showingReferencePicker && !model.busy && !model.confirmingHard && model.progress == nil && !model.chooser.busy && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        closed = true; model.invalidateInitialModeFocus(); model.invalidateReferenceSelection()
        referencePicker?.close(); referencePicker = nil; referencePickerRequest = nil
        commitPicker?.close(); commitPicker = nil; commitPickerRequest = nil; model.finishCommitPicker()
        modifiedComparison?.close(); modifiedComparison = nil
        model.finishModifiedFiles(); onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class ResetWindowModel: ObservableObject {
    let chooser: SwitchWindowModel
    let access: RepositoryAccessLease?
    private let initialRevision: String?
    private let preferences: UserDefaults
    @Published var currentBranch = ""
    @Published var mode = ResetMode.mixed
    @Published var bare = false
    @Published var busy = false
    @Published var error: String?
    @Published private(set) var confirmingHard = false
    @Published private(set) var progress: ResetProgressWindowModel?
    var onProgress: ((ResetProgressWindowModel) -> Void)?
    var onPostAction: ((ResetPostAction) -> Void)?
    var onChanged: (String) -> Void = { _ in }
    func finish(_ result: ResetProgressWindowModel) {
        guard progress === result, !result.busy, !result.confirmingCancellation else { return }
        progress = nil; result.invalidate(); busy = false; error = nil
        if result.success { close(); onReset(result.output) }
    }
    var close: () -> Void = {}
    var confirmHard: (ResetPlan, @escaping (Bool) -> Void) -> Void = { _, choose in choose(false) }
    var onReset: (String) -> Void = { _ in }
    private(set) var initialModeFocusPending = true
    private(set) var initialModeFocusAvailable = true
    var canFocusInitialMode: Bool { initialModeFocusAvailable && initialModeFocusPending && !busy && !chooser.busy && !confirmingHard && progress == nil && !showingModifiedFiles && !showingCommitPicker && !showingReferencePicker && error == nil && chooser.error == nil }
    func acknowledgeInitialModeFocus() { initialModeFocusPending = false }
    func invalidateInitialModeFocus() { initialModeFocusAvailable = false; initialModeFocusPending = false }
    @Published private(set) var showingReferencePicker = false
    private var referenceSelectionAvailable = true
    @Published private(set) var referenceFocusRequest = 0
    private var appliedReferenceFocusRequest = 0
    private var referenceSelectionToken: OperationCancellation?
    var onShowReferencePicker: () -> Void = {}
    var canShowReferencePicker: Bool { referenceSelectionAvailable && !busy && !chooser.busy && chooser.browser == nil && !confirmingHard && progress == nil && !showingModifiedFiles && !showingCommitPicker && !showingReferencePicker && chooser.options.target == .branch }
    func showReferencePicker() { guard canShowReferencePicker else { return }; onShowReferencePicker() }
    func beginReferencePicker() -> Bool { guard canShowReferencePicker else { return false }; showingReferencePicker = true; return true }
    func finishReferencePicker() { referenceSelectionToken?.cancel(); referenceSelectionToken = nil; showingReferencePicker = false }
    func invalidateReferenceSelection() { referenceSelectionAvailable = false; referenceFocusRequest = 0; finishReferencePicker() }
    func focusReference(_ control: NSControl, target: CheckoutTarget) {
        guard referenceSelectionAvailable, referenceFocusRequest > appliedReferenceFocusRequest,
              chooser.options.target == target, !busy, !chooser.busy, !showingReferencePicker, !showingCommitPicker, !showingModifiedFiles,
              !confirmingHard, progress == nil, error == nil, chooser.error == nil,
              control.isEnabled, let window = control.window, window.attachedSheet == nil else { return }
        if window.makeFirstResponder(control) { appliedReferenceFocusRequest = referenceFocusRequest }
    }
    func acceptReferenceSelection(_ name: String?, completion: @escaping () -> Void) {
        guard referenceSelectionAvailable, showingReferencePicker else { return }
        referenceSelectionToken?.cancel(); let token = OperationCancellation(); referenceSelectionToken = token
        let revision = name ?? chooser.revision, commitDraft = chooser.commitRevision
        Task {
            var applied = false
            defer { if referenceSelectionToken === token { referenceSelectionToken = nil; showingReferencePicker = false; if applied { initialModeFocusPending = false; referenceFocusRequest += 1 }; completion() } }
            do {
                try validateAccess()
                let references = try await chooser.repository.checkoutReferences(cancellation: token)
                guard referenceSelectionAvailable, referenceSelectionToken === token, !token.isCancelled else { return }
                chooser.references = references
                if let reference = references.first(where: { GitReferenceName.equal($0.name, revision) }), let target = reference.target {
                    chooser.options.target = target
                    if target == .tag { chooser.tagRevision = revision } else { chooser.branchRevision = revision }
                    chooser.commitRevision = commitDraft
                } else { chooser.options.target = .commit; chooser.commitRevision = revision }
                applied = true
            } catch { if referenceSelectionAvailable, referenceSelectionToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    @Published private(set) var showingCommitPicker = false
    var onShowCommitPicker: () -> Void = {}
    var canShowCommitPicker: Bool { !busy && !chooser.busy && chooser.browser == nil && !confirmingHard && progress == nil && !showingModifiedFiles && !showingCommitPicker && !showingReferencePicker && chooser.options.target == .commit }
    func showCommitPicker() { guard canShowCommitPicker else { return }; onShowCommitPicker() }
    func beginCommitPicker() -> Bool { guard canShowCommitPicker else { return false }; showingCommitPicker = true; return true }
    func finishCommitPicker() { showingCommitPicker = false }
    @Published private(set) var showingModifiedFiles = false
    var onShowModified: () -> Void = {}
    var canShowModifiedFiles: Bool { !bare && !busy && !chooser.busy && chooser.browser == nil && !showingCommitPicker && !showingReferencePicker && !confirmingHard && progress == nil && !showingModifiedFiles }
    func showModifiedFiles() { guard canShowModifiedFiles else { return }; onShowModified() }
    func beginModifiedFiles() -> Bool { guard canShowModifiedFiles else { return false }; showingModifiedFiles = true; return true }
    func finishModifiedFiles() { showingModifiedFiles = false }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String?, preferences: UserDefaults = .standard) {
        chooser = SwitchWindowModel(repository: repository, access: access); self.access = access; initialRevision = revision; self.preferences = preferences
    }
    func load() {
        guard !busy, !showingReferencePicker, !showingCommitPicker, !showingModifiedFiles else { return }; busy = true; chooser.load(revision: initialRevision)
        Task {
            defer { busy = false }
            do { currentBranch = try await chooser.repository.branch(); bare = try await chooser.repository.isBare(); if bare { mode = .soft } }
            catch { self.error = error.localizedDescription }
        }
    }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(chooser.repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func reset() {
        guard !busy, !showingReferencePicker, !showingCommitPicker, !showingModifiedFiles, !confirmingHard, progress == nil, !chooser.busy else { return }; busy = true
        let revision = chooser.revision, mode = mode
        Task {
            do {
                try validateAccess()
                let plan = try await chooser.repository.prepareReset(to: revision, mode: mode)
                busy = false
                if mode == .hard {
                    confirmingHard = true
                    confirmHard(plan) { [weak self] accepted in guard let self, self.confirmingHard else { return }; self.confirmingHard = false; if accepted { self.apply(plan) } }
                } else { apply(plan) }
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
    func apply(_ plan: ResetPlan) {
        guard !busy, !showingReferencePicker, !showingCommitPicker, !showingModifiedFiles, !confirmingHard, progress == nil else { return }; busy = true; error = nil
        do { try validateAccess() } catch { self.error = error.localizedDescription; busy = false; return }
        if let onProgress {
            let result = ResetProgressWindowModel(repository: chooser.repository, plan: plan, preferences: preferences)
            result.close = { [weak self, weak result] in guard let result else { return }; self?.finish(result) }
            result.onChanged = onChanged
            result.onPostAction = { [weak self] action in self?.onPostAction?(action) }
            progress = result; onProgress(result); result.start()
        } else {
            Task {
                defer { busy = false }
                do { let output = try await chooser.repository.reset(plan); onChanged(output); onReset(output); close() }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
private struct ResetDialog: View {
    @ObservedObject var model: ResetWindowModel
    @ObservedObject var chooser: SwitchWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Current branch:").frame(width: 110, alignment: .leading); Text(model.currentBranch.isEmpty ? "detached HEAD" : model.currentBranch).textSelection(.enabled); Spacer() }
            GroupBox("Reset active branch") {
                VStack(spacing: 6) {
                    HStack { SwitchRadio(title: "Branch", target: .branch, selection: $chooser.options.target).frame(width: 100)
                        ReferencePopup(references: chooser.branches, selection: $chooser.branchRevision, accessibilityLabel: "Reset branch revision", focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .branch) }).disabled(chooser.options.target != .branch)
                        Button("…") { model.showReferencePicker() }.accessibilityLabel("Browse references").disabled(chooser.options.target != .branch)
                    }.frame(height: 26)
                    HStack { SwitchRadio(title: "Tag", target: .tag, selection: $chooser.options.target).frame(width: 100)
                        ReferencePopup(references: chooser.tags, selection: $chooser.tagRevision, accessibilityLabel: "Reset tag revision", focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .tag) }).disabled(chooser.options.target != .tag); Color.clear.frame(width: 29)
                    }.frame(height: 26)
                    HStack { SwitchRadio(title: "Commit", target: .commit, selection: $chooser.options.target).frame(width: 100)
                        ResetRevisionField(text: $chooser.commitRevision, focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .commit) }).disabled(chooser.options.target != .commit)
                        Button("…") { model.showCommitPicker() }.accessibilityLabel("Choose commit").disabled(chooser.options.target != .commit)
                    }.frame(height: 26)
                }.padding(8)
            }
            GroupBox("Reset Type") {
                VStack(alignment: .leading, spacing: 7) {
                    ResetRadio(title: "Soft: Leave working tree and index untouched", value: .soft, selection: $model.mode, model: model).frame(height: 22)
                    ResetRadio(title: "Mixed: Leave working tree untouched, reset index", value: .mixed, selection: $model.mode, model: model).frame(height: 22).disabled(model.bare)
                    ResetRadio(title: "Hard: Reset working tree and index (discard all local changes)", value: .hard, selection: $model.mode, model: model).frame(height: 22).disabled(model.bare)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { model.showModifiedFiles() } label: { CommandLabel(title: "Show modified files in working tree", icon: .compare).frame(maxWidth: .infinity) }.disabled(model.bare)
            HStack { if model.busy || chooser.busy { ProgressView().controlSize(.small) }; Spacer()
                Button("OK") { model.reset() }.keyboardShortcut(.defaultAction).disabled(chooser.revision.isEmpty)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-reset.html")!) } label: { CommandLabel(title: "Help", icon: .help) }
            }
        }.padding(12).disabled(model.busy || model.showingReferencePicker || model.showingCommitPicker || model.showingModifiedFiles || model.confirmingHard || chooser.busy).onAppear { model.load() }
        .sheet(item: $chooser.browser) { target in SwitchReferenceChooser(model: chooser, target: target) }
        .alert("Reset failed", isPresented: Binding(get: { model.error != nil || chooser.error != nil }, set: { if !$0 { model.error = nil; chooser.error = nil } })) { Button("OK") { model.error = nil; chooser.error = nil } } message: { Text(model.error ?? chooser.error ?? "") }
    }
}
private struct ResetRevisionField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let onFocus: (NSTextField) -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(); field.isBezeled = true; field.bezelStyle = .squareBezel; field.drawsBackground = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize); field.placeholderString = "Commit"; field.setAccessibilityLabel("Reset commit revision")
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
private struct ResetRadio: NSViewRepresentable {
    let title: String
    let value: ResetMode
    @Binding var selection: ResetMode
    let model: ResetWindowModel
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Button {
        let button = Button(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.setAccessibilityLabel(title)
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        button.title = title; button.state = selection == value ? .on : .off; button.isEnabled = enabled
        context.coordinator.select = { selection = value }
        button.focus = { [weak button, weak model] in
            guard let button, let model, model.mode == value, model.canFocusInitialMode,
                  button.isEnabled, let owner = button.window, owner.attachedSheet == nil else { return }
            if owner.makeFirstResponder(button) { model.acknowledgeInitialModeFocus() }
        }
        button.scheduleFocus()
    }
    static func dismantleNSView(_ button: Button, coordinator: Coordinator) { button.focus = nil; coordinator.select = {} }
    final class Coordinator: NSObject { var select: () -> Void = {}; @objc func clicked(_ sender: NSButton) { select() } }
    final class Button: NSButton {
        var focus: (() -> Void)?
        private var focusQueued = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleFocus() }
        func scheduleFocus() {
            guard let owner = window, !focusQueued else { return }; focusQueued = true
            DispatchQueue.main.async { [weak self, weak owner] in
                guard let self else { return }; self.focusQueued = false
                guard let owner, self.window === owner else { return }; self.focus?()
            }
        }
    }
}

enum ResetPostAction: String, Hashable {
    case retry, submoduleUpdate, bisectGood, bisectBad, bisectSkip, bisectReset, clean
    var title: String { switch self { case .retry: return "Retry"; case .submoduleUpdate: return "Submodule Update…"; case .bisectGood: return "Bisect good"; case .bisectBad: return "Bisect bad"; case .bisectSkip: return "Bisect skip"; case .bisectReset: return "Bisect reset"; case .clean: return "Clean up…" } }
    var icon: MenuIcon { switch self { case .retry: return .refresh; case .submoduleUpdate: return .fetch; case .bisectGood: return .bisectGood; case .bisectBad: return .bisectBad; case .bisectSkip: return .bisect; case .bisectReset: return .bisectReset; case .clean: return .clean } }
}
@MainActor final class ResetProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let plan: ResetPlan
    private let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private var cancellation = OperationCancellation()
    private var started = false, invalidated = false, dispatched = false, abandoned = false
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var output = ""
    @Published private(set) var postActions: [ResetPostAction] = []
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onPostAction: ((ResetPostAction) -> Void)?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { busy && !cancelling && !confirmingCancellation }
    init(repository: GitRepository, plan: ResetPlan, preferences: UserDefaults = .standard) { self.repository = repository; self.plan = plan; self.preferences = preferences; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences) }
    func invalidate() { invalidated = true }
    func abandonPresentation() { abandoned = true; cancellation.cancel() }
    func start() { Task { await run() } }
    func run() async { guard !started, !invalidated else { return }; started = true; await execute() }
    private func execute() async {
        do {
            output = try await repository.reset(plan, cancellation: cancellation); success = true
            if plan.mode == .hard, FileManager.default.fileExists(atPath: repository.root.appendingPathComponent(".gitmodules").path) { postActions.append(.submoduleUpdate) }
            if (try? await repository.bisectState().active) == true { postActions += [.bisectGood, .bisectBad, .bisectSkip, .bisectReset] }
            if plan.mode == .hard { postActions.append(.clean) }
        } catch { output = error.localizedDescription; cancelled = cancellation.isCancelled; postActions = [.retry] }
        busy = false; cancelling = false; onChanged(output)
        finishAutomaticClose()
    }
    private func finishAutomaticClose() { if !busy, !confirmingCancellation, !invalidated, abandoned || autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() } }
    func cancel() {
        guard canCancel, !invalidated else { return }
        let token = cancellation
        if preferences.bool(forKey:"ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, self.cancellation === token else { return }; self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; token.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: ResetPostAction) {
        guard !busy, !invalidated, !confirmingCancellation, !dispatched, postActions.contains(action) else { return }
        if action == .retry {
            ProgressActionLog.nextAttempt(self);
            busy = true; success = false; cancelled = false; output = ""; postActions = []; cancellation = OperationCancellation()
            Task { await execute() }; return
        }
        guard let onPostAction else { return }; dispatched = true; close(); onPostAction(action)
    }
}
@MainActor final class ResetProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: ResetProgressWindowModel
    var onClosed: () -> Void = {}
    init(model: ResetProgressWindowModel) {
        self.model = model
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:430),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Reset – \(model.repository.root.lastPathComponent) – TurtleGit"; window.minSize = NSSize(width:650,height:320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:ResetProgressDialog(model:model)); super.init(window:window); window.delegate = self
        model.close = { [weak self] in guard let self, !self.model.busy, !self.model.confirmingCancellation, self.window?.attachedSheet == nil else { return }; if let window = self.window { window.sheetParent?.endSheet(window); window.close() } }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle:"Yes"); alert.addButton(withTitle:"No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for:window) { choose($0 == .alertFirstButtonReturn) }
        }

        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { if model.busy { model.cancel(); return false }; guard !model.confirmingCancellation, sender.attachedSheet == nil else { return false }; sender.sheetParent?.endSheet(sender); return true }
    func windowWillClose(_ notification:Notification) { model.saveActionLog(); model.invalidate(); onClosed() }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
}
struct ResetProgressDialog: View {
    @ObservedObject var model: ResetProgressWindowModel
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            ScrollView { Text(model.output).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxWidth:.infinity,maxHeight:.infinity).padding(8).background(Color(nsColor:.textBackgroundColor))
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.busy ? model.cancelling ? "Cancelling…" : "Resetting…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Reset failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red); Spacer() }
            HStack { if let first = model.postActions.first { Button { model.perform(first) } label: { CommandLabel(title:first.title,icon:first.icon) }; Menu { ForEach(model.postActions,id:\.self) { action in Button { model.perform(action) } label: { CommandLabel(title:action.title,icon:action.icon) } } } label: { Image(systemName:"chevron.down").accessibilityLabel("Reset post-actions") }.menuStyle(.borderlessButton).fixedSize() }; Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.confirmingCancellation)
        }.padding(12)
    }
}
