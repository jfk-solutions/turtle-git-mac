// Native adaptation of TortoiseGit BisectStartDlg.cpp and AppUtils.cpp.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class BisectWindowController: NSWindowController, NSWindowDelegate {
    let model: BisectWindowModel
    var onClosed: () -> Void = {}
    private var picker: LogWindowController?
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
        model.confirmStash = { [weak window] in
            guard let window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Stash local changes before bisect?"
            alert.informativeText = "Bisect checks out revisions. Stash saves your tracked changes; the stash stays available after bisect."
            alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Stash")
            return await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertSecondButtonReturn) } }
        }
        model.load(good: good, bad: bad, operation: operation, revisions: revisions, requireStart: requireStart)
    }
    private func chooseRevision(good: Bool) {
        guard !model.busy, let window, window.attachedSheet == nil else { return }
        let picker = LogWindowController(repository: model.repository, access: model.access, onChoose: { [weak self] entry in
            self?.picker = nil
            if let entry { if good { self?.model.good = entry.hash } else { self?.model.bad = entry.hash } }
        })
        self.picker = picker; let revision = good ? model.good : model.bad; picker.model.endRevision = revision.isEmpty ? nil : revision
        picker.model.reload(); if let child = picker.window { window.beginSheet(child) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !activeOperation }
    func windowWillClose(_ notification: Notification) { picker?.close(); picker = nil; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class BisectWindowModel: ObservableObject {
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
        for observer in logObservers { observer.model?.reload() }
    }
    var onSubmoduleUpdate: (() -> Void)?
    var canUpdateSubmodules: Bool { !busy && hasSubmodules && lastExitCode == 0 && onSubmoduleUpdate != nil }
    func updateSubmodules() { guard canUpdateSubmodules else { return }; onSubmoduleUpdate?() }
    var canStart: Bool { !busy && state?.active == false && !good.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !bad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func canPerform(_ operation: BisectOperation) -> Bool { !busy && state?.active == true && (operation == .reset || lastExitCode == nil || lastExitCode == 0) }
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load(good presetGood: String? = nil, bad presetBad: String? = nil, operation: BisectOperation? = nil, revisions: [String] = [], requireStart: Bool = false) {
        guard !busy else { return }; busy = true; error = nil
        Task {
            do {
                try validateAccess()
                guard try await !repository.isBare() else { throw BisectFailure.workingTree }
                choices = Array(Set(try await repository.checkoutReferences().filter { $0.symbolicTarget == nil }.map(\.label))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                let freshState = try await repository.bisectState(), metadata = try await repository.finderMetadata()
                state = freshState; hasSubmodules = metadata.hasSubmoduleConfig
                if freshState.active { if output.isEmpty { output = freshState.log }; onProgress() }
                if requireStart && (freshState.active || metadata.mergeActive) { throw BisectFailure.active }
                if operation != nil && !freshState.active { throw BisectFailure.inactive }
                if let presetGood { good = presetGood }
                if let presetBad { bad = presetBad }
                else if bad.isEmpty { let branch = try await repository.branch(); bad = branch.isEmpty ? "HEAD" : branch }
                lastExitCode = nil
            } catch { self.error = error.localizedDescription }
            busy = false
            if error == nil, let operation { perform(operation, revisions: revisions) }
        }
    }
    func start() {
        guard canStart else { return }
        let good = self.good.trimmingCharacters(in: .whitespacesAndNewlines), bad = self.bad.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try validateAccess()
                let result: BisectExecution
                do { result = try await repository.startBisect(good: good, bad: bad) }
                catch BisectFailure.dirty {
                    guard await confirmStash() else { return }
                    try validateAccess(); let stash = try await repository.stashBeforeBisect()
                    output = stash.output; changed(stash.output)
                    result = try await repository.startBisect(good: good, bad: bad)
                }
                await accept(result)
            } catch { await recover(error) }
        }
    }
    func perform(_ operation: BisectOperation, revisions: [String] = []) {
        guard canPerform(operation) else { return }; busy = true; error = nil
        Task {
            defer { busy = false }
            do { try validateAccess(); await accept(try await repository.bisect(operation, revisions: revisions)) }
            catch { await recover(error) }
        }
    }
    private func accept(_ result: BisectExecution) async {
        state = result.state; lastExitCode = result.exitCode; output += result.output
        // A bisect checkout can add or remove .gitmodules. Upstream queries the
        // resulting worktree in its post-command callback, not the initial one.
        hasSubmodules = (try? await repository.finderMetadata().hasSubmoduleConfig) ?? false
        onProgress(); changed(result.output)
        if result.exitCode != 0 { error = result.output.isEmpty ? "Bisect failed (\(result.exitCode))." : result.output }
    }
    private func recover(_ failure: Error) async {
        error = failure.localizedDescription; lastExitCode = 1
        state = try? await repository.bisectState()
        hasSubmodules = (try? await repository.finderMetadata().hasSubmoduleConfig) ?? false
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
                Button(model.output.isEmpty ? "Cancel" : "Close") { model.close() }.keyboardShortcut(.cancelAction).disabled(model.busy)
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
