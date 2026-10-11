// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

enum SynchronizationTrackingChoice { case yes, no, cancel }
struct SynchronizationTrackingAnswer {
    let choice: SynchronizationTrackingChoice
    var suppress = false
}
enum SynchronizationProgressResult: Sendable {
    case checkout(SynchronizationPullCheckout), merge(GitResult)
}
enum SynchronizationProgressOperation: Sendable {
    case checkout(SynchronizationTransportPlan), merge(SynchronizationRebaseState)
    var title: String { if case .checkout = self { return "Checkout Progress" }; return "Merge Progress" }
    var label: String {
        switch self {
        case .checkout(let plan): return "Switch to " + (plan.checkoutBranch ?? plan.options.localBranch)
        case .merge(let state): return "Fast-forward to " + state.target
        }
    }
    var work: String { if case .checkout = self { return "Switching…" }; return "Merging…" }
    var failure: String { if case .checkout = self { return "Checkout failed" }; return "Merge failed" }
}

@MainActor final class SynchronizationProgressController: NSWindowController, NSWindowDelegate {
    let model: SynchronizationProgressModel
    var onClosed: () -> Void = {}
    private var alert: NSAlert?
    private var completion: ((Result<SynchronizationProgressResult, Error>) -> Void)?
    init(repository: GitRepository, operation: SynchronizationProgressOperation, cancellation: OperationCancellation, preferences: UserDefaults,
         completion: @escaping (Result<SynchronizationProgressResult, Error>) -> Void) {
        model = SynchronizationProgressModel(repository: repository, operation: operation, cancellation: cancellation, preferences: preferences)
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – \(operation.title) – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 560, height: 300)
        window.contentViewController = NSHostingController(rootView: SynchronizationProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in self?.closePresentation() }
        model.confirmCancel = { [weak self] reply in
            guard let self, let window = self.window, window.attachedSheet == nil else { reply(false); return }
            let alert = NSAlert(); alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); self.alert = alert
            alert.beginSheetModal(for: window) { [weak self] response in self?.alert = nil; reply(response == .alertFirstButtonReturn) }
        }
        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func closePresentation() { guard !model.busy, !model.confirmingCancellation else { return }; window?.sheetParent?.endSheet(window!); close() }
    func abortPresentation() {
        model.invalidate()
        if let alert, window?.attachedSheet === alert.window { window?.endSheet(alert.window, returnCode: .abort) }
        alert = nil; window?.sheetParent?.endSheet(window!); close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        guard !model.confirmingCancellation, sender.attachedSheet == nil else { return false }
        sender.sheetParent?.endSheet(sender); return true
    }
    func windowWillClose(_ notification: Notification) {
        let result = model.result ?? .failure(OperationCancellationFailure.cancelled)
        model.invalidate(); window?.sheetParent?.endSheet(window!)
        let callback = completion; completion = nil; onClosed(); callback?(result)
    }
}

@MainActor final class SynchronizationProgressModel: ObservableObject {
    let repository: GitRepository, operation: SynchronizationProgressOperation, preferences: UserDefaults
    private let cancellation: OperationCancellation
    private var started = false, closed = false
    @Published private(set) var busy = true
    @Published private(set) var output = ""
    @Published private(set) var confirmingCancellation = false
    private(set) var result: Result<SynchronizationProgressResult, Error>?
    var close: () -> Void = {}
    var confirmCancel: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    init(repository: GitRepository, operation: SynchronizationProgressOperation, cancellation: OperationCancellation, preferences: UserDefaults) {
        self.repository = repository; self.operation = operation; self.cancellation = cancellation; self.preferences = preferences
    }
    func invalidate() { closed = true; if busy { cancellation.cancel() }; busy = false; confirmingCancellation = false }
    func cancel() {
        guard !closed, busy, !confirmingCancellation, !cancellation.isCancelled else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            var answered = false
            confirmCancel { [weak self] accepted in
                guard !answered, let self, !self.closed else { return }; answered = true; self.confirmingCancellation = false
                if accepted, self.busy { self.cancellation.cancel() }
                if !self.busy, case .success = self.result { self.close() }
            }
        } else { cancellation.cancel() }
    }
    func start() {
        guard !started, !closed else { return }; started = true
        Task {
            let parser = GitCliOutputParser(limit: GitProgressOutputState(preferences: preferences).limit)
            var state = GitProgressOutputState(preferences: preferences)
            let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let operation = Task {
                defer { continuation.finish() }
                switch self.operation {
                case .checkout(let plan):
                    return SynchronizationProgressResult.checkout(try await repository.synchronizationPullCheckout(plan, checkoutAuthorized: true, cancellation: cancellation,
                        onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }))
                case .merge(let state):
                    return SynchronizationProgressResult.merge(try await repository.synchronizationFastForward(state, cancellation: cancellation,
                        onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }))
                }
            }
            for await _ in updates {
                guard !closed else { continue }; state.consume(parser.processPending(), parser: parser); output = state.output
            }
            guard !closed else { _ = try? await operation.value; return }
            state.consume(parser.processPending(), parser: parser); state.consume(parser.finish(), parser: parser); output = state.output
            do { result = .success(try await operation.value) }
            catch {
                result = .failure(error)
                if let failure = error as? GitFailure, state.hasOutput { output += "\nGit command failed (\(failure.code))." }
                else { output += "\n" + error.localizedDescription }
            }
            guard !closed else { return }; busy = false
            if !confirmingCancellation, case .success = result { close() }
        }
    }
}

private struct SynchronizationProgressDialog: View {
    @ObservedObject var model: SynchronizationProgressModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.operation.label).font(.headline)
            SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: { if case .success = model.result { return true }; return false }(), preferences: model.preferences)
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text(model.operation.work) } else { Text(model.operation.failure).foregroundStyle(.red) }
                Spacer()
                if model.busy { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.confirmingCancellation)
        }.padding(12)
    }
}

