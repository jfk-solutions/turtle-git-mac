// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
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
extension SynchronizationStashAction {
    var title: String { switch self { case .save: return "Stash changes"; case .pop: return "Stash pop"; case .apply: return "Stash apply" } }
    var icon: MenuIcon { self == .save ? .stash : .stashPop }
}
extension SynchronizationSubmoduleAction {
    var title: String {
        switch self { case .update: return "Submodule Update"; case .initialize: return "Submodule Init"; case .sync: return "Submodule Sync" }
    }
    var icon: MenuIcon {
        switch self { case .update: return .fetch; case .initialize: return .add; case .sync: return .sync }
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
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "\(operation.title)", preferences: preferences)
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
    let progressPresentation: GitCommandPresentation
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
        self.repository = repository; self.operation = operation; self.cancellation = cancellation; self.preferences = preferences; progressPresentation = GitCommandPresentation(defaults: preferences)
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
            if let result {
                let succeeded: Bool
                if case .success = result { succeeded = true } else { succeeded = false }
                OperationSounds.report(failed: !succeeded, preferences: preferences)
            }
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
                if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity); Text(model.operation.work) } else if case .success = model.result { Text("Finished") } else { Text(model.operation.failure).foregroundStyle(.red) }
                Spacer()
                if model.busy { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.confirmingCancellation)
        }.padding(12)
    }
}

enum SynchronizationHistoryOperation: Equatable {
    case merge(String), reset(String), checkout(String), switchBranch(String)
    case editNotes(String), revert([LogEntry], Int?), combine([LogEntry], Int, String)
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.merge(let a), .merge(let b)), (.reset(let a), .reset(let b)), (.checkout(let a), .checkout(let b)), (.switchBranch(let a), .switchBranch(let b)), (.editNotes(let a), .editNotes(let b)): return a == b
        case (.revert(let a, let x), .revert(let b, let y)): return a.map(\.hash) == b.map(\.hash) && x == y
        case (.combine(let a, let x, let h), .combine(let b, let y, let j)): return a.map(\.hash) == b.map(\.hash) && x == y && h == j
        default: return false
        }
    }
}

@MainActor final class SynchronizationWindowController: NSWindowController, NSWindowDelegate {
    var configureExport: (ExportWindowController) -> Void = { _ in }
    private static var placementSequence = 0
    let model: SynchronizationWindowModel
    var onClosed: () -> Void = {}
    private var cancellationAlert: NSAlert?
    private var pullAlert: NSAlert?
    private var historyDeletionAlert: NSAlert?
    private var historyDeletionAnswer: ((Int) -> Void)?
    private(set) var commandProgress: SynchronizationProgressController?
    private(set) var optionsController: FetchWindowController?
    private(set) var pushOptionsController: PushWindowController?
    private(set) var remoteSettingsController: RemoteSettingsWindowController?
    private(set) var importPatchController: ImportPatchWindowController?
    private(set) var emailWorkflow: SendMailWorkflow?
    private var emailAlert: NSAlert?
    private(set) var branchPicker: ReferenceBrowserWindowController?
    private var branchPickerRequest: UUID?
    private var branchPickerCompletion: (() -> Void)?
    private weak var branchPickerFocus: NSResponder?
    var configureBranchPicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var configureHistoryReference: (BranchTagWindowController) -> Void = { _ in }
    private(set) var historyReferenceController: BranchTagWindowController?
    private(set) var historyExportController: ExportWindowController?
    private(set) var historyOperationController: NSWindowController?
    var configureHistoryOperation: (NSWindowController) -> Void = { _ in }
    var configureHistoryContainingReferences: (CommitContainingReferencesWindowController) -> Void = { _ in }
    private(set) var historyContainingReferences: [UUID: CommitContainingReferencesWindowController] = [:]
    private(set) var historyFind: [Int: RevisionGraphFindController] = [:]
    private var historyFindAvailability: AnyCancellable?
    var configureOptions: (FetchWindowController) -> Void = { _ in }
    var configurePushOptions: (PushWindowController) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = SynchronizationWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Git Synchronization", preferences: preferences)
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 860, height: 500)
        window.contentViewController = NSHostingController(rootView: SynchronizationDialog(model: model))
        super.init(window: window); window.delegate = self; model.window = window
        model.clientHooks.windowProvider = { [weak window] in window?.attachedSheet ?? window }
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
        model.historyReferencesBlocking = { [weak self] in
            guard let self else { return false }
            return self.historyContainingReferences.values.contains { $0.hasBlockingChild }
                || self.historyFind.values.contains { $0.acknowledgingFailure || $0.window?.attachedSheet != nil }
        }
        model.confirmHistoryDeletion = { [weak self] request in
            guard let self else { return .abort }
            let selected = await self.historyDeletionQuestion(request.message, detail: "", buttons: request.choices.map(\.title), defaultIndex: request.choices.count - 1)
            return request.choices.indices.contains(selected) ? request.choices[selected].choice : .abort
        }
        model.acknowledgeHistoryDeletionFailure = { [weak self] message in
            _ = await self?.historyDeletionQuestion("Could not delete reference.", detail: message, buttons: ["OK"], defaultIndex: 0)
        }
        model.onHistoryOperation = { [weak self] action in self?.showHistoryOperation(action) }
        model.onHistoryFind = { [weak self] tab, index in self?.showHistoryFind(sourceTab: tab, selectionIndex: index) }
        model.onHistoryExport = { [weak self] revision in
            guard let self, !self.model.closed, !self.model.busy, !self.model.confirmingQuit,
                  !self.model.confirmingCancellation, !self.model.hasBlockingChild,
                  self.historyExportController == nil, let parent = self.window, parent.attachedSheet == nil else { return }
            let child = ExportWindowController(repository: self.model.repository, access: self.model.access, revision: revision, preferences: self.model.preferences)
            self.configureExport(child)
            self.historyExportController = child; self.model.exportingHistory = true
            child.onClosed = { [weak self, weak child, weak parent] in
                if let window = child?.window, window.sheetParent === parent { parent?.endSheet(window) }
                guard let self, self.historyExportController === child else { return }
                self.historyExportController = nil; self.model.exportingHistory = false
            }
            if let window = child.window {
                window.alphaValue = parent.alphaValue; window.appearance = parent.appearance
                parent.beginSheet(window)
            }
        }
        historyFindAvailability = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.historyFind.values.forEach { $0.updateAvailability() } }
        }
        model.onHistoryContainingReferences = { [weak self] hash, sourceTab in
            guard let self, !self.model.closed, !self.model.busy, !self.model.confirmingQuit,
                  !self.model.confirmingCancellation, !self.model.hasBlockingChild,
                  let owner = self.window, owner.attachedSheet == nil, !hash.isEmpty else { return }
            let id = UUID()
            let child = CommitContainingReferencesWindowController(repository: self.model.repository, access: self.model.access, revision: hash, preferences: self.model.preferences)
            self.configureHistoryContainingReferences(child)
            child.onNavigate = { [weak self, weak child] hash, select in
                guard let self, let child, !child.closed, !self.model.closed, !self.model.busy, !self.model.confirmingQuit,
                      !self.model.confirmingCancellation, !self.model.hasBlockingChild else { return }
                let entries = sourceTab == 4 ? (self.model.incomingCommits ?? []) : (self.model.outgoing?.commits ?? [])
                guard entries.contains(where: { $0.hash == hash }) else {
                    child.status.stringValue = "The reference is not visible in " + (sourceTab == 4 ? "In Commits." : "Out Commits.")
                    return
                }
                child.status.stringValue = ""
                if !select { self.model.historyHighlights[sourceTab] = hash }
                self.model.historyNavigation[sourceTab] = (UUID(), hash, select)
            }
            child.onClosed = { [weak self, weak child, weak owner] in
                if let window = child?.window { owner?.removeChildWindow(window) }
                self?.historyContainingReferences.removeValue(forKey: id)
            }
            self.historyContainingReferences[id] = child
            if let window = child.window {
                window.alphaValue = owner.alphaValue; window.appearance = owner.appearance
                owner.addChildWindow(window, ordered: .above); window.center(); window.orderFront(nil)
                window.makeFirstResponder(child.revision)
            }
            child.refresh()
        }
        model.onHistoryCreateReference = { [weak self] isTag, revision in
            guard let self, !self.model.closed, !self.model.busy, !self.model.confirmingQuit,
                  !self.model.hasBlockingChild, let owner = self.window, owner.attachedSheet == nil,
                  self.historyReferenceController == nil else { return }
            let child = BranchTagWindowController(repository: self.model.repository, access: self.model.access, isTag: isTag, preferences: self.model.preferences)
            self.configureHistoryReference(child)
            var created = false
            let onCreated = child.model.onCreated
            child.model.onCreated = { [weak self] output in
                created = true; onCreated(output)
                // The standalone creation path reports after closing; the native
                // switch handoff reports before closing. Refresh once for either.
                if let self, self.historyReferenceController == nil, !self.model.closed { self.model.refresh() }
            }
            child.onClosed = { [weak self, weak child] in
                guard let self else { return }
                if let window = child?.window, window.sheetParent === self.window { self.window?.endSheet(window) }
                self.historyReferenceController = nil; self.model.creatingHistoryReference = false
                if created && !self.model.closed { self.model.refresh() }
            }
            self.historyReferenceController = child; self.model.creatingHistoryReference = true
            child.model.load(revision: revision)
            owner.beginSheet(child.window!)
        }
        model.presentHistoryNotice = { [weak self] message in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = message
            alert.addButton(withTitle: "OK"); self.pullAlert = alert
            _ = await alert.beginSheetModal(for: window)
            if self.pullAlert === alert { self.pullAlert = nil }
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
        model.onApplyPatch = { [weak self] oldHead in self?.showImportPatch(oldHead: oldHead) }
        model.onEmailPatches = { [weak self] files in self?.showEmailPatches(files) }
        model.onEmailMessage = { [weak self] title, message in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { return }
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "OK")
            self.emailAlert = alert
            alert.beginSheetModal(for: window) { [weak self, weak alert] _ in
                if self?.emailAlert === alert { self?.emailAlert = nil }
            }
        }
        model.onBrowseBranch = { [weak self] target in self?.showBranchPicker(target) }
        model.onManageRemotes = { [weak self] in self?.showRemoteSettings() }
        model.comparison.window = window; model.incomingComparison.window = window; window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(branchPickerSheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        DialogGeometry.attach(window, identifier: "SyncDlg", legacyName: "SyncDlg")
        if model.preferences.bool(forKey: "SyncDialogRandomPos"), Self.placementSequence > 0 {
            let offset = CGFloat(Self.placementSequence % 5) * 30
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
            var origin = window.frame.origin; origin.y += offset
            if origin.y + window.frame.height > visible.maxY { origin.y -= 150 }
            origin.y = max(visible.minY, min(origin.y, visible.maxY - window.frame.height))
            origin.x = max(visible.minX, min(origin.x, visible.maxX - window.frame.width))
            window.setFrameOrigin(origin)
        }
        Self.placementSequence += 1
    }
    func showImportPatch(oldHead: String) {
        guard !model.closed, !model.confirmingQuit, !model.busy, !model.hasBlockingChild,
              let owner = window, owner.attachedSheet == nil, importPatchController == nil else { return }
        owner.makeFirstResponder(nil)
        let child = ImportPatchWindowController(repository: model.repository, access: model.access, preferences: model.preferences)
        importPatchController = child; model.importingPatches = true
        child.model.onChanged = { [weak self] output in
            guard let self, !self.model.closed else { return }; self.model.onTransportFinished(output)
        }
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.importPatchController === child else { return }
            self.importPatchController = nil; self.model.importingPatches = false
            if child.model.accepted { self.model.finishPatchImport(oldHead: oldHead) }
        }
        guard let window = child.window else { child.close(); importPatchController = nil; model.importingPatches = false; return }
        window.alphaValue = owner.alphaValue; owner.beginSheet(window)
    }
    private func showEmailPatches(_ files: [URL]) {
        guard !model.closed, !model.confirmingQuit, !model.busy, !model.hasBlockingChild,
              !files.isEmpty, let owner = window, owner.attachedSheet == nil, emailWorkflow == nil else { return }
        owner.makeFirstResponder(nil); model.emailingPatches = true
        let workflow = SendMailWorkflow(files: files, repository: model.repository, access: model.access,
            fileAccess: [model.access].compactMap { $0 }, preferences: model.preferences,
            presentation: { [weak self] child in
                guard let self, !self.model.closed, let owner = self.window, let window = child.window else { child.close(); return }
                // Send Mail submits before closing its options window. Detach
                // that sheet before presenting the owned result/progress sheet.
                if let old = owner.attachedSheet, old.delegate is SendPatchWindowController { owner.endSheet(old); old.orderOut(nil) }
                guard owner.attachedSheet == nil else { child.close(); return }
                let dismissed: () -> Void = { [weak window] in
                    guard let window else { return }; window.sheetParent?.endSheet(window)
                }
                if let options = child as? SendPatchWindowController {
                    let original = options.onClosed; options.onClosed = { dismissed(); original() }
                } else if let progress = child as? SendPatchProgressWindowController {
                    let original = progress.onClosed; progress.onClosed = { dismissed(); original() }
                }
                window.alphaValue = owner.alphaValue; owner.beginSheet(window)
            }) { [weak self] _ in
                guard let self, !self.model.closed else { return }
                self.emailWorkflow = nil; self.model.emailingPatches = false
            }
        emailWorkflow = workflow; workflow.start()
    }
    @objc private func branchPickerSheetEnded() {
        guard !model.closed, let window, window.attachedSheet == nil, let completion = branchPickerCompletion else { return }
        branchPickerCompletion = nil; branchPickerRequest = nil; model.choosingBranch = false
        if let focus = branchPickerFocus { window.makeFirstResponder(focus) }; branchPickerFocus = nil
        completion()
    }
    func showBranchPicker(_ target: SynchronizationBranchTarget) {
        guard !model.closed, !model.confirmingQuit, !model.busy, !model.hasBlockingChild,
              let owner = window, owner.attachedSheet == nil, branchPicker == nil, branchPickerRequest == nil else { return }
        branchPickerFocus = (owner.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSResponder : $0 } ?? owner.firstResponder
        let request = UUID(), values = [model.localBranch, model.remote, model.remoteBranch].map { GitReferenceName($0) }
        branchPickerRequest = request
        let initial = target == .local ? "refs/heads/" + model.localBranch : RemoteTrackingSelection.initialReference(remote: model.remote, branch: model.remoteBranch)
        let child = ReferenceBrowserWindowController(repository: model.repository, access: model.access, initial: initial,
            preferences: model.preferences, scope: target == .local ? .heads : .remotes) { [weak self] reference in
                guard let self, !self.model.closed, self.branchPickerRequest == request else { return }
                self.branchPicker = nil
                self.branchPickerCompletion = { [weak self] in
                    guard let self, !self.model.closed,
                          [self.model.localBranch, self.model.remote, self.model.remoteBranch].map({ GitReferenceName($0) }) == values,
                          let reference else { return }
                    self.model.applyBranchSelection(reference, target: target)
                }
                self.branchPickerSheetEnded()
            }
        branchPicker = child; model.choosingBranch = true; configureBranchPicker(child.model)
        guard let window = child.window else { branchPicker = nil; branchPickerRequest = nil; model.choosingBranch = false; child.abandonPresentation(); return }
        window.alphaValue = owner.alphaValue; window.appearance = owner.appearance; owner.beginSheet(window); child.model.load()
    }
    func showRemoteSettings() {
        guard !model.closed, !model.confirmingQuit, !model.busy, !model.hasBlockingChild,
              let owner = window, owner.attachedSheet == nil, remoteSettingsController == nil else { return }
        owner.makeFirstResponder(nil)
        let child = RemoteSettingsWindowController(repository: model.repository, access: model.access, preferences: model.preferences)
        remoteSettingsController = child; model.managingRemotes = true
        child.configureFetch = configureOptions
        child.presentFetch = { owner, window in
            guard owner.attachedSheet == nil else { return false }
            window.alphaValue = owner.alphaValue; owner.beginSheet(window); return true
        }
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.remoteSettingsController === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.remoteSettingsController = nil; self.model.managingRemotes = false
            // Upstream Refresh reloads outgoing results after the modal settings
            // page closes, including dismissal without edits.
            if !self.model.closed { self.model.reload(refreshRemoteSelection: true) }
        }
        guard let window = child.window else { remoteSettingsController = nil; model.managingRemotes = false; return }
        window.alphaValue = owner.alphaValue; owner.beginSheet(window); child.model.load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.transportRunning, !model.confirmingCancellation, !model.hasBlockingChild, sender.attachedSheet == nil else { return false }
        if let child = [model.comparison, model.incomingComparison].flatMap({ Array($0.comparisonWindows.values) }).first(where: { $0.model.dirty }) {
            child.window?.makeKeyAndOrderFront(nil); child.window?.performClose(nil); return false
        }
        model.saveHistory()
        return true
    }
    private var canHistoryFind: Bool {
        !model.closed && !model.busy && !model.confirmingQuit && !model.confirmingCancellation
            && !model.hasBlockingChild && window?.attachedSheet == nil
    }
    func showHistoryFind(sourceTab: Int, selectionIndex: Int? = nil, regexExecutable: URL? = nil) {
        guard [0, 4].contains(sourceTab), canHistoryFind, let parent = window else { return }
        // ID_FINDENTRY resets the originating list's search cursor even when
        // focusing its already-open CFindDlg.
        if let selectionIndex { model.historyFindIndex[sourceTab] = max(0, selectionIndex) }
        if let child = historyFind[sourceTab] { child.window?.makeKeyAndOrderFront(nil); return }
        let child = RevisionGraphFindController(repository: model.repository, access: model.access, preferences: model.preferences, regexExecutable: regexExecutable)
        historyFind[sourceTab] = child
        child.logSnapshot = { [weak model] in
            guard let model else { return [] }
            return sourceTab == 4 ? (model.incomingCommits ?? []) : (model.outgoing?.commits ?? [])
        }
        child.searchIndex = { [weak model] in model?.historyFindIndex[sourceTab] ?? 0 }
        child.didFindIndex = { [weak model] in model?.historyFindIndex[sourceTab] = $0 }
        child.logDateSettings = .load(defaults: model.preferences)
        child.canSearch = { [weak self] in self?.canHistoryFind == true }
        child.navigate = { [weak self, weak child] hash, select in
            guard let self, let child, !child.closed, self.canHistoryFind else { return }
            let entries = sourceTab == 4 ? (self.model.incomingCommits ?? []) : (self.model.outgoing?.commits ?? [])
            guard entries.contains(where: { $0.hash == hash }) else { return }
            if !select { self.model.historyHighlights[sourceTab] = hash }
            self.model.historyNavigation[sourceTab] = (UUID(), hash, select)
        }
        child.modalChanged = { [weak model] in model?.objectWillChange.send() }
        child.onClosed = { [weak self, weak child, weak parent] in
            if let window = child?.window { parent?.removeChildWindow(window) }
            guard let self, self.historyFind[sourceTab] === child else { return }
            self.historyFind.removeValue(forKey: sourceTab); self.model.objectWillChange.send()
        }
        if let window = child.window {
            window.alphaValue = parent.alphaValue; window.appearance = parent.appearance
            parent.addChildWindow(window, ordered: .above); window.center(); window.orderFront(nil); window.makeFirstResponder(child.searchBox)
        }
        child.updateAvailability(); child.loadReferences()
    }
    private func historyDeletionQuestion(_ title: String, detail: String, buttons: [String], defaultIndex: Int) async -> Int {
        guard !model.closed, historyDeletionAlert == nil, let window, window.attachedSheet == nil else { return -1 }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = detail
        for title in buttons { alert.addButton(withTitle: title).keyEquivalent = "" }
        if alert.buttons.indices.contains(defaultIndex) {
            alert.buttons[defaultIndex].keyEquivalent = "\r"; alert.window.defaultButtonCell = alert.buttons[defaultIndex].cell as? NSButtonCell
        }
        historyDeletionAlert = alert
        return await withCheckedContinuation { continuation in
            var answered = false
            let answer: (Int) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            historyDeletionAnswer = answer
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.historyDeletionAlert === alert, !self.model.closed else { answer(-1); return }
                self.historyDeletionAlert = nil; self.historyDeletionAnswer = nil
                answer(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            }
        }
    }
    private func showHistoryOperation(_ action: SynchronizationHistoryOperation) {
        guard !model.closed, !model.busy, !model.confirmingQuit, !model.confirmingCancellation,
              !model.hasBlockingChild, historyOperationController == nil,
              let owner = window, owner.attachedSheet == nil else { return }
        let child: NSWindowController
        let start: () -> Void
        switch action {
        case .merge(let revision):
            let options = MergeWindowController(repository: model.repository, access: model.access, preferences: model.preferences)
            child = options; start = { options.model.load(revision: revision) }
        case .reset(let revision):
            let options = ResetWindowController(repository: model.repository, access: model.access, revision: revision, preferences: model.preferences)
            child = options; start = { options.model.load() }
        case .checkout(let revision):
            let options = SwitchWindowController(repository: model.repository, access: model.access, revision: revision, preferences: model.preferences)
            child = options; start = { options.model.load(revision: revision) }
        case .combine(let entries, let offset, let head):
            let result = HistoryCombineWindowController(repository: model.repository, access: model.access, entries: entries, firstOffset: offset, expectedHead: head, preferences: model.preferences)
            child = result; start = { result.model.start() }
        case .editNotes(let revision):
            let options = HistoryNotesWindowController(repository: model.repository, access: model.access, revision: revision, preferences: model.preferences)
            child = options; start = { options.model.load() }
        case .revert(let entries, let mainline):
            let result = HistoryRevertWindowController(repository: model.repository, access: model.access, entries: entries, mainline: mainline, preferences: model.preferences)
            child = result; start = { result.model.start() }
        case .switchBranch(let reference):
            var options = CheckoutOptions(); options.target = .branch; options.revision = "refs/heads/" + reference
            let result = SwitchProgressWindowModel(repository: model.repository, access: model.access, options: options, preferences: model.preferences)
            child = SwitchProgressWindowController(model: result); start = { result.start() }
        }
        historyOperationController = child; model.operatingHistory = true
        let finished: () -> Void = { [weak self, weak child, weak owner] in
            if let window = child?.window, window.sheetParent === owner { owner?.endSheet(window) }
            guard let self, self.historyOperationController === child else { return }
            self.historyOperationController = nil; self.model.operatingHistory = false
            if !self.model.closed { self.model.refresh() }
        }
        switch child {
        case let child as MergeWindowController: child.onClosed = finished
        case let child as ResetWindowController: child.onClosed = finished
        case let child as SwitchWindowController: child.onClosed = finished
        case let child as SwitchProgressWindowController: child.onClosed = finished
        case let child as HistoryNotesWindowController: child.onClosed = finished
        case let child as HistoryRevertWindowController: child.onClosed = finished
        case let child as HistoryCombineWindowController: child.onClosed = finished
        default: break
        }
        configureHistoryOperation(child)
        guard let window = child.window else { child.close(); finished(); return }
        window.alphaValue = owner.alphaValue; window.appearance = owner.appearance
        owner.beginSheet(window); start()
    }
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self); branchPickerRequest = nil; branchPickerCompletion = nil; branchPickerFocus = nil
        model.invalidate()
        let answer = historyDeletionAnswer; historyDeletionAnswer = nil
        if let alert = historyDeletionAlert { window?.endSheet(alert.window, returnCode: .abort) }
        historyDeletionAlert = nil; answer?(-1)
        model.detachRebase()
        if let child = historyOperationController {
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window, returnCode: .abort) }
            child.close(); historyOperationController = nil; model.operatingHistory = false
        }
        historyFindAvailability = nil
        let findDialogs = Array(historyFind.values); historyFind.removeAll()
        findDialogs.forEach { $0.close() }
        if let child = historyExportController {
            child.model.invalidate()
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window, returnCode: .abort) }
            child.close(); historyExportController = nil; model.exportingHistory = false
        }
        let references = Array(historyContainingReferences.values); historyContainingReferences.removeAll()
        references.forEach { $0.close() }
        if let child = historyReferenceController {
            child.model.invalidate()
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            child.close(); historyReferenceController = nil; model.creatingHistoryReference = false
        }
        optionsController?.close(); optionsController = nil
        pushOptionsController?.close(); pushOptionsController = nil
        if let child = branchPicker {
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            child.abandonPresentation(); branchPicker = nil; model.choosingBranch = false
        }
        importPatchController?.close(); importPatchController = nil; model.importingPatches = false
        emailWorkflow?.invalidate(); emailWorkflow = nil; model.emailingPatches = false
        if let alert = emailAlert, window?.attachedSheet === alert.window { window?.endSheet(alert.window, returnCode: .abort) }
        emailAlert = nil
        remoteSettingsController?.close(); remoteSettingsController = nil; model.managingRemotes = false
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

