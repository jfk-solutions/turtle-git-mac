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
    case checkout(SynchronizationPullCheckout), merge(GitResult), tags(SynchronizationTagSnapshot), tag(GitResult), deletedRemote(SynchronizationTagSnapshot?, String?)
}
enum SynchronizationProgressOperation: Sendable {
    case checkout(SynchronizationTransportPlan), merge(SynchronizationRebaseState)
    case tags(String), tag(SynchronizationTagAction, SynchronizationTagRow, SynchronizationTagSnapshot, Bool)
    var title: String {
        switch self {
        case .checkout: return "Checkout Progress"
        case .merge: return "Merge Progress"
        case .tags: return "Compare Tags"
        case .tag(let action, _, _, _): return action.title + " Progress"
        }
    }
    var label: String {
        switch self {
        case .checkout(let plan): return "Switch to " + (plan.checkoutBranch ?? plan.options.localBranch)
        case .merge(let state): return "Fast-forward to " + state.target
        case .tags(let remote): return "Loading tags from " + remote
        case .tag(.deleteRemote, _, _, _): return "Deleting remote refs…"
        case .tag(let action, let row, let snapshot, _): return action.title + " – " + row.tag.rawValue + (action == .deleteLocal ? "" : " – " + snapshot.remote)
        }
    }
    var work: String {
        switch self { case .checkout: return "Switching…"; case .merge: return "Merging…"; case .tags: return "Please wait…"; case .tag(.deleteRemote, _, _, _): return "Please wait…"; case .tag: return "Running Git…" }
    }
    var failure: String { title.replacingOccurrences(of: " Progress", with: "") + " failed" }
    var loadingTags: Bool { if case .tags = self { return true }; return false }
    var compactProgress: Bool {
        if loadingTags { return true }
        if case .tag(.deleteRemote, _, _, _) = self { return true }
        return false
    }
}
extension SynchronizationTagAction {
    var title: String {
        switch self { case .fetch: return "Fetch"; case .push: return "Push"; case .deleteLocal: return "Delete local tag"; case .deleteRemote: return "Delete tag on remote" }
    }
}
extension SynchronizationTagKind {
    var title: String {
        switch self { case .same: return "Same"; case .differ: return "Differ"; case .onlyLocal: return "Only local"; case .onlyRemote: return "Only remote" }
    }
}

@MainActor final class SynchronizationProgressController: NSWindowController, NSWindowDelegate {
    let model: SynchronizationProgressModel
    var onClosed: () -> Void = {}
    private var alert: NSAlert?
    private var completion: ((Result<SynchronizationProgressResult, Error>) -> Void)?
    init(repository: GitRepository, operation: SynchronizationProgressOperation, cancellation: OperationCancellation, preferences: UserDefaults, transportFactory: SSHTransportFactory? = nil,
         completion: @escaping (Result<SynchronizationProgressResult, Error>) -> Void) {
        model = SynchronizationProgressModel(repository: repository, operation: operation, cancellation: cancellation, preferences: preferences, transportFactory: transportFactory)
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: operation.compactProgress ? 480 : 760, height: operation.compactProgress ? 170 : 420), styleMask: operation.compactProgress ? [.titled, .closable] : [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – \(operation.title) – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = operation.compactProgress ? NSSize(width: 400, height: 150) : NSSize(width: 560, height: 300)
        window.contentViewController = NSHostingController(rootView: SynchronizationProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in self?.closePresentation() }
        model.confirmCancel = { [weak self] reply in
            guard let self, let window = self.window, window.attachedSheet == nil else { reply(false); return }
            let alert = NSAlert(); alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); self.alert = alert
            alert.beginSheetModal(for: window) { [weak self] response in self?.alert = nil; reply(response == .alertFirstButtonReturn) }
        }
        if !operation.compactProgress { DialogGeometry.attach(window, identifier: "ProgressDlg") }
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
    private let autoClosePolicy: GitProgressAutoClose
    private let transportFactory: SSHTransportFactory?
    private var transportCoordinator: SSHTransportCoordinator?
    private var started = false, closed = false
    @Published private(set) var busy = true
    @Published private(set) var output = ""
    @Published private(set) var confirmingCancellation = false
    private(set) var result: Result<SynchronizationProgressResult, Error>?
    var close: () -> Void = {}
    var confirmCancel: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    init(repository: GitRepository, operation: SynchronizationProgressOperation, cancellation: OperationCancellation, preferences: UserDefaults, transportFactory: SSHTransportFactory? = nil) {
        self.transportFactory = transportFactory; autoClosePolicy = GitProgressAutoClose(preferences: preferences)
        self.repository = repository; self.operation = operation; self.cancellation = cancellation; self.preferences = preferences
    }
    func invalidate() { closed = true; if busy { cancellation.cancel() }; transportCoordinator?.close(); transportCoordinator = nil; busy = false; confirmingCancellation = false }
    func cancel() {
        guard !closed, busy, !confirmingCancellation, !cancellation.isCancelled else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            var answered = false
            confirmCancel { [weak self] accepted in
                guard !answered, let self, !self.closed else { return }; answered = true; self.confirmingCancellation = false
                if accepted, self.busy { self.cancellation.cancel() }
                if !self.busy, self.automaticClose { self.close() }
            }
        } else { cancellation.cancel() }
    }
    private var automaticClose: Bool {
        guard let result else { return false }
        if operation.compactProgress { return true }
        let success: Bool; if case .success = result { success = true } else { success = false }
        if case .tag = operation { return autoClosePolicy.shouldClose(success: success, postActionCount: 0) }
        return success
    }
    func start() {
        guard !started, !closed else { return }; started = true
        Task {
            let coordinator = transportFactory?(); transportCoordinator = coordinator
            defer { coordinator?.close(); transportCoordinator = nil }
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
                case .tags(let remote):
                    return SynchronizationProgressResult.tags(try await repository.synchronizationTags(remote: remote, cancellation: cancellation, prepareTransport: coordinator?.preparation))
                case .tag(let action, let row, let snapshot, let authorized):
                    let command = try await repository.synchronizeTag(action, row: row, snapshot: snapshot, deletionAuthorized: authorized, cancellation: cancellation,
                        onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }, prepareTransport: coordinator?.preparation)
                    if action == .deleteRemote {
                        // The source keeps its system progress dialog open through
                        // Fill. A failed deletion never enters the refill phase.
                        do { return .deletedRemote(try await repository.synchronizationTags(remote: snapshot.remote, cancellation: cancellation, prepareTransport: coordinator?.preparation), nil) }
                        catch { return .deletedRemote(nil, error.localizedDescription) }
                    }
                    return SynchronizationProgressResult.tag(command)
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
            if !confirmingCancellation, automaticClose { close() }
        }
    }
}