@MainActor final class SynchronizationWindowController: NSWindowController, NSWindowDelegate {
    let model: SynchronizationWindowModel
    var onClosed: () -> Void = {}
    private var cancellationAlert: NSAlert?
    private var pullAlert: NSAlert?
    private var commandProgress: SynchronizationProgressController?
    private(set) var optionsController: FetchWindowController?
    var configureOptions: (FetchWindowController) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = SynchronizationWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Git Synchronization – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 860, height: 500)
        window.contentViewController = NSHostingController(rootView: SynchronizationDialog(model: model))
        super.init(window: window); window.delegate = self; model.window = window
        model.runOptions = { [weak self] isPull, remote in
            guard let self, !self.model.closed, let owner = self.window, owner.attachedSheet == nil else { throw OperationCancellationFailure.cancelled }
            await withCheckedContinuation { continuation in
                let child = FetchWindowController(repository: repository, access: access, isPull: isPull, preferences: preferences)
                self.configureOptions(child)
                var dismissed = false
                child.onClosed = { [weak self, weak child] in
                    guard !dismissed else { return }; dismissed = true
                    if let window = child?.window { window.sheetParent?.endSheet(window) }
                    self?.optionsController = nil
                    continuation.resume()
                }
                self.optionsController = child
                child.window?.alphaValue = owner.alphaValue
                child.model.load(remote: remote, allRemotes: false)
                owner.beginSheet(child.window!)
            }
        }
        model.presentConflictHint = { [weak self] in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "TurtleGit"
            alert.informativeText = MergeProgressWindowModel.conflictHint
            alert.addButton(withTitle: "OK"); alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't show this message again"
            self.pullAlert = alert
            _ = await alert.beginSheetModal(for: window)
            if self.pullAlert === alert { self.pullAlert = nil }
            return alert.suppressionButton?.state == .on
        }
        model.confirmCheckout = { [weak self] branch in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Pull into a different local branch?"
            alert.informativeText = "Switch to \(branch) before pulling."
            alert.addButton(withTitle: "Switch to \(branch)"); alert.addButton(withTitle: "Abort")
            self.pullAlert = alert
            let response = await alert.beginSheetModal(for: window)
            if self.pullAlert === alert { self.pullAlert = nil }
            return response == .alertFirstButtonReturn
        }
        model.askTracking = { [weak self] branch, remote, destination in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { return SynchronizationTrackingAnswer(choice: .cancel) }
            let alert = NSAlert(); alert.messageText = "Set tracked branch?"
            alert.informativeText = "\(branch) has no tracked branch. Track \(remote)/\(destination)?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Cancel")
            let remember = NSButton(checkboxWithTitle: "Do not show again", target: nil, action: nil); alert.accessoryView = remember
            self.pullAlert = alert
            let response = await alert.beginSheetModal(for: window)
            if self.pullAlert === alert { self.pullAlert = nil }
            let choice: SynchronizationTrackingChoice = response == .alertFirstButtonReturn ? .yes : response == .alertSecondButtonReturn ? .no : .cancel
            return SynchronizationTrackingAnswer(choice: choice, suppress: remember.state == .on)
        }
        model.performCheckout = { [weak self] plan, token in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { throw OperationCancellationFailure.cancelled }
            return try await withCheckedThrowingContinuation { continuation in
                let child = SynchronizationProgressController(repository: repository, operation: .checkout(plan), cancellation: token, preferences: preferences) { result in
                    switch result {
                    case .success(.checkout(let checkpoint)): continuation.resume(returning: checkpoint)
                    case .success(.merge): continuation.resume(throwing: SynchronizationFailure.invalidInput)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                self.commandProgress = child
                child.onClosed = { [weak self] in self?.commandProgress = nil }
                child.window?.alphaValue = window.alphaValue
                window.beginSheet(child.window!); child.model.start()
            }
        }
        model.performFastForward = { [weak self] state, token in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { return .failure(OperationCancellationFailure.cancelled) }
            return await withCheckedContinuation { continuation in
                let child = SynchronizationProgressController(repository: repository, operation: .merge(state), cancellation: token, preferences: preferences) { result in
                    switch result {
                    case .success(.merge(let command)): continuation.resume(returning: .success(command))
                    case .success(.checkout): continuation.resume(returning: .failure(SynchronizationFailure.invalidInput))
                    case .failure(let error): continuation.resume(returning: .failure(error))
                    }
                }
                self.commandProgress = child; child.onClosed = { [weak self] in self?.commandProgress = nil }
                child.window?.alphaValue = window.alphaValue; window.beginSheet(child.window!); child.model.start()
            }
        }
        model.presentRebasePrompt = { [weak self] prompt in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { return FetchRebaseAnswer(value: prompt.answers[prompt.defaultIndex], suppress: false) }
            let alert = NSAlert(); alert.messageText = "TurtleGit"; alert.informativeText = prompt.message
            for (index, title) in prompt.buttons.enumerated() {
                let button = alert.addButton(withTitle: title); button.keyEquivalent = index == prompt.defaultIndex ? "\r" : ""
                if index == prompt.defaultIndex { alert.window.defaultButtonCell = button.cell as? NSButtonCell }
            }
            if prompt == .fastForward { alert.buttons.last?.keyEquivalent = "\u{1b}" }
            alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Do not show again"; self.pullAlert = alert
            let response = await alert.beginSheetModal(for: window)
            if self.pullAlert === alert { self.pullAlert = nil }
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            return FetchRebaseAnswer(value: prompt.answers.indices.contains(index) ? prompt.answers[index] : prompt.answers[prompt.defaultIndex], suppress: alert.suppressionButton?.state == .on)
        }
        model.sshSettings.present = { [weak self] prompt in
            guard let self, !self.model.closed, !self.model.confirmingQuit, let window = self.window, window.attachedSheet == nil else { return false }
            guard let child = prompt.window else { return false }
            window.makeFirstResponder(nil); window.beginSheet(child); return true
        }
        model.confirmCancellation = { [weak self] reply in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { reply(false); return }
            let alert = NSAlert(); alert.messageText = "Cancel synchronization?"
            alert.informativeText = "Git may have already updated remote-tracking references."
            alert.addButton(withTitle: "Keep Running"); alert.addButton(withTitle: "Cancel Operation")
            self.cancellationAlert = alert
            alert.beginSheetModal(for: window) { [weak self, weak alert] response in
                if self?.cancellationAlert === alert { self?.cancellationAlert = nil }
                reply(response == .alertSecondButtonReturn)
            }
        }
        model.comparison.window = window; model.incomingComparison.window = window; window.center()
        DialogGeometry.attach(window, identifier: "SyncDlg", legacyName: "SyncDlg")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.transportRunning, !model.confirmingCancellation, !model.hasBlockingChild, sender.attachedSheet == nil else { return false }
        if let child = [model.comparison, model.incomingComparison].flatMap({ Array($0.comparisonWindows.values) }).first(where: { $0.model.dirty }) {
            child.window?.makeKeyAndOrderFront(nil); child.window?.performClose(nil); return false
        }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        model.invalidate()
        model.detachRebase()
        optionsController?.close(); optionsController = nil
        commandProgress?.abortPresentation(); commandProgress = nil
        if let alert = pullAlert, window?.attachedSheet === alert.window { window?.endSheet(alert.window, returnCode: .abort) }
        pullAlert = nil
        if let alert = cancellationAlert, window?.attachedSheet === alert.window { window?.endSheet(alert.window, returnCode: .abort) }
        cancellationAlert = nil
        Array(model.comparison.comparisonWindows.values).forEach { $0.close() }
        Array(model.comparison.unifiedWindows.values).forEach { $0.close() }
        Array(model.incomingComparison.comparisonWindows.values).forEach { $0.close() }
        Array(model.incomingComparison.unifiedWindows.values).forEach { $0.close() }
        onClosed()
    }
}