enum SynchronizationBranchTarget { case local, remote }

enum SynchronizationHistoryCopy: String, CaseIterable {
    case details = "Full log details", detailsWithoutPaths = "Full log details without changed paths"
    case hashes = "Hashes", authors = "Authors", authorNames = "Author names", authorEmails = "Author emails"
    case subjects = "Subjects", messages = "Messages", referenceNames = "Tag/branch names"
}

enum SynchronizationHistoryDiff {
    case revisions(String, String), allParents(String), mergedFiles(String), extraChanges(String)
    var arguments: [String] {
        let safe = ["--no-ext-diff", "--no-textconv", "--no-color"]
        switch self {
        case .revisions(let base, let revision): return ["diff-tree", "-r", "-p", "--stat"] + safe + ["--end-of-options", base, revision, "--"]
        case .allParents(let revision): return ["diff-tree", "-r", "-p", "-m", "--stat"] + safe + ["--end-of-options", revision, "--"]
        case .mergedFiles(let revision): return ["diff-tree", "-r", "-p", "-c", "--stat"] + safe + ["--end-of-options", revision, "--"]
        case .extraChanges(let revision): return ["diff-tree", "--cc"] + safe + ["--end-of-options", revision, "--"]
        }
    }
    var title: String {
        switch self {
        case .revisions: return "Show changes as unified diff"
        case .allParents: return "All Parents"
        case .mergedFiles: return "Only Merged Files"
        case .extraChanges: return "Show extra changes after merge"
        }
    }
}