private struct SynchronizationProgressDialog: View {
    @ObservedObject var model: SynchronizationProgressModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.operation.label).font(.headline)
            if model.operation.compactProgress {
                Spacer()
            } else {
                SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: { if case .success = model.result { return true }; return false }(), preferences: model.preferences)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text(model.operation.work) } else if case .success = model.result { Text("Finished") } else { Text(model.operation.failure).foregroundStyle(.red) }
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
    private(set) var commandProgress: SynchronizationProgressController?
    private(set) var optionsController: FetchWindowController?
    private(set) var pushOptionsController: PushWindowController?
    var configureOptions: (FetchWindowController) -> Void = { _ in }
    var configurePushOptions: (PushWindowController) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = SynchronizationWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Git Synchronization – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 860, height: 500)
        window.contentViewController = NSHostingController(rootView: SynchronizationDialog(model: model))
        super.init(window: window); window.delegate = self; model.window = window
        model.runPushOptions = { [weak self] source in
            guard let self, !self.model.closed, let owner = self.window, owner.attachedSheet == nil else { throw OperationCancellationFailure.cancelled }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let child = PushWindowController(repository: repository, access: access, preferences: preferences)
                self.configurePushOptions(child)
                var dismissed = false
                child.onClosed = { [weak self, weak child] in
                    guard !dismissed else { return }; dismissed = true
                    if let window = child?.window { window.sheetParent?.endSheet(window) }
                    self?.pushOptionsController = nil; continuation.resume()
                }
                self.pushOptionsController = child
                child.window?.alphaValue = owner.alphaValue
                child.model.load(source: source.isEmpty ? nil : source)
                owner.beginSheet(child.window!)
            }
        }
        model.confirmPushDeletion = { [weak self] destination in
            guard let self, !self.model.closed, let owner = self.window, owner.attachedSheet == nil else { return false }
            let alert = PushWindowController.submissionAlert(message: "The local branch/tag name is empty. This results in removal of \"\(destination)\" on the remote.\nContinue?", allBranches: false, deletion: true)
            alert.window.alphaValue = owner.alphaValue; self.pullAlert = alert
            let response = await alert.beginSheetModal(for: owner)
            if self.pullAlert === alert { self.pullAlert = nil }
            return response == .alertFirstButtonReturn
        }
        model.runOptions = { [weak self] isPull, remote in
            guard let self, !self.model.closed, let owner = self.window, owner.attachedSheet == nil else { throw OperationCancellationFailure.cancelled }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let child = FetchWindowController(repository: repository, access: access, isPull: isPull, preferences: preferences)
                self.configureOptions(child)
                var dismissed = false
                var handoffError: Error?
                child.model.onOwnedRebase = { [weak self, weak child] target, autoStart, preserve in
                    guard let self, !self.model.closed, let child, let options = child.window,
                          options.sheetParent === owner, let progress = child.fetchProgressController?.window,
                          progress.sheetParent === options, progress.attachedSheet == nil else { handoffError = OperationCancellationFailure.cancelled; throw OperationCancellationFailure.cancelled }
                    // Suspend presentation without invalidating the Fetch model:
                    // it owns the pending completion until Rebase is dismissed.
                    options.endSheet(progress); progress.orderOut(nil)
                    owner.endSheet(options); options.orderOut(nil)
                    do { try await self.model.runRebase(target, autoStart, preserve) }
                    catch { handoffError = error; throw error }
                    guard !self.model.closed else { throw OperationCancellationFailure.cancelled }
                }
                child.onClosed = { [weak self, weak child] in
                    guard !dismissed else { return }; dismissed = true
                    if let window = child?.window { window.sheetParent?.endSheet(window) }
                    self?.optionsController = nil
                    if let handoffError { continuation.resume(throwing: handoffError) }
                    else { continuation.resume() }
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
                    case .success: continuation.resume(throwing: SynchronizationFailure.invalidInput)
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
                    case .success: continuation.resume(returning: .failure(SynchronizationFailure.invalidInput))
                    case .failure(let error): continuation.resume(returning: .failure(error))
                    }
                }
                self.commandProgress = child; child.onClosed = { [weak self] in self?.commandProgress = nil }
                child.window?.alphaValue = window.alphaValue; window.beginSheet(child.window!); child.model.start()
            }
        }
        model.performTagOperation = { [weak self] operation, token in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { return .failure(OperationCancellationFailure.cancelled) }
            return await withCheckedContinuation { continuation in
                let child = SynchronizationProgressController(repository: repository, operation: operation, cancellation: token, preferences: preferences, transportFactory: self.model.sshSettings.capture()) { result in
                    continuation.resume(returning: result)
                }
                self.commandProgress = child; child.onClosed = { [weak self] in self?.commandProgress = nil }
                child.window?.alphaValue = window.alphaValue; window.beginSheet(child.window!); child.model.start()
            }
        }
        model.presentTagError = { [weak self] details in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { return }
            let alert = NSAlert(); alert.alertStyle = .critical; alert.messageText = "TurtleGit"; alert.informativeText = details
            alert.addButton(withTitle: "OK"); alert.window.alphaValue = window.alphaValue; self.pullAlert = alert
            _ = await alert.beginSheetModal(for: window)
            if self.pullAlert === alert { self.pullAlert = nil }
        }
        model.confirmTagDeletion = { [weak self] action, row, snapshot in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Delete tag?"
            alert.informativeText = "Do you really want to delete \"\(row.tag.rawValue)\"?" + (action == .deleteRemote ? "\nRemote: \(snapshot.remote)" : "")
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); alert.window.alphaValue = window.alphaValue; self.pullAlert = alert
            let response = await alert.beginSheetModal(for: window)
            if self.pullAlert === alert { self.pullAlert = nil }
            return response == .alertFirstButtonReturn
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
            guard let self, !self.model.closed, !self.model.confirmingQuit, let root = self.window else { return false }
            let window = self.commandProgress?.window ?? root
            guard window.attachedSheet == nil, let child = prompt.window else { return false }
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
        pushOptionsController?.close(); pushOptionsController = nil
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
    @Published private(set) var compareTagsSelected = false
    @Published private(set) var pushAction: SynchronizationTransportAction = .push
    @Published private(set) var comparingTags = false
    @Published private(set) var tagSnapshot: SynchronizationTagSnapshot?
    @Published var hideEqualTags = false
    var performTagOperation: (SynchronizationProgressOperation, OperationCancellation) async -> Result<SynchronizationProgressResult, Error> = { _, _ in .failure(SynchronizationFailure.invalidInput) }
    var presentTagError: (String) async -> Void = { _ in }
    var confirmTagDeletion: (SynchronizationTagAction, SynchronizationTagRow, SynchronizationTagSnapshot) async -> Bool = { _, _, _ in false }
    var tagRows: [SynchronizationTagRow] { (tagSnapshot?.rows ?? []).filter { !hideEqualTags || $0.kind != .same } }
    var confirmCheckout: (String) async -> Bool = { _ in false }
    var askTracking: (String, String, String) async -> SynchronizationTrackingAnswer = { _, _, _ in SynchronizationTrackingAnswer(choice: .cancel) }
    var performCheckout: ((SynchronizationTransportPlan, OperationCancellation) async throws -> SynchronizationPullCheckout)?
    var performFastForward: ((SynchronizationRebaseState, OperationCancellation) async -> Result<GitResult, Error>)?
    var presentRebasePrompt: (FetchRebasePrompt) async -> FetchRebaseAnswer = { prompt in FetchRebaseAnswer(value: prompt.answers[prompt.defaultIndex], suppress: false) }
    var runRebase: (String, Bool, Bool) async throws -> Void = { _, _, _ in throw SynchronizationFailure.invalidInput }
    var detachRebase: () -> Void = {}
    var presentConflictHint: () async -> Bool = { false }
    var runOptions: (Bool, String?) async throws -> Void = { _, _ in throw SynchronizationFailure.invalidInput }
    var runPushOptions: (String) async throws -> Void = { _ in throw SynchronizationFailure.invalidInput }
    var confirmPushDeletion: (String) async -> Bool = { _ in false }
    var onResolve: ([String]) -> Void = { _ in }
    var displayedComparison: RevisionComparisonWindowModel { tab == 5 ? incomingComparison : comparison }
    var historyEntries: [LogEntry] { tab == 4 ? (incomingCommits ?? []) : (outgoing?.commits ?? []) }
    var historyGraph: [CommitGraphRow] { tab == 4 ? incomingGraph : graph }
    var incomingUpToDate: Bool {
        guard let snapshot = incomingComparison.snapshot else { return false }
        return snapshot.from == snapshot.to
    }
    var pullActionTitle: String {
        if compareTagsSelected { return "Compare Tags" }
        switch pullAction {
        case .pull: return "Pull"
        case .fetchAndRebase: return "Fetch & Rebase"
        case .fetchAllBranches: return "Fetch All"
        case .remoteUpdate: return "Remote Update"
        case .prune: return "Cleanup stale remote branches"
        default: return "Fetch"
        }
    }
    var pushActionTitle: String {
        switch pushAction { case .pushTags: return "Push tags"; case .pushNotes: return "Push notes"; default: return "Push" }
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
    var onTagLog: ((String) -> Void)?
    var onTagsChanged: () -> Void = {}
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
        case 6: compareTagsSelected = true
        default: pullAction = .pull
        }
        switch preferences.integer(forKey: historyKey + ".pushAction") {
        case 1: pushAction = .pushTags
        case 2: pushAction = .pushNotes
        default: pushAction = .push
        }
        branchHistory = preferences.stringArray(forKey: historyKey + ".branches") ?? []
        urlHistory = preferences.stringArray(forKey: historyKey + ".urls") ?? []
        sshSettings.load(preferences, key: historyKey + ".autoload")
        hideUnchangedReferences = preferences.bool(forKey: "RefCompareHideUnchanged")
        hideEqualTags = preferences.bool(forKey: "TagCompareHideEqual")
    }
    var status: String {
        if transportRunning { return cancelling ? "Cancelling…" : (currentWork.isEmpty ? "Running Git…" : currentWork) }
        if busy { return "Loading…" }
        if let error { return error }
        if comparingTags { return "\(tagRows.count) tags" }
        switch outgoing?.disposition {
        case .unknownURL: return "Outgoing commits are unknown for a URL."
        case .unknownRemoteBranch: return "Remote branch is unknown."
        case .upToDate: return "Up to date."
        case .needsForce: return "Local branch is not a fast-forward of the remote branch. Enable Force to show outgoing changes."
        case .outgoing: return "\(outgoing?.commits.count ?? 0) outgoing commits"
        case nil: return ""
        }
    }
    func invalidate() { closed = true; token?.cancel(); token = nil; comparison.invalidate(); incomingComparison.invalidate(); busy = false; transportRunning = false; cancelling = false; confirmingCancellation = false; cancellationQuestion = nil; transportID = nil }
    func reload(selectTracking: Bool = false, initial: Bool = false, preserveError: Bool = false) {
        guard !closed, !confirmingQuit, !transportRunning, !hasBlockingChild else { return }
        token?.cancel()
        comparingTags = false; tagSnapshot = nil; if tab == 7 { tab = 0 }
        let retainedError = preserveError ? error : nil
        let request = OperationCancellation(); token = request; busy = true; error = retainedError
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
                self.error = retainedError ?? error.localizedDescription
            }
        }
    }
    func performPullAction(_ action: SynchronizationTransportAction? = nil, shift: Bool = NSEvent.modifierFlags.contains(.shift)) {
        if action == nil, compareTagsSelected { compareTags(shift: shift) }
        else { fetch(action ?? pullAction, shift: shift) }
    }
    func refresh() { if comparingTags { compareTags() } else { reload() } }
    func compareTags(shift: Bool = false) {
        guard !closed, !confirmingQuit, !busy, !hasBlockingChild, window?.attachedSheet == nil else { return }
        compareTagsSelected = true; preferences.set(6, forKey: historyKey + ".pullAction")
        if shift { return }
        let request = OperationCancellation(); token = request; busy = true; transportRunning = true
        comparingTags = true; tagSnapshot = nil; tab = 7; error = nil; commandOutput = ""; referenceChanges = []
        incomingCommits = nil; incomingGraph = []; incomingComparison.snapshot = nil; conflicts = []
        let selectedRemote = remote
        sshSettings.save(preferences, key: historyKey + ".autoload")
        Task {
            defer { if token === request { token = nil; busy = false; transportRunning = false } }
            do {
                try checkTagAccess()
                _ = try await repository.run(["rev-parse", "--verify", "HEAD"], cancellation: request)
                if request.isCancelled { throw OperationCancellationFailure.cancelled }
                guard !closed, token === request else { return }
                let result = await performTagOperation(.tags(selectedRemote), request)
                guard !closed, token === request, !request.isCancelled else { return }
                switch result {
                case .success(.tags(let snapshot)): tagSnapshot = snapshot
                case .failure(let failure): error = failure.localizedDescription; await presentTagError(failure.localizedDescription)
                default: error = SynchronizationFailure.invalidInput.localizedDescription
                }
            } catch { if !closed, token === request { self.error = error.localizedDescription } }
        }
    }
    private func checkTagAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func performTag(_ action: SynchronizationTagAction, row: SynchronizationTagRow) {
        guard !closed, !confirmingQuit, !busy, !hasBlockingChild, window?.attachedSheet == nil,
              let snapshot = tagSnapshot, snapshot.rows.contains(row), row.allows(action) else { return }
        let request = OperationCancellation(); token = request; busy = true; transportRunning = true; error = nil
        let factory = sshSettings.capture()
        sshSettings.save(preferences, key: historyKey + ".autoload")
        Task {
            let coordinator = action == .deleteLocal ? factory?() : nil
            defer { coordinator?.close() }
            var finalRequest = request
            defer { if token === finalRequest { token = nil; busy = false; transportRunning = false } }
            do {
                try checkTagAccess()
                if action == .deleteLocal || action == .deleteRemote {
                    let accepted = await confirmTagDeletion(action, row, snapshot)
                    guard !closed, token === request, !request.isCancelled, accepted else { return }
                }
                let result: Result<SynchronizationProgressResult, Error>
                if action == .deleteLocal {
                    // The source deletes locally without a command progress dialog.
                    do { result = .success(.tag(try await repository.synchronizeTag(.deleteLocal, row: row, snapshot: snapshot, deletionAuthorized: true, cancellation: request))) }
                    catch { result = .failure(error) }
                } else {
                    result = await performTagOperation(.tag(action, row, snapshot, action == .deleteRemote), request)
                }
                guard !closed, token === request else { return }
                onTagsChanged()
                if case .failure(let failure) = result {
                    error = failure.localizedDescription
                    // Upstream remote deletion returns immediately on failure.
                    if action == .deleteRemote { await presentTagError(failure.localizedDescription); return }
                }
                if case .success(.deletedRemote(let updated, let failure)) = result {
                    tagSnapshot = updated; error = failure
                    if let failure { await presentTagError(failure) }
                    return
                }
                // Fetch/Push refill after their progress closes, even after failure
                // or cancellation, since Git may already have changed a tag.
                let refresh = OperationCancellation(); finalRequest = refresh; token = refresh; tagSnapshot = nil
                let updated: Result<SynchronizationProgressResult, Error>
                if action == .deleteLocal {
                    // Fill after local deletion also has no system progress dialog.
                    do { updated = .success(.tags(try await repository.synchronizationTags(remote: snapshot.remote, cancellation: refresh, prepareTransport: coordinator?.preparation))) }
                    catch { updated = .failure(error) }
                } else { updated = await performTagOperation(.tags(snapshot.remote), refresh) }
                guard !closed, token === refresh, !refresh.isCancelled else { return }
                switch updated {
                case .success(.tags(let snapshot)): tagSnapshot = snapshot
                case .failure(let failure): error = error ?? failure.localizedDescription; await presentTagError(failure.localizedDescription)
                default: error = error ?? SynchronizationFailure.invalidInput.localizedDescription
                }
            } catch { if !closed, token === finalRequest { self.error = error.localizedDescription } }
        }
    }
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
        pullAction = action; compareTagsSelected = false
        let actionIndex = action == .pull ? 0 : action == .fetch ? 1 : action == .fetchAndRebase ? 2 : action == .fetchAllBranches ? 3 : action == .remoteUpdate ? 4 : 5
        preferences.set(actionIndex, forKey: historyKey + ".pullAction")
        if shift && action != .pull && action != .fetch { return }
        runTransport(action, shift: shift)
    }
    func push(_ action: SynchronizationTransportAction? = nil, shift: Bool = NSEvent.modifierFlags.contains(.shift)) {
        let selected = action ?? pushAction
        guard [.push, .pushTags, .pushNotes].contains(selected), !closed, !confirmingQuit, !confirmingCancellation,
              !busy, !hasBlockingChild, window?.attachedSheet == nil else { return }
        pushAction = selected
        if shift {
            // Source only opens full options for Push; tags/notes ignore Shift
            // without changing the persisted split selection or running Git.
            guard selected == .push else { return }
            let request = OperationCancellation(); token = request; busy = true; transportRunning = true; cancelling = false; error = nil
            let source = PushSourcePresentation.normalized(localBranch)
            Task {
                defer { if token === request { token = nil; busy = false; transportRunning = false; cancelling = false } }
                do {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let before = try await repository.synchronizationReferenceSnapshot(cancellation: request)
                    guard !closed, token === request, !request.isCancelled else { return }
                    try await runPushOptions(source)
                    guard !closed, token === request, !request.isCancelled else { return }
                    let after = try await repository.synchronizationReferenceSnapshot(cancellation: request)
                    let rows = try await repository.synchronizationReferenceChanges(from: before, to: after, cancellation: request)
                    guard !closed, token === request, !request.isCancelled else { return }
                    referenceChanges = rows
                    busy = false; transportRunning = false; token = nil
                    onTransportFinished(commandOutput); reload(preserveError: true)
                } catch { if !closed, token === request { self.error = error.localizedDescription } }
            }
        } else { runTransport(selected, shift: false) }
    }
    private func runTransport(_ action: SynchronizationTransportAction, shift: Bool) {
        let pushing = [.push, .pushTags, .pushNotes].contains(action)
        comparingTags = false; tagSnapshot = nil
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
                }
                if action == .pull || action == .push && !options.localBranch.isEmpty {
                    if !options.remote.contains("/"), !options.remote.contains("\\"),
                       preferences.object(forKey: "AskSetTrackedBranch") == nil || preferences.bool(forKey: "AskSetTrackedBranch") {
                        let tracking = try await repository.synchronizationBranches(localBranch: options.localBranch, cancellation: request)
                        if tracking.trackedBranch.isEmpty {
                            let destination = plan.options.remoteBranch.isEmpty ? options.localBranch : plan.options.remoteBranch
                            let answer = await askTracking(options.localBranch, options.remote, destination)
                            guard !closed, token === request else { return }
                            if answer.suppress { preferences.set(false, forKey: "AskSetTrackedBranch") }
                            guard answer.choice != .cancel, !request.isCancelled else { throw OperationCancellationFailure.cancelled }
                            if answer.choice == .yes {
                                var branch = destination
                                if let short = GitReferenceName.removingPrefix("refs/heads/", from: branch) { branch = short }
                                else if let short = GitReferenceName.removingPrefix("refs/", from: branch) { branch = short }
                                _ = try await repository.run(["config", "--local", "branch." + options.localBranch + ".remote", options.remote], cancellation: request)
                                _ = try await repository.run(["config", "--local", "branch." + options.localBranch + ".merge", "refs/heads/" + branch], cancellation: request)
                            }
                        }
                    }
                }
                let deletionAuthorized: Bool
                if plan.deletesDestination {
                    deletionAuthorized = await confirmPushDeletion(plan.options.remoteBranch)
                    guard deletionAuthorized, !closed, token === request, !request.isCancelled else { throw OperationCancellationFailure.cancelled }
                } else { deletionAuthorized = false }
                if pushing { preferences.set(action == .push ? 0 : action == .pushTags ? 1 : 2, forKey: historyKey + ".pushAction") }
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
                        return try await repository.synchronize(plan, deletionAuthorized: deletionAuthorized, cancellation: request,
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
            if let oldHead, action == .pull || shift && !pushing || incomingRevision != nil {
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
            reload(preserveError: true)
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
                if model.comparingTags { Text("Compare Tags").tag(7) }
                else {
                Text("Outgoing Commits").tag(0); Text("Outgoing Changes").tag(1); Text("Command Log").tag(2); Text("Ref changes").tag(3)
                if model.incomingCommits != nil { Text("Incoming Commits").tag(4) }
                if model.incomingComparison.snapshot?.files.isEmpty == false { Text("Incoming Changes").tag(5) }
                if !model.conflicts.isEmpty { Text("Conflicts").tag(6) }
                }
            }.pickerStyle(.segmented)
            if model.tab == 7 {
                SynchronizationTagTable(model: model)
                    .overlay { if model.tagRows.isEmpty { Text(model.busy ? "Please wait…" : "No differences found.").foregroundStyle(.secondary).allowsHitTesting(false) } }
            } else if model.tab == 3 {
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
                    Button { model.performPullAction() } label: { CommandLabel(title: model.pullActionTitle, icon: model.compareTagsSelected ? .tag : model.pullAction == .pull ? .pull : .fetch) }
                    Menu {
                        Button { model.performPullAction(.pull) } label: { CommandLabel(title: "Pull", icon: .pull) }
                        Button { model.performPullAction(.fetch) } label: { CommandLabel(title: "Fetch", icon: .fetch) }
                        Button { model.performPullAction(.fetchAndRebase) } label: { CommandLabel(title: "Fetch & Rebase", icon: .rebase) }
                        Button { model.performPullAction(.fetchAllBranches) } label: { CommandLabel(title: "Fetch All", icon: .fetch) }
                        Button { model.performPullAction(.remoteUpdate) } label: { CommandLabel(title: "Remote Update", icon: .fetch) }
                        Button { model.performPullAction(.prune) } label: { CommandLabel(title: "Cleanup stale remote branches", icon: .clean) }
                        Button { model.compareTags(shift: NSEvent.modifierFlags.contains(.shift)) } label: { CommandLabel(title: "Compare Tags", icon: .tag) }
                    } label: { Text("").accessibilityLabel("Pull actions") }.menuStyle(.borderlessButton).fixedSize()
                }.disabled(model.busy || model.hasBlockingChild)
                HStack(spacing: 0) {
                    Button { model.push() } label: { CommandLabel(title: model.pushActionTitle, icon: .push) }
                    Menu {
                        Button { model.push(.push) } label: { CommandLabel(title: "Push", icon: .push) }
                        Button { model.push(.pushTags) } label: { CommandLabel(title: "Push tags", icon: .tag) }
                        Button { model.push(.pushNotes) } label: { CommandLabel(title: "Push notes", icon: .push) }
                    } label: { Text("").accessibilityLabel("Push actions") }.menuStyle(.borderlessButton).fixedSize()
                }.disabled(model.busy || model.hasBlockingChild)
                Button { model.onLog(model.localBranch) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(model.busy || model.localBranch.isEmpty)
                Button { model.onCommit() } label: { CommandLabel(title: "Commit", icon: .commit) }.disabled(model.busy)
                Button("Refresh") { model.refresh() }.disabled(model.transportRunning || model.hasBlockingChild)
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

private struct SynchronizationTagTable: NSViewRepresentable {
    @ObservedObject var model: SynchronizationWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = SynchronizationReferenceNativeTable(); table.rowHeight = 24
        let titles = ["Tag", "Status", "Local hash", "Local message", "Remote hash", "Remote message"]
        for (index, title) in titles.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = title; column.width = [180.0, 100, 100, 200, 100, 200][index]
            column.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: true)
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        if model.preferences.bool(forKey: "SortTagsReversed") { table.sortDescriptors = [NSSortDescriptor(key: "0", ascending: false)] }
        let header = SynchronizationReferenceHeader(); header.makeMenu = { [weak coordinator = context.coordinator] in coordinator?.headerMenu() }; table.headerView = header
        table.makeMenu = { [weak table, weak coordinator = context.coordinator] in coordinator?.rowMenu(table?.selectedRow ?? -1) }
        if model.preferences === UserDefaults.standard { table.autosaveName = "TurtleGit.SyncTags.Columns"; table.autosaveTableColumns = true }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = table
        context.coordinator.table = table; context.coordinator.reload(); return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.model = model; context.coordinator.reload() }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: SynchronizationWindowModel
        weak var table: NSTableView?
        var rows: [SynchronizationTagRow] = []
        init(_ model: SynchronizationWindowModel) { self.model = model }
        private func field(_ row: SynchronizationTagRow, _ column: Int) -> String {
            switch column {
            case 0: return row.name.rawValue
            case 1: return row.kind.title
            case 2: return row.localHash ?? ""
            case 3: return row.localMessage
            case 4: return row.remoteHash ?? ""
            default: return row.remoteMessage
            }
        }
        func reload() {
            let selected = table.flatMap { rows.indices.contains($0.selectedRow) ? rows[$0.selectedRow].id : nil }
            let descriptor = table?.sortDescriptors.first, column = Int(descriptor?.key ?? "0") ?? 0
            let logical = !model.preferences.bool(forKey: "NoStrCmpLogical")
            rows = model.tagRows.enumerated().sorted { a, b in
                let lhs = field(a.element, column), rhs = field(b.element, column)
                let order = logical && [0, 3, 5].contains(column) ? lhs.localizedStandardCompare(rhs) : lhs.compare(rhs, options: .literal)
                if order == .orderedSame { return a.offset < b.offset }
                return descriptor?.ascending == false ? order == .orderedDescending : order == .orderedAscending
            }.map(\.element)
            table?.reloadData()
            if let selected, let index = rows.firstIndex(where: { $0.id == selected }) { table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            else { table?.deselectAll(nil) }
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { reload() }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let index = Int(column?.identifier.rawValue ?? "") else { return nil }
            let value = field(rows[row], index)
            let text = NSTextField(labelWithString: [2, 4].contains(index) ? String(value.prefix(8)) : value)
            text.lineBreakMode = .byTruncatingTail; text.toolTip = value
            return text
        }
        private var available: Bool { !model.closed && !model.busy && !model.confirmingQuit && !model.confirmingCancellation && !model.hasBlockingChild }
        func headerMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            let item = NSMenuItem(title: "Hide unchanged", action: #selector(toggleEqual), keyEquivalent: "")
            item.target = self; item.state = model.hideEqualTags ? .on : .off; item.isEnabled = available; menu.addItem(item); return menu
        }
        @objc func toggleEqual() { guard available else { return }; model.hideEqualTags.toggle() }
        func rowMenu(_ index: Int) -> NSMenu? {
            guard rows.indices.contains(index) else { return nil }
            let row = rows[index], menu = NSMenu(); menu.autoenablesItems = false
            func add(_ title: String, _ selector: Selector, _ icon: MenuIcon) {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self
                item.representedObject = row; item.isEnabled = available
                item.image = MenuPresentationSettings.applicationContextIcons(defaults: model.preferences) ? icon.image() : nil
                menu.addItem(item)
            }
            if let hash = row.localHash { add("Show log of " + String(hash.prefix(8)), #selector(localLog(_:)), .log) }
            if row.kind != .same {
                if let hash = row.remoteHash { add("Show log of " + String(hash.prefix(8)), #selector(remoteLog(_:)), .log) }
                if row.localHash != nil, row.remoteHash != nil { add("Compare with previous revision", #selector(compare(_:)), .compare) }
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                if row.allows(.fetch) { add("Fetch", #selector(fetch(_:)), .fetch) }
                if row.allows(.push) { add("Push", #selector(push(_:)), .commit) }
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            if row.allows(.deleteLocal) { add("Delete local tag", #selector(deleteLocal(_:)), .remove) }
            if row.allows(.deleteRemote) { add("Delete tag on remote", #selector(deleteRemote(_:)), .remove) }
            return menu
        }
        private func current(_ sender: NSMenuItem) -> SynchronizationTagRow? {
            guard available, let row = sender.representedObject as? SynchronizationTagRow, model.tagSnapshot?.rows.contains(row) == true else { return nil }; return row
        }
        @objc func localLog(_ sender: NSMenuItem) { guard let row = current(sender), let hash = row.localHash else { return }; (model.onTagLog ?? model.onLog)(hash) }
        @objc func remoteLog(_ sender: NSMenuItem) { guard let row = current(sender), let hash = row.remoteHash else { return }; (model.onTagLog ?? model.onLog)(hash) }
        @objc func compare(_ sender: NSMenuItem) { guard let row = current(sender), let local = row.localHash, let remote = row.remoteHash else { return }; model.onReferenceCompare(local, remote) }
        @objc func fetch(_ sender: NSMenuItem) { guard let row = current(sender) else { return }; model.performTag(.fetch, row: row) }
        @objc func push(_ sender: NSMenuItem) { guard let row = current(sender) else { return }; model.performTag(.push, row: row) }
        @objc func deleteLocal(_ sender: NSMenuItem) { guard let row = current(sender) else { return }; model.performTag(.deleteLocal, row: row) }
        @objc func deleteRemote(_ sender: NSMenuItem) { guard let row = current(sender) else { return }; model.performTag(.deleteRemote, row: row) }
    }
}