@MainActor final class SynchronizationWindowModel: ObservableObject {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    let comparison: RevisionComparisonWindowModel
    let incomingComparison: RevisionComparisonWindowModel
    let sshSettings: SSHTransportSettings
    weak var window: NSWindow?
    @Published private(set) var localBranches: [String] = []
    @Published private(set) var remotes: [String] = []
    @Published private(set) var branchHistory: [String] = []
    @Published private(set) var urlHistory: [String] = []
    @Published var localBranch = ""
    @Published var remoteBranch = ""
    @Published var remote = ""
    @Published var force = false
    @Published var confirmingQuit = false {
        didSet {
            comparison.confirmingQuit = confirmingQuit
            incomingComparison.confirmingQuit = confirmingQuit
            for viewer in comparison.unifiedWindows.values { viewer.model.confirmingQuit = confirmingQuit }
            for viewer in incomingComparison.unifiedWindows.values { viewer.model.confirmingQuit = confirmingQuit }
        }
    }
    @Published var tab = 0 { didSet { if tab != oldValue { fileSelection = [] } } }
    @Published private(set) var incomingCommits: [LogEntry]?
    @Published private(set) var incomingGraph: [CommitGraphRow] = []
    @Published private(set) var conflicts: [StatusEntry] = []
    @Published var pullAction = SynchronizationTransportAction.pull
    var confirmCheckout: (String) async -> Bool = { _ in false }
    var askTracking: (String, String, String) async -> SynchronizationTrackingAnswer = { _, _, _ in SynchronizationTrackingAnswer(choice: .cancel) }
    var performCheckout: ((SynchronizationTransportPlan, OperationCancellation) async throws -> SynchronizationPullCheckout)?
    var performFastForward: ((SynchronizationRebaseState, OperationCancellation) async -> Result<GitResult, Error>)?
    var presentRebasePrompt: (FetchRebasePrompt) async -> FetchRebaseAnswer = { prompt in FetchRebaseAnswer(value: prompt.answers[prompt.defaultIndex], suppress: false) }
    var runRebase: (String, Bool, Bool) async throws -> Void = { _, _, _ in throw SynchronizationFailure.invalidInput }
    var detachRebase: () -> Void = {}
    var presentConflictHint: () async -> Bool = { false }
    var runOptions: (Bool, String?) async throws -> Void = { _, _ in throw SynchronizationFailure.invalidInput }
    var onResolve: ([String]) -> Void = { _ in }
    var displayedComparison: RevisionComparisonWindowModel { tab == 5 ? incomingComparison : comparison }
    var historyEntries: [LogEntry] { tab == 4 ? (incomingCommits ?? []) : (outgoing?.commits ?? []) }
    var historyGraph: [CommitGraphRow] { tab == 4 ? incomingGraph : graph }
    var incomingUpToDate: Bool {
        guard let snapshot = incomingComparison.snapshot else { return false }
        return snapshot.from == snapshot.to
    }
    var pullActionTitle: String {
        switch pullAction {
        case .pull: return "Pull"
        case .fetchAndRebase: return "Fetch & Rebase"
        case .fetchAllBranches: return "Fetch All"
        case .remoteUpdate: return "Remote Update"
        case .prune: return "Cleanup stale remote branches"
        default: return "Fetch"
        }
    }
    @Published var fileSelection = Set<String>()
    @Published private(set) var referenceChanges: [SynchronizationReferenceChange] = []
    @Published var hideUnchangedReferences = false { didSet { preferences.set(hideUnchangedReferences, forKey: "RefCompareHideUnchanged") } }
    var referenceRows: [SynchronizationReferenceChange] {
        referenceChanges.filter { !hideUnchangedReferences || $0.kind != .same }.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.name.rawValue.localizedStandardCompare($1.name.rawValue) == .orderedAscending
        }
    }
    @Published private(set) var outgoing: SynchronizationOutgoing?
    @Published private(set) var graph: [CommitGraphRow] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var transportRunning = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var cancelling = false
    @Published private(set) var commandOutput = ""
    @Published private(set) var commandSucceeded = false
    @Published private(set) var commandCompleted = false
    @Published private(set) var percentage: Int?
    @Published private(set) var currentWork = ""
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var onTransportFinished: (String) -> Void = { _ in }
    private var outputState: GitProgressOutputState
    private var cancellationQuestion: UUID?
    private var transportID: UUID?
    private var token: OperationCancellation?
    private(set) var closed = false
    var onLog: (String) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onReferenceLog: (String) -> Void = { _ in }
    var onReferenceCompare: (String, String) -> Void = { _, _ in }
    var hasBlockingChild: Bool {
        NSApp.modalWindow != nil || [comparison, incomingComparison].contains { child in
            child.busy || child.comparisonWindows.values.contains { $0.model.busy || $0.window?.attachedSheet != nil } || child.unifiedWindows.values.contains { $0.model.busy || $0.window?.attachedSheet != nil }
        }
    }
    var remoteChoices: [String] {
        var seen = Set<GitReferenceName>()
        return (urlHistory + remotes).filter { seen.insert(GitReferenceName($0)).inserted }.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }
    private var historyKey: String { "TurtleGit.Sync." + repository.root.path }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.preferences = preferences
        sshSettings = SSHTransportSettings(repository: repository)
        outputState = GitProgressOutputState(preferences: preferences)
        comparison = RevisionComparisonWindowModel(repository: repository, access: access, from: .revision("HEAD"), to: .revision("HEAD"))
        incomingComparison = RevisionComparisonWindowModel(repository: repository, access: access, from: .revision("HEAD"), to: .revision("HEAD"))
        switch preferences.integer(forKey: historyKey + ".pullAction") {
        case 1: pullAction = .fetch
        case 2: pullAction = .fetchAndRebase
        case 3: pullAction = .fetchAllBranches
        case 4: pullAction = .remoteUpdate
        case 5: pullAction = .prune
        default: pullAction = .pull
        }
        branchHistory = preferences.stringArray(forKey: historyKey + ".branches") ?? []
        urlHistory = preferences.stringArray(forKey: historyKey + ".urls") ?? []
        sshSettings.load(preferences, key: historyKey + ".autoload")
        hideUnchangedReferences = preferences.bool(forKey: "RefCompareHideUnchanged")
    }
    var status: String {
        if transportRunning { return cancelling ? "Cancelling…" : (currentWork.isEmpty ? "Running Git…" : currentWork) }
        if busy { return "Loading…" }
        if let error { return error }
        switch outgoing?.disposition {
        case .unknownURL: return "Outgoing commits are unknown for a URL."
        case .unknownRemoteBranch: return "Remote branch is unknown."
        case .upToDate: return "Up to date."
        case .needsForce: return "Local branch is not a fast-forward of the remote branch. Enable Force to show outgoing changes."
        case .outgoing: return "\(outgoing?.commits.count ?? 0) outgoing commits"
        case nil: return ""
        }
    }
    func invalidate() { closed = true; token?.cancel(); token = nil; comparison.invalidate(); incomingComparison.invalidate(); busy = false; confirmingCancellation = false; cancellationQuestion = nil; transportID = nil }
    func reload(selectTracking: Bool = false, initial: Bool = false) {
        guard !closed, !confirmingQuit, !transportRunning, !hasBlockingChild else { return }
        token?.cancel()
        let request = OperationCancellation(); token = request; busy = true; error = nil
        outgoing = nil; graph = []; fileSelection = []; comparison.snapshot = nil
        let local = localBranch, selectedRemote = remote, selectedBranch = remoteBranch, forced = force
        Task {
            defer { if token === request { token = nil; busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let catalog = try await repository.synchronizationBranches(localBranch: initial ? nil : local, cancellation: request)
                guard !closed, token === request, !request.isCancelled else { return }
                let branch = initial ? catalog.currentBranch : local
                let destination = selectTracking || initial ? catalog.trackedBranch : selectedBranch
                let url = selectTracking || initial ? (catalog.trackedRemote.isEmpty ? (initial ? (urlHistory.first ?? catalog.remotes.first ?? "") : selectedRemote) : catalog.trackedRemote) : selectedRemote
                localBranches = catalog.localBranches; remotes = catalog.remotes
                localBranch = branch; remoteBranch = destination; remote = url
                let projection = try await repository.synchronizationOutgoing(localBranch: branch, remote: url, remoteBranch: destination, force: forced, cancellation: request)
                guard !closed, token === request, !request.isCancelled else { return }
                outgoing = projection; graph = CommitGraph.layout(projection.commits); comparison.snapshot = projection.comparison
                // Native control edits never write Git configuration or refs.
            } catch {
                guard !closed, token === request, !request.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
    func performPullAction(_ action: SynchronizationTransportAction? = nil, shift: Bool = NSEvent.modifierFlags.contains(.shift)) { fetch(action ?? pullAction, shift: shift) }
    private func rebaseAnswer(_ prompt: FetchRebasePrompt, request: OperationCancellation) async throws -> Int {
        guard !closed, token === request, !request.isCancelled else { throw OperationCancellationFailure.cancelled }
        if let saved = preferences.object(forKey: prompt.rawValue) as? Int, prompt.answers.contains(saved) { return saved }
        let answer = await presentRebasePrompt(prompt)
        guard !closed, token === request, !request.isCancelled else { throw OperationCancellationFailure.cancelled }
        let value = prompt.answers.contains(answer.value) ? answer.value : prompt.answers[prompt.defaultIndex]
        if answer.suppress { preferences.set(value, forKey: prompt.rawValue) }
        return value
    }
    /// Shift opens the full Pull/Fetch options; other split entries ignore Shift.
    func fetch(_ action: SynchronizationTransportAction = .fetch, shift: Bool = false) {
        guard [.pull, .fetch, .fetchAndRebase, .fetchAllBranches, .remoteUpdate, .prune].contains(action),
              !closed, !confirmingQuit, !confirmingCancellation, !busy, !hasBlockingChild, window?.attachedSheet == nil else { return }
        pullAction = action
        let actionIndex = action == .pull ? 0 : action == .fetch ? 1 : action == .fetchAndRebase ? 2 : action == .fetchAllBranches ? 3 : action == .remoteUpdate ? 4 : 5
        preferences.set(actionIndex, forKey: historyKey + ".pullAction")
        if shift && action != .pull && action != .fetch { return }
        let operationID = UUID(); transportID = operationID
        let request = OperationCancellation(); token = request; busy = true; transportRunning = true
        cancelling = false; commandCompleted = false; commandSucceeded = false; referenceChanges = []
        incomingCommits = nil; incomingGraph = []; incomingComparison.snapshot = nil; conflicts = []
        outputState.reset(); commandOutput = ""; percentage = nil; currentWork = ""; error = nil; tab = 2
        var options = SynchronizationTransportOptions(action: action)
        options.localBranch = localBranch; options.remote = remote; options.remoteBranch = remoteBranch; options.force = force
        let factory = sshSettings.capture()
        sshSettings.save(preferences, key: historyKey + ".autoload")
        Task {
            let coordinator = factory?(); defer { coordinator?.close() }
            defer { if transportID == operationID { token = nil; busy = false; transportRunning = false; transportID = nil } }
            let parser = GitCliOutputParser(limit: outputState.limit)
            var oldReferences: SynchronizationReferenceSnapshot?
            var oldHead: String?
            var incomingRevision: String?
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let plan = try await (shift ? repository.synchronizationOptionsPlan(options, cancellation: request) : repository.synchronizationTransportPlan(options, cancellation: request))
                oldHead = plan.oldHead
                var checkout: SynchronizationPullCheckout?
                if action == .pull {
                    if let branch = plan.checkoutBranch {
                        guard await confirmCheckout(branch), !closed, token === request, !request.isCancelled else { throw OperationCancellationFailure.cancelled }
                        guard let performCheckout else { throw SynchronizationFailure.invalidInput }
                        checkout = try await performCheckout(plan, request)
                    } else { checkout = try await repository.synchronizationPullCheckout(plan, cancellation: request) }
                    guard !closed, token === request, !request.isCancelled else { throw OperationCancellationFailure.cancelled }
                    if !options.remote.contains("/"), !options.remote.contains("\\"), !plan.options.remoteBranch.isEmpty,
                       preferences.object(forKey: "AskSetTrackedBranch") == nil || preferences.bool(forKey: "AskSetTrackedBranch") {
                        let tracking = try await repository.synchronizationBranches(localBranch: options.localBranch, cancellation: request)
                        if tracking.trackedBranch.isEmpty {
                            let answer = await askTracking(options.localBranch, options.remote, plan.options.remoteBranch)
                            guard !closed, token === request else { return }
                            if answer.suppress { preferences.set(false, forKey: "AskSetTrackedBranch") }
                            guard answer.choice != .cancel, !request.isCancelled else { throw OperationCancellationFailure.cancelled }
                            if answer.choice == .yes {
                                var branch = plan.options.remoteBranch
                                if let short = GitReferenceName.removingPrefix("refs/heads/", from: branch) { branch = short }
                                else if let short = GitReferenceName.removingPrefix("refs/", from: branch) { branch = short }
                                _ = try await repository.run(["config", "--local", "branch." + options.localBranch + ".remote", options.remote], cancellation: request)
                                _ = try await repository.run(["config", "--local", "branch." + options.localBranch + ".merge", "refs/heads/" + branch], cancellation: request)
                            }
                        }
                    }
                }
                oldReferences = try await repository.synchronizationReferenceSnapshot(cancellation: request)
                guard !closed, token === request else { return }
                if request.isCancelled { throw OperationCancellationFailure.cancelled }
                if shift {
                    // The options dialog owns its own command/progress. Pull has
                    // already switched the selected branch; Fetch receives only
                    // a named remote, never the URL from this dialog.
                    if let preparation = coordinator?.preparation, action != .remoteUpdate {
                        _ = try await preparation(plan.transportRemotes, request)
                    }
                    guard !closed, token === request, !request.isCancelled else { throw OperationCancellationFailure.cancelled }
                    let preset = action == .fetch && !options.remote.contains("/") && !options.remote.contains("\\") ? options.remote : nil
                    try await runOptions(action == .pull, preset)
                    guard !closed, token === request, !request.isCancelled else { throw OperationCancellationFailure.cancelled }
                    let entries = try await repository.status(refreshIndex: false, cancellation: request).filter { $0.state == .conflicted }
                    guard !closed, token === request else { return }
                    if entries.isEmpty { incomingRevision = "HEAD" }
                    // Conflicts are loaded below, after refreshing references.
                    commandSucceeded = true
                } else {
                    let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    let operation = Task {
                        defer { continuation.finish() }
                        if let checkout {
                            return try await repository.synchronize(checkout, cancellation: request,
                                onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }, prepareTransport: coordinator?.preparation)
                        }
                        return try await repository.synchronize(plan, cancellation: request,
                            onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }, prepareTransport: coordinator?.preparation)
                    }
                    for await _ in updates { consume(parser.processPending(), parser: parser, request: request) }
                    consume(parser.processPending(), parser: parser, request: request)
                    consume(parser.finish(), parser: parser, request: request)
                    let result = try await operation.value
                    guard !closed, token === request else { return }
                    if !outputState.hasOutput { commandOutput = result.command.text }
                    var followUpSucceeded = true
                    if action == .pull, let target = result.rebaseTarget, result.rebaseMode != .none {
                        try await runRebase(target, true, result.rebaseMode == .preserveMerges)
                        guard !closed, token === request else { return }
                        incomingRevision = "HEAD"
                    } else if action == .pull { incomingRevision = "HEAD" }
                    else if action == .fetchAndRebase, let target = result.rebaseTarget {
                        let unchanged = plan.oldRemoteHash != nil && plan.oldRemoteHash == target
                        if unchanged, try await rebaseAnswer(.unchanged, request: request) == 7 { incomingRevision = target }
                        else {
                            let state = try await repository.synchronizationRebaseState(target: target, cancellation: request)
                            let choice = state.canFastForward ? try await rebaseAnswer(.fastForward, request: request) : 2
                            if choice == 1 {
                                guard let performFastForward else { throw SynchronizationFailure.invalidInput }
                                let merge = await performFastForward(state, request)
                                guard !closed, token === request else { return }
                                if case .failure(let error) = merge { followUpSucceeded = false; self.error = error.localizedDescription; commandOutput += "\nFast-forward failed.\n" + error.localizedDescription }
                                incomingRevision = "HEAD"
                            } else if choice == 2 {
                                try await repository.validateSynchronizationRebaseState(state, cancellation: request)
                                try await runRebase(target, false, false)
                                guard !closed, token === request else { return }; incomingRevision = "HEAD"
                            }
                            // Abort keeps the successful Fetch and reference results.
                        }
                    }
                    commandSucceeded = followUpSucceeded
                }
            } catch {
                guard !closed, token === request else { return }
                let message: String
                if request.isCancelled || error is OperationCancellationFailure { message = "Synchronization cancelled." }
                else if let failure = error as? GitFailure, outputState.hasOutput { message = "Git command failed (\(failure.code))." }
                else { message = error.localizedDescription }
                commandOutput += (commandOutput.isEmpty || commandOutput.hasSuffix("\n") ? "" : "\n") + message
                self.error = message
            }
            guard !closed, token === request else { return }
            // A normal cancellation may still move refs. Inspect with a fresh
            // token; forced owner closure cancels this read as well.
            if let before = oldReferences {
                let inspection = OperationCancellation(); token = inspection
                do {
                    let after = try await repository.synchronizationReferenceSnapshot(cancellation: inspection)
                    let rows = try await repository.synchronizationReferenceChanges(from: before, to: after, cancellation: inspection)
                    guard !closed, token === inspection else { return }
                    referenceChanges = rows
                    tab = 3
                } catch {
                    guard !closed, token === inspection else { return }
                    commandOutput += "\nReading reference changes failed.\n" + error.localizedDescription
                }
                guard !closed, token === inspection else { return }
            }
            if let oldHead, action == .pull || shift || incomingRevision != nil {
                let inspection = OperationCancellation(); token = inspection
                do {
                    if let incomingRevision {
                        let result = try await repository.synchronizationIncoming(from: oldHead, to: incomingRevision, cancellation: inspection)
                        guard !closed, token === inspection else { return }
                        incomingCommits = result.commits; incomingGraph = CommitGraph.layout(result.commits); incomingComparison.snapshot = result.comparison
                        tab = result.comparison.from == result.comparison.to ? 3 : 4
                    } else if oldReferences != nil {
                        let entries = try await repository.status(refreshIndex: false, cancellation: inspection).filter { $0.state == .conflicted }
                        guard !closed, token === inspection else { return }; conflicts = entries; tab = entries.isEmpty ? 2 : 6
                        if !entries.isEmpty, !preferences.bool(forKey: MergeProgressWindowModel.conflictHintPreference) {
                            let suppress = await presentConflictHint()
                            guard !closed, token === inspection, !inspection.isCancelled else { return }
                            if suppress { preferences.set(true, forKey: MergeProgressWindowModel.conflictHintPreference) }
                        }
                    }
                } catch {
                    guard !closed, token === inspection else { return }
                    commandOutput += "\nReading Pull results failed.\n" + error.localizedDescription
                }
                guard !closed, token === inspection else { return }
            }
            commandCompleted = true; cancelling = false; transportRunning = false; busy = false; token = nil; transportID = nil
            onTransportFinished(commandOutput)
            // Fetch completion refreshes outgoing projection, not incoming HEAD.
            // A cancelled/failed Git command can still have updated references.
            reload()
        }
    }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser, request: OperationCancellation) {
        guard !closed, token === request else { return }
        outputState.consume(emission, parser: parser)
        commandOutput = outputState.output; percentage = outputState.percentage; currentWork = outputState.currentWork
    }
    func cancelTransport() {
        guard !closed, !confirmingQuit, transportRunning, !cancelling, !confirmingCancellation, let request = token else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            let question = UUID(); cancellationQuestion = question; confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, !self.closed, self.cancellationQuestion == question else { return }
                self.cancellationQuestion = nil; self.confirmingCancellation = false
                guard self.token === request, self.transportRunning else { return }
                if accepted { self.cancelling = true; request.cancel() }
            }
        } else { cancelling = true; request.cancel() }
    }
    func compareFiles(unified: Bool) {
        let child = displayedComparison
        guard !closed, !confirmingQuit, !busy, child.snapshot != nil, !fileSelection.isEmpty else { return }
        if unified { child.showPatch(fileSelection, alternate: false) }
        else { child.compare(fileSelection) }
    }
}