@MainActor final class SynchronizationWindowModel: ObservableObject {
    private(set) static var activePushWorkflows=0
    lazy var clientHooks=ClientHookSession(preferences:preferences)
    private(set) static var activeHistoryDeletions = 0
    private var combineSelectionReads:[UUID:OperationCancellation]=[:]
    func validateCombineSelection(_ entries:[LogEntry],offset:Int,head:String,token:OperationCancellation) async throws {
        let identity=UUID();combineSelectionReads[identity]=token
        defer { combineSelectionReads.removeValue(forKey:identity) }
        guard !closed else { throw OperationCancellationFailure.cancelled }
        try await HistoryCombineSelectionReader.validate(repository:repository,access:access,entries:entries,offset:offset,head:head,token:token)
    }
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
    var remoteWasSelected = false
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
    @Published private(set) var incomingFromPatch = false
    private var lastTransportOldHash: String?
    @Published private(set) var incomingCommits: [LogEntry]?
    @Published private(set) var incomingGraph: [CommitGraphRow] = []
    @Published private(set) var conflicts: [StatusEntry] = []
    @Published var pullAction = SynchronizationTransportAction.pull
    @Published private(set) var compareTagsSelected = false
    @Published private(set) var pushAction: SynchronizationTransportAction = .push
    @Published private(set) var stashAction: SynchronizationStashAction = .save
    @Published private(set) var submoduleAction: SynchronizationSubmoduleAction = .update
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
    func historyParentTitle(_ hash: String, index: Int) -> String {
        // The pinned CGit::GetShortHASHLength returns eight, independent of core.abbrev.
        let label = "Parent \(index + 1)", short = String(hash.prefix(8))
        guard let text = historyEntries.first(where: { $0.hash == hash })?.subject ?? historyParentSubjects[hash] else { return "\(label) (\(short))" }
        let subject = text as NSString
        let title = subject.length > 20 ? subject.substring(to: 20) + "..." : text
        return "\(label): \"\(title)\" (\(short))"
    }
    private(set) var historyParentSubjects: [String: String] = [:]
    private var historyParentRequests: [UUID: OperationCancellation] = [:]
    func loadHistoryParentSubjects(_ entry: LogEntry) async {
        guard !closed, !busy, !confirmingQuit, !hasBlockingChild, !Task.isCancelled,
              entry.parents.count > 1 else { return }
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { return }
        let id = UUID(), request = OperationCancellation(), generation = historyActionGeneration
        historyParentRequests[id] = request
        defer { historyParentRequests.removeValue(forKey: id) }
        await withTaskCancellationHandler {
            for hash in entry.parents where historyParentSubjects[hash] == nil && !historyEntries.contains(where: { $0.hash == hash }) {
                do {
                    let result = try await repository.run(["show", "--encoding=UTF-8", "--no-patch", "--no-notes", "--format=%B", "--end-of-options", hash, "--"], cancellation: request)
                    guard !closed, generation == historyActionGeneration, !request.isCancelled, !Task.isCancelled else { return }
                    historyParentSubjects[hash] = LogEntry.splitHistoryMessage(result.text).subject
                } catch {
                    guard !closed, generation == historyActionGeneration, !request.isCancelled, !Task.isCancelled else { return }
                    // A missing/corrupt parent keeps the source's hash-only fallback.
                }
            }
        } onCancel: { request.cancel() }
    }
    func compareHistoryChangeSets(first: String, second: String) {
        guard !closed, !busy, !confirmingQuit, !confirmingCancellation, !hasBlockingChild,
              window?.attachedSheet == nil else { return }
        let request = OperationCancellation(), child = tab == 4 ? incomingComparison : comparison
        let alternateTool = ComparisonToolInvocation.capture
        token?.cancel(); token = request; busy = true; error = nil
        Task {
            defer { if token === request { token = nil; busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result = try await repository.commitChangeSets(first: first, second: second, cancellation: request)
                guard !closed, token === request, !request.isCancelled else { return }
                let key = "Sync change sets " + UUID().uuidString
                let viewer = FileComparisonWindowController(repository: repository, access: access, changeSets: result)
                viewer.model.captureToolChoice(alternateTool)
                viewer.model.comparisonDefaults = preferences
                viewer.onClosed = { [weak child] in child?.comparisonWindows.removeValue(forKey: key) }
                child.comparisonWindows[key] = viewer; viewer.model.load(); viewer.showWindow(nil)
            } catch {
                guard !closed, token === request, !request.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
    var presentHistoryNotice: (String) async -> Void = { _ in }
    func showHistoryDiff(_ diff: SynchronizationHistoryDiff, alternate: Bool = false) {
        guard !closed, !busy, !confirmingQuit, !confirmingCancellation, !hasBlockingChild,
              window?.attachedSheet == nil else { return }
        let request = OperationCancellation(), child = tab == 4 ? incomingComparison : comparison
        token?.cancel(); token = request; busy = true; error = nil
        Task {
            defer { if token === request { token = nil; busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let bytes = try await repository.run(diff.arguments, cancellation: request).stdout
                guard !closed, token === request, !request.isCancelled else { return }
                if case .extraChanges(let hash) = diff {
                    let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
                    guard lines.count > 1, lines[0] == hash, !lines[1].isEmpty else {
                        await presentHistoryNotice("No extra changes after merge"); return
                    }
                }
                if try await UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: preferences, title: diff.title, permissions: access.map { [$0] } ?? [], cancellation: request) { return }
                guard !closed, token === request, !request.isCancelled else { return }
                let key = "Sync revision diff " + diff.arguments.joined(separator: "\0")
                let viewer = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access,
                    existing: child.unifiedWindows[key], title: diff.title,
                    onClosed: { [weak child] in child?.unifiedWindows.removeValue(forKey: key) })
                child.unifiedWindows[key] = viewer
            } catch {
                guard !closed, token === request, !request.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
    var historyPasteboard: NSPasteboard = .general
    func copyHistory(_ entries: [LogEntry], kind: SynchronizationHistoryCopy, pointedReference: String? = nil) {
        guard !closed, !confirmingQuit, !busy, !hasBlockingChild, !entries.isEmpty,
              entries.allSatisfy({ !$0.hash.isEmpty }) else { return }
        func publish(_ text: String) {
            historyPasteboard.clearContents(); historyPasteboard.setString(text, forType: .string)
        }
        switch kind {
        case .hashes: publish(entries.map(\.hash).joined(separator: "\n"))
        case .authors: publish(entries.map { "\($0.author) <\($0.email)>" }.joined(separator: "\n"))
        case .authorNames: publish(entries.map(\.author).joined(separator: "\n"))
        case .authorEmails: publish(entries.map(\.email).joined(separator: "\n"))
        case .subjects, .messages: publish(LogEntry.historyClipboard(entries, subjectsOnly: kind == .subjects))
        case .referenceNames:
            guard entries.count == 1 else { return }
            if let pointedReference {
                guard entries[0].references.contains(where: { GitReferenceName.equal($0.name, pointedReference) }) else { return }
                let tag = GitReferenceName.removingPrefix("refs/tags/", from: pointedReference)
                let name = tag.map { GitReferenceName.removingSuffix("^{}", from: $0) ?? $0 }
                    ?? GitReferenceName.removingPrefix("refs/heads/", from: pointedReference)
                    ?? GitReferenceName.removingPrefix("refs/", from: pointedReference) ?? pointedReference
                publish(String(name.reversed().drop(while: { $0.isWhitespace }).reversed()))
            } else {
                publish(entries[0].references.map { ref in
                    (ref.name.hasPrefix("refs/tags/") ? GitReferenceName.removingSuffix("^{}", from: ref.name) ?? ref.name : ref.name) + "\r\n"
                }.joined())
            }
        case .details, .detailsWithoutPaths:
            let request = OperationCancellation(); token = request; busy = true; error = nil
            let dates = HistoryDateSettings.load(defaults: preferences)
            Task {
                defer { if token === request { token = nil; busy = false } }
                do {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    var text = ""
                    for entry in entries {
                        text += try await repository.commitLogText(revision: entry.hash, includePaths: kind == .details, cancellation: request, dateSettings: dates)
                    }
                    guard !closed, token === request, !request.isCancelled else { return }
                    publish(text)
                } catch {
                    guard !closed, token === request, !request.isCancelled else { return }
                    self.error = error.localizedDescription
                }
            }
        }
    }
    @Published private(set) var historyReferenceContext = HistoryReferenceContext()
    @Published private(set) var historyIssueProperties = IssueTrackerProperties()
    @Published private(set) var historyActions: [String: LogRevisionActions] = [:]
    @Published private(set) var historyActionFailures = Set<String>()
    private var historyActionToken: OperationCancellation?
    private var historyActionQueue: [LogEntry] = []
    private var activeHistoryAction: String?
    private var historyActionGeneration = 0
    private func cancelHistoryActions() {
        for request in historyParentRequests.values { request.cancel() }
        historyParentRequests = [:]
        historyActionToken?.cancel(); historyActionToken = nil
        historyActionQueue = []; activeHistoryAction = nil; historyActionGeneration += 1
    }
    func requestHistoryActions(_ entry: LogEntry) {
        guard !closed, !busy, !entry.hash.isEmpty, historyActions[entry.hash] == nil,
              !historyActionFailures.contains(entry.hash), activeHistoryAction != entry.hash,
              !historyActionQueue.contains(where: { $0.hash == entry.hash }) else { return }
        historyActionQueue.append(entry)
        guard historyActionToken == nil else { return }
        let request = OperationCancellation(), generation = historyActionGeneration
        historyActionToken = request
        Task {
            while !closed, generation == historyActionGeneration, !request.isCancelled, !historyActionQueue.isEmpty {
                let entry = historyActionQueue.removeFirst(); activeHistoryAction = entry.hash
                do {
                    let actions = try await repository.revisionActions(in: entry, cancellation: request)
                    guard !closed, generation == historyActionGeneration, !request.isCancelled else { return }
                    historyActions[entry.hash] = actions
                } catch {
                    guard !closed, generation == historyActionGeneration, !request.isCancelled else { return }
                    historyActionFailures.insert(entry.hash)
                }
                activeHistoryAction = nil
            }
            if generation == historyActionGeneration { historyActionToken = nil; activeHistoryAction = nil }
        }
    }
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
    @Published private(set) var busy = false { didSet { if busy { cancelHistoryActions() } } }
    @Published private(set) var error: String?
    @Published private(set) var transportRunning = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var cancelling = false
    @Published private(set) var commandOutput = ""
    @Published private(set) var commandSucceeded = false
    @Published private(set) var commandCompleted = false {
        didSet {
            if commandCompleted && !oldValue && !closed {
                OperationSounds.report(failed: !commandSucceeded, preferences: preferences)
            }
        }
    }
    @Published private(set) var percentage: Int?
    @Published private(set) var currentWork = ""
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var onTransportFinished: (String) -> Void = { _ in }
    private var outputState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { outputState.presentation }
    private var cancellationQuestion: UUID?
    private var transportID: UUID?
    private var token: OperationCancellation?
    private(set) var closed = false
    var onLog: (String) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onApplyPatch: (String) -> Void = { _ in }
    @Published var importingPatches = false
    var onEmailPatches: ([URL]) -> Void = { _ in }
    var onEmailMessage: (String, String) -> Void = { _, _ in }
    @Published var emailingPatches = false
    var onBrowseBranch: (SynchronizationBranchTarget) -> Void = { _ in }
    @Published var choosingBranch = false
    var onManageRemotes: () -> Void = {}
    @Published var managingRemotes = false
    var onStashOptions: () -> Void = {}
    var onSubmoduleOptions: (SynchronizationSubmoduleAction) -> Void = { _ in }
    var onTagLog: ((String) -> Void)?
    var onTagsChanged: () -> Void = {}
    var onReferenceLog: (String) -> Void = { _ in }
    var onReferenceCompare: (String, String) -> Void = { _, _ in }
    var onHistoryCompare: ((ComparisonRevision, ComparisonRevision) -> Void)?
    var onHistoryBrowseRepository: ((String) -> Void)?
    var onHistoryLog: ((String) -> Void)?
    var onHistoryLogRange: ((HistoryRevisionRange) -> Void)?
    var onHistoryContainingReferences: ((String, Int) -> Void)?
    var onHistoryFind: ((Int, Int?) -> Void)?
    var onHistoryExport: ((String) -> Void)?
    @Published var exportingHistory = false
    var onHistoryOperation: ((SynchronizationHistoryOperation) -> Void)?
    var onHistoryBisect: ((LogBisectRequest) -> Void)?
    var onHistoryFormatPatch: ((FormatPatchPreset) -> Void)?
    var onHistoryPush: ((String, Bool) -> Void)?
    var onHistoryPull: (() -> Void)?
    var onHistoryReferenceChanged: (String) -> Void = { _ in }
    var confirmHistoryDeletion: (HistoryReferenceDeletion) async -> HistoryReferenceDeleteChoice = { _ in .abort }
    var acknowledgeHistoryDeletionFailure: (String) async -> Void = { _ in }
    private var historyDeletionCoordinator: SSHTransportCoordinator?
    func deleteHistoryReferences(_ names: [String], revision: String) {
        guard !closed, !busy, !hasBlockingChild, !confirmingQuit, !confirmingCancellation,
              window?.attachedSheet == nil, !names.isEmpty else { return }
        let request = OperationCancellation(), factory = sshSettings.capture()
        token = request; busy = true; error = nil; Self.activeHistoryDeletions += 1
        Task { [weak self, access, repository] in
            _ = access
            defer { Self.activeHistoryDeletions -= 1 }
            guard let self else { return }
            let coordinator = factory?(); self.historyDeletionCoordinator = coordinator
            var refresh = false
            defer {
                coordinator?.close(); if self.historyDeletionCoordinator === coordinator { self.historyDeletionCoordinator = nil }
                if self.token === request { self.token = nil; self.busy = false; if refresh && !self.closed { self.refresh() } }
            }
            for name in names {
                guard !self.closed, self.token === request, !request.isCancelled else { break }
                var choice = HistoryReferenceDeleteChoice.abort
                do {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let snapshot = try await repository.prepareHistoryReferenceDeletion(name, cancellation: request)
                    let resolved = try await repository.run(["rev-parse", "--verify", "--end-of-options", name + "^{commit}"], cancellation: request).text.trimmingCharacters(in: .newlines)
                    guard resolved == revision else { throw HistoryReferenceDeletionFailure.changed }
                    choice = await self.confirmHistoryDeletion(snapshot)
                    guard choice != .abort, !self.closed, self.token === request, !request.isCancelled else { break }
                    let output = try await repository.deleteHistoryReference(snapshot, choice: choice, cancellation: request, prepareTransport: coordinator?.preparation)
                    refresh = true; self.onHistoryReferenceChanged(output)
                } catch {
                    guard !self.closed, !request.isCancelled else { break }
                    self.error = error.localizedDescription
                    await self.acknowledgeHistoryDeletionFailure(error.localizedDescription)
                    if [.remoteAndLocal, .stashAll, .stashOne].contains(choice) { refresh = true } else { break }
                }
            }
        }
    }

    @Published private(set) var historyBisectActive = false
    func requestHistoryBisect(_ handoff: LogBisectRequest, entries: [LogEntry]) {
        guard !closed, !busy, !hasBlockingChild, !confirmingQuit, !confirmingCancellation,
              window?.attachedSheet == nil, !entries.isEmpty, let onHistoryBisect else { return }
        let request = OperationCancellation(); token = request; busy = true; error = nil
        Task { [weak self, access, repository] in
            _ = access
            guard let self else { return }
            defer { if self.token === request { self.token = nil; self.busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                guard try await !repository.isBare(cancellation: request) else { throw BisectFailure.workingTree }
                let path = try await repository.run(["rev-parse", "--git-path", "BISECT_START"], cancellation: request).text.trimmingCharacters(in: .newlines)
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repository.root.appendingPathComponent(path)
                let active = FileManager.default.fileExists(atPath: url.path)
                var captured = handoff
                if handoff.operation == nil {
                    guard !active, try await !repository.logMergeActive(cancellation: request) else { throw BisectFailure.active }
                    func preset(_ entry: LogEntry) async throws -> String {
                        guard let reference = entry.references.first?.name else { return entry.hash }
                        let resolved = try await repository.run(["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"], successfulExitCodes: 0...128, cancellation: request)
                        return resolved.exitCode == 0 && resolved.text.trimmingCharacters(in: .newlines) == entry.hash ? reference : entry.hash
                    }
                    let bad = try await preset(entries[0]), good = try await preset(entries[entries.count - 1])
                    captured = LogBisectRequest(good: good, bad: bad, operation: nil, revisions: [])
                } else {
                    guard active else { throw BisectFailure.inactive }
                    let marks = try await repository.run(["for-each-ref", "--points-at", entries[0].hash, "--format=%(refname)", "refs/bisect/"], cancellation: request)
                    guard marks.stdout.isEmpty else { throw BisectFailure.operation }
                }
                guard !self.closed, self.token === request, !request.isCancelled else { return }
                self.token = nil; self.busy = false; onHistoryBisect(captured)
            } catch {
                if !self.closed, self.token === request, !request.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    var runHistoryReplay: ((String?, [String]?) async throws -> Void)?
    @Published var operatingHistory = false
    @Published private(set) var historyCurrentBranch = ""
    @Published private(set) var historyHead = ""
    @Published private(set) var historyBare = false
    @Published private(set) var historyMergeActive = false
    func replayHistory(upstream: String?, commits: [String]?) {
        guard !closed, !busy, !confirmingQuit, !confirmingCancellation, !hasBlockingChild,
              window?.attachedSheet == nil, let runHistoryReplay else { return }
        operatingHistory = true
        Task { [weak self] in
            do { try await runHistoryReplay(upstream, commits) }
            catch { if let self, !self.closed { self.error = error.localizedDescription } }
            guard let self else { return }; self.operatingHistory = false
            if !self.closed { self.refresh() }
        }
    }
    var historyFindIndex: [Int: Int] = [:]
    var historyReferencesBlocking: () -> Bool = { false }
    @Published var historyNavigation: [Int: (id: UUID, hash: String, select: Bool)] = [:]
    var handledHistoryNavigation: [Int: UUID] = [:]
    @Published var historyHighlights: [Int: String] = [:]
    var onHistoryCreateReference: ((Bool, String) -> Void)?
    @Published var creatingHistoryReference = false
    var hasBlockingChild: Bool {
        historyReferencesBlocking() || operatingHistory || exportingHistory || creatingHistoryReference || emailingPatches || importingPatches || choosingBranch || managingRemotes || NSApp.modalWindow != nil || [comparison, incomingComparison].contains { child in
            child.busy || child.comparisonWindows.values.contains { $0.model.busy || $0.window?.attachedSheet != nil } || child.unifiedWindows.values.contains { $0.model.busy || $0.window?.attachedSheet != nil }
        }
    }
    var remoteChoices: [String] {
        var seen = Set<GitReferenceName>()
        return urlHistory.filter { seen.insert(GitReferenceName($0)).inserted }
    }
    private var historyKey: String { "TurtleGit.Sync." + repository.root.path }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.preferences = preferences
        sshSettings = SSHTransportSettings(repository: repository)
        outputState = GitProgressOutputState(preferences: preferences)
        comparison = RevisionComparisonWindowModel(repository: repository, access: access, from: .revision("HEAD"), to: .revision("HEAD"), preferences: preferences)
        incomingComparison = RevisionComparisonWindowModel(repository: repository, access: access, from: .revision("HEAD"), to: .revision("HEAD"), preferences: preferences)
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
        submoduleAction = SynchronizationSubmoduleAction(rawValue: preferences.integer(forKey: historyKey + ".submoduleAction")) ?? .update
        branchHistory = FetchDialogHistory.load(preferences, key: historyKey + ".branches", caseSensitive: false)
        urlHistory = FetchDialogHistory.load(preferences, key: historyKey + ".urls", caseSensitive: true, maxItems: Int(Int32.max))
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
    func invalidate() { combineSelectionReads.values.forEach {$0.cancel()};combineSelectionReads.removeAll();closed = true; clientHooks.retire(); historyDeletionCoordinator?.close(); historyDeletionCoordinator = nil; cancelHistoryActions(); token?.cancel(); token = nil; comparison.invalidate(); incomingComparison.invalidate(); busy = false; transportRunning = false; cancelling = false; confirmingCancellation = false; cancellationQuestion = nil; transportID = nil }
    func reload(selectTracking: Bool = false, initial: Bool = false, preserveError: Bool = false, refreshRemoteSelection: Bool = false) {
        guard !closed, !confirmingQuit, !transportRunning, !hasBlockingChild else { return }
        token?.cancel()
        comparingTags = false; tagSnapshot = nil; if tab == 7 { tab = 0 }
        let retainedError = preserveError ? error : nil
        let request = OperationCancellation(); token = request; busy = true; error = retainedError
        outgoing = nil; graph = []; fileSelection = []; comparison.snapshot = nil
        let local = localBranch, selectedRemote = remote, selectedBranch = remoteBranch, forced = force
        let selectedChoice = remoteWasSelected
        if refreshRemoteSelection { urlHistory = FetchDialogHistory.load(preferences, key: historyKey + ".urls", caseSensitive: true, maxItems: Int(Int32.max)) }
        Task {
            defer { if token === request { token = nil; busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let catalog = try await repository.synchronizationBranches(localBranch: initial ? nil : local, cancellation: request)
                guard !closed, token === request, !request.isCancelled else { return }
                let branch = initial ? catalog.currentBranch : local
                let destination = selectTracking || initial ? catalog.trackedBranch : selectedBranch
                var url = selectTracking || initial ? (catalog.trackedRemote.isEmpty ? (initial ? (urlHistory.first ?? catalog.remotes.first ?? "") : selectedRemote) : catalog.trackedRemote) : selectedRemote
                localBranches = catalog.localBranches; remotes = catalog.remotes
                if initial || refreshRemoteSelection {
                    for name in remotes { urlHistory = FetchDialogHistory.inserting(name, into: urlHistory, atFront: false, caseSensitive: true, maxItems: Int(Int32.max)) }
                }
                // Source Refresh falls back only for an actual combo selection
                // that no longer names a remote; typed URLs/branch fields survive.
                if refreshRemoteSelection && selectedChoice && !catalog.remotes.contains(where: { GitReferenceName($0) == GitReferenceName(selectedRemote) }) {
                    url = remoteChoices.first ?? ""
                }
                if initial || selectTracking { remoteWasSelected = remoteChoices.contains(where: { GitReferenceName($0) == GitReferenceName(url) }) }
                localBranch = branch; remoteBranch = destination; remote = url
                if initial || selectTracking { branchHistory = FetchDialogHistory.inserting(destination, into: branchHistory, atFront: false, caseSensitive: false) }
                let projection = try await repository.synchronizationOutgoing(localBranch: branch, remote: url, remoteBranch: destination, force: forced, cancellation: request)
                guard !closed, token === request, !request.isCancelled else { return }
                let references = try await repository.historyReferenceContext(cancellation: request)
                let properties = try await repository.issueTrackerProperties(cancellation: request)
                let bare = try await repository.isBare(cancellation: request)
                let mergeActive = try await repository.logMergeActive(cancellation: request)
                let bisectPath = try await repository.run(["rev-parse", "--git-path", "BISECT_START"], cancellation: request).text.trimmingCharacters(in: .newlines)
                let bisectURL = bisectPath.hasPrefix("/") ? URL(fileURLWithPath: bisectPath) : repository.root.appendingPathComponent(bisectPath)
                let bisectActive = FileManager.default.fileExists(atPath: bisectURL.path)
                let head = try await repository.run(["rev-parse", "--verify", "HEAD"], successfulExitCodes: 0...128, cancellation: request)
                guard !closed, token === request, !request.isCancelled else { return }
                historyReferenceContext = references; historyIssueProperties = properties
                historyBare = bare; historyMergeActive = mergeActive; historyBisectActive = bisectActive; historyCurrentBranch = catalog.currentBranch
                historyHead = head.exitCode == 0 ? head.text.trimmingCharacters(in: .newlines) : ""
                historyActionFailures = []
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
    func applyPatch() {
        guard !closed, !confirmingQuit, !busy, !hasBlockingChild, window?.attachedSheet == nil else { return }
        let request = OperationCancellation(); token = request; busy = true; error = nil
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let hash = try await repository.run(["rev-parse", "--verify", "HEAD^{commit}"], cancellation: request).text.trimmingCharacters(in: .newlines)
                guard !closed, token === request, !request.isCancelled else { return }
                token = nil; busy = false; onApplyPatch(hash)
            } catch {
                guard !closed, token === request else { return }; self.error = error.localizedDescription; token = nil; busy = false
            }
        }
    }
    var canEmailPatch: Bool { !closed && !confirmingQuit && !busy && !hasBlockingChild && window?.attachedSheet == nil && outgoing?.canEmailPatch == true }
    func emailPatch() {
        guard canEmailPatch else { return }
        let request = OperationCancellation(); token = request; busy = true; emailingPatches = true; error = nil
        let local = localBranch, selectedRemote = remote, branch = remoteBranch
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result = try await repository.synchronizationEmailPatches(localBranch: local, remote: selectedRemote, remoteBranch: branch, cancellation: request)
                guard !closed, token === request, !request.isCancelled else { return }
                let root = repository.root.resolvingSymlinksInPath()
                let files = String(decoding: result.stdout, as: UTF8.self).components(separatedBy: root.path + "/").dropFirst().compactMap { part -> URL? in
                    let name = part.hasSuffix("\n") ? String(part.dropLast()) : part
                    guard !name.isEmpty, !name.contains("/"), !name.contains("\n"), name != ".", name != ".." else { return nil }
                    let file = root.appendingPathComponent(name)
                    return FileManager.default.fileExists(atPath: file.path) ? file : nil
                }
                token = nil; busy = false; emailingPatches = false
                if files.isEmpty { onEmailMessage("Email Patch", "No patches generated.") }
                else { onEmailPatches(files) }
            } catch {
                guard !closed, token === request else { return }
                token = nil; busy = false; emailingPatches = false; self.error = error.localizedDescription
                onEmailMessage("Could not create patches", error.localizedDescription)
            }
        }
    }
    func finishPatchImport(oldHead: String) {
        guard !closed, !confirmingQuit, !transportRunning, !hasBlockingChild else { return }
        let request = OperationCancellation(); token?.cancel(); token = request; busy = true; error = nil
        comparingTags = false; tagSnapshot = nil
        incomingFromPatch = true; incomingCommits = nil; incomingGraph = []; incomingComparison.snapshot = nil
        Task {
            do {
                let result = try await repository.synchronizationIncoming(from: oldHead, to: "HEAD", cancellation: request)
                guard !closed, token === request, !request.isCancelled else { return }
                var commits = result.commits
                // Source uses the previous Pull/Fetch HEAD for the log range,
                // but the immediate pre-dialog HEAD for the changed-file diff.
                if result.comparison.from != result.comparison.to, let baseline = lastTransportOldHash,
                   case .revision(let newHash) = result.comparison.to {
                    var options = HistoryOptions(); options.useMailmap = preferences.usesMailmap; options.limit = -1
                    options.revisionRange = HistoryRevisionRange(from: baseline, to: newHash, kind: .difference)
                    commits = try await repository.history(options: options, cancellation: request)
                }
                guard !closed, token === request, !request.isCancelled else { return }
                incomingCommits = commits; incomingGraph = CommitGraph.layout(commits); incomingComparison.snapshot = result.comparison
                tab = 4; token = nil; busy = false
                if result.comparison.from != result.comparison.to { reload() }
            } catch {
                guard !closed, token === request else { return }; self.error = error.localizedDescription; token = nil; busy = false
            }
        }
    }
    func browseBranch(_ target: SynchronizationBranchTarget) {
        guard !closed, !confirmingQuit, !busy, !hasBlockingChild, window?.attachedSheet == nil else { return }
        onBrowseBranch(target)
    }
    func applyBranchSelection(_ reference: String, target: SynchronizationBranchTarget) {
        guard !closed, !confirmingQuit, !transportRunning, !hasBlockingChild else { return }
        switch target {
        case .local:
            guard let branch = GitReferenceName.removingPrefix("refs/heads/", from: reference), !branch.isEmpty else { return }
            localBranch = branch; reload(selectTracking: true)
        case .remote:
            guard let selection = RemoteTrackingSelection(reference: reference, remotes: remotes) else { return }
            let branch = selection.branch
            remote = selection.remote; remoteWasSelected = true; remoteBranch = branch
            branchHistory = FetchDialogHistory.inserting(branch, into: branchHistory, atFront: false, caseSensitive: false)
            reload()
        }
    }
    // Sync Close saves both controls; forced teardown/Cancel does not insert them.
    func saveHistory() {
        guard !closed, !confirmingQuit, !transportRunning, !confirmingCancellation, !hasBlockingChild else { return }
        branchHistory = FetchDialogHistory.save(remoteBranch, entries: branchHistory, preferences: preferences, key: historyKey + ".branches", caseSensitive: false)
        urlHistory = FetchDialogHistory.save(remote, entries: remoteChoices, preferences: preferences, key: historyKey + ".urls", caseSensitive: true, maxItems: Int(Int32.max))
        sshSettings.save(preferences, key: historyKey + ".autoload")
    }
    func deleteBranchHistory(at index: Int) {
        guard !closed, !confirmingQuit, !transportRunning, !hasBlockingChild,
              let result = FetchDialogHistory.removing(index, entries: branchHistory, preferences: preferences, key: historyKey + ".branches") else { return }
        branchHistory = result.entries; remoteBranch = result.selection; reload()
    }
    func deleteURLHistory(at index: Int) {
        guard !closed, !confirmingQuit, !transportRunning, !hasBlockingChild,
              let result = FetchDialogHistory.removing(index, entries: remoteChoices, preferences: preferences, key: historyKey + ".urls", maxItems: Int(Int32.max)) else { return }
        urlHistory = result.entries; remote = result.selection; remoteWasSelected = !remote.isEmpty; reload()
    }
    func manageRemotes() {
        guard !closed, !confirmingQuit, !busy, !hasBlockingChild, window?.attachedSheet == nil else { return }
        onManageRemotes()
    }
    func refresh() { if comparingTags { compareTags() } else { reload(refreshRemoteSelection: true) } }
    func compareTags(shift: Bool = false) {
        guard !closed, !confirmingQuit, !busy, !hasBlockingChild, window?.attachedSheet == nil else { return }
        compareTagsSelected = true; preferences.set(6, forKey: historyKey + ".pullAction")
        if shift { return }
        let request = OperationCancellation(); token = request; busy = true; transportRunning = true
        comparingTags = true; tagSnapshot = nil; tab = 7; error = nil; commandOutput = ""; referenceChanges = []
        incomingFromPatch = false; incomingCommits = nil; incomingGraph = []; incomingComparison.snapshot = nil; conflicts = []
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
            Self.activePushWorkflows += 1
            Task {
                defer { Self.activePushWorkflows -= 1;withExtendedLifetime(access) {} }
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
    func submodule(_ action: SynchronizationSubmoduleAction? = nil, shift: Bool = NSEvent.modifierFlags.contains(.shift)) {
        guard !closed, !confirmingQuit, !confirmingCancellation, !busy, !hasBlockingChild, window?.attachedSheet == nil else { return }
        let selected = action ?? submoduleAction; submoduleAction = selected
        if shift {
            // Source launches a separate process and returns immediately. Init
            // and Update both open full Update; Sync opens standalone Sync.
            onSubmoduleOptions(selected == .sync ? .sync : .update)
            return
        }
        preferences.set(selected.rawValue, forKey: historyKey + ".submoduleAction")
        comparingTags = false; tagSnapshot = nil
        let operationID = UUID(); transportID = operationID
        let request = OperationCancellation(); token = request; busy = true; transportRunning = true
        cancelling = false; commandCompleted = false; commandSucceeded = false
        outputState.reset(); commandOutput = ""; percentage = nil; currentWork = ""; error = nil; tab = 2
        let forced = force
        Task {
            defer { if transportID == operationID { token = nil; busy = false; transportRunning = false; cancelling = false; transportID = nil } }
            let parser = GitCliOutputParser(limit: outputState.limit)
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let operation = Task {
                    defer { continuation.finish() }
                    return try await repository.synchronizeSubmodules(selected, force: forced, cancellation: request,
                        onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) })
                }
                for await _ in updates { consume(parser.processPending(), parser: parser, request: request) }
                consume(parser.processPending(), parser: parser, request: request); consume(parser.finish(), parser: parser, request: request)
                let result = try await operation.value
                guard !closed, token === request else { return }
                if !outputState.hasOutput { commandOutput = result.text }
                commandSucceeded = true
            } catch {
                guard !closed, token === request else { return }
                let message = request.isCancelled ? "Synchronization cancelled." : error.localizedDescription
                commandOutput += (commandOutput.isEmpty || commandOutput.hasSuffix("\n") ? "" : "\n") + message
                self.error = message
            }
            guard !closed, token === request else { return }
            commandCompleted = true; cancelling = false; transportRunning = false; busy = false; token = nil; transportID = nil
            // Source Submodule completion leaves Command Log selected, without
            // Fetch's reference/incoming/outgoing refill phases.
            onTransportFinished(commandOutput)
        }
    }
    func stash(_ action: SynchronizationStashAction? = nil, shift: Bool = NSEvent.modifierFlags.contains(.shift)) {
        guard !closed, !confirmingQuit, !confirmingCancellation, !busy, !hasBlockingChild, window?.attachedSheet == nil else { return }
        let selected = action ?? stashAction; stashAction = selected
        if shift { if selected == .save { onStashOptions() }; return }
        incomingFromPatch = false; incomingCommits = nil; incomingGraph = []; incomingComparison.snapshot = nil; conflicts = []
        comparingTags = false; tagSnapshot = nil
        let operationID = UUID(); transportID = operationID
        let request = OperationCancellation(); token = request; busy = true; transportRunning = true
        cancelling = false; commandCompleted = false; commandSucceeded = false
        outputState.reset(); commandOutput = ""; percentage = nil; currentWork = ""; error = nil; tab = 2
        Task {
            defer { if transportID == operationID { token = nil; busy = false; transportRunning = false; cancelling = false; transportID = nil } }
            let parser = GitCliOutputParser(limit: outputState.limit)
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let operation = Task {
                    defer { continuation.finish() }
                    return try await repository.synchronizationStash(selected, cancellation: request,
                        onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) })
                }
                for await _ in updates { consume(parser.processPending(), parser: parser, request: request) }
                consume(parser.processPending(), parser: parser, request: request); consume(parser.finish(), parser: parser, request: request)
                let result = try await operation.value
                guard !closed, token === request else { return }
                if !outputState.hasOutput { commandOutput = result.command.text }
                commandSucceeded = result.command.exitCode == 0
                if !commandSucceeded { self.error = result.conflictCheckError ?? "Git exited with status \(result.command.exitCode)." }
                if let message = result.conflictCheckError { commandOutput += "\nChecking for conflicts failed: " + message }
                conflicts = result.conflicts; if !conflicts.isEmpty { tab = 6 }
            } catch {
                guard !closed, token === request else { return }
                let message = request.isCancelled ? "Synchronization cancelled." : error.localizedDescription
                commandOutput += (commandOutput.isEmpty || commandOutput.hasSuffix("\n") ? "" : "\n") + message
                self.error = message
            }
            guard !closed, token === request else { return }
            commandCompleted = true; cancelling = false; transportRunning = false; busy = false; token = nil; transportID = nil
            // Stash leaves the outgoing/reference projection unchanged. Failed
            // restore shows Conflicts only for actual unmerged entries.
            onTransportFinished(commandOutput)
        }
    }
    private func runTransport(_ action: SynchronizationTransportAction, shift: Bool) {
        let pushing = [.push, .pushTags, .pushNotes].contains(action)
        comparingTags = false; tagSnapshot = nil
        let operationID = UUID(); transportID = operationID
        let request = OperationCancellation(); token = request; busy = true; transportRunning = true
        cancelling = false; commandCompleted = false; commandSucceeded = false; referenceChanges = []
        incomingFromPatch = false; incomingCommits = nil; incomingGraph = []; incomingComparison.snapshot = nil; conflicts = []
        outputState.reset(); commandOutput = ""; percentage = nil; currentWork = ""; error = nil; tab = 2
        var options = SynchronizationTransportOptions(action: action)
        options.localBranch = localBranch; options.remote = remote; options.remoteBranch = remoteBranch; options.force = force
        options.fetchVerbose = GitCommandPresentation(defaults: preferences).fetchVerbose
        let factory = sshSettings.capture()
        sshSettings.save(preferences, key: historyKey + ".autoload")
        if pushing { Self.activePushWorkflows += 1 }
        Task {
            defer { if pushing { Self.activePushWorkflows -= 1 };withExtendedLifetime(access) {} }
            let coordinator = factory?(); defer { coordinator?.close() }
            defer { if transportID == operationID { token = nil; busy = false; transportRunning = false; transportID = nil } }
            let parser = GitCliOutputParser(limit: outputState.limit)
            var oldReferences: SynchronizationReferenceSnapshot?
            var oldHead: String?
            var incomingRevision: String?
            var pushAttempted=false
            var ignoredPreHook:ClientHookResult?
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let plan = try await (shift ? repository.synchronizationOptionsPlan(options, cancellation: request) : repository.synchronizationTransportPlan(options, cancellation: request))
                oldHead = plan.oldHead
                if !pushing { lastTransportOldHash = plan.oldHead }
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
                if pushing {
                    preferences.set(action == .push ? 0 : action == .pushTags ? 1 : 2, forKey: historyKey + ".pushAction")
                    currentWork=ClientHookType.prePush.title
                    let result=try await clientHooks.run(.prePush,repository:repository,access:access,cancellation:request,allowContinue:true)
                    guard !closed,token === request,!request.isCancelled else { return }
                    if let result,result.exitCode != 0 { ignoredPreHook=result }
                    currentWork=""
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
                    pushAttempted=pushing
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
            if let ignoredPreHook {
                commandOutput += "\nPre-push hook failure was continued.\n" + (ignoredPreHook.error.isEmpty ? ignoredPreHook.output : ignoredPreHook.error)
            }
            // RunPostAction executes after both successful and failed/cancelled
            // Push commands; forced owner exit suppresses it. A fresh token lets
            // the live post-action settle independently of the killed Git child.
            if pushing,pushAttempted,!closed {
                let postRequest=OperationCancellation();token=postRequest;cancelling=false;currentWork=ClientHookType.postPush.title
                do { _ = try await clientHooks.run(.postPush,repository:repository,access:access,cancellation:postRequest) }
                catch {
                    guard !closed,token === postRequest else { return }
                    let text=postRequest.isCancelled ? "Post-push hook cancelled. Push effects are retained." : (commandSucceeded ? "The push succeeded, but its post-push hook failed.\n\n" : "The post-push hook failed.\n\n") + error.localizedDescription
                    commandOutput += "\n"+text;self.error=(self.error.map { $0+"\n\n" } ?? "")+text
                }
                guard !closed,token === postRequest else { return };currentWork=""
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
        if unified { child.showPatch(fileSelection, alternate: ComparisonToolInvocation.capture) }
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
                        Button("…") { model.browseBranch(.local) }.accessibilityLabel("Browse local branches")
                        Text("Remote Branch:")
                        FetchHistoryCombo(value: edit(\.remoteBranch), choices: model.branchHistory, label: "Remote Branch", onDelete: model.deleteBranchHistory)
                        Button("…") { model.browseBranch(.remote) }.accessibilityLabel("Browse remote branches")
                    }
                    HStack {
                        Text("Remote URL:")
                        FetchHistoryCombo(value: edit(\.remote), choices: model.remoteChoices, label: "Remote URL", onDelete: model.deleteURLHistory, onSelectionState: { model.remoteWasSelected = $0 })
                        Button { model.manageRemotes() } label: { CommandLabel(title: "Manage", icon: .settings) }
                            .disabled(model.busy || model.confirmingQuit)
                    }
                    HStack(spacing: 24) {
                        SSHAutoloadToggle(settings: model.sshSettings)
                        Toggle("Force", isOn: Binding(get: { model.force }, set: { model.force = $0; model.reload() }))
                        Spacer()
                    }.padding(.leading, 100)
                }.padding(6)
            }.disabled(model.transportRunning || model.hasBlockingChild)
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
                    GitCommandProgressBar(percentage: model.percentage, animate: model.progressPresentation.animateActivity)
                }
            } else if model.tab == 0 || model.tab == 4 {
                SynchronizationHistoryTable(model: model)
                    .id(model.tab)
                    .overlay { if model.tab == 4, model.incomingUpToDate { Text(model.incomingFromPatch ? "No commits get from patch" : "Up to date.").foregroundStyle(.secondary) } }
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
            Picker("Changes", selection: $model.tab) {
                if model.comparingTags { Text("Compare tags").tag(7) }
                else {
                    Text("Log").tag(2)
                    if model.incomingCommits != nil { Text("In Commits").tag(4) }
                    if model.incomingComparison.snapshot?.files.isEmpty == false { Text("In Changelist").tag(5) }
                    if !model.conflicts.isEmpty { Text("Conflicts").tag(6) }
                    Text("Out Commits").tag(0); Text("Out Changelist").tag(1); Text("Ref List").tag(3)
                }
            }.labelsHidden().pickerStyle(.segmented)
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
                HStack(spacing: 0) {
                    Button { model.submodule() } label: { CommandLabel(title: model.submoduleAction.title, icon: model.submoduleAction.icon) }
                    Menu {
                        ForEach(SynchronizationSubmoduleAction.allCases, id: \.rawValue) { action in
                            Button { model.submodule(action) } label: { CommandLabel(title: action.title, icon: action.icon) }
                        }
                    } label: { Text("").accessibilityLabel("Submodule actions") }.menuStyle(.borderlessButton).fixedSize()
                }.disabled(model.busy || model.hasBlockingChild)
                Button { model.applyPatch() } label: { CommandLabel(title: "Apply Patch", icon: .patch) }.disabled(model.busy || model.hasBlockingChild)
                Button { model.emailPatch() } label: { CommandLabel(title: "Email Patch", icon: .sendMail) }.disabled(!model.canEmailPatch)
                Spacer()
            }
            HStack {
                Button { model.onLog(model.localBranch) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(model.busy || model.localBranch.isEmpty)
                Button { model.onCommit() } label: { CommandLabel(title: "Commit", icon: .commit) }.disabled(model.busy)
                HStack(spacing: 0) {
                    Button { model.stash() } label: { CommandLabel(title: model.stashAction.title, icon: model.stashAction.icon) }
                    Menu {
                        ForEach(SynchronizationStashAction.allCases, id: \.rawValue) { action in
                            Button { model.stash(action) } label: { CommandLabel(title: action.title, icon: action.icon) }
                        }
                    } label: { Text("").accessibilityLabel("Stash actions") }.menuStyle(.borderlessButton).fixedSize()
                }.disabled(model.busy || model.hasBlockingChild)
                Button("Refresh") { model.refresh() }.disabled(model.transportRunning || model.hasBlockingChild)
                Spacer()
            }
            HStack {
                if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
                Text(model.status).foregroundStyle(model.error == nil ? Color.secondary : Color.red).textSelection(.enabled)
                Spacer()
                if model.transportRunning {
                    Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancelTransport() }
                        .keyboardShortcut(.cancelAction).disabled(model.cancelling || model.confirmingCancellation)
                } else {
                    Button("Close") { model.window?.performClose(nil) }.keyboardShortcut(.defaultAction)
                }
                Button("Help") { TurtleGitHelp.show(.synchronization) }
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

enum SynchronizationHistoryColumns {
    // GitLogListBase::InsertGitColumn, shared by upstream SyncIn and SyncOut.
    static let definitions: [(id: String, title: String, width: Double, visible: Bool)] = [
        ("graph", "Graph", 65, true), ("hash", "SHA-1", 110, false), ("actions", "Actions", 90, true),
        ("message", "Message", 450, true), ("author", "Author", 150, true), ("date", "Date", 180, true),
        ("email", "Email", 200, false), ("committer", "Commit Name", 150, false),
        ("committerEmail", "Commit Email", 200, false), ("committerDate", "Commit Date", 180, false),
        ("bugs", "Bug-ID", 110, true)
    ]
    static func key(incoming: Bool, id: String) -> String { "TurtleGit.Sync." + (incoming ? "In" : "Out") + ".Column.Visible." + id }
    static func visible(_ id: String, incoming: Bool, preferences: UserDefaults) -> Bool {
        guard let definition = definitions.first(where: { $0.id == id }) else { return false }
        return (preferences.object(forKey: key(incoming: incoming, id: id)) as? NSNumber)?.boolValue ?? definition.visible
    }
}

struct SynchronizationHistoryTable: NSViewRepresentable {
    @ObservedObject var model: SynchronizationWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = HistoryTableView(); table.rowHeight = 24; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.allowsMultipleSelection = true
        table.menu = NSMenu(); table.menu?.delegate = context.coordinator
        for definition in SynchronizationHistoryColumns.definitions {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.id)); column.title = definition.title; column.width = definition.width
            column.isHidden = !SynchronizationHistoryColumns.visible(definition.id, incoming: model.tab == 4, preferences: model.preferences) || definition.id == "bugs" && !model.historyIssueProperties.showsBugIDColumn
            table.addTableColumn(column)
        }
        if model.preferences === UserDefaults.standard { table.autosaveName = model.tab == 4 ? "TurtleGit.SyncIn.RevisionColumns.v2" : "TurtleGit.SyncOut.RevisionColumns.v2"; table.autosaveTableColumns = true }
        let header = SynchronizationReferenceHeader()
        header.makeMenu = { [weak coordinator = context.coordinator] in coordinator?.headerMenu() }
        table.headerView = header; context.coordinator.table = table; context.coordinator.entryHashes = model.historyEntries.map(\.hash)
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.activateRevision)
        table.onReturn = { [weak coordinator = context.coordinator] in coordinator?.activateParentComparison() ?? false }
        table.onFind = { [weak coordinator = context.coordinator] in coordinator?.findHistory() ?? false }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        guard context.coordinator.sourceTab == model.tab, let table = scroll.documentView as? NSTableView else { return }
        if let column = table.tableColumns.first(where: { $0.identifier.rawValue == "graph" }) {
            // GraphCell uses three quarters of the row height per lane. Keep a
            // compact single-lane column, expanding enough to show all lanes.
            column.minWidth = max(65, CGFloat(model.historyGraph.map(\.width).max() ?? 1) * floor(table.rowHeight * 3 / 4) + 24)
            column.width = max(column.width, column.minWidth)
        }
        for column in table.tableColumns {
            let id = column.identifier.rawValue
            column.isHidden = !SynchronizationHistoryColumns.visible(id, incoming: model.tab == 4, preferences: model.preferences) || id == "bugs" && !model.historyIssueProperties.showsBugIDColumn
        }
        let previousHashes = context.coordinator.entryHashes
        let selectedHashes = Set(table.selectedRowIndexes.compactMap { previousHashes.indices.contains($0) ? previousHashes[$0] : nil })
        let hashes = model.historyEntries.map(\.hash)
        context.coordinator.entryHashes = hashes
        table.reloadData()
        let selection = IndexSet(hashes.enumerated().compactMap { selectedHashes.contains($0.element) ? $0.offset : nil })
        if table.selectedRowIndexes != selection { table.selectRowIndexes(selection, byExtendingSelection: false) }
        if let navigation = model.historyNavigation[model.tab], model.handledHistoryNavigation[model.tab] != navigation.id {
            model.handledHistoryNavigation[model.tab] = navigation.id
            if let row = hashes.firstIndex(of: navigation.hash) {
                if navigation.select { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                table.scrollRowToVisible(row)
            }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: SynchronizationWindowModel
        weak var table: NSTableView?
        var entryHashes: [String] = []
        let sourceTab: Int
        private var parentMenuTask: Task<Void, Never>?
        private var revertMenuTask: Task<Void, Never>?
        private var combineMenuTask: Task<Void, Never>?
        private var combineMenuCancellation: OperationCancellation?
        init(_ model: SynchronizationWindowModel) { self.model = model; sourceTab = model.tab }
        private final class CopyTarget: NSObject {
            let entries: [LogEntry], kind: SynchronizationHistoryCopy, reference: String?
            init(entries: [LogEntry], kind: SynchronizationHistoryCopy, reference: String?) { self.entries = entries; self.kind = kind; self.reference = reference }
        }
        private final class ComparisonTarget: NSObject {
            let from: ComparisonRevision, to: ComparisonRevision
            init(from: ComparisonRevision, to: ComparisonRevision) { self.from = from; self.to = to }
        }
        private final class RevisionTarget: NSObject {
            let revision: String, isTag: Bool, sourceTab: Int?
            init(_ revision: String, isTag: Bool = false, sourceTab: Int? = nil) { self.revision = revision; self.isTag = isTag; self.sourceTab = sourceTab }
        }
        private var revisionActionAvailable: Bool {
            !model.closed && !model.busy && !model.confirmingQuit && !model.confirmingCancellation && !model.hasBlockingChild && model.window?.attachedSheet == nil
        }
        func findHistory() -> Bool {
            guard sourceTab == model.tab, revisionActionAvailable, let action = model.onHistoryFind, table != nil else { return false }
            action(sourceTab, nil); return true
        }
        private final class FindTarget: NSObject {
            let tab: Int, index: Int
            init(tab: Int, index: Int) { self.tab = tab; self.index = index }
        }
        @objc func historyFind(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? FindTarget else { return }
            model.onHistoryFind?(target.tab, target.index)
        }
        @objc func historyExport(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? RevisionTarget else { return }
            model.onHistoryExport?(target.revision)
        }
        private final class OperationTarget: NSObject {
            let action: SynchronizationHistoryOperation
            init(_ action: SynchronizationHistoryOperation) { self.action = action }
        }
        private final class BisectTarget: NSObject {
            let request: LogBisectRequest
            let entries: [LogEntry]
            init(_ request: LogBisectRequest, entries: [LogEntry]) { self.request = request; self.entries = entries }
        }
        private final class DeleteTarget: NSObject {
            let names: [String], revision: String
            init(_ names: [String], revision: String) { self.names = names; self.revision = revision }
        }
        @objc func historyDelete(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? DeleteTarget else { return }
            model.deleteHistoryReferences(target.names, revision: target.revision)
        }
        private final class PushTarget: NSObject {
            let revision: String, preserveAllBranches: Bool
            init(_ revision: String, preserveAllBranches: Bool) { self.revision = revision; self.preserveAllBranches = preserveAllBranches }
        }
        @objc func historyPush(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? PushTarget else { return }
            model.onHistoryPush?(target.revision, target.preserveAllBranches)
        }
        @objc func historyPull(_ sender: NSMenuItem) { guard revisionActionAvailable else { return }; model.onHistoryPull?() }
        private final class PatchTarget: NSObject {
            let preset: FormatPatchPreset
            init(_ preset: FormatPatchPreset) { self.preset = preset }
        }
        @objc func historyBisect(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? BisectTarget else { return }
            model.requestHistoryBisect(target.request, entries: target.entries)
        }
        @objc func historyFormatPatch(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? PatchTarget else { return }
            model.onHistoryFormatPatch?(target.preset)
        }
        private final class ReplayTarget: NSObject {
            let upstream: String?, commits: [String]?
            init(upstream: String? = nil, commits: [String]? = nil) { self.upstream = upstream; self.commits = commits }
        }
        @objc func historyOperation(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? OperationTarget else { return }
            model.onHistoryOperation?(target.action)
        }
        @objc func historyReplay(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? ReplayTarget else { return }
            model.replayHistory(upstream: target.upstream, commits: target.commits)
        }
        private final class RangeTarget: NSObject {
            let range: HistoryRevisionRange
            init(_ range: HistoryRevisionRange) { self.range = range }
        }
        @objc func historyRangeLog(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? RangeTarget else { return }
            model.onHistoryLogRange?(target.range)
        }
        @objc func historyContainingReferences(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? RevisionTarget else { return }
            if let tab = target.sourceTab { model.onHistoryContainingReferences?(target.revision, tab) }
        }
        @objc func historyLog(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? RevisionTarget else { return }
            model.onHistoryLog?(target.revision)
        }
        @objc func browseHistory(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? RevisionTarget else { return }
            model.onHistoryBrowseRepository?(target.revision)
        }
        @objc func createHistoryReference(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? RevisionTarget else { return }
            model.onHistoryCreateReference?(target.isTag, target.revision)
        }
        private final class DiffTarget: NSObject {
            let diff: SynchronizationHistoryDiff
            init(_ diff: SynchronizationHistoryDiff) { self.diff = diff }
        }
        @objc func compareChangeSets(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? ComparisonTarget,
                  case .revision(let first) = target.from, case .revision(let second) = target.to else { return }
            model.compareHistoryChangeSets(first: first, second: second)
        }
        @objc func historyDiff(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? DiffTarget else { return }
            model.showHistoryDiff(target.diff, alternate: NSEvent.modifierFlags.contains(.shift))
        }
        @objc func compareHistory(_ sender: NSMenuItem) {
            guard !model.closed, !model.busy, !model.confirmingQuit, !model.confirmingCancellation,
                  !model.hasBlockingChild, model.window?.attachedSheet == nil,
                  let target = sender.representedObject as? ComparisonTarget else { return }
            model.onHistoryCompare?(target.from, target.to)
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            parentMenuTask?.cancel(); parentMenuTask = nil; revertMenuTask?.cancel(); revertMenuTask = nil; combineMenuTask?.cancel(); combineMenuTask = nil; combineMenuCancellation?.cancel(); combineMenuCancellation = nil
            menu.removeAllItems(); menu.autoenablesItems = false
            guard sourceTab == model.tab, let table else { return }
            let entries = table.selectedRowIndexes.compactMap { model.historyEntries.indices.contains($0) ? model.historyEntries[$0] : nil }
            guard !entries.isEmpty else { return }
            model.historyFindIndex[sourceTab] = max(0, table.selectedRow)
            let clipboard = NSMenu(title: "Copy to clipboard"); clipboard.autoenablesItems = false
            let available = !model.closed && !model.busy && !model.confirmingQuit && !model.hasBlockingChild
            let pointed = (table as? HistoryTableView)?.contextReference
            func comparisonItem(_ title: String, from: ComparisonRevision, to: ComparisonRevision, in targetMenu: NSMenu) {
                let item = NSMenuItem(title: title, action: #selector(compareHistory(_:)), keyEquivalent: "")
                item.target = self
                item.isEnabled = available && !model.confirmingCancellation && model.window?.attachedSheet == nil && model.onHistoryCompare != nil
                item.image = MenuIcon.compare.contextImage(defaults: model.preferences)
                item.representedObject = ComparisonTarget(from: from, to: to)
                targetMenu.addItem(item)
            }
            func diffItem(_ title: String, diff: SynchronizationHistoryDiff, in targetMenu: NSMenu) {
                let item = NSMenuItem(title: title, action: #selector(historyDiff(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = available && !model.confirmingCancellation && model.window?.attachedSheet == nil
                item.image = MenuIcon.compare.contextImage(defaults: model.preferences)
                item.representedObject = DiffTarget(diff); targetMenu.addItem(item)
            }
            func operationItem(_ title: String, _ action: SynchronizationHistoryOperation, _ icon: MenuIcon, in targetMenu: NSMenu) {
                let item = NSMenuItem(title: title, action: #selector(historyOperation(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryOperation != nil
                item.image = icon.contextImage(defaults: model.preferences); item.representedObject = OperationTarget(action); targetMenu.addItem(item)
            }
            func replayItem(_ title: String, _ target: ReplayTarget, _ icon: MenuIcon) {
                let item = NSMenuItem(title: title, action: #selector(historyReplay(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = revisionActionAvailable && model.runHistoryReplay != nil
                item.image = icon.contextImage(defaults: model.preferences); item.representedObject = target; menu.addItem(item)
            }
            func bisectItem(_ command: LogBisectCommand) {
                let request: LogBisectRequest
                if command == .start {
                    request = LogBisectRequest(good: entries.last!.references.first?.name ?? entries.last!.hash, bad: entries.first!.references.first?.name ?? entries.first!.hash, operation: nil, revisions: [])
                } else { request = LogBisectRequest(good: nil, bad: nil, operation: command.operation, revisions: entries.map(\.hash)) }
                let item = NSMenuItem(title: command.title, action: #selector(historyBisect(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryBisect != nil
                item.image = command.icon.contextImage(defaults: model.preferences); item.representedObject = BisectTarget(request, entries: entries); menu.addItem(item)
            }
            if entries.count == 1, let entry = entries.first {
                comparisonItem("Compare with working tree", from: .revision(entry.hash), to: .workingTree, in: menu)
                if entry.parents.count == 1, let parent = entry.parents.first {
                    diffItem("Show changes as unified diff", diff: .revisions(parent, entry.hash), in: menu)
                    comparisonItem("Compare with previous revision", from: .revision(parent), to: .revision(entry.hash), in: menu)
                } else if entry.parents.count > 1 {
                    let unified = NSMenu(); unified.autoenablesItems = false
                    for diff in [SynchronizationHistoryDiff.allParents(entry.hash), .mergedFiles(entry.hash), .extraChanges(entry.hash)] {
                        diffItem(diff.title, diff: diff, in: unified)
                    }
                    for (index, hash) in entry.parents.enumerated() {
                        diffItem(model.historyParentTitle(hash, index: index), diff: .revisions(hash, entry.hash), in: unified)
                    }
                    let unifiedItem = NSMenuItem(title: "Unified diff with", action: nil, keyEquivalent: "")
                    unifiedItem.image = MenuIcon.compare.contextImage(defaults: model.preferences); unifiedItem.submenu = unified; menu.addItem(unifiedItem)
                    let parentItem = NSMenuItem(title: "Compare with previous revision", action: nil, keyEquivalent: "")
                    parentItem.image = MenuIcon.compare.contextImage(defaults: model.preferences)
                    let parents = NSMenu(); parents.autoenablesItems = false
                    for (index, hash) in entry.parents.enumerated() {
                        comparisonItem(model.historyParentTitle(hash, index: index), from: .revision(hash), to: .revision(entry.hash), in: parents)
                    }
                    parentItem.submenu = parents; menu.addItem(parentItem)
                    let model = model
                    parentMenuTask = Task { [weak parents, weak unified] in
                        await model.loadHistoryParentSubjects(entry)
                        guard !Task.isCancelled, !model.closed, !model.busy, let parents else { return }
                        for (index, item) in parents.items.enumerated() where entry.parents.indices.contains(index) {
                            item.title = model.historyParentTitle(entry.parents[index], index: index)
                        }
                        if let unified {
                            for (index, item) in unified.items.dropFirst(3).enumerated() where entry.parents.indices.contains(index) {
                                item.title = model.historyParentTitle(entry.parents[index], index: index)
                            }
                        }
                    }
                }
            } else if entries.count == 2 || table.selectedRowIndexes.last! - table.selectedRowIndexes.first! + 1 == entries.count {
                comparisonItem("Compare revisions", from: .revision(entries.last!.hash), to: .revision(entries.first!.hash), in: menu)
                if entries.count == 2 { diffItem("Show changes as unified diff", diff: .revisions(entries.last!.hash, entries.first!.hash), in: menu) }
            }
            if entries.count == 2 {
                let first = entries[0].hash, last = entries[1].hash
                let ranges = [HistoryRevisionRange(from: last, to: first), HistoryRevisionRange(from: first, to: last), HistoryRevisionRange(from: last, to: first, kind: .symmetricDifference)]
                for range in ranges {
                    let title = "Show log of " + range.from.prefix(8) + range.separator + range.to.prefix(8)
                    let item = NSMenuItem(title: title, action: #selector(historyRangeLog(_:)), keyEquivalent: "")
                    item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryLogRange != nil
                    item.image = MenuIcon.log.contextImage(defaults: model.preferences); item.representedObject = RangeTarget(range); menu.addItem(item)
                }
                let changes = NSMenuItem(title: "Compare change sets", action: #selector(compareChangeSets(_:)), keyEquivalent: "")
                changes.target = self; changes.isEnabled = revisionActionAvailable
                changes.image = MenuIcon.compare.contextImage(defaults: model.preferences)
                changes.representedObject = ComparisonTarget(from: .revision(entries[0].hash), to: .revision(entries[1].hash)); menu.addItem(changes)
            }
            if !model.historyBare, model.historyBisectActive, entries.count == 1,
               !entries[0].references.contains(where: { $0.name.hasPrefix("refs/bisect/") }) {
                for command in [LogBisectCommand.good, .bad, .skip] { bisectItem(command) }
                menu.addItem(.separator())
            }
            if entries.count == 1, let entry = entries.first {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                let stash = entry.references.contains { $0.name == "refs/stash" }
                if !stash && !entry.references.isEmpty || (table as? HistoryTableView)?.contextExtendedMenu == true {
                    let log = NSMenuItem(title: "Show log", action: #selector(historyLog(_:)), keyEquivalent: "")
                    log.target = self; log.isEnabled = revisionActionAvailable && model.onHistoryLog != nil
                    log.image = MenuIcon.log.contextImage(defaults: model.preferences); log.representedObject = RevisionTarget(entry.hash); menu.addItem(log)
                }
                let browse = NSMenuItem(title: "Browse repository", action: #selector(browseHistory(_:)), keyEquivalent: "")
                browse.target = self; browse.isEnabled = revisionActionAvailable && model.onHistoryBrowseRepository != nil
                browse.image = MenuIcon.repositoryBrowser.contextImage(defaults: model.preferences); browse.representedObject = RevisionTarget(entry.hash); menu.addItem(browse)
                if !stash && !model.historyBare {
                    let isHead = entry.hash == model.historyHead
                    if !isHead && !model.historyMergeActive {
                        operationItem("Merge to \"" + model.historyCurrentBranch + "\"…", .merge(pointed?.name ?? entry.references.first?.name ?? entry.hash), .merge, in: menu)
                    }
                    operationItem("Reset \"" + model.historyCurrentBranch + "\" to this…", .reset(entry.hash), .reset, in: menu)
                    let branches = (pointed.map { [$0.name] } ?? entry.references.map(\.name)).filter { $0.hasPrefix("refs/heads/") && $0 != "refs/heads/" + model.historyCurrentBranch }
                    if branches.count == 1 {
                        let reference = branches[0], short = String(reference.dropFirst("refs/heads/".count))
                        operationItem("Switch/Checkout to \"" + short + "\"", .switchBranch(short), .checkout, in: menu)
                    } else if branches.count > 1 {
                        let submenu = NSMenu(); submenu.autoenablesItems = false
                        for reference in branches {
                            let short = String(reference.dropFirst("refs/heads/".count))
                            operationItem(short, .switchBranch(short), .checkout, in: submenu)
                            submenu.items.last?.image = nil
                        }
                        let item = NSMenuItem(title: "Switch/Checkout to", action: nil, keyEquivalent: "")
                        item.image = MenuIcon.checkout.contextImage(defaults: model.preferences); item.submenu = submenu; menu.addItem(item)
                    }
                    if !isHead {
                        operationItem("Switch/Checkout to this…", .checkout(pointed?.name ?? entry.references.first { $0.name.hasPrefix("refs/remotes/") }?.name ?? entry.hash), .checkout, in: menu)
                    }
                }
                if !entry.references.contains(where: { $0.name == "refs/stash" }) {
                    let remote = entry.references.first { $0.name.hasPrefix("refs/remotes/") }?.name
                    for isTag in [false, true] {
                        // Source only uses a pointed remote label for branch creation;
                        // otherwise both commands prefer the first remote for tracking.
                        let pointedRemote = !isTag ? pointed?.name : nil
                        let revision = pointedRemote.flatMap { name in entry.references.contains { $0.name == name && name.hasPrefix("refs/remotes/") } ? name : nil } ?? remote ?? entry.hash
                        let item = NSMenuItem(title: isTag ? "Create tag at this version…" : "Create branch at this version…", action: #selector(createHistoryReference(_:)), keyEquivalent: "")
                        item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryCreateReference != nil
                        item.image = (isTag ? MenuIcon.tag : .branch).contextImage(defaults: model.preferences)
                        item.representedObject = RevisionTarget(revision, isTag: isTag); menu.addItem(item)
                    }
                }
                if !stash && !model.historyBare && !model.historyMergeActive && entry.hash != model.historyHead {
                    let upstream = entry.references.first { $0.name.hasPrefix("refs/heads/") }.map { String($0.name.dropFirst("refs/heads/".count)) } ?? entry.references.first?.name ?? entry.hash
                    replayItem("Rebase \"" + model.historyCurrentBranch + "\" onto this…", ReplayTarget(upstream: upstream), .rebase)
                }
                let export = NSMenuItem(title: "Export this version…", action: #selector(historyExport(_:)), keyEquivalent: "")
                export.target = self; export.isEnabled = revisionActionAvailable && model.onHistoryExport != nil
                export.image = MenuIcon.export.contextImage(defaults: model.preferences)
                export.representedObject = RevisionTarget(entry.references.first { $0.name.hasPrefix("refs/tags/") }?.name ?? entry.hash)
                menu.addItem(export)
                if !stash && !model.historyBare && !model.historyMergeActive {
                    if entry.parents.count == 1 {
                        operationItem("Revert change by this commit", .revert([entry], nil), .revert, in: menu)
                    } else if entry.parents.count > 1 {
                        let parents = NSMenu(); parents.autoenablesItems = false
                        for (index, hash) in entry.parents.enumerated() {
                            operationItem(model.historyParentTitle(hash, index: index), .revert([entry], index + 1), .revert, in: parents)
                            parents.items.last?.image = nil
                        }
                        let item = NSMenuItem(title: "Revert change by this commit", action: nil, keyEquivalent: "")
                        item.image = MenuIcon.revert.contextImage(defaults: model.preferences); item.submenu = parents; menu.addItem(item)
                        // Parent captions share the compare/unified menu's owned metadata read.
                        revertMenuTask = Task { [weak parents] in
                            await model.loadHistoryParentSubjects(entry)
                            guard !Task.isCancelled, !model.closed, let parents else { return }
                            for (index, item) in parents.items.enumerated() { item.title = model.historyParentTitle(entry.parents[index], index: index) }
                        }
                    }
                }
                if !stash { operationItem("Edit Notes", .editNotes(entry.hash), .rebaseEdit, in: menu) }
            }
            if entries.count > 1, !model.historyBare, !model.historyMergeActive {
                operationItem("Revert changes by these commits", .revert(entries, nil), .revert, in: menu)
            }
            if entries.count > 1, !model.historyBare, model.historyBisectActive,
               !entries[0].references.contains(where: { $0.name.hasPrefix("refs/bisect/") }) { bisectItem(.skip); menu.addItem(.separator()) }
            if entries.count > 1, !model.historyBare, !model.historyMergeActive,
               table.selectedRowIndexes.last! - table.selectedRowIndexes.first! + 1 == entries.count,
               let headRow = model.historyEntries.firstIndex(where: { $0.hash == model.historyHead }), table.selectedRowIndexes.first! >= headRow {
                let offset = table.selectedRowIndexes.first! - headRow, expectedHead = model.historyHead
                operationItem("Combine to one commit", .combine(entries, offset, expectedHead), .combine, in: menu)
                let item = menu.items.last!; item.isHidden = true; item.isEnabled = false
                let request = OperationCancellation(); combineMenuCancellation = request
                let repository = model.repository
                combineMenuTask = Task { [weak item, weak self] in
                    do {
                        guard let self else { return }
                        try await self.model.validateCombineSelection(entries,offset:offset,head:expectedHead,token:request)
                        guard !request.isCancelled,!Task.isCancelled,!self.model.closed,let table=self.table,
                              table.selectedRowIndexes.compactMap({ self.model.historyEntries.indices.contains($0) ? self.model.historyEntries[$0].hash:nil }) == entries.map(\.hash) else { return }
                        item?.isHidden = false; item?.isEnabled = self.revisionActionAvailable
                    } catch { /* Source omits Combine when ancestry cannot be resolved. */ }
                }
            }
            if !model.historyBare && !model.historyMergeActive && entries.first?.hash != model.historyHead {
                replayItem(entries.count > 1 ? "Cherry Pick selected commits…" : "Cherry Pick this commit…", ReplayTarget(commits: entries.map(\.hash)), .cherryPick)
            }
            if let preset = FormatPatchPreset.logSelection(orderedHashes: model.historyEntries.map(\.hash), selected: Set(entries.map(\.hash))) {
                let item = NSMenuItem(title: "Format Patch…", action: #selector(historyFormatPatch(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryFormatPatch != nil
                item.image = MenuIcon.patch.contextImage(defaults: model.preferences); item.representedObject = PatchTarget(preset); menu.addItem(item)
            }
            if entries.count == 2, !model.historyBare, !model.historyMergeActive, !model.historyBisectActive,
               !entries[0].references.contains(where: { $0.name == "refs/stash" }) { menu.addItem(.separator()); bisectItem(.start) }
            if entries.count == 1, let entry = entries.first {
                let extended = (table as? HistoryTableView)?.contextExtendedMenu == true
                let stash = entry.references.contains { $0.name == "refs/stash" }
                let local = entry.references.contains { $0.name.hasPrefix("refs/heads/") || $0.name.hasPrefix("refs/tags/") }
                if (!stash && local) || extended {
                    let pointedLocal = pointed?.name.hasPrefix("refs/heads/") == true || pointed?.name.hasPrefix("refs/tags/") == true ? pointed?.name : nil
                    let pointedTarget = pointed?.name.hasPrefix("refs/remotes/") == false ? pointed?.name : nil
                    let target = pointedTarget ?? entry.references.first { $0.name.hasPrefix("refs/heads/") }?.name ?? entry.references.first { $0.name.hasPrefix("refs/tags/") }?.name ?? entry.hash
                    let title = pointedLocal.map { "Push \"" + (GitReferenceName.removingPrefix("refs/heads/", from: $0) ?? GitReferenceName.removingPrefix("refs/tags/", from: $0) ?? $0) + "\"…" } ?? "Push…"
                    let item = NSMenuItem(title: title, action: #selector(historyPush(_:)), keyEquivalent: "")
                    item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryPush != nil
                    item.image = MenuIcon.push.contextImage(defaults: model.preferences); item.representedObject = PushTarget(GitReferenceName.removingSuffix("^{}", from: target) ?? target, preserveAllBranches: pointedTarget == nil); menu.addItem(item)
                }
                if entry.hash == model.historyHead, !model.historyBare, !model.historyMergeActive {
                    let item = NSMenuItem(title: "Pull…", action: #selector(historyPull(_:)), keyEquivalent: "")
                    item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryPull != nil
                    item.image = MenuIcon.pull.contextImage(defaults: model.preferences); menu.addItem(item)
                }
                let candidates = (pointed.map { [$0.name] } ?? entry.references.map(\.name)).filter { $0 != "refs/heads/" + model.historyCurrentBranch }
                func deletionItem(_ title: String, names: [String], in targetMenu: NSMenu, icon: Bool) {
                    let item = NSMenuItem(title: title, action: #selector(historyDelete(_:)), keyEquivalent: "")
                    item.target = self; item.isEnabled = revisionActionAvailable
                    if icon { item.image = MenuIcon.remove.contextImage(defaults: model.preferences) }
                    item.representedObject = DeleteTarget(names, revision: entry.hash); targetMenu.addItem(item)
                }
                if candidates.count == 1 { deletionItem("Delete " + candidates[0], names: candidates, in: menu, icon: true) }
                else if candidates.count > 1 {
                    let submenu = NSMenu(); submenu.autoenablesItems = false
                    for name in candidates { deletionItem(name, names: [name], in: submenu, icon: false) }
                    deletionItem("All", names: candidates, in: submenu, icon: false)
                    let item = NSMenuItem(title: "Delete branch/tag", action: nil, keyEquivalent: "")
                    item.image = MenuIcon.remove.contextImage(defaults: model.preferences); item.submenu = submenu; menu.addItem(item)
                }
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for kind in SynchronizationHistoryCopy.allCases {
                if kind == .referenceNames && (entries.count != 1 || entries[0].references.isEmpty) { continue }
                let item = NSMenuItem(title: kind.rawValue, action: #selector(copyHistory(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = available
                item.image = MenuIcon.copy.contextImage(defaults: model.preferences)
                item.representedObject = CopyTarget(entries: entries, kind: kind, reference: kind == .referenceNames ? pointed?.name : nil)
                clipboard.addItem(item)
            }
            let parent = NSMenuItem(title: "Copy to clipboard", action: nil, keyEquivalent: "")
            parent.image = MenuIcon.copy.contextImage(defaults: model.preferences); parent.submenu = clipboard; menu.addItem(parent)
            let find = NSMenuItem(title: "Find", action: #selector(historyFind(_:)), keyEquivalent: "")
            find.target = self; find.isEnabled = revisionActionAvailable && model.onHistoryFind != nil
            find.image = MenuIcon.historyFind.contextImage(defaults: model.preferences)
            find.representedObject = FindTarget(tab: sourceTab, index: max(0, table.selectedRow)); menu.addItem(find)
            if entries.count == 1, let entry = entries.first {
                let item = NSMenuItem(title: "Show branches this commit is on", action: #selector(historyContainingReferences(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryContainingReferences != nil
                item.image = MenuIcon.showBranches.contextImage(defaults: model.preferences)
                item.representedObject = RevisionTarget(entry.hash, sourceTab: model.tab); menu.addItem(item)
            }
        }
        func menuDidClose(_ menu: NSMenu) { parentMenuTask?.cancel(); parentMenuTask = nil; revertMenuTask?.cancel(); revertMenuTask = nil; combineMenuTask?.cancel(); combineMenuTask = nil; combineMenuCancellation?.cancel(); combineMenuCancellation = nil; (table as? HistoryTableView)?.contextReference = nil; (table as? HistoryTableView)?.contextExtendedMenu = false }
        @objc func copyHistory(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? CopyTarget else { return }
            model.copyHistory(target.entries, kind: target.kind, pointedReference: target.reference)
        }
        func headerMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            let reset = NSMenuItem(title: "Reset columns", action: #selector(resetColumns), keyEquivalent: ""); reset.target = self; menu.addItem(reset); menu.addItem(.separator())
            for definition in SynchronizationHistoryColumns.definitions where definition.id != "bugs" || model.historyIssueProperties.showsBugIDColumn {
                let item = NSMenuItem(title: definition.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = definition.id
                item.state = table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(definition.id))?.isHidden == false ? .on : .off
                menu.addItem(item)
            }
            return menu
        }
        @objc func toggleColumn(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String, let column = table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }
            column.isHidden.toggle()
            model.preferences.set(!column.isHidden, forKey: SynchronizationHistoryColumns.key(incoming: model.tab == 4, id: id))
        }
        @objc func resetColumns() {
            guard let table else { return }
            for (index, definition) in SynchronizationHistoryColumns.definitions.enumerated() {
                model.preferences.removeObject(forKey: SynchronizationHistoryColumns.key(incoming: model.tab == 4, id: definition.id))
                guard let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(definition.id)) else { continue }
                table.moveColumn(table.tableColumns.firstIndex(of: column)!, toColumn: index)
                column.width = definition.width; column.isHidden = !definition.visible || definition.id == "bugs" && !model.historyIssueProperties.showsBugIDColumn
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { model.historyEntries.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            let entries = model.historyEntries
            guard entries.indices.contains(row) else { return nil }
            let entry = entries[row]
            if column?.identifier.rawValue == "graph" {
                let cell = GraphCell(); cell.preferences = model.preferences; cell.parentCount = entry.parents.count
                if model.historyGraph.indices.contains(row) { cell.graph = model.historyGraph[row] }; return cell
            }
            if column?.identifier.rawValue == "actions" {
                model.requestHistoryActions(entry)
                let cell = NSTableCellView()
                let slots: [(LogRevisionActions, MenuIcon, String)] = [(.modified, .actionModified, "Modified"), (.added, .actionAdded, "Added/copied"), (.deleted, .actionDeleted, "Deleted"), (.replaced, .actionReplaced, "Replaced/renamed"), (.conflicted, .actionConflicted, "Conflicted")]
                var images: [NSView] = [], labels: [String] = []
                if let actions = model.historyActions[entry.hash] {
                    for (flag, icon, title) in slots {
                        let image = NSImageView(); image.image = actions.contains(flag) ? icon.image() : nil
                        images.append(image); if actions.contains(flag) { labels.append(title) }
                    }
                    if labels.isEmpty { labels = ["No changed files"] }
                } else {
                    let failed = model.historyActionFailures.contains(entry.hash)
                    images = [NSImageView(image: (failed ? MenuIcon.actionError : .actionFetching).image() ?? NSImage())]
                    labels = [failed ? "Could not read changed files" : "Reading changed files"]
                }
                for image in images { image.translatesAutoresizingMaskIntoConstraints = false; image.widthAnchor.constraint(equalToConstant: 16).isActive = true; image.heightAnchor.constraint(equalToConstant: 16).isActive = true }
                let stack = NSStackView(views: images); stack.orientation = .horizontal; stack.spacing = 0; stack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stack)
                NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                cell.toolTip = labels.joined(separator: ", "); cell.setAccessibilityLabel(cell.toolTip); return cell
            }
            let dates = HistoryDateSettings.load(defaults: model.preferences)
            let text = NSTextField(labelWithString: ""); text.lineBreakMode = .byTruncatingTail; text.maximumNumberOfLines = 1
            if column?.identifier.rawValue == "message" {
                let painter = LogReferenceTextCell(textCell: ""); painter.isEditable = false; painter.isSelectable = false; painter.isBordered = false; painter.drawsBackground = false; text.cell = painter
            }
            text.font = .systemFont(ofSize: 12, weight: entry.isHead ? .bold : .regular)
            if model.preferences.bool(forKey: "LogFontForLogCtrl") {
                let size = (model.preferences.object(forKey: "LogFontSize") as? NSNumber)?.intValue ?? MessageEditorFont.defaultSize
                let font = MessageEditorFont.resolve(name: model.preferences.string(forKey: "LogFontName") ?? MessageEditorFont.defaultName, size: size)
                text.font = entry.isHead ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
            }
            if model.historyHighlights[sourceTab] == entry.hash, let font = text.font {
                text.font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            switch column?.identifier.rawValue {
            case "hash": text.stringValue = entry.hash
            case "author": text.stringValue = entry.author
            case "date": text.stringValue = dates.format(entry.date); text.toolTip = dates.relative ? dates.format(entry.date, absolute: true) : nil
            case "email": text.stringValue = entry.email
            case "committer": text.stringValue = entry.committer
            case "committerEmail": text.stringValue = entry.committerEmail
            case "committerDate": text.stringValue = dates.format(entry.committerDate); text.toolTip = dates.relative ? dates.format(entry.committerDate, absolute: true) : nil
            case "bugs": text.stringValue = entry.issueIDs
            default:
                let badges = NSMutableAttributedString()
                let badgeFont = model.preferences.bool(forKey: "LogFontForLogCtrl") ? text.font! : NSFont.systemFont(ofSize: 11, weight: .medium)
                let font = model.historyHighlights[sourceTab] == entry.hash ? NSFontManager.shared.convert(badgeFont, toHaveTrait: .italicFontMask) : badgeFont
                for badge in model.historyReferenceContext.labels(entry.references, symbolize: model.preferences.bool(forKey: "SymbolizeRefNames")) {
                    let color = LogPalette.native(LogColorRole.reference(badge.reference), preferences: model.preferences)
                    let foreground = NSColor(name: nil) { _ in LogPalette.foreground(background: color) }
                    let attributes: [NSAttributedString.Key: Any] = [.backgroundColor: color, .foregroundColor: foreground, .font: font]
                    let start = badges.length; badges.append(NSAttributedString(string: " ", attributes: attributes))
                    if badge.singleRemote {
                        let marker = NSMutableAttributedString(attachment: LogUpstreamMarker.attachment(foreground: foreground, font: font, isHead: entry.isHead))
                        marker.addAttributes(attributes, range: NSRange(location: 0, length: marker.length)); badges.append(marker)
                    }
                    badges.append(NSAttributedString(string: badge.text + " ", attributes: attributes))
                    badges.addAttribute(.logReference, value: LogReferenceStyle(badge, color: color), range: NSRange(location: start, length: badges.length - start))
                    let space = (" " as NSString).size(withAttributes: [.font: font]).width
                    badges.addAttribute(.kern, value: 4 - space, range: NSRange(location: start, length: 1))
                    badges.addAttribute(.kern, value: 4 - space + (badge.kind == .annotatedTag ? 8 : 0), range: NSRange(location: badges.length - 1, length: 1))
                    badges.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: 1 - space]))
                }
                let label = NSMutableAttributedString(), message = NSAttributedString(string: entry.logLine(fullMessage: model.preferences.bool(forKey: "FullCommitMessageOnLogLine")), attributes: [.font: text.font!])
                if model.preferences.bool(forKey: "DrawTagsBranchesOnRightSide") { label.append(message); if badges.length > 0 { label.append(NSAttributedString(string: " ", attributes: [.font: text.font!])); label.append(badges) } }
                else { label.append(badges); label.append(message) }
                text.attributedStringValue = label; text.toolTip = entry.historySubject
            }
            let cell = NSTableCellView(); cell.addSubview(text); cell.textField = text; text.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        func activateParentComparison() -> Bool {
            guard model.preferences.bool(forKey: "DiffByDoubleClickInLog") else { return false }
            guard revisionActionAvailable, let table,
                  let index = table.selectedRowIndexes.first, model.historyEntries.indices.contains(index),
                  let parent = model.historyEntries[index].parents.first else { return true }
            model.onHistoryCompare?(.revision(parent), .revision(model.historyEntries[index].hash))
            return true
        }
        @objc func activateRevision(_ sender: Any?) { _ = activateParentComparison() }
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
