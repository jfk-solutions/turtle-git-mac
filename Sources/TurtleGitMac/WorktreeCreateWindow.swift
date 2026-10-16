import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class WorktreeCreateWindowController: NSWindowController, NSWindowDelegate {
    let model: WorktreeCreateWindowModel
    var onClosed: () -> Void = {}
    private var directoryPanel:NSOpenPanel?
    private var pickers: VersionPickerCoordinator!
    var referencePicker: ReferenceBrowserWindowController? { pickers.referencePicker }
    var commitPicker: LogWindowController? { pickers.commitPicker }
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void { get { pickers.configureReferencePicker } set { pickers.configureReferencePicker = newValue } }
    var configureCommitPicker: (LogWindowModel) -> Void { get { pickers.configureCommitPicker } set { pickers.configureCommitPicker = newValue } }
    var presentPicker: (NSWindow, NSWindow) -> Bool { get { pickers.presentPicker } set { pickers.presentPicker = newValue } }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void, UserDefaults, String?) -> LogWindowController { get { pickers.makeCommitPicker } set { pickers.makeCommitPicker = newValue } }

    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = WorktreeCreateWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "New Worktree", preferences: preferences)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WorktreeCreateDialog(model: model, chooser: model.chooser).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        pickers = VersionPickerCoordinator(window: window, model: model.chooser, access: access, preferences: preferences, allowed: { [weak model] in model?.canPickBase == true })
        pickers.contextualDraft = { [weak model] in guard let model else { return [] }; return [String(model.useHead), model.directory, model.branchName, String(model.createBranch), String(model.detach), String(model.force), String(model.checkout)].map { GitReferenceName($0) } }
        pickers.onSelection = { [weak model] in if model?.useHead == false { model?.changedBase() } }
        window.setContentSize(NSSize(width: 660, height: 420)); window.contentMinSize = NSSize(width: 640, height: 420)
        window.center()
        model.close = { [weak self] in self?.window?.performClose(nil) }
        model.chooseDirectory = { [weak self] in self?.chooseDirectory() }
        model.confirmCancellation = { [weak window] reply in
            guard let window, window.attachedSheet == nil else { reply(false); return }
            let alert = NSAlert(); alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            alert.beginSheetModal(for: window) { reply($0 == .alertFirstButtonReturn) }
        }
        model.load()

        DialogGeometry.attach(window, identifier: "CreateWorktreeDialog", legacyName: "CreateWorktreeDialog")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy && model.progress { model.cancel(); return false }
        return !model.busy && !model.confirmingCancellation && !model.chooser.busy && model.chooser.pickerTarget == nil && sender.attachedSheet == nil
    }
    func windowWillClose(_ notification: Notification) {
        model.saveActionLog(); model.invalidate(); pickers.invalidate()
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil) }
        if let panel=directoryPanel { panel.sheetParent?.endSheet(panel,returnCode:.cancel); panel.orderOut(nil) }; directoryPanel=nil
        onClosed()
    }
    private func chooseDirectory() {
        guard model.active, !model.chooser.busy, let window, window.attachedSheet == nil, !model.busy, model.chooser.pickerTarget == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.title = "Worktree Directory"; panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: model.directory).deletingLastPathComponent()
        directoryPanel=panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; self.directoryPanel=nil
            guard self.model.active, response == .OK, let folder = panel.url else { return }
            let lease = RepositoryAccessLease(url: folder)
            guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { self.model.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
            self.model.destinationAccess = lease; self.model.directory = folder.path
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class WorktreeCreateWindowModel: ObservableObject {
    let progressPresentation: GitCommandPresentation
    static var activeOperations=0
    var active:Bool { !invalidated }
    let chooser: SwitchWindowModel
    let access: RepositoryAccessLease?
    var destinationAccess: RepositoryAccessLease?
    @Published var directory: String
    @Published var currentBranch = ""
    @Published var useHead = true
    @Published var createBranch = false
    @Published var branchName = ""
    @Published var checkout = true
    @Published var force = false
    @Published var detach = false
    @Published var busy = false
    @Published var progress = false
    @Published var success = false
    @Published var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { active && busy && progress && !cancelling && !confirmingCancellation }
    @Published var error: String?
    @Published var hasSubmodules = false
    @Published var cancelled = false
    private var invalidated = false
    var canPickBase: Bool { !invalidated && !busy && !progress && !useHead }
    func invalidate() { invalidated = true; cancellation?.cancel(); confirmingCancellation = false; chooser.invalidate() }
    private var cancellation: OperationCancellation?
    private var createdPath: URL?
    private var shortHashLength = 7
    var close: () -> Void = {}
    var chooseDirectory: () -> Void = {}
    var onCreated: (String) -> Void = { _ in }
    var onSubmodules: (URL, RepositoryAccessLease?) -> Void = { _, _ in }
    var automaticDetach: Bool { !createBranch && !useHead && (chooser.options.target != .branch || chooser.remote) }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.preferences = preferences; progressPresentation = GitCommandPresentation(defaults: preferences); autoClosePolicy = GitProgressAutoClose(preferences: preferences); self.access = access; chooser = SwitchWindowModel(repository: repository, access: access, preferences: preferences)
        let root = repository.root.path
        directory = root.hasSuffix(".git") ? String(root.dropLast(4)) : root + "-worktree"
    }
    func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(chooser.repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load() {
        guard !invalidated, !busy, !progress, chooser.pickerTarget == nil else { return }
        let token=OperationCancellation(); cancellation=token
        busy = true; Self.activeOperations += 1
        Task {
            defer { busy = false; cancellation=nil; Self.activeOperations -= 1; withExtendedLifetime(access) {} }
            do {
                try checkAccess()
                let branch = try await chooser.repository.branch(cancellation:token)
                let length = (try? await chooser.repository.run(["rev-parse", "--short", "HEAD"],cancellation:token).text.trimmingCharacters(in: .newlines).count) ?? 7
                if token.isCancelled { throw OperationCancellationFailure.cancelled }; guard !invalidated else { return }; currentBranch = branch; shortHashLength = length
                chooser.load(); applyBase()
            } catch { if !invalidated, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private var suggestedBaseDraft: [GitReferenceName]?
    func changedBase() { guard active, !busy, !progress, chooser.pickerTarget == nil else { return }; applyBase() }
    private func applyBase() {
        let reference = chooser.references.first(where: { GitReferenceName.equal($0.name, chooser.branchRevision) })
        let values: [String]
        if useHead { values = ["HEAD", directory] }
        else if chooser.options.target == .branch { values = ["branch", chooser.revision, reference?.suggestedBranch ?? "", String(reference?.remote ?? false)] }
        else if chooser.options.target == .tag { values = ["tag", chooser.revision, chooser.tags.first(where: { GitReferenceName.equal($0.name, chooser.tagRevision) })?.label ?? chooser.revision] }
        else { values = ["commit", chooser.revision, String(shortHashLength)] }
        let draft = values.map { GitReferenceName($0) }
        // Deferred SwiftUI notifications must not rewrite a captured picker
        // context or reset custom options for an unchanged base after Cancel.
        guard suggestedBaseDraft != draft else { return }
        suggestedBaseDraft = draft
        if useHead {
            branchName = URL(fileURLWithPath: directory).lastPathComponent; createBranch = false
        } else if chooser.options.target == .branch, let reference = chooser.references.first(where: { GitReferenceName.equal($0.name, chooser.branchRevision) }) {
            branchName = reference.suggestedBranch; createBranch = reference.remote
        } else {
            let revision = chooser.options.target == .commit ? String(chooser.commitRevision.prefix(shortHashLength)) : chooser.tags.first(where: { GitReferenceName.equal($0.name, chooser.tagRevision) })?.label ?? chooser.revision
            branchName = "Branch_" + revision; createBranch = chooser.options.target != .branch
        }
        detach=automaticDetach
    }
    func changedBranch() { guard active, !busy, !progress else { return }; detach = automaticDetach }
    func changedDetach() { guard active, !busy, !progress else { return }; if detach { createBranch = false } }
    func create() {
        guard !invalidated, !busy, !chooser.busy, !progress, chooser.pickerTarget == nil else { return }
        guard !directory.isEmpty, directory.hasPrefix("/"), !directory.contains("\0") else { error = "Enter an absolute worktree directory."; return }
        let path = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        do {
            try checkAccess()
            if GitRuntime.isAppStoreBuild && !(access?.contains(path) == true || destinationAccess?.hasSecurityScope == true && destinationAccess?.contains(path) == true) {
                error = "Choose the worktree directory using Browse to grant access. You can create an empty folder in the picker."; return
            }
        } catch { self.error = error.localizedDescription; return }
        var options = WorktreeCreationOptions()
        options.checkout = checkout; options.force = force; options.detach = detach
        options.newBranch = createBranch ? branchName : nil; options.revision = useHead ? "HEAD" : chooser.revision
        // CChooseVersion uses short branch/tag labels unless both share a name.
        // Passing refs/heads/foo directly to worktree add would detach HEAD.
        if !useHead, chooser.options.target != .commit,
           let reference = chooser.references.first(where: { $0.name == chooser.revision }) {
            let ambiguous = chooser.branches.contains(where: { $0.label == reference.label }) && chooser.tags.contains(where: { $0.label == reference.label })
            if !ambiguous { options.revision = reference.label }
        }
        ProgressActionLog.nextAttempt(self, savePrevious: progress)
        let token = OperationCancellation(); cancellation = token
        currentWork = ""; percentage = nil; cancelling = false; confirmingCancellation = false
        busy = true; progress = true; success = false; cancelled = false; output = ""; error = nil
        Self.activeOperations += 1
        let destinationLease = destinationAccess
        Task {
            defer { busy = false; cancellation = nil; currentWork = ""; percentage = nil; cancelling = false; Self.activeOperations -= 1; LocalGitCommandProgress.end(); withExtendedLifetime(access) {}; withExtendedLifetime(destinationLease) {}; finishAutomaticClose() }
            LocalGitCommandProgress.begin()
            do {
                let repository = chooser.repository
                let text = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in
                    guard let self, self.active, self.cancellation === token else { return }
                    self.output = state.output; self.currentWork = state.currentWork; self.percentage = state.percentage
                }, resultText: { $0 }, operation: { emit in try await repository.createWorktree(at: path, options: options, cancellation: token, onOutput: emit) })
                guard active else { return }
                success = true; createdPath = path
                hasSubmodules = checkout && FileManager.default.fileExists(atPath: path.appendingPathComponent(".gitmodules").path)
                onCreated(text)
            } catch let failure as GitCommandCancellationFailure { guard active else { return }; cancelled = true; output = LocalGitCommandProgress.failure(failure, existing: output, preferences: preferences) }
            catch OperationCancellationFailure.cancelled { guard active else { return }; cancelled = true; output = "Cancelled before worktree creation." }
            catch { if active { output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences) } }
        }
    }
    private func finishAutomaticClose() {
        guard active, !busy, !confirmingCancellation, success else { return }
        if autoClosePolicy.shouldClose(success: true, postActionCount: hasSubmodules ? 1 : 0) { saveActionLog(); close() }
    }
    func cancel() {
        guard canCancel, let token = cancellation else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true; var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, self.active else { return }; answered = true; self.confirmingCancellation = false
                if self.busy, self.cancellation === token, accepted { self.cancelling = true; token.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; token.cancel() }
    }
    func returnToOptions() { guard active, !busy, !confirmingCancellation else { return }; saveActionLog(); progress = false }
    func updateSubmodules() {
        guard active, success, !busy, !confirmingCancellation, let createdPath else { return }
        let lease = destinationAccess?.contains(createdPath) == true ? destinationAccess : access
        onSubmodules(createdPath, lease); close()
    }
}

private struct WorktreeCreateDialog: View {
    @ObservedObject var model: WorktreeCreateWindowModel
    @ObservedObject var chooser: SwitchWindowModel
    func radio(_ title: String, target: CheckoutTarget) -> some View {
        BaseRadio(title: title, selected: !model.useHead && chooser.options.target == target) {
            model.useHead = false; chooser.options.target = target; model.changedBase()
        }.frame(width: 100)
    }
    var body: some View {
        VStack(spacing: 12) {
            if model.progress { progress }
            else {
                GroupBox("Location") { HStack {
                    Text("Directory:").frame(width: 100, alignment: .leading)
                    PathEntryField(text: $model.directory, label: "Worktree directory", permissions: [model.access, model.destinationAccess].compactMap { $0 }, preferences: model.preferences, mayEdit: { !model.busy && !chooser.busy && chooser.pickerTarget == nil }).frame(height: 22)
                    Button("Browse…") { model.chooseDirectory() }
                }.padding(8) }
                GroupBox("Base On") { VStack(spacing: 6) {
                    BaseRadio(title: "HEAD (\(model.currentBranch.isEmpty ? "detached" : model.currentBranch))", selected: model.useHead) { model.useHead = true; model.changedBase() }.frame(height: 22)
                    HStack { radio("Branch", target: .branch)
                        ReferencePopup(references: chooser.branches, selection: $chooser.branchRevision, accessibilityLabel: "Base branch revision", focusRequest: chooser.referenceFocusRequest, onFocus: { chooser.focusReference($0, target: .branch) }).disabled(model.useHead || chooser.options.target != .branch)
                        Button("…") { chooser.browse(.branch) }.accessibilityLabel("Browse references").disabled(model.useHead || chooser.options.target != .branch)
                    }.frame(height: 26)
                    HStack { radio("Tag", target: .tag)
                        ReferencePopup(references: chooser.tags, selection: $chooser.tagRevision, accessibilityLabel: "Base tag revision", focusRequest: chooser.referenceFocusRequest, onFocus: { chooser.focusReference($0, target: .tag) }).disabled(model.useHead || chooser.options.target != .tag)
                        Color.clear.frame(width: 29)
                    }.frame(height: 26)
                    HStack { radio("Commit", target: .commit)
                        VersionRevisionField(text: $chooser.commitRevision, choices: chooser.commitChoices, accessibilityLabel: "Base commit revision", focusRequest: chooser.referenceFocusRequest, onFocus: { chooser.focusReference($0, target: .commit) }).disabled(model.useHead || chooser.options.target != .commit)
                        Button("…") { chooser.browse(.commit) }.accessibilityLabel("Choose commit").disabled(model.useHead || chooser.options.target != .commit)
                    }.frame(height: 26)
                }.padding(8) }
                GroupBox("Options") { VStack(spacing: 8) {
                    HStack { Toggle("Create New Branch", isOn: Binding(get: { model.createBranch }, set: { model.createBranch = $0; model.changedBranch() })).frame(width: 180, alignment: .leading)
                        TextField("New branch name", text: $model.branchName).disabled(!model.createBranch)
                    }
                    HStack { Toggle("Checkout", isOn: $model.checkout); Toggle("Force", isOn: $model.force).help("Allow checking out a branch that is already checked out in another worktree.")
                        Toggle("Detach", isOn: Binding(get: { model.detach }, set: { model.detach = $0; model.changedDetach() })).disabled(model.automaticDetach); Spacer()
                    }
                }.padding(8) }
                HStack { if model.busy || chooser.busy || chooser.pickerTarget != nil { ProgressView().controlSize(.small) }; Spacer()
                    Button("OK") { model.create() }.keyboardShortcut(.defaultAction).disabled(model.directory.isEmpty || model.createBranch && model.branchName.isEmpty)
                    Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                    Button("Help") { TurtleGitHelp.show(.worktrees) }
                }
            }
        }.padding(16)
        .disabled(!model.progress && (model.busy || chooser.busy || chooser.pickerTarget != nil))
        .onChange(of: chooser.pickerTarget) { value in if value == nil { model.changedBase() } }
        .onChange(of: chooser.branchRevision) { _ in if !model.useHead && chooser.options.target == .branch { model.changedBase() } }
        .onChange(of: chooser.tagRevision) { _ in if !model.useHead && chooser.options.target == .tag { model.changedBase() } }
        .onChange(of: chooser.commitRevision) { _ in if !model.useHead && chooser.options.target == .commit { model.changedBase() } }
        .alert("New Worktree", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(item: $chooser.browser) { target in SwitchReferenceChooser(model: chooser, target: target) }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.busy ? "Creating worktree…" : model.success ? "Worktree created" : model.cancelled ? "Cancelled" : "Worktree creation failed").font(.headline)
            SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: model.success, preferences: model.preferences).frame(maxHeight: .infinity)
            HStack { if model.busy { LocalGitProgressIndicator(percentage: model.percentage, animate: model.progressPresentation.animateActivity); Text(model.cancelling ? "Cancelling…" : model.currentWork).font(.caption) }; Spacer()
                if model.success && model.hasSubmodules { Button { model.updateSubmodules() } label: { CommandLabel(title: "Submodule Update…", icon: .fetch) } }
                if model.busy { Button("Cancel") { model.cancel() }.disabled(!model.canCancel) }
                else {
                    if !model.success { Button("Back") { model.returnToOptions() }.disabled(model.confirmingCancellation) }
                    Button("Close") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.confirmingCancellation)
                }
            }
        }
    }
}
