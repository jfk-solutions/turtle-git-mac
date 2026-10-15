// Native adaptation of TortoiseGit BisectStartDlg.cpp and AppUtils.cpp.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class BisectWindowController: NSWindowController, NSWindowDelegate {
    let model: BisectWindowModel
    var onClosed: () -> Void = {}
    private var picker: LogWindowController?
    private var stashAlert: NSAlert?
    private var stashReply: ((Bool) -> Void)?
    private var retired = false
    private var pickerRequest: UUID?
    var makePicker: (GitRepository, RepositoryAccessLease?, String?, UserDefaults, @escaping (LogEntry?) -> Void) -> LogWindowController = { repository, access, revision, preferences, choose in
        LogWindowController(repository: repository, access: access, onChoose: choose, labelDefaults: preferences, initialRevision: revision)
    }
    var presentPicker: (NSWindow, NSWindow) -> Bool = { parent, child in parent.beginSheet(child); return true }
    var activeOperation: Bool { model.busy || model.hasPicker || model.confirmingCancellation || window?.attachedSheet != nil }
    init(repository: GitRepository, access: RepositoryAccessLease?, good: String? = nil, bad: String? = nil, operation: BisectOperation? = nil, revisions: [String] = [], requireStart: Bool = false, preferences: UserDefaults = .standard) {
        model = BisectWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 180), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Bisect start", preferences: preferences)
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 620, height: 180)
        window.contentViewController = NSHostingController(rootView: BisectDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.onProgress = { [weak window] in
            guard let window else { return }; RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Bisect", preferences: preferences)
            if window.contentLayoutRect.height < 440 { window.setContentSize(NSSize(width: max(660, window.contentLayoutRect.width), height: 440)) }
        }
        model.onOptions = { [weak window] in
            guard let window else { return };RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Bisect start", preferences: preferences);window.setContentSize(NSSize(width:max(660,window.contentLayoutRect.width),height:180))
        }
        model.chooseRevision = { [weak self] good in self?.chooseRevision(good: good) }
        model.cancelPrompt = { [weak self] in self?.finishStash(false) }
        model.confirmCancellation = { [weak window] reply in
            guard let window, window.attachedSheet == nil else { reply(false); return }
            let alert=NSAlert();alert.messageText="The process is still running.";alert.informativeText="Are you sure to abort?"
            alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No")
            alert.beginSheetModal(for:window) { reply($0 == .alertFirstButtonReturn) }
        }
        model.confirmStash = { [weak self, weak window] in
            guard let self, !self.retired, let window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Stash local changes before bisect?"
            alert.informativeText = "Bisect checks out revisions. Stash saves your tracked changes; the stash stays available after bisect."
            alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Stash")
            self.stashAlert = alert
            return await withCheckedContinuation { continuation in
                self.stashReply = { continuation.resume(returning: $0) }
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard let self, self.stashAlert === alert else { return }
                    self.finishStash(response == .alertSecondButtonReturn && !self.retired)
                }
            }
        }
        model.load(good: good, bad: bad, operation: operation, revisions: revisions, requireStart: requireStart)

        DialogGeometry.attach(window, identifier: "BisectWindowController")
    }
    func chooseRevision(good: Bool) {
        guard !retired, model.canPickRevision, picker == nil, let window, window.attachedSheet == nil else { return }
        let request=UUID(), revision=good ? model.good : model.bad
        pickerRequest=request; model.hasPicker=true
        let child=makePicker(model.repository,model.access,revision.isEmpty ? nil : revision,model.preferences) { [weak self] entry in
            guard let self, !self.retired, self.pickerRequest == request else { return }
            self.pickerRequest=nil;self.picker=nil;self.model.hasPicker=false
            guard self.model.canPickRevision, (good ? self.model.good : self.model.bad) == revision else { return }
            if let entry { if good { self.model.good=entry.hash } else { self.model.bad=entry.hash } }
        }
        picker=child
        guard let childWindow=child.window, presentPicker(window,childWindow) else {
            pickerRequest=nil;picker=nil;model.hasPicker=false;child.close();return
        }
    }
    private func finishStash(_ accepted: Bool) {
        let reply = stashReply; stashReply = nil
        if let alert = stashAlert { stashAlert = nil; if let parent = alert.window.sheetParent { parent.endSheet(alert.window) }; alert.window.orderOut(nil) }
        reply?(accepted)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !activeOperation }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }; retired = true; model.saveActionLog(); model.retire(); finishStash(false); pickerRequest=nil
        if let window, let sheet=window.attachedSheet { window.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil) }
        if let child = picker?.window, child.sheetParent === window { window?.endSheet(child) }
        picker?.close(); picker = nil; model.hasPicker = false; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class BisectWindowModel: ObservableObject {
    let progressPresentation: GitCommandPresentation
    private(set) static var activeOperations = 0
    private(set) var retired = false
    private var token: OperationCancellation?
    @Published private(set) var cancelling = false
    @Published var hasPicker = false
    var cancelPrompt: () -> Void = {}
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var showingProgress = false
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var cancelled = false
    private var awaitingStash = false
    private var autoClosePolicy: GitProgressAutoClose?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { !retired && busy && !cancelling && !confirmingCancellation }
    var canPickRevision: Bool { !retired && !showingProgress && !hasPicker && !busy && !confirmingCancellation && state?.active == false }
    func cancel() {
        guard canCancel, let captured=token else { return }
        if showingProgress && !awaitingStash && preferences.bool(forKey:"ConfirmKillProcess") {
            confirmingCancellation=true;var answered=false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.retired else { return };answered=true;self.confirmingCancellation=false
                if self.busy, self.token === captured, accepted { self.cancelling=true;captured.cancel();self.cancelPrompt() }
                self.finishAutomaticClose()
            }
        } else { cancelling=true;captured.cancel();cancelPrompt() }
    }
    func retire() { guard !retired else { return }; retired=true;token?.cancel();cancelPrompt();confirmingCancellation=false;logObservers.removeAll() }
    private func begin(progress: Bool = false) -> OperationCancellation {
        let value=OperationCancellation();token=value;busy=true;cancelling=false;error=nil;Self.activeOperations += 1
        if progress {
            ProgressActionLog.nextAttempt(self, savePrevious: showingProgress)
            showingProgress=true;output="";lastExitCode=nil;cancelled=false;currentWork="";percentage=nil
            autoClosePolicy=GitProgressAutoClose(preferences:preferences);onProgress()
        }
        return value
    }
    private func finish() { token=nil;busy=false;cancelling=false;currentWork="";percentage=nil;Self.activeOperations -= 1;withExtendedLifetime(access) {};finishAutomaticClose() }
    private func finishAutomaticClose() {
        guard !retired, !busy, showingProgress, !confirmingCancellation, !awaitingStash, !cancelled, error == nil, lastExitCode == 0 else { return }
        let count=(state?.active == true ? 4 : 0) + (hasSubmodules ? 1 : 0)
        if autoClosePolicy?.shouldClose(success:true,postActionCount:count) == true { saveActionLog();close() }
    }
    private func stream<T>(token captured: OperationCancellation, resultText: @escaping (T) -> String,
                           operation: @escaping (@escaping @Sendable (GitOutputChunk) -> Void) async throws -> T) async throws -> T {
        let prefix=output
        LocalGitCommandProgress.begin();defer { LocalGitCommandProgress.end() }
        return try await LocalGitCommandProgress.stream(preferences:preferences,update: { [weak self] state in
            guard let self, !self.retired, self.token === captured else { return }
            self.output=LocalGitCommandProgress.bounded(prefix + state.output,preferences:self.preferences)
            self.currentWork=state.currentWork;self.percentage=state.percentage
        },resultText:resultText,operation:operation)
    }
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    @Published var good = ""
    @Published var bad = ""
    @Published var choices: [String] = []
    @Published var state: BisectState?
    @Published var busy = false
    @Published var error: String?
    @Published var output = ""
    @Published var lastExitCode: Int32?
    @Published var hasSubmodules = false
    var close: () -> Void = {}
    var onProgress: () -> Void = {}
    var onOptions: () -> Void = {}
    var chooseRevision: (Bool) -> Void = { _ in }
    var confirmStash: () async -> Bool = { false }
    var onChanged: (String) -> Void = { _ in }
    private final class LogObserver {
        weak var model: LogWindowModel?
        init(_ model: LogWindowModel) { self.model = model }
    }
    private var logObservers: [LogObserver] = []
    func observeLog(_ model: LogWindowModel) {
        guard model.repository.root == repository.root, !model.isInvalidated else { return }
        logObservers.removeAll { $0.model == nil || $0.model?.isInvalidated == true }
        if !logObservers.contains(where: { $0.model === model }) { logObservers.append(LogObserver(model)) }
    }
    private func changed(_ output: String) {
        onChanged(output)
        logObservers.removeAll { $0.model == nil || $0.model?.isInvalidated == true }
        for observer in logObservers { observer.model?.requestRepositoryRefresh() }
    }
    var onSubmoduleUpdate: (() -> Void)?
    var canUpdateSubmodules: Bool { !retired && !hasPicker && !busy && !confirmingCancellation && hasSubmodules && lastExitCode == 0 && onSubmoduleUpdate != nil }
    func updateSubmodules() { guard canUpdateSubmodules else { return }; onSubmoduleUpdate?() }
    var canStart: Bool { !retired && !showingProgress && !hasPicker && !busy && !confirmingCancellation && state?.active == false && !good.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !bad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func canPerform(_ operation: BisectOperation) -> Bool { !retired && !hasPicker && !busy && !confirmingCancellation && state?.active == true && (operation == .reset || lastExitCode == nil || lastExitCode == 0) }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; self.preferences = preferences; progressPresentation = GitCommandPresentation(defaults: preferences) }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func requireLive(_ token: OperationCancellation) throws {
        if retired || token.isCancelled { throw OperationCancellationFailure.cancelled }
    }
    func load(good presetGood: String? = nil, bad presetBad: String? = nil, operation: BisectOperation? = nil, revisions: [String] = [], requireStart: Bool = false) {
        guard !retired, !hasPicker, !busy else { return }; let token = begin()
        Task {
            do {
                try validateAccess()
                guard try await !repository.isBare(cancellation: token) else { throw BisectFailure.workingTree }
                let references=try await repository.checkoutReferences(cancellation:token).filter { $0.symbolicTarget == nil }
                var choices: [String]=[]
                for reference in references.filter({ $0.target == .branch }) + references.filter({ $0.target == .tag }) {
                    if !choices.contains(where:{ GitReferenceName.equal($0,reference.label) }) { choices.append(reference.label) }
                }
                let freshState = try await repository.bisectState(cancellation: token)
                let metadata = try await repository.finderMetadata(cancellation: token)
                let branch = presetBad == nil && bad.isEmpty ? try await repository.branch(cancellation: token) : ""
                try requireLive(token)
                self.choices = choices; state = freshState; hasSubmodules = metadata.hasSubmoduleConfig
                if freshState.active { showingProgress=true;if output.isEmpty { output=LocalGitCommandProgress.bounded(freshState.log,preferences:preferences) };onProgress() }
                if requireStart && !freshState.active { showingProgress=false;onOptions() }
                if requireStart && (freshState.active || metadata.mergeActive) { throw BisectFailure.active }
                if operation != nil && !freshState.active { throw BisectFailure.inactive }
                if let presetGood { good = presetGood }
                if let presetBad { bad = presetBad }
                else if bad.isEmpty { bad = branch.isEmpty ? "HEAD" : branch }
                lastExitCode = nil
            } catch { if !retired { self.error = error.localizedDescription } }
            finish()
            if !retired, !token.isCancelled, error == nil, let operation { perform(operation, revisions: revisions) }
        }
    }
    func start() {
        guard canStart else { return }
        func normalized(_ value:String) -> String { let trimmed=value.trimmingCharacters(in:.whitespacesAndNewlines);return trimmed.hasPrefix("remotes/") ? String(trimmed.dropFirst(8)) : trimmed }
        let good=normalized(self.good),bad=normalized(self.bad)
        let token=begin(progress:true)
        Task {
            defer { finish() }
            do {
                try validateAccess()
                let result: BisectExecution
                do { result=try await stream(token:token,resultText: { $0.output }) { [repository] emit in try await repository.startBisect(good:good,bad:bad,cancellation:token,onOutput:emit) } }
                catch BisectFailure.dirty {
                    awaitingStash=true;let accepted=await confirmStash();awaitingStash=false
                    guard accepted else { if !retired && !token.isCancelled { showingProgress=false;onOptions() };return }
                    try requireLive(token); try validateAccess()
                    let stash=try await stream(token:token,resultText: { $0.output }) { [repository] emit in try await repository.stashBeforeBisect(cancellation:token,onOutput:emit) }
                    try requireLive(token);changed(stash.output)
                    result=try await stream(token:token,resultText: { $0.output }) { [repository] emit in try await repository.startBisect(good:good,bad:bad,cancellation:token,onOutput:emit) }
                }
                try await accept(result, token: token)
            } catch { await recover(error) }
        }
    }
    func perform(_ operation: BisectOperation, revisions: [String] = []) {
        guard canPerform(operation) else { return }; let token=begin(progress:true)
        Task {
            defer { finish() }
            do {
                try validateAccess()
                let result=try await stream(token:token,resultText: { $0.output }) { [repository] emit in try await repository.bisect(operation,revisions:revisions,cancellation:token,onOutput:emit) }
                try await accept(result,token:token)
            }
            catch { await recover(error) }
        }
    }
    private func accept(_ result: BisectExecution, token: OperationCancellation) async throws {
        let metadata = try await repository.finderMetadata(cancellation: token)
        try requireLive(token)
        state = result.state; lastExitCode = result.exitCode
        hasSubmodules = metadata.hasSubmoduleConfig
        onProgress(); changed(result.output)
        if result.exitCode != 0 { error = result.output.isEmpty ? "Bisect failed (\(result.exitCode))." : result.output }
    }
    private func recover(_ failure: Error) async {
        guard !retired else { return }
        // Cancellation can leave Git's session active. Read its actual state with
        // a fresh owned token so Reset remains available; never undo it implicitly.
        let recovery = OperationCancellation(); token = recovery
        let recoveredState = try? await repository.bisectState(cancellation: recovery)
        let metadata = try? await repository.finderMetadata(cancellation: recovery)
        guard !retired, !recovery.isCancelled else { return }
        cancelled = failure is OperationCancellationFailure || failure is GitCommandCancellationFailure || cancelling
        error = failure.localizedDescription; lastExitCode = 1; state = recoveredState
        hasSubmodules = metadata?.hasSubmoduleConfig ?? false
        output=LocalGitCommandProgress.failure(failure,existing:output,preferences:preferences)
        if state?.active == true { onProgress() }
        changed(failure.localizedDescription)
    }
    func returnToOptions() {
        guard !retired, !busy, !hasPicker, !confirmingCancellation, state?.active == false else { return };saveActionLog();showingProgress=false;onOptions()
    }
    var postOperations: [BisectOperation] {
        guard !busy, state?.active == true else { return [] }
        return lastExitCode == nil || lastExitCode == 0 ? BisectOperation.allCases : [.reset]
    }
    func title(_ operation: BisectOperation) -> String {
        "Bisect " + (operation == .good ? state?.goodTerm ?? "good" : operation == .bad ? state?.badTerm ?? "bad" : operation.rawValue)
    }
}

