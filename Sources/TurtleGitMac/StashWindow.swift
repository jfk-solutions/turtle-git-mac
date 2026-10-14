import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class StashWindowController: NSWindowController, NSWindowDelegate {
    let model: StashWindowModel
    var onClosed: () -> Void = {}
    private var progressController: StashSaveProgressWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = StashWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Stash – TurtleGit"
        window.minSize = NSSize(width: 500, height: 272); window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 272)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StashDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 560, height: 240)); window.center()
        model.close = { [weak self] in
            guard let self, !self.model.busy, !self.model.confirmingUntracked, self.window?.attachedSheet == nil else { return }
            self.window?.close()
        }
        model.onProgress = { [weak self] progress in
            guard let self, let window = self.window, window.attachedSheet == nil else { progress.cancel(); return }
            let controller = StashSaveProgressWindowController(model: progress)
            controller.window?.alphaValue = window.alphaValue
            controller.onClosed = { [weak self, weak progress] in
                guard let self, let progress else { return }
                self.progressController = nil; self.model.finish(progress)
            }
            self.progressController = controller
            if let child = controller.window { window.beginSheet(child) }
        }
        model.confirmUntracked = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Include untracked files?"
            alert.informativeText = "Untracked files will be saved in the stash and removed from the working tree. Restore them by applying or popping the stash."
            alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Continue")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not show this warning again (if Continue is selected)"
            alert.beginSheetModal(for: window) { response in
                guard response == .alertSecondButtonReturn else { choose(false); return }
                if alert.suppressionButton?.state == .on { preferences.set(true, forKey: "Stash.NoIncludeUntrackedWarning") }
                choose(true)
            }
        }

        DialogGeometry.attach(window, identifier: "StashWindowController")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && !model.confirmingUntracked && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        model.invalidate()
        if let window, let child = window.attachedSheet { window.endSheet(child, returnCode: .abort); child.close() }
        progressController?.close(); progressController = nil
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class StashWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    @Published var options = StashSaveOptions()
    @Published var busy = false
    @Published var error: String?
    @Published private(set) var confirmingUntracked = false
    @Published private(set) var progress: StashSaveProgressWindowModel?
    var followUp = StashSaveFollowUp()
    var onProgress: ((StashSaveProgressWindowModel) -> Void)?
    var onPostAction: ((StashSavePostAction, StashSaveFollowUp) -> Void)?
    private var invalidated = false
    var confirmUntracked: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    var close: () -> Void = {}
    var onSaved: (StashSaveResult) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; self.preferences = preferences }
    func save() {
        guard !invalidated, !busy, !confirmingUntracked else { return }
        let snapshot = options
        if snapshot.includeUntracked && !preferences.bool(forKey: "Stash.NoIncludeUntrackedWarning") {
            confirmingUntracked = true
            confirmUntracked { [weak self] accepted in
                guard let self, !self.invalidated, self.confirmingUntracked else { return }
                self.confirmingUntracked = false
                if accepted { self.perform(snapshot) }
            }
        } else { perform(snapshot) }
    }
    func invalidate() { invalidated = true; progress?.invalidate(); progress = nil; busy = false; confirmingUntracked = false }
    func finish(_ progress: StashSaveProgressWindowModel) {
        guard !invalidated, self.progress === progress, !progress.busy else { return }
        self.progress = nil; busy = false; close()
    }
    private func perform(_ snapshot: StashSaveOptions) {
        guard !invalidated, !busy else { return }; busy = true
        let progress = StashSaveProgressWindowModel(repository: repository, access: access, options: snapshot, followUp: followUp, preferences: preferences)
        self.progress = progress
        progress.onFinished = { [weak self] result, details in
            guard let self, !self.invalidated else { return }
            if let result { self.onSaved(result) } else { self.onFailed(details) }
        }
        progress.onPostAction = onPostAction
        progress.close = { [weak self, weak progress] in if let progress { self?.finish(progress) } }
        onProgress?(progress); progress.start()
    }
}
private struct StashDialog: View {
    @ObservedObject var model: StashWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Stash Message") { TextField("Optional stash message", text: $model.options.message).textFieldStyle(.roundedBorder).padding(8) }
            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("include untracked", isOn: $model.options.includeUntracked).disabled(model.options.all)
                    Toggle("--all", isOn: $model.options.all).disabled(model.options.includeUntracked).help("Include untracked and ignored files.")
                }.toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Spacer(minLength: 0)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.save() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-stash.html")!) }
            }
        }.padding(16).disabled(model.busy || model.confirmingUntracked)
        .alert("Stash failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

struct StashSaveFollowUp {
    var showPull = false
    var pullShowPush = false
    var mergeRevision: String?
}
enum StashSavePostAction: String, CaseIterable, Hashable {
    case pull, merge, pop, apply
    var title: String {
        switch self { case .pull: return "Pull…"; case .merge: return "Merge…"; case .pop: return "Stash Pop"; case .apply: return "Stash Apply" }
    }
    var icon: MenuIcon {
        switch self { case .pull: return .pull; case .merge: return .merge; case .pop, .apply: return .stashPop }
    }
}
@MainActor final class StashSaveProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let options: StashSaveOptions
    let followUp: StashSaveFollowUp
    let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private let access: RepositoryAccessLease?
    private let cancellation = OperationCancellation()
    private var started = false
    private var invalidated = false
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { busy && !invalidated && !cancelling && !confirmingCancellation }
    @Published private(set) var result: StashSaveResult?
    @Published private(set) var postActions: [StashSavePostAction] = []
    var close: () -> Void = {}
    var onFinished: (StashSaveResult?, String) -> Void = { _, _ in }
    var onPostAction: ((StashSavePostAction, StashSaveFollowUp) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, options: StashSaveOptions, followUp: StashSaveFollowUp, preferences: UserDefaults = .standard) { self.preferences = preferences; self.repository = repository; self.access = access; self.options = options; self.followUp = followUp; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences) }
    func start() { Task { await run() } }
    func cancel() {
        guard canCancel else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true; var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.invalidated else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; self.cancellation.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; cancellation.cancel() }
    }
    private func finishAutomaticClose() {
        if !invalidated, !busy, !confirmingCancellation, autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() }
    }
    func invalidate() { invalidated = true; cancellation.cancel(); confirmingCancellation = false; busy = false; postActions = [] }
    func run() async {
        guard !started, !invalidated else { return }; started = true
        LocalGitCommandProgress.begin(); defer { LocalGitCommandProgress.end(); withExtendedLifetime(access) {} }
        var originalOutput = ""
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let saved = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in
                guard let self, !self.invalidated else { return }
                self.output = state.output; self.currentWork = state.currentWork; self.percentage = state.percentage
            }, resultText: { $0.output }, operation: { [repository, options, cancellation] emit in try await repository.saveStash(options, cancellation: cancellation, onOutput: emit) })
            guard !invalidated else { return }
            result = saved; originalOutput = saved.output; success = true
            if followUp.showPull { postActions.append(.pull) }
            if followUp.mergeRevision != nil { postActions.append(.merge) }
            if saved.created { postActions += [.pop, .apply] }
        } catch {
            guard !invalidated else { return }; originalOutput = (error as? GitCommandCancellationFailure)?.result.text ?? error.localizedDescription
            output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences); cancelled = cancellation.isCancelled
        }
        busy = false; cancelling = false; currentWork = ""; percentage = nil; onFinished(result, originalOutput)
        finishAutomaticClose()
    }
    func perform(_ action: StashSavePostAction) {
        guard !invalidated, !busy, !confirmingCancellation, success, postActions.contains(action), let onPostAction else { return }
        close(); onPostAction(action, followUp)
    }
}
@MainActor final class StashSaveProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: StashSaveProgressWindowModel
    var onClosed: () -> Void = {}
    init(model: StashSaveProgressWindowModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 390), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(model.repository.root.lastPathComponent) – Stash Save Progress – TurtleGit"
        window.contentMinSize = NSSize(width: 520, height: 280); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StashSaveProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in
            guard let self, !self.model.busy, self.window?.attachedSheet == nil else { return }
            if let window = self.window { window.sheetParent?.endSheet(window); window.close() }
        }

        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
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
    func windowWillClose(_ notification: Notification) { if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil) }; model.saveActionLog(); model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
private struct StashSaveProgressDialog: View {
    @ObservedObject var model: StashSaveProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: model.success, preferences: model.preferences).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if model.busy { LocalGitProgressIndicator(percentage: model.percentage); Text(model.currentWork.isEmpty ? "Saving stash…" : model.currentWork) }
                else { Text(model.cancelled ? "Cancelled" : model.success ? "Finished" : "Stash failed").foregroundStyle(model.success ? Color.green : Color.red) }
                Spacer()
            }
            HStack {
                if let first = model.postActions.first {
                    HStack(spacing: 2) {
                        Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                        Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Stash post-actions") }.menuStyle(.borderlessButton).fixedSize()
                    }.disabled(model.onPostAction == nil)
                }
                Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(12)
    }
}
