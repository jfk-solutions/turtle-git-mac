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
    var activeOperation: Bool { model.busy || window?.attachedSheet != nil }
    init(repository: GitRepository, access: RepositoryAccessLease?, good: String? = nil, bad: String? = nil, operation: BisectOperation? = nil, revisions: [String] = [], requireStart: Bool = false) {
        model = BisectWindowModel(repository: repository, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 180), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Bisect start – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 620, height: 180)
        window.contentViewController = NSHostingController(rootView: BisectDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.onProgress = { [weak window] in
            guard let window else { return }; window.title = "\(repository.root.lastPathComponent) – Bisect – TurtleGit"
            if window.contentLayoutRect.height < 440 { window.setContentSize(NSSize(width: max(660, window.contentLayoutRect.width), height: 440)) }
        }
        model.chooseRevision = { [weak self] good in self?.chooseRevision(good: good) }
        model.cancelPrompt = { [weak self] in self?.finishStash(false) }
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
    private func chooseRevision(good: Bool) {
        guard !retired, !model.busy, picker == nil, let window, window.attachedSheet == nil else { return }
        let picker = LogWindowController(repository: model.repository, access: model.access, onChoose: { [weak self] entry in
            guard let self, !self.retired else { return }
            self.picker = nil; self.model.hasPicker = false
            if let entry { if good { self.model.good = entry.hash } else { self.model.bad = entry.hash } }
        })
        self.picker = picker; model.hasPicker = true; let revision = good ? model.good : model.bad; picker.model.endRevision = revision.isEmpty ? nil : revision
        picker.model.reload(); if let child = picker.window { window.beginSheet(child) }
    }
    private func finishStash(_ accepted: Bool) {
        let reply = stashReply; stashReply = nil
        if let alert = stashAlert { stashAlert = nil; if let parent = alert.window.sheetParent { parent.endSheet(alert.window) }; alert.window.orderOut(nil) }
        reply?(accepted)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !activeOperation }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }; retired = true; model.retire(); finishStash(false)
        if let child = picker?.window, child.sheetParent === window { window?.endSheet(child) }
        picker?.close(); picker = nil; model.hasPicker = false; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class BisectWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    private(set) var retired = false
    private var token: OperationCancellation?
    @Published private(set) var cancelling = false
    @Published var hasPicker = false
    var cancelPrompt: () -> Void = {}
    func cancel() { guard busy else { return }; cancelling = true; token?.cancel(); cancelPrompt() }
    func retire() { guard !retired else { return }; retired = true; cancel(); logObservers.removeAll() }
    private func begin() -> OperationCancellation {
        let value = OperationCancellation(); token = value; busy = true; cancelling = false; error = nil
        Self.activeOperations += 1; return value
    }
    private func finish() { token = nil; busy = false; cancelling = false; Self.activeOperations -= 1 }
    let repository: GitRepository
    let access: RepositoryAccessLease?
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
    var canUpdateSubmodules: Bool { !retired && !hasPicker && !busy && hasSubmodules && lastExitCode == 0 && onSubmoduleUpdate != nil }
    func updateSubmodules() { guard canUpdateSubmodules else { return }; onSubmoduleUpdate?() }
    var canStart: Bool { !retired && !hasPicker && !busy && state?.active == false && !good.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !bad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func canPerform(_ operation: BisectOperation) -> Bool { !retired && !hasPicker && !busy && state?.active == true && (operation == .reset || lastExitCode == nil || lastExitCode == 0) }
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
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
                let choices = Array(Set(try await repository.checkoutReferences(cancellation: token).filter { $0.symbolicTarget == nil }.map(\.label))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                let freshState = try await repository.bisectState(cancellation: token)
                let metadata = try await repository.finderMetadata(cancellation: token)
                let branch = presetBad == nil && bad.isEmpty ? try await repository.branch(cancellation: token) : ""
                try requireLive(token)
                self.choices = choices; state = freshState; hasSubmodules = metadata.hasSubmoduleConfig
                if freshState.active { if output.isEmpty { output = freshState.log }; onProgress() }
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
        let good = self.good.trimmingCharacters(in: .whitespacesAndNewlines), bad = self.bad.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = begin()
        Task {
            defer { finish() }
            do {
                try validateAccess()
                let result: BisectExecution
                do { result = try await repository.startBisect(good: good, bad: bad, cancellation: token) }
                catch BisectFailure.dirty {
                    guard await confirmStash() else { return }
                    try requireLive(token); try validateAccess()
                    let stash = try await repository.stashBeforeBisect(cancellation: token)
                    try requireLive(token); output = stash.output; changed(stash.output)
                    result = try await repository.startBisect(good: good, bad: bad, cancellation: token)
                }
                try await accept(result, token: token)
            } catch { await recover(error) }
        }
    }
    func perform(_ operation: BisectOperation, revisions: [String] = []) {
        guard canPerform(operation) else { return }; let token = begin()
        Task {
            defer { finish() }
            do { try validateAccess(); try await accept(try await repository.bisect(operation, revisions: revisions, cancellation: token), token: token) }
            catch { await recover(error) }
        }
    }
    private func accept(_ result: BisectExecution, token: OperationCancellation) async throws {
        let metadata = try await repository.finderMetadata(cancellation: token)
        try requireLive(token)
        state = result.state; lastExitCode = result.exitCode; output += result.output
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
        error = failure.localizedDescription; lastExitCode = 1; state = recoveredState
        hasSubmodules = metadata?.hasSubmoduleConfig ?? false
        if let cancelled = failure as? GitCommandCancellationFailure { output += cancelled.result.text }
        if state?.active == true { onProgress() }
        changed(failure.localizedDescription)
    }
    func title(_ operation: BisectOperation) -> String {
        "Bisect " + (operation == .good ? state?.goodTerm ?? "good" : operation == .bad ? state?.badTerm ?? "bad" : operation.rawValue)
    }
}