private struct BisectDialog: View {
    @ObservedObject var model: BisectWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.showingProgress { VStack(spacing: 10) {
                HStack { Text("Last known good:").frame(width: 135, alignment: .leading); BisectCombo(value: $model.good, choices: model.choices, label: "Last known good"); Button { model.chooseRevision(true) } label: { CommandLabel(title:"…",icon:.log) }.accessibilityLabel("Choose last known good commit") }
                HStack { Text("First known bad:").frame(width: 135, alignment: .leading); BisectCombo(value: $model.bad, choices: model.choices, label: "First known bad"); Button { model.chooseRevision(false) } label: { CommandLabel(title:"…",icon:.log) }.accessibilityLabel("Choose first known bad commit") }
            }.disabled(!model.canPickRevision) }
            if model.showingProgress {
                if let hash = model.state?.firstBadCommit { Text("First \(model.state?.badTerm ?? "bad") commit: \(hash)").foregroundStyle(.green).textSelection(.enabled) }
                else if model.state?.active == true { Text("Testing: \(model.state?.head ?? "")").foregroundStyle(.blue).textSelection(.enabled) }
                SubmoduleProgressOutputView(text:model.output,completed:!model.busy,success:model.lastExitCode == 0,preferences:model.preferences).frame(minHeight:160)
                if model.hasSubmodules, model.lastExitCode == 0, !model.busy, model.onSubmoduleUpdate != nil { Button { model.updateSubmodules() } label: { CommandLabel(title: "Submodule Update…", icon: .fetch) }.disabled(!model.canUpdateSubmodules) }
                HStack {
                    ForEach(model.postOperations, id: \.rawValue) { operation in
                        Button { model.perform(operation) } label: { CommandLabel(title: model.title(operation), icon: operation.icon) }.disabled(!model.canPerform(operation))
                    }
                }

            }
            HStack { if model.busy { LocalGitProgressIndicator(percentage: model.percentage, animate: model.progressPresentation.animateActivity);Text(model.currentWork).font(.caption) }; Spacer()
                if !model.showingProgress { Button("OK") { model.start() }.keyboardShortcut(.defaultAction).disabled(!model.canStart) }
                if model.showingProgress && model.state?.active == false && model.lastExitCode != 0 { Button("Back") { model.returnToOptions() }.disabled(model.busy || model.hasPicker || model.confirmingCancellation) }
                Button(model.busy ? (model.cancelling ? "Cancelling…" : "Cancel") : model.output.isEmpty ? "Cancel" : "Close") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction).disabled(model.cancelling || model.hasPicker || model.confirmingCancellation)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-bisect.html")!) }
            }
        }.padding(16)
        .alert("Bisect", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
private struct BisectCombo: NSViewRepresentable {
    @Binding var value: String; let choices: [String]; let label: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox { let view = NSComboBox(); view.delegate = context.coordinator; view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view }
    func updateNSView(_ view: NSComboBox, context: Context) {
        let c = context.coordinator; c.updating = true; defer { c.updating = false }; c.enabled=enabled;c.change = { value = $0 }
        if c.choices != choices { view.removeAllItems(); view.addItems(withObjectValues: choices); c.choices = choices }
        if view.stringValue != value { view.stringValue = value }; view.isEnabled = enabled; view.setAccessibilityLabel(label)
    }
    static func dismantleNSView(_ view:NSComboBox,coordinator:Coordinator) { coordinator.enabled=false;coordinator.change={_ in};view.delegate=nil }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var updating = false; var enabled=false; var choices: [String] = []; var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) { guard !updating, enabled, let view = notification.object as? NSComboBox, view.isEnabled else { return }; change(view.stringValue) }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard !updating, enabled, let view = notification.object as? NSComboBox, view.isEnabled, choices.indices.contains(view.indexOfSelectedItem) else { return }; change(choices[view.indexOfSelectedItem]) }
    }
}
extension BisectOperation {
    var icon: MenuIcon { switch self { case .good: return .bisectGood; case .bad: return .bisectBad; case .skip: return .bisect; case .reset: return .bisectReset } }
}
