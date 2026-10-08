import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class ResetWindowController: NSWindowController, NSWindowDelegate {
    let model: ResetWindowModel
    var onClosed: () -> Void = {}
    private var progressController: ResetProgressWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil) {
        model = ResetWindowModel(repository: repository, access: access, revision: revision)
        let size = NSSize(width: 690, height: 405)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Reset – TurtleGit"
        window.contentMinSize = size; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ResetDialog(model: model, chooser: model.chooser))
        super.init(window: window); window.delegate = self
        window.setFrameAutosaveName("ResetDialog"); window.setContentSize(size); window.center()
        model.close = { [weak self] in guard let self, !self.model.busy, self.model.progress == nil, self.window?.attachedSheet == nil else { return }; self.window?.close() }
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
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && !model.confirmingHard && model.progress == nil && !model.chooser.busy && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class ResetWindowModel: ObservableObject {
    let chooser: SwitchWindowModel
    private let access: RepositoryAccessLease?
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
    var onStatus: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String?, preferences: UserDefaults = .standard) {
        chooser = SwitchWindowModel(repository: repository, access: access); self.access = access; initialRevision = revision; self.preferences = preferences
    }
    func load() {
        guard !busy else { return }; busy = true; chooser.load(revision: initialRevision)
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
        guard !busy, !confirmingHard, progress == nil, !chooser.busy else { return }; busy = true
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
        guard !busy, !confirmingHard, progress == nil else { return }; busy = true; error = nil
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
                        ReferencePopup(references: chooser.branches, selection: $chooser.branchRevision).disabled(chooser.options.target != .branch)
                        Button("…") { chooser.browse(.branch) }.accessibilityLabel("Browse references").disabled(chooser.options.target != .branch)
                    }.frame(height: 26)
                    HStack { SwitchRadio(title: "Tag", target: .tag, selection: $chooser.options.target).frame(width: 100)
                        ReferencePopup(references: chooser.tags, selection: $chooser.tagRevision).disabled(chooser.options.target != .tag); Color.clear.frame(width: 29)
                    }.frame(height: 26)
                    HStack { SwitchRadio(title: "Commit", target: .commit, selection: $chooser.options.target).frame(width: 100)
                        TextField("Commit", text: $chooser.commitRevision).disabled(chooser.options.target != .commit)
                        Button("…") { chooser.browse(.commit) }.accessibilityLabel("Choose commit").disabled(chooser.options.target != .commit)
                    }.frame(height: 26)
                }.padding(8)
            }
            GroupBox("Reset Type") {
                VStack(alignment: .leading, spacing: 7) {
                    ResetRadio(title: "Soft: Leave working tree and index untouched", value: .soft, selection: $model.mode).frame(height: 22)
                    ResetRadio(title: "Mixed: Leave working tree untouched, reset index", value: .mixed, selection: $model.mode).frame(height: 22).disabled(model.bare)
                    ResetRadio(title: "Hard: Reset working tree and index (discard all local changes)", value: .hard, selection: $model.mode).frame(height: 22).disabled(model.bare)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { model.onStatus() } label: { CommandLabel(title: "Show modified files in working tree", icon: .status).frame(maxWidth: .infinity) }.disabled(model.bare)
            HStack { if model.busy || chooser.busy { ProgressView().controlSize(.small) }; Spacer()
                Button("OK") { model.reset() }.keyboardShortcut(.defaultAction).disabled(chooser.revision.isEmpty)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-reset.html")!) } label: { CommandLabel(title: "Help", icon: .help) }
            }
        }.padding(12).disabled(model.busy || model.confirmingHard || chooser.busy).onAppear { model.load() }
        .sheet(item: $chooser.browser) { target in SwitchReferenceChooser(model: chooser, target: target) }
        .alert("Reset failed", isPresented: Binding(get: { model.error != nil || chooser.error != nil }, set: { if !$0 { model.error = nil; chooser.error = nil } })) { Button("OK") { model.error = nil; chooser.error = nil } } message: { Text(model.error ?? chooser.error ?? "") }
    }
}
private struct ResetRadio: NSViewRepresentable {
    let title: String
    let value: ResetMode
    @Binding var selection: ResetMode
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:))) }
    func updateNSView(_ button: NSButton, context: Context) { button.title = title; button.state = selection == value ? .on : .off; button.isEnabled = enabled; context.coordinator.select = { selection = value } }
    final class Coordinator: NSObject { var select: () -> Void = {}; @objc func clicked(_ sender: NSButton) { select() } }
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