private struct BisectDialog: View {
    @ObservedObject var model: BisectWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                HStack { Text("Last known good:").frame(width: 135, alignment: .leading); BisectCombo(value: $model.good, choices: model.choices, label: "Last known good"); Button("…") { model.chooseRevision(true) }.accessibilityLabel("Choose last known good commit") }
                HStack { Text("First known bad:").frame(width: 135, alignment: .leading); BisectCombo(value: $model.bad, choices: model.choices, label: "First known bad"); Button("…") { model.chooseRevision(false) }.accessibilityLabel("Choose first known bad commit") }
            }.disabled(model.busy || model.state?.active == true)
            if !model.output.isEmpty || model.state?.active == true {
                if let hash = model.state?.firstBadCommit { Text("First \(model.state?.badTerm ?? "bad") commit: \(hash)").foregroundStyle(.green).textSelection(.enabled) }
                else if model.state?.active == true { Text("Testing: \(model.state?.head ?? "")").foregroundStyle(.blue).textSelection(.enabled) }
                ScrollView { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 160)
                HStack {
                    ForEach(BisectOperation.allCases, id: \.rawValue) { operation in
                        Button { model.perform(operation) } label: { CommandLabel(title: model.title(operation), icon: operation.icon) }.disabled(!model.canPerform(operation))
                    }
                }
                if model.hasSubmodules, model.onSubmoduleUpdate != nil { Button { model.updateSubmodules() } label: { CommandLabel(title: "Submodule Update…", icon: .fetch) }.disabled(!model.canUpdateSubmodules) }
            }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer()
                if model.state?.active != true { Button("OK") { model.start() }.keyboardShortcut(.defaultAction).disabled(!model.canStart) }
                Button(model.busy ? (model.cancelling ? "Cancelling…" : "Cancel") : model.output.isEmpty ? "Cancel" : "Close") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction).disabled(model.cancelling || model.hasPicker)
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
        let c = context.coordinator; c.updating = true; defer { c.updating = false }; c.change = { value = $0 }
        if c.choices != choices { view.removeAllItems(); view.addItems(withObjectValues: choices); c.choices = choices }
        if view.stringValue != value { view.stringValue = value }; view.isEnabled = enabled; view.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var updating = false; var choices: [String] = []; var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) { guard !updating, let view = notification.object as? NSComboBox else { return }; change(view.stringValue) }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard !updating, let view = notification.object as? NSComboBox, choices.indices.contains(view.indexOfSelectedItem) else { return }; change(choices[view.indexOfSelectedItem]) }
    }
}
extension BisectOperation {
    var icon: MenuIcon { switch self { case .good: return .bisectGood; case .bad: return .bisectBad; case .skip: return .bisect; case .reset: return .bisectReset } }
}