private struct SynchronizationDialog: View {
    @ObservedObject var model: SynchronizationWindowModel
    private func edit(_ key: ReferenceWritableKeyPath<SynchronizationWindowModel, String>, tracking: Bool = false) -> Binding<String> {
        Binding(get: { model[keyPath: key] }, set: { model[keyPath: key] = $0; model.reload(selectTracking: tracking) })
    }
    var body: some View {
        VStack(spacing: 10) {
            GroupBox {
                VStack(spacing: 10) {
                    HStack {
                        Text("Local Branch:")
                        Picker("Local Branch", selection: Binding(get: { GitReferenceName(model.localBranch) }, set: { model.localBranch = $0.rawValue; model.reload(selectTracking: true) })) {
                            ForEach(model.localBranches.map { GitReferenceName($0) }, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden()
                        Text("Remote Branch:")
                        FetchHistoryCombo(value: edit(\.remoteBranch), choices: model.branchHistory, label: "Remote Branch")
                    }
                    HStack {
                        Text("Remote URL:")
                        FetchHistoryCombo(value: edit(\.remote), choices: model.remoteChoices, label: "Remote URL")
                    }
                    HStack { SSHAutoloadToggle(settings: model.sshSettings); Spacer() }
                    Toggle("Force", isOn: Binding(get: { model.force }, set: { model.force = $0; model.reload() }))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(6)
            }.disabled(model.transportRunning || model.hasBlockingChild)
            Picker("Changes", selection: $model.tab) {
                Text("Outgoing Commits").tag(0); Text("Outgoing Changes").tag(1); Text("Command Log").tag(2); Text("Ref changes").tag(3)
                if model.incomingCommits != nil { Text("Incoming Commits").tag(4) }
                if model.incomingComparison.snapshot?.files.isEmpty == false { Text("Incoming Changes").tag(5) }
                if !model.conflicts.isEmpty { Text("Conflicts").tag(6) }
            }.pickerStyle(.segmented)
            if model.tab == 3 {
                SynchronizationReferenceTable(model: model)
                    .overlay {
                        if model.referenceRows.isEmpty {
                            Text(model.transportRunning ? "Please wait…" : "No differences found.").foregroundStyle(.secondary).allowsHitTesting(false)
                        }
                    }
            } else if model.tab == 2 {
                SubmoduleProgressOutputView(text: model.commandOutput, completed: model.commandCompleted, success: model.commandSucceeded, preferences: model.preferences)
                if model.transportRunning {
                    if let value = model.percentage { ProgressView(value: Double(value), total: 100) }
                    else { ProgressView().progressViewStyle(.linear) }
                }
            } else if model.tab == 0 || model.tab == 4 {
                SynchronizationHistoryTable(model: model)
                    .id(model.tab)
                    .overlay { if model.tab == 4, model.incomingUpToDate { Text("Up to date.").foregroundStyle(.secondary) } }
            } else if model.tab == 6 {
                List(model.conflicts) { entry in
                    HStack { Image(nsImage: FileState.conflicted.icon.image() ?? NSImage()); Text(entry.path); Spacer()
                        Button { model.onResolve([entry.path]) } label: { CommandLabel(title: "Resolve", icon: .resolve) }.disabled(model.busy)
                    }
                }
            } else {
                SynchronizationFiles(model: model)
                HStack {
                    Button { model.compareFiles(unified: false) } label: { CommandLabel(title: "Compare two revisions", icon: .compare) }.disabled(model.fileSelection.isEmpty || model.busy)
                    Button { model.compareFiles(unified: true) } label: { CommandLabel(title: "Show unified diff", icon: .compare) }.disabled(model.fileSelection.isEmpty || model.busy)
                    Spacer()
                }
            }
            HStack {
                HStack(spacing: 0) {
                    Button { model.performPullAction() } label: { CommandLabel(title: model.pullActionTitle, icon: model.pullAction == .pull ? .pull : .fetch) }
                    Menu {
                        Button { model.performPullAction(.pull) } label: { CommandLabel(title: "Pull", icon: .pull) }
                        Button { model.performPullAction(.fetch) } label: { CommandLabel(title: "Fetch", icon: .fetch) }
                        Button { model.performPullAction(.fetchAndRebase) } label: { CommandLabel(title: "Fetch & Rebase", icon: .rebase) }
                        Button { model.performPullAction(.fetchAllBranches) } label: { CommandLabel(title: "Fetch All", icon: .fetch) }
                        Button { model.performPullAction(.remoteUpdate) } label: { CommandLabel(title: "Remote Update", icon: .fetch) }
                        Button { model.performPullAction(.prune) } label: { CommandLabel(title: "Cleanup stale remote branches", icon: .clean) }
                    } label: { Image(systemName: "chevron.down").accessibilityLabel("Pull actions") }.menuStyle(.borderlessButton).fixedSize()
                }.disabled(model.busy || model.hasBlockingChild)
                Button { model.onLog(model.localBranch) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(model.busy || model.localBranch.isEmpty)
                Button { model.onCommit() } label: { CommandLabel(title: "Commit", icon: .commit) }.disabled(model.busy)
                Button("Refresh") { model.reload() }.disabled(model.transportRunning || model.hasBlockingChild)
                Spacer()
                if model.transportRunning {
                    Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancelTransport() }
                        .keyboardShortcut(.cancelAction).disabled(model.cancelling || model.confirmingCancellation)
                } else {
                    Button("Close") { model.window?.performClose(nil) }.keyboardShortcut(.defaultAction)
                }
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).foregroundStyle(model.error == nil ? Color.secondary : Color.red).textSelection(.enabled)
                Spacer()
            }
        }.padding(12).disabled(model.confirmingQuit).onAppear { model.reload(initial: true) }
    }
}

private struct SynchronizationFiles: View {
    @ObservedObject var model: SynchronizationWindowModel
    private var files: [CommitFile] { model.displayedComparison.snapshot?.files ?? [] }
    private func state(_ file: CommitFile) -> FileState {
        switch file.action.first { case "A": return .added; case "D": return .deleted; default: return .modified }
    }
    var body: some View {
        Table(files, selection: $model.fileSelection) {
                    TableColumn("Path") { file in
                        HStack {
                            Image(nsImage: state(file).icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16)
                            Text(file.path).foregroundStyle(model.fileSelection.contains(file.id) ? Color.primary : state(file).textColor(preferences: model.preferences))
                        }.help(file.oldPath.map { "Renamed from " + $0 } ?? file.path)
                    }
                    TableColumn("Extension") { file in Text(file.fileExtension) }.width(80)
                    TableColumn("Status") { file in Text(file.status) }.width(70)
                    TableColumn("Added") { file in Text(file.addedText) }.width(65)
                    TableColumn("Deleted") { file in Text(file.removedText) }.width(65)
                }.contextMenu {
                    Button { model.compareFiles(unified: false) } label: { CommandLabel(title: "Compare two revisions", icon: .compare) }
                    Button { model.compareFiles(unified: true) } label: { CommandLabel(title: "Show unified diff", icon: .compare) }
                }
    }
}

private struct SynchronizationHistoryTable: NSViewRepresentable {
    @ObservedObject var model: SynchronizationWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView(); table.rowHeight = 24; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in [("graph", "Graph", 90.0), ("hash", "Hash", 110.0), ("message", "Message", 450.0), ("author", "Author", 150.0), ("date", "Date", 180.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        if model.preferences === UserDefaults.standard { table.autosaveName = model.tab == 4 ? "TurtleGit.SyncIn.RevisionColumns" : "TurtleGit.SyncOut.RevisionColumns"; table.autosaveTableColumns = true }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.showLog)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model; (scroll.documentView as? NSTableView)?.reloadData()
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: SynchronizationWindowModel
        init(_ model: SynchronizationWindowModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { model.historyEntries.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            let entries = model.historyEntries
            guard entries.indices.contains(row) else { return nil }
            let entry = entries[row]
            if column?.identifier.rawValue == "graph" {
                let cell = GraphCell(); cell.preferences = model.preferences; cell.parentCount = entry.parents.count
                if model.historyGraph.indices.contains(row) { cell.graph = model.historyGraph[row] }; return cell
            }
            let text: String
            switch column?.identifier.rawValue {
            case "hash": text = String(entry.hash.prefix(8))
            case "message": text = entry.subject
            case "author": text = entry.author
            case "date": text = entry.date
            default: text = ""
            }
            let cell = NSTextField(labelWithString: text); cell.lineBreakMode = .byTruncatingTail; return cell
        }
        @objc func showLog(_ table: NSTableView) {
            let entries = model.historyEntries
            guard !model.closed, !model.confirmingQuit, !model.busy, entries.indices.contains(table.clickedRow) else { return }
            model.onLog(entries[table.clickedRow].hash)
        }
    }
}

private final class SynchronizationReferenceNativeTable: NSTableView {
    var makeMenu: () -> NSMenu? = { nil }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return makeMenu()
    }
}
private final class SynchronizationReferenceHeader: NSTableHeaderView {
    var makeMenu: () -> NSMenu? = { nil }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
}
private struct SynchronizationReferenceTable: NSViewRepresentable {
    @ObservedObject var model: SynchronizationWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = SynchronizationReferenceNativeTable(); table.rowHeight = 24
        let titles = ["Reference", "Type", "Change", "Old hash", "Old message", "New hash", "New message"]
        for (index, title) in titles.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = title; column.width = [180.0, 110, 140, 100, 200, 100, 200][index]
            column.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: true)
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        let header = SynchronizationReferenceHeader(); header.makeMenu = { [weak coordinator = context.coordinator] in coordinator?.headerMenu() }; table.headerView = header
        table.makeMenu = { [weak table, weak coordinator = context.coordinator] in coordinator?.rowMenu(table?.selectedRow ?? -1) }
        if model.preferences === UserDefaults.standard { table.autosaveName = "TurtleGit.SyncRefs.Columns"; table.autosaveTableColumns = true }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = table
        context.coordinator.table = table; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model; context.coordinator.reload()
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: SynchronizationWindowModel
        weak var table: NSTableView?
        var rows: [SynchronizationReferenceChange] = []
        init(_ model: SynchronizationWindowModel) { self.model = model }
        private func field(_ row: SynchronizationReferenceChange, _ column: Int) -> String {
            switch column {
            case 0: return row.shortName
            case 1: return row.typeName
            case 2: return row.change
            case 3: return row.oldHash ?? ""
            case 4: return row.oldMessage
            case 5: return row.newHash ?? ""
            default: return row.newMessage
            }
        }
        func reload() {
            let selected = table.flatMap { rows.indices.contains($0.selectedRow) ? rows[$0.selectedRow].id : nil }
            rows = model.referenceRows
            if let descriptor = table?.sortDescriptors.first, let column = Int(descriptor.key ?? "") {
                rows = rows.enumerated().sorted { a, b in
                    let lhs = field(a.element, column), rhs = field(b.element, column)
                    let order = [0, 4, 6].contains(column) ? lhs.localizedStandardCompare(rhs) : lhs.compare(rhs, options: .literal)
                    if order == .orderedSame { return a.offset < b.offset }
                    return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
                }.map(\.element)
            }
            table?.reloadData()
            if let selected, let index = rows.firstIndex(where: { $0.id == selected }) { table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            else { table?.deselectAll(nil) }
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { reload() }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let index = Int(column?.identifier.rawValue ?? "") else { return nil }
            let entry = rows[row]
            let value = field(entry, index)
            let text = NSTextField(labelWithString: [3, 5].contains(index) ? String(value.prefix(8)) : value)
            text.lineBreakMode = .byTruncatingTail; text.toolTip = value
            if index == 0, let icon = ReferenceTypeIcon(referenceName: entry.name.rawValue)?.image() {
                let image = NSImageView(image: icon); image.setContentHuggingPriority(.required, for: .horizontal)
                let stack = NSStackView(views: [image, text]); stack.orientation = .horizontal; stack.spacing = 4; return stack
            }
            return text
        }
        private var available: Bool { !model.closed && !model.busy && !model.confirmingQuit && !model.confirmingCancellation && !model.hasBlockingChild }
        func headerMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            let item = NSMenuItem(title: "Hide unchanged refs", action: #selector(toggleUnchanged), keyEquivalent: "")
            item.target = self; item.state = model.hideUnchangedReferences ? .on : .off; menu.addItem(item); return menu
        }
        @objc func toggleUnchanged() { model.hideUnchangedReferences.toggle() }
        func rowMenu(_ row: Int) -> NSMenu? {
            guard rows.indices.contains(row) else { return nil }
            let entry = rows[row], menu = NSMenu(); menu.autoenablesItems = false
            func add(_ title: String, _ selector: Selector, _ icon: MenuIcon) {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self
                item.representedObject = entry; item.isEnabled = available
                item.image = MenuPresentationSettings.applicationContextIcons(defaults: model.preferences) ? icon.image() : nil
                menu.addItem(item)
            }
            if let hash = entry.oldHash { add("Show log of " + String(hash.prefix(8)), #selector(oldLog(_:)), .log) }
            if let hash = entry.newHash, entry.oldHash != hash { add("Show log of " + String(hash.prefix(8)), #selector(newLog(_:)), .log) }
            if entry.oldHash != nil && entry.newHash != nil && entry.oldHash != entry.newHash { add("Compare revisions", #selector(compare(_:)), .compare) }
            add("Reflog", #selector(reflog(_:)), .log); return menu
        }
        @objc func oldLog(_ sender: NSMenuItem) { guard available, let row = sender.representedObject as? SynchronizationReferenceChange, let hash = row.oldHash else { return }; model.onLog(hash) }
        @objc func newLog(_ sender: NSMenuItem) { guard available, let row = sender.representedObject as? SynchronizationReferenceChange, let hash = row.newHash else { return }; model.onLog(hash) }
        @objc func compare(_ sender: NSMenuItem) { guard available, let row = sender.representedObject as? SynchronizationReferenceChange, let old = row.oldHash, let new = row.newHash else { return }; model.onReferenceCompare(old, new) }
        @objc func reflog(_ sender: NSMenuItem) { guard available, let row = sender.representedObject as? SynchronizationReferenceChange else { return }; model.onReferenceLog(row.name.rawValue) }
    }
}
