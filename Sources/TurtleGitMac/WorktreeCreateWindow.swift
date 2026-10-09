import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class WorktreeCreateWindowController: NSWindowController, NSWindowDelegate {
    let model: WorktreeCreateWindowModel
    var onClosed: () -> Void = {}
    private var pickers: VersionPickerCoordinator!
    var referencePicker: ReferenceBrowserWindowController? { pickers.referencePicker }
    var commitPicker: LogWindowController? { pickers.commitPicker }
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void { get { pickers.configureReferencePicker } set { pickers.configureReferencePicker = newValue } }
    var presentPicker: (NSWindow, NSWindow) -> Bool { get { pickers.presentPicker } set { pickers.presentPicker = newValue } }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void, UserDefaults) -> LogWindowController { get { pickers.makeCommitPicker } set { pickers.makeCommitPicker = newValue } }

    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = WorktreeCreateWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – New Worktree – TurtleGit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WorktreeCreateDialog(model: model, chooser: model.chooser).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        pickers = VersionPickerCoordinator(window: window, model: model.chooser, access: access, preferences: preferences, allowed: { [weak model] in model?.canPickBase == true })
        pickers.onSelection = { [weak model] in if model?.useHead == false { model?.changedBase() } }
        window.setContentSize(NSSize(width: 660, height: 420)); window.contentMinSize = NSSize(width: 640, height: 420)
        window.center()
        model.close = { [weak self] in self?.window?.performClose(nil) }
        model.chooseDirectory = { [weak self] in self?.chooseDirectory() }
        model.load()

        DialogGeometry.attach(window, identifier: "CreateWorktreeDialog", legacyName: "CreateWorktreeDialog")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && !model.chooser.busy && model.chooser.pickerTarget == nil && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); pickers.invalidate(); onClosed() }
    private func chooseDirectory() {
        guard let window, window.attachedSheet == nil, !model.busy, model.chooser.pickerTarget == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.title = "Worktree Directory"; panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: model.directory).deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url, let self else { return }
            let lease = RepositoryAccessLease(url: folder)
            guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { self.model.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
            self.model.destinationAccess = lease; self.model.directory = folder.path
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class WorktreeCreateWindowModel: ObservableObject {
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
    @Published var error: String?
    @Published var hasSubmodules = false
    @Published var cancelled = false
    private var invalidated = false
    var canPickBase: Bool { !invalidated && !busy && !progress && !useHead }
    func invalidate() { invalidated = true; chooser.invalidate() }
    private var cancellation: OperationCancellation?
    private var createdPath: URL?
    private var shortHashLength = 7
    var close: () -> Void = {}
    var chooseDirectory: () -> Void = {}
    var onCreated: (String) -> Void = { _ in }
    var onSubmodules: (URL, RepositoryAccessLease?) -> Void = { _, _ in }
    var automaticDetach: Bool { !createBranch && !useHead && (chooser.options.target != .branch || chooser.remote) }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.access = access; chooser = SwitchWindowModel(repository: repository, access: access, preferences: preferences)
        let root = repository.root.path
        directory = root.hasSuffix(".git") ? String(root.dropLast(4)) : root + "-worktree"
    }
    func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(chooser.repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load() {
        guard !invalidated, !busy, !progress, chooser.pickerTarget == nil else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try checkAccess()
                let branch = try await chooser.repository.branch()
                let length = (try? await chooser.repository.run(["rev-parse", "--short", "HEAD"]).text.trimmingCharacters(in: .newlines).count) ?? 7
                guard !invalidated else { return }; currentBranch = branch; shortHashLength = length
                chooser.load(); changedBase()
            } catch { if !invalidated { self.error = error.localizedDescription } }
        }
    }
    func changedBase() {
        if useHead {
            branchName = URL(fileURLWithPath: directory).lastPathComponent; createBranch = false
        } else if chooser.options.target == .branch, let reference = chooser.references.first(where: { GitReferenceName.equal($0.name, chooser.branchRevision) }) {
            branchName = reference.suggestedBranch; createBranch = reference.remote
        } else {
            let revision = chooser.options.target == .commit ? String(chooser.commitRevision.prefix(shortHashLength)) : chooser.tags.first(where: { GitReferenceName.equal($0.name, chooser.tagRevision) })?.label ?? chooser.revision
            branchName = "Branch_" + revision; createBranch = chooser.options.target != .branch
        }
        changedBranch()
    }
    func changedBranch() { detach = automaticDetach }
    func changedDetach() { if detach { createBranch = false } }
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
        let token = OperationCancellation(); cancellation = token
        busy = true; progress = true; success = false; cancelled = false; output = "Creating worktree…"; error = nil
        Task {
            defer { busy = false; cancellation = nil }
            do {
                output = try await chooser.repository.createWorktree(at: path, options: options, cancellation: token)
                success = true; createdPath = path
                hasSubmodules = checkout && FileManager.default.fileExists(atPath: path.appendingPathComponent(".gitmodules").path)
                onCreated(output)
            } catch let failure as GitCommandCancellationFailure { cancelled = true; output = failure.result.text }
            catch OperationCancellationFailure.cancelled { cancelled = true; output = "Cancelled before worktree creation." }
            catch { output = error.localizedDescription }
        }
    }
    func cancel() { cancellation?.cancel() }
    func updateSubmodules() {
        guard success, !busy, let createdPath else { return }
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
                    TextField("Worktree directory", text: $model.directory)
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
                        VersionRevisionField(text: $chooser.commitRevision, accessibilityLabel: "Base commit revision", focusRequest: chooser.referenceFocusRequest, onFocus: { chooser.focusReference($0, target: .commit) }).disabled(model.useHead || chooser.options.target != .commit)
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
                    Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-worktrees.html#tgit-dug-worktree-create")!) }
                }
            }
        }.padding(16)
        .disabled(!model.progress && (model.busy || chooser.busy || chooser.pickerTarget != nil))
        .onChange(of: chooser.branchRevision) { _ in if !model.useHead && chooser.options.target == .branch { model.changedBase() } }
        .onChange(of: chooser.tagRevision) { _ in if !model.useHead && chooser.options.target == .tag { model.changedBase() } }
        .onChange(of: chooser.commitRevision) { _ in if !model.useHead && chooser.options.target == .commit { model.changedBase() } }
        .alert("New Worktree", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(item: $chooser.browser) { target in SwitchReferenceChooser(model: chooser, target: target) }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.busy ? "Creating worktree…" : model.success ? "Worktree created" : model.cancelled ? "Cancelled" : "Worktree creation failed").font(.headline)
            ScrollView { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: .infinity)
            HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer()
                if model.success && model.hasSubmodules { Button { model.updateSubmodules() } label: { CommandLabel(title: "Submodule Update…", icon: .fetch) } }
                if model.busy { Button("Cancel") { model.cancel() } }
                else {
                    if !model.success { Button("Back") { model.progress = false } }
                    Button("Close") { model.close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
