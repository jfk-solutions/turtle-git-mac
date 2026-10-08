import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class StashWindowController: NSWindowController, NSWindowDelegate {
    let model: StashWindowModel
    var onClosed: () -> Void = {}
    private var progressController: StashSaveProgressWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = StashWindowModel(repository: repository, access: access)
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
                if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "Stash.NoIncludeUntrackedWarning") }
                choose(true)
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && !model.confirmingUntracked && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); onClosed() }
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
    func invalidate() { invalidated = true }
    func finish(_ progress: StashSaveProgressWindowModel) {
        guard self.progress === progress, !progress.busy else { return }
        self.progress = nil; busy = false; close()
    }
    private func perform(_ snapshot: StashSaveOptions) {
        guard !invalidated, !busy else { return }; busy = true
        let progress = StashSaveProgressWindowModel(repository: repository, access: access, options: snapshot, followUp: followUp)
        self.progress = progress
        progress.onFinished = { [weak self] result, details in
            if let result { self?.onSaved(result) } else { self?.onFailed(details) }
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
    private let autoClosePolicy: GitProgressAutoClose
    private let access: RepositoryAccessLease?
    private let cancellation = OperationCancellation()
    private var started = false
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var output = ""
    @Published private(set) var result: StashSaveResult?
    @Published private(set) var postActions: [StashSavePostAction] = []
    var close: () -> Void = {}
    var onFinished: (StashSaveResult?, String) -> Void = { _, _ in }
    var onPostAction: ((StashSavePostAction, StashSaveFollowUp) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, options: StashSaveOptions, followUp: StashSaveFollowUp, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; self.options = options; self.followUp = followUp; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences) }
    func start() { Task { await run() } }
    func cancel() { guard busy else { return }; cancellation.cancel() }
    func run() async {
        guard !started else { return }; started = true
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let saved = try await repository.saveStash(options, cancellation: cancellation)
            result = saved; output = saved.output; success = true
            if followUp.showPull { postActions.append(.pull) }
            if followUp.mergeRevision != nil { postActions.append(.merge) }
            if saved.created { postActions += [.pop, .apply] }
        } catch { output = error.localizedDescription; cancelled = cancellation.isCancelled }
        busy = false; onFinished(result, output)
        if autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() }
    }
    func perform(_ action: StashSavePostAction) {
        guard !busy, success, postActions.contains(action), let onPostAction else { return }
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
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        guard sender.attachedSheet == nil else { return false }
        sender.sheetParent?.endSheet(sender); return true
    }
    func windowWillClose(_ notification: Notification) { model.saveActionLog(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
private struct StashSaveProgressDialog: View {
    @ObservedObject var model: StashSaveProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor))
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text("Saving stash…") }
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
                if model.busy { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(12)
    }
}
