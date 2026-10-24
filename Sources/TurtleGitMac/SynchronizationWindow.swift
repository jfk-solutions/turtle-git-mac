// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
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
    private var presentationClosed = false
    private var pendingRecovery = false
    var onRecovery: () -> Void = {}
    private var completion: ((Result<SynchronizationProgressResult, Error>) -> Void)?
    init(repository: GitRepository, operation: SynchronizationProgressOperation, cancellation: OperationCancellation, preferences: UserDefaults, access: RepositoryAccessLease? = nil, transportFactory: SSHTransportFactory? = nil, backend:GitLibGit2Configuration? = nil,
         completion: @escaping (Result<SynchronizationProgressResult, Error>) -> Void) {
        model = SynchronizationProgressModel(repository: repository, operation: operation, cancellation: cancellation, preferences: preferences, access: access, transportFactory: transportFactory,backend:backend)
        self.completion = completion
        let window = SubmoduleProgressNativeWindow(contentRect: NSRect(x: 0, y: 0, width: operation.compactProgress ? 480 : 760, height: operation.compactProgress ? 170 : 420), styleMask: operation.compactProgress ? [.titled, .closable] : [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "\(operation.title)", preferences: preferences)
        window.isReleasedWhenClosed = false; window.contentMinSize = operation.compactProgress ? NSSize(width: 400, height: 150) : NSSize(width: 560, height: 300)
        window.contentViewController = NSHostingController(rootView: SynchronizationProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in self?.closePresentation() }
        model.requestRecovery = { [weak self] in
            guard let self, !self.presentationClosed, !self.pendingRecovery, !self.model.busy,
                  !self.model.confirmingCancellation, self.window?.attachedSheet == nil else { return false }
            self.pendingRecovery = true; self.closePresentation(); return true
        }
        window.escapeAction = { [weak model] in guard let model else { return }; if model.busy { model.cancel() } else { model.close() } }
        model.confirmCancel = { [weak self] reply in
            guard let self, let window = self.window, window.attachedSheet == nil else { reply(false); return }
            let alert = NSAlert(); alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); self.alert = alert
            alert.beginSheetModal(for: window) { [weak self] response in self?.alert = nil; reply(response == .alertFirstButtonReturn) }
        }
        if !operation.compactProgress { DialogGeometry.attach(window, identifier: "ProgressDlg") }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func closePresentation() { guard !model.busy, !model.confirmingCancellation, window?.attachedSheet == nil else { return }; window?.sheetParent?.endSheet(window!); close() }
    func abortPresentation() {
        pendingRecovery = false; model.invalidate()
        if let alert, window?.attachedSheet === alert.window { window?.endSheet(alert.window, returnCode: .abort) }
        alert = nil; window?.sheetParent?.endSheet(window!); close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        guard !model.confirmingCancellation, sender.attachedSheet == nil else { return false }
        sender.sheetParent?.endSheet(sender); return true
    }
    func windowWillClose(_ notification: Notification) {
        guard !presentationClosed else { return }; presentationClosed = true
        let result = model.result ?? .failure(OperationCancellationFailure.cancelled)
        model.saveActionLog(); model.invalidate(); window?.sheetParent?.endSheet(window!)
        if let alert, window?.attachedSheet === alert.window { window?.endSheet(alert.window, returnCode: .abort); alert.window.close() }
        alert = nil
        let callback = completion, didClose = onClosed
        let recovery = pendingRecovery ? onRecovery : nil; pendingRecovery = false; completion = nil
        // A forcibly closed child must not let its parent mutate Git while the
        // previous worker is still draining (including ignored cancellation).
        model.whenDrained { didClose(); callback?(result); recovery?() }
    }
}

@MainActor final class SynchronizationProgressModel: ObservableObject, ActionLogProgress {
    private(set) static var activeOperations = 0
    let progressPresentation: GitCommandPresentation
    let repository: GitRepository, operation: SynchronizationProgressOperation, preferences: UserDefaults
    let backend:GitLibGit2Configuration
    private let cancellation: OperationCancellation
    private let autoClosePolicy: GitProgressAutoClose
    private let transportFactory: SSHTransportFactory?
    private var transportCoordinator: SSHTransportCoordinator?
    private let access: RepositoryAccessLease?
    private var started = false, closed = false, working = false
    private var drained: [() -> Void] = []
    private var outputState: GitProgressOutputState
    private var startedAt: TimeInterval = 0
    private var inspection: OperationCancellation?
    private let recoveryOwner = UUID()
    private var recoveryRevision = UUID()
    @Published private(set) var recoveryAvailable = false
    @Published private(set) var recoveryConsumed = false
    struct RecoveryReceipt { fileprivate let owner: UUID; fileprivate let revision: UUID }
    var requestRecovery: () -> Bool = { false }
    var inspectConflicts: ((OperationCancellation) async throws -> Bool)?
    func captureRecovery() -> RecoveryReceipt? {
        guard !closed, !working, !busy, !confirmingCancellation, recoveryAvailable, !recoveryConsumed else { return nil }
        return RecoveryReceipt(owner:recoveryOwner,revision:recoveryRevision)
    }
    func performRecovery(_ receipt: RecoveryReceipt) {
        guard receipt.owner == recoveryOwner, receipt.revision == recoveryRevision, captureRecovery() != nil else { return }
        recoveryConsumed = true
        if !requestRecovery(), !closed { recoveryConsumed = false }
    }
    private var activeCancellation: OperationCancellation { inspection ?? cancellation }
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var completionRange: NSRange?
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var busy = true
    @Published private(set) var output = ""
    @Published private(set) var confirmingCancellation = false
    private(set) var result: Result<SynchronizationProgressResult, Error>?
    var close: () -> Void = {}
    var confirmCancel: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    // The receiver can hold an actual worker boundary without changing product Git operations.
    var executeOperation: ((@escaping @Sendable (GitOutputChunk) -> Void) async throws -> SynchronizationProgressResult)?
    var actionLogRepository: URL { repository.root }
    var actionLogCancelled: Bool { cancelled }
    var actionLogFailed: Bool { !success }
    var actionLogEligible: Bool { started && !busy && !closed && !operation.compactProgress }
    func saveActionLog() {
        guard actionLogEligible else { return }
        ProgressActionLog.record(owner: self, repository: repository.root, output: output, cancelled: cancelled, failed: !success)
    }
    init(repository: GitRepository, operation: SynchronizationProgressOperation, cancellation: OperationCancellation, preferences: UserDefaults, access: RepositoryAccessLease? = nil, transportFactory: SSHTransportFactory? = nil,backend:GitLibGit2Configuration? = nil) {
        let isCheckout:Bool;if case .checkout=operation {isCheckout=true}else{isCheckout=false}
        let capturedBackend=(isCheckout ? repository.libgit2Configuration:nil) ?? backend ?? .load(from:preferences,helperURL:repository.libgit2Configuration?.helperURL)
        self.backend = capturedBackend
        self.access = access; self.transportFactory = transportFactory; autoClosePolicy = GitProgressAutoClose(preferences: preferences)
        // A checkout receipt belongs to the exact actor captured by its parent
        // transport attempt. Preserve that actor and its already frozen policy.
        self.repository = isCheckout ? repository:repository.capturingBackend(capturedBackend); self.operation = operation; self.cancellation = cancellation; self.preferences = preferences
        outputState = GitProgressOutputState(preferences: preferences); progressPresentation = outputState.presentation
    }
    func whenDrained(_ completion: @escaping () -> Void) { if working { drained.append(completion) } else { completion() } }
    func invalidate() {
        guard !closed else { return }; closed = true
        if working && busy { cancellation.cancel(); inspection?.cancel() }
        recoveryRevision = UUID(); recoveryAvailable = false
        transportCoordinator?.close(); transportCoordinator = nil; confirmingCancellation = false
        if !working { busy = false }
    }
    func cancel() {
        guard !closed, busy, !confirmingCancellation, !cancelling else { return }
        let target = activeCancellation
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            var answered = false
            confirmCancel { [weak self] accepted in
                guard !answered, let self, !self.closed else { return }; answered = true; self.confirmingCancellation = false
                if accepted, self.busy, self.activeCancellation === target { self.cancelling = true; target.cancel() }
                if !self.busy, self.automaticClose { self.close() }
            }
        } else { cancelling = true; target.cancel() }
    }
    private var automaticClose: Bool {
        guard let result else { return false }
        if operation.compactProgress { return true }
        let success: Bool; if case .success = result { success = true } else { success = false }
        if case .tag = operation { return autoClosePolicy.shouldClose(success: success, postActionCount: 0) }
        return success
    }
    func start() {
        guard !started, !closed else { return }; started = true; working = true; Self.activeOperations += 1
        startedAt = ProcessInfo.processInfo.systemUptime; currentWork = operation.work
        Task {
            let coordinator = transportFactory?(); transportCoordinator = coordinator
            defer {
                coordinator?.close(); transportCoordinator = nil; inspection = nil; working = false; busy = false
                Self.activeOperations -= 1; withExtendedLifetime(access) {}
                let callbacks = drained; drained.removeAll(); callbacks.forEach { $0() }
            }
            let parser = GitCliOutputParser(limit: outputState.limit)
            let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let operation = Task {
                defer { continuation.finish() }
                if GitRuntime.isAppStoreBuild {
                    guard access?.hasSecurityScope == true, access?.contains(repository.root) == true else { throw RepositoryAccessFailure.securityScopeUnavailable }
                }
                if let executeOperation { return try await executeOperation { chunk in parser.appendChunk(chunk.data); continuation.yield(()) } }
                switch self.operation {
                case .checkout(let plan):
                    return SynchronizationProgressResult.checkout(try await repository.synchronizationPullCheckout(plan, checkoutAuthorized: true, cancellation: cancellation,
                        onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }))
                case .merge(let state):
                    return SynchronizationProgressResult.merge(try await repository.synchronizationFastForward(state, cancellation: cancellation,
                        onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }))
                case .tags(let remote):
                    return SynchronizationProgressResult.tags(try await repository.synchronizationTags(remote: remote, cancellation: cancellation, prepareTransport: coordinator?.preparation,backend:backend))
                case .tag(let action, let row, let snapshot, let authorized):
                    let command = try await repository.synchronizeTag(action, row: row, snapshot: snapshot, deletionAuthorized: authorized, cancellation: cancellation,
                        onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }, prepareTransport: coordinator?.preparation,backend:backend)
                    if action == .deleteRemote {
                        // The source keeps its system progress dialog open through
                        // Fill. A failed deletion never enters the refill phase.
                        do { return .deletedRemote(try await repository.synchronizationTags(remote: snapshot.remote, cancellation: cancellation, prepareTransport: coordinator?.preparation,backend:backend), nil) }
                        catch { return .deletedRemote(nil, error.localizedDescription) }
                    }
                    return SynchronizationProgressResult.tag(command)
                }
            }
            for await _ in updates {
                guard !closed else { continue }; consume(parser.processPending(), parser: parser)
            }
            guard !closed else { _ = try? await operation.value; return }
            consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser)
            var exitCode: Int32?
            do { result = .success(try await operation.value); success = true; exitCode = 0 }
            catch {
                result = .failure(error); exitCode = (error as? GitFailure)?.code
                if let failure = error as? GitFailure, outputState.hasOutput { output += "\nGit command failed (\(failure.code))." }
                else { output += "\n" + error.localizedDescription }
            }
            guard !closed else { return }
            cancelled = cancellation.isCancelled && !success
            let finished = Date(), elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            if case .merge = self.operation, !success {
                // Source's failed ff-only progress offers Resolve when unmerged
                // index entries remain; its callback opens Commit. Inspect with
                // a fresh token so an ordinary Git cancellation can still settle.
                let read = OperationCancellation(); inspection = read; cancelling = false; currentWork = "Checking for conflicts…"
                do {
                    let conflicts: Bool
                    if let inspectConflicts { conflicts = try await inspectConflicts(read) }
                    else { conflicts = try await repository.hasWorkingTreeConflicts(cancellation:read) }
                    guard !closed, inspection === read else { return }
                    try read.check(); recoveryAvailable = conflicts; recoveryRevision = UUID()
                } catch {
                    guard !closed, inspection === read else { return }
                    output += "\nChecking for conflicts failed.\n" + error.localizedDescription
                }
                inspection = nil
            }
            guard !closed else { return }
            let completion = SubmoduleProgressCompletion(success: success, cancelled: cancelled, exitCode: exitCode,
                elapsed: elapsed, finished: finished, preferences: preferences)
            currentWork = completion.currentWork; percentage = 100; completionRange = completion.append(to: &output)
            busy = false; saveActionLog(); OperationSounds.report(failed: !success, preferences: preferences)
            if !confirmingCancellation, automaticClose { close() }
        }
    }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        outputState.consume(emission, parser: parser); output = outputState.output
        currentWork = outputState.currentWork; percentage = outputState.percentage
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
                Text(model.currentWork.isEmpty ? " " : model.currentWork).font(.caption).lineLimit(1).help(model.currentWork)
                ProgressView(value: Double(model.busy ? model.percentage ?? 0 : 100), total: 100)
                    .tint(model.busy ? .accentColor : model.success ? .blue : .red)
                    .accessibilityLabel("Git command progress")
                SubmoduleProgressOutputView(text: model.output, completed: !model.busy, completionRange: model.completionRange, success: model.success, preferences: model.preferences)
            }
            HStack {
                if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity).frame(width: 16, height: 16); Text(model.cancelling ? "Cancelling…" : model.operation.work) } else if model.cancelled { Text("User cancelled").foregroundStyle(.red) } else if case .success = model.result { Text("Finished") } else { Text(model.operation.failure).foregroundStyle(.red) }
                Spacer()
                if let recovery = model.captureRecovery() {
                    Button { model.performRecovery(recovery) } label: { CommandLabel(title:"Resolve",icon:.resolve) }
                }
                if model.busy { Button("Abort") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(model.cancelling) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.confirmingCancellation)
        }.padding(12)
        .gitDockProgress(.command(busy: model.busy, success: model.success, waiting: model.confirmingCancellation, percentage: model.percentage))
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

final class SynchronizationNativeWindow: NSWindow {
    var refreshAction: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 96, event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty, event.window === self, isKeyWindow, attachedSheet==nil, NSApp.modalWindow==nil { refreshAction(); return true }
        return super.performKeyEquivalent(with:event)
    }
}

@MainActor final class SynchronizationWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var activeInlineReleases = 0
    private var retiredPresentation = false
    var configureExport: (ExportWindowController) -> Void = { _ in }
    private static var placementSequence = 0
    private var conflictApplicationPanel: NSOpenPanel?
    let model: SynchronizationWindowModel
    let notificationFiles:RemoteProgressFileActions
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
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, sequence: Int? = nil) {
        model = SynchronizationWindowModel(repository: repository, access: access, preferences: preferences)
        notificationFiles=RemoteProgressFileActions(repository:repository,access:access)
        let window = SynchronizationNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Git Synchronization", preferences: preferences)
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 860, height: 500)
        window.contentViewController = NSHostingController(rootView: SynchronizationDialog(model: model))
        super.init(window: window); window.delegate = self; model.window = window
        window.refreshAction = { [weak model] in model?.refresh() }
        let conflictActions = model.conflictFileActions
        conflictActions.comparisonWindow = window
        conflictActions.chooseApplication = { [weak self, weak window] in
            guard let self, let window, !self.model.closed, window.attachedSheet == nil else { return nil }
            let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"
            panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath:"/Applications",isDirectory:true); panel.alphaValue = window.alphaValue
            self.conflictApplicationPanel = panel
            return await withCheckedContinuation { reply in
                panel.beginSheetModal(for:window) { [weak self, weak panel] response in
                    let url = response == .OK ? panel?.url : nil
                    if self?.conflictApplicationPanel === panel { self?.conflictApplicationPanel = nil }
                    reply.resume(returning:url)
                }
            }
        }
        conflictActions.actionOwnerAvailable = { [weak self, weak window] in
            guard let self, let window, self.model.canUseConflictFiles else { return false }
            return window.attachedSheet == nil || window.attachedSheet === self.conflictApplicationPanel
        }
        notificationFiles.window=window
        notificationFiles.available={ [weak model] in model?.notificationOwnerAvailable==true }
        notificationFiles.onBusy={ [weak model] in model?.fileActionBusy=$0 }
        notificationFiles.onError={ [weak model] in model?.appendNotificationDiagnostic($0) }
        notificationFiles.onLog={ [weak model] repository,access,paths,old,new in model?.onNotificationLog(repository,access,paths,old,new) }
        model.onNotificationFileAction={ [weak self] in self?.notificationFiles.perform($0,$1) }
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
                    handoffError = nil
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
        model.performCheckout = { [weak self] capturedRepository, plan, token in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { throw OperationCancellationFailure.cancelled }
            return try await withCheckedThrowingContinuation { continuation in
                let child = SynchronizationProgressController(repository: capturedRepository, operation: .checkout(plan), cancellation: token, preferences: preferences, access: self.model.access) { result in
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
                let child = SynchronizationProgressController(repository: repository, operation: .merge(state), cancellation: token, preferences: preferences, access: self.model.access) { result in
                    switch result {
                    case .success(.merge(let command)): continuation.resume(returning: .success(command))
                    case .success: continuation.resume(returning: .failure(SynchronizationFailure.invalidInput))
                    case .failure(let error): continuation.resume(returning: .failure(error))
                    }
                }
                self.commandProgress = child; child.onClosed = { [weak self] in self?.commandProgress = nil }
                child.onRecovery = { [weak self] in
                    guard let self, !self.model.closed, !self.model.confirmingQuit, self.window?.attachedSheet == nil else { return }
                    self.model.onCommit()
                }
                child.window?.alphaValue = window.alphaValue; window.beginSheet(child.window!); child.model.start()
            }
        }
        model.performTagOperation = { [weak self] operation, token in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { return .failure(OperationCancellationFailure.cancelled) }
            return await withCheckedContinuation { continuation in
                let child = SynchronizationProgressController(repository: repository, operation: operation, cancellation: token, preferences: preferences, access: self.model.access, transportFactory: self.model.sshSettings.capture(),backend:self.model.tagBackend) { result in
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
            await Self.detachInlineSheet(alert.window)
            if self.pullAlert === alert { self.pullAlert = nil }
        }
        model.confirmTagDeletion = { [weak self] action, row, snapshot in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Delete tag?"
            alert.informativeText = "Do you really want to delete \"\(row.tag.rawValue)\"?" + (action == .deleteRemote ? "\nRemote: \(snapshot.remote)" : "")
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); alert.window.alphaValue = window.alphaValue; self.pullAlert = alert
            let response = await alert.beginSheetModal(for: window)
            await Self.detachInlineSheet(alert.window)
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
            alert.window.alphaValue = window.alphaValue; alert.window.appearance = window.appearance
            self.cancellationAlert = alert; Self.activeInlineReleases += 1
            alert.beginSheetModal(for: window) { [weak self] response in
                Task { @MainActor in
                    defer { Self.activeInlineReleases -= 1 }
                    await Self.detachInlineSheet(alert.window)
                    if self?.cancellationAlert === alert { self?.cancellationAlert = nil }
                    reply(response == .alertSecondButtonReturn)
                }
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
        let placement = sequence ?? Self.placementSequence
        if model.preferences.bool(forKey: "SyncDialogRandomPos"), placement > 0 {
            let offset = CGFloat(placement % 5) * 30
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
            if !self.model.closed {
                if let notes = child as? HistoryNotesWindowController, notes.saved {
                    self.model.finishNoteEditing(warning: notes.model.error)
                } else { self.model.refresh() }
            }
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
    private static func detachInlineSheet(_ child: NSWindow) async {
        let parent = child.sheetParent
        parent?.endSheet(child, returnCode: .abort); child.orderOut(nil)
        while child.sheetParent != nil || parent?.attachedSheet === child {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    override func close() { super.close(); retirePresentation() }
    func windowWillClose(_ notification: Notification) { retirePresentation() }
    private func retirePresentation() {
        guard !retiredPresentation else { return }; retiredPresentation = true
        let ownedSheets = [window?.attachedSheet, cancellationAlert?.window, pullAlert?.window, historyDeletionAlert?.window,
                           emailAlert?.window, conflictApplicationPanel].compactMap { $0 }
        Self.activeInlineReleases += 1

        NotificationCenter.default.removeObserver(self); branchPickerRequest = nil; branchPickerCompletion = nil; branchPickerFocus = nil
        notificationFiles.retire();model.invalidate()
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
        conflictApplicationPanel?.cancel(nil); conflictApplicationPanel = nil
        commandProgress?.abortPresentation(); commandProgress = nil
        if let alert = pullAlert, window?.attachedSheet === alert.window { window?.endSheet(alert.window, returnCode: .abort) }
        pullAlert = nil
        if let alert = cancellationAlert, window?.attachedSheet === alert.window { window?.endSheet(alert.window, returnCode: .abort) }
        cancellationAlert = nil
        Array(model.comparison.comparisonWindows.values).forEach { $0.close() }
        Array(model.comparison.unifiedWindows.values).forEach { $0.close() }
        Array(model.incomingComparison.comparisonWindows.values).forEach { $0.close() }
        Array(model.incomingComparison.unifiedWindows.values).forEach { $0.close() }
        Task { [self] in
            defer { Self.activeInlineReleases -= 1 }
            for sheet in ownedSheets { await Self.detachInlineSheet(sheet) }
            while model.hasPendingInlineWork || notificationFiles.busy { try? await Task.sleep(nanoseconds: 5_000_000) }
            onClosed()
        }
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

private final class SynchronizationInlineReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SynchronizationCommandCompletion?
    func record(_ completion: SynchronizationCommandCompletion) {
        lock.lock(); defer { lock.unlock() }
        if value == nil { value = completion }
    }
    func read() -> SynchronizationCommandCompletion? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

private final class SynchronizationInlinePresentation:@unchecked Sendable {
    private let lock=NSLock()
    private var value:SynchronizationCommandPresentation?
    func record(_ next:SynchronizationCommandPresentation){lock.lock();defer{lock.unlock()};value=next}
    func take()->SynchronizationCommandPresentation? {lock.lock();defer{lock.unlock()};let next=value;value=nil;return next}
}

/// One captured main Sync workflow owns its actual reads, Git producer and
/// follow-up stages independently of whether its window is still presented.
@MainActor private final class SynchronizationInlineAttempt {
    let identity = UUID(), dockOwner = UUID(), cancellation: OperationCancellation
    let displaysCommand: Bool
    let notificationCommand:String
    let receipt = SynchronizationInlineReceipt()
    let notifications=RemoteProgressNotificationBuffer()
    let presentation=SynchronizationInlinePresentation()
    var notificationStarted=Date()
    var completedWork = ""
    var startedAt = ProcessInfo.processInfo.systemUptime
    var finishedAt: Date?, elapsed: TimeInterval?
    var completed = false
    init(cancellation: OperationCancellation, displaysCommand: Bool,notificationCommand:String) {
        self.cancellation = cancellation; self.displaysCommand = displaysCommand;self.notificationCommand=notificationCommand
    }
    func startCommand() { startedAt = ProcessInfo.processInfo.systemUptime }
    func producerFinished() {
        guard finishedAt == nil else { return }
        finishedAt = Date(); elapsed = ProcessInfo.processInfo.systemUptime - startedAt
    }
}

@MainActor final class SynchronizationWindowModel: ObservableObject {
    private(set) static var activeInlineOperations = 0
    private var inlineAttempts: [UUID: SynchronizationInlineAttempt] = [:]
    let notifications:FileOperationProgressState
    @Published private(set) var showsNotifications=false
    @Published private(set) var notificationWarnings:[String]=[]
    @Published var fileActionBusy=false
    private(set) var notificationBackend:GitLibGit2Configuration?
    private var notificationAttemptID:UUID?
    var onNotificationLog:RemoteProgressLogHandler = {_,_,_,_,_ in}
    var onNotificationFileAction:(FileOperationProgressAction,FileOperationProgressRow)->Void = {_,_ in}
    var notificationOwnerAvailable:Bool {showsNotifications && tab==2 && !closed && !confirmingQuit && !confirmingCancellation && !busy && !hasOtherBlockingChild && historyQuestionCount==0 && window?.attachedSheet==nil}
    var notificationActionsAvailable:Bool {notificationOwnerAvailable && !fileActionBusy}
    var notificationKeyboardAvailable:Bool {showsNotifications && tab==2 && !closed && !confirmingQuit && !confirmingCancellation && !fileActionBusy && !hasOtherBlockingChild && historyQuestionCount==0 && window?.attachedSheet==nil}
    var actionLogOutput:String {showsNotifications ? notifications.output+"\n\n"+commandOutput:commandOutput}
    func appendNotificationDiagnostic(_ text:String){guard !closed else{return};appendInlineDiagnostic(text)}
    private func resetNotifications() {showsNotifications=false;notificationBackend=nil;notificationAttemptID=nil;notificationWarnings=[];notifications.retire()}
    private func drainNotifications(_ attempt:SynchronizationInlineAttempt) {
        // Core announces the actual command presentation before emitting any
        // typed event. Read events first: if this snapshot contains a row, its
        // earlier announcement is already buffered (or installed previously).
        let values=attempt.notifications.take()
        let mode=attempt.presentation.take()
        guard !closed,notificationAttemptID==attempt.identity else{return}
        if let mode {
            switch mode {
            case .text:showsNotifications=false;notifications.retire()
            case .transferNotifications:
                showsNotifications=true;attempt.notificationStarted=Date();notifications.begin(attempt.notificationCommand)
            }
        }
        guard showsNotifications else{return}
        for value in values {
            notifications.appendTransfer(value)
            if case .issue(let warning)=value {notificationWarnings.append(warning.message)}
        }
    }

    var hasPendingInlineWork: Bool { fileActionBusy || !inlineAttempts.isEmpty || historyQuestionCount > 0 || !historyParentRequests.isEmpty || !combineSelectionReads.isEmpty || historyActionWorkers > 0 || outgoingFileList.hasPendingQuestion || incomingFileList.hasPendingQuestion || comparison.hasOwnedPreparation || incomingComparison.hasOwnedPreparation }

    private(set) static var activePushWorkflows=0
    lazy var clientHooks=ClientHookSession(preferences:preferences)
    private(set) static var activeHistoryDeletions = 0
    private var combineSelectionReads:[UUID:OperationCancellation]=[:]
    func validateCombineSelection(_ entries:[LogEntry],offset:Int,head:String,token:OperationCancellation) async throws {
        let identity=UUID();combineSelectionReads[identity]=token
        Self.activeInlineOperations += 1
        defer { combineSelectionReads.removeValue(forKey:identity);Self.activeInlineOperations -= 1 }
        guard !closed else { throw OperationCancellationFailure.cancelled }
        try await HistoryCombineSelectionReader.validate(repository:repository.capturingDiffBackend(preferences:preferences),access:access,entries:entries,offset:offset,head:head,token:token)
    }
    let repository: GitRepository
    private(set) var acceptedOperationRepository:GitRepository?
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
    // A receipt belongs to one rendered form and one read generation. Native
    // controls may still deliver callbacks after SwiftUI disables/replaces them.
    struct FormContext:Equatable {
        let owner:ObjectIdentifier,revision:UUID
        let values:[GitReferenceName]
        let force:Bool
        let textRevisions:[UUID]
    }
    private var formRevision=UUID() {didSet {cancelDeferredTextReload()}}
    private var remoteTextRevision=UUID(),branchTextRevision=UUID()
    private var deferredTextTask:Task<Void,Never>?
    private var deferredTextID:UUID?
    private var formReadToken:OperationCancellation?
    private var formCatalogLoaded=false
    @Published private(set) var waitingForInput=false
    var formContext:FormContext {.init(owner:ObjectIdentifier(self),revision:formRevision,values:[localBranch,remoteBranch,remote].map {GitReferenceName($0)},force:force,textRevisions:[remoteTextRevision,branchTextRevision])}
    private var formOwnerAvailable:Bool {!closed && !confirmingQuit && !confirmingCancellation && !transportRunning && !hasBlockingChild && window?.attachedSheet==nil && NSApp.modalWindow==nil}
    var canEditForm:Bool {formOwnerAvailable && !busy}
    var canEditText:Bool {formOwnerAvailable && (!busy || formCatalogLoaded && formReadToken != nil && token === formReadToken)}
    var canUseActionControl:Bool {canEditForm && window != nil}
    func acceptsForm(_ context:FormContext)->Bool {canEditForm && context==formContext}
    // Continuous callbacks from the same field editor keep their receipt. A
    // different field, option, picker, command, Quit or read generation retires it.
    private func acceptsText(_ context:FormContext,key:ReferenceWritableKeyPath<SynchronizationWindowModel,String>)->Bool {
        guard canEditText,context.owner==ObjectIdentifier(self),context.revision==formRevision,context.force==force else{return false}
        let index:Int
        if key == \.remote {index=2} else if key == \.remoteBranch {index=1} else{return false}
        guard context.textRevisions[index==2 ? 0:1] == (index==2 ? remoteTextRevision:branchTextRevision) else{return false}
        return context.values.enumerated().allSatisfy {$0.offset==index || $0.element==formContext.values[$0.offset]}
    }
    func formString(_ key:ReferenceWritableKeyPath<SynchronizationWindowModel,String>,context:FormContext,tracking:Bool=false)->Binding<String> {
        Binding(get:{self[keyPath:key]},set:{[weak self] value in
            guard let self else{return}
            if key == \.localBranch {
                guard self.acceptsForm(context) else{return};self[keyPath:key]=value;self.reload(selectTracking:tracking);return
            }
            guard self.acceptsText(context,key:key) else{return}
            if let read=self.formReadToken,self.token === read {read.cancel();self.token=nil;self.formReadToken=nil;self.busy=false}
            if key == \.remote {self.branchTextRevision=UUID()} else {self.remoteTextRevision=UUID()}
            self[keyPath:key]=value
            self.outgoing=nil;self.graph=[];self.fileSelection=[];self.comparison.snapshot=nil
            self.scheduleTextReload()
        })
    }
    private func cancelDeferredTextReload() {
        deferredTextID=nil;deferredTextTask?.cancel();deferredTextTask=nil
        if waitingForInput {waitingForInput=false}
    }
    private func scheduleTextReload() {
        cancelDeferredTextReload()
        let identity=UUID(),captured=formContext,request=OperationCancellation()
        deferredTextID=identity;waitingForInput=true
        let attempt=beginInlineAttempt(request,command:false,preserveFormFocus:true)
        deferredTextTask=Task { [self] in
            defer {releaseInlineAttempt(attempt)}
            do {try await Task.sleep(nanoseconds:1_000_000_000)} catch{return}
            guard deferredTextID==identity,formOwnerAvailable,formContext==captured,!request.isCancelled else {
                if deferredTextID==identity {deferredTextID=nil;deferredTextTask=nil;waitingForInput=false};return
            }
            deferredTextID=nil;deferredTextTask=nil;waitingForInput=false
            reload()
        }
    }
    func formForce(context:FormContext)->Binding<Bool> {
        Binding(get:{self.force},set:{[weak self] value in guard let self,self.acceptsForm(context) else{return};self.force=value;self.reload()})
    }
    func setRemoteSelection(_ selected:Bool,context:FormContext) {
        guard acceptsText(context,key:\.remote) else{return};remoteWasSelected=selected
    }
    func deleteFormHistory(_ index:Int,remoteURL:Bool,context:FormContext,entries:[String]) {
        guard acceptsForm(context),entries.map({GitReferenceName($0)})==(remoteURL ? remoteChoices:branchHistory).map({GitReferenceName($0)}) else{return}
        if remoteURL {deleteURLHistory(at:index)} else {deleteBranchHistory(at:index)}
    }
    @Published var localBranch = ""
    @Published var remoteBranch = ""
    @Published var remote = "" {didSet {if !GitReferenceName.equal(remote,oldValue) {resultGeneration=UUID()}}}
    var remoteWasSelected = false
    @Published var force = false
    @Published var confirmingQuit = false {
        didSet {
            if confirmingQuit != oldValue { formRevision=UUID();fileListGeneration=UUID();resultGeneration=UUID() }
            conflictFileActionsStorage?.confirmingQuit = confirmingQuit
            comparison.confirmingQuit = confirmingQuit
            incomingComparison.confirmingQuit = confirmingQuit
            for viewer in comparison.unifiedWindows.values { viewer.model.confirmingQuit = confirmingQuit }
            for viewer in incomingComparison.unifiedWindows.values { viewer.model.confirmingQuit = confirmingQuit }
        }
    }
    @Published var tab = 0 { didSet { if tab != oldValue { fileListGeneration=UUID();resultGeneration=UUID();if oldValue==2 || tab==2 {notifications.retire()} } } }
    @Published private(set) var incomingFromPatch = false
    private var lastTransportOldHash: String?
    @Published private(set) var incomingCommits: [LogEntry]? {didSet {resultGeneration=UUID();prepareHistorySVN()}}
    @Published private(set) var incomingGraph: [CommitGraphRow] = []
    @Published private(set) var conflicts: [StatusEntry] = []
    @Published var pullAction = SynchronizationTransportAction.pull
    @Published private(set) var compareTagsSelected = false
    @Published private(set) var pushAction: SynchronizationTransportAction = .push
    @Published private(set) var stashAction: SynchronizationStashAction = .save
    @Published private(set) var submoduleAction: SynchronizationSubmoduleAction = .update
    @Published private(set) var comparingTags = false
    @Published private(set) var tagSnapshot: SynchronizationTagSnapshot? {didSet {resultGeneration=UUID()}}
    private(set) var tagBackend:GitLibGit2Configuration?
    var captureTagBackend:(()->GitLibGit2Configuration)?
    @Published var hideEqualTags = false
    var performTagOperation: (SynchronizationProgressOperation, OperationCancellation) async -> Result<SynchronizationProgressResult, Error> = { _, _ in .failure(SynchronizationFailure.invalidInput) }
    var presentTagError: (String) async -> Void = { _ in }
    var confirmTagDeletion: (SynchronizationTagAction, SynchronizationTagRow, SynchronizationTagSnapshot) async -> Bool = { _, _, _ in false }
    var tagRows: [SynchronizationTagRow] { (tagSnapshot?.rows ?? []).filter { !hideEqualTags || $0.kind != .same } }
    var confirmCheckout: (String) async -> Bool = { _ in false }
    var askTracking: (String, String, String) async -> SynchronizationTrackingAnswer = { _, _, _ in SynchronizationTrackingAnswer(choice: .cancel) }
    var performCheckout: ((GitRepository, SynchronizationTransportPlan, OperationCancellation) async throws -> SynchronizationPullCheckout)?
    var performFastForward: ((SynchronizationRebaseState, OperationCancellation) async -> Result<GitResult, Error>)?
    var presentRebasePrompt: (FetchRebasePrompt) async -> FetchRebaseAnswer = { prompt in FetchRebaseAnswer(value: prompt.answers[prompt.defaultIndex], suppress: false) }
    var runRebase: (String, Bool, Bool) async throws -> Void = { _, _, _ in throw SynchronizationFailure.invalidInput }
    var detachRebase: () -> Void = {}
    var presentConflictHint: () async -> Bool = { false }
    var runOptions: (Bool, String?) async throws -> Void = { _, _ in throw SynchronizationFailure.invalidInput }
    var runPushOptions: (String) async throws -> Void = { _ in throw SynchronizationFailure.invalidInput }
    var confirmPushDeletion: (String) async -> Bool = { _ in false }
    static let conflictColumns: Set<StatusListColumn> = [.path,.fileExtension,.status,.added,.removed]
    private var conflictFileActionsStorage: StatusWindowModel?
    private var conflictFilesSubscription: AnyCancellable?
    var conflictFileActions: StatusWindowModel {
        if let value = conflictFileActionsStorage { return value }
        let value = StatusWindowModel(repository:repository,access:access,defaults:preferences,columnKey:"ConflictSyncDlg.FileColumns",initialColumns:StatusListColumnSettings(visible:Self.conflictColumns))
        value.groupsEnabled = false; value.showsStagedStatus = false
        value.readStatus = { [repository] token in try await repository.workingTreeStatus(refreshIndex:false,cancellation:token).filter { $0.state == .conflicted } }
        value.actionOwnerAvailable = { [weak self] in self?.canUseConflictFiles == true }
        value.onAction = { [weak self] action, paths in self?.onConflictAction(action,paths) }
        conflictFilesSubscription = value.$files.dropFirst().sink { [weak self] rows in
            guard let self, !self.closed else {return}; self.conflicts = rows.map(\.entry)
        }
        conflictFileActionsStorage = value; return value
    }
    var onConflictAction: (RepositoryAction,[String]) -> Void = { _,_ in }
    var canUseConflictFiles: Bool { !closed && !busy && !confirmingQuit && !confirmingCancellation && tab == 6 && !hasOtherBlockingChild }
    func refreshConflictFiles() { guard canUseConflictFiles else { return }; conflictFileActions.requestReload() }
    func conflictMenu(_ ids:some Sequence<String>,mark:String? = nil) -> StatusFileMenuSnapshot {
        let snapshot = conflictFileActions.fileMenu(ids,mark:mark)
        let allowed:Set<StatusFileCommand> = [.log,.editor,.open,.openWith,.reveal]
        return StatusFileMenuSnapshot(generation:snapshot.generation,entries:snapshot.entries,mark:snapshot.mark,commands:snapshot.commands.filter { allowed.contains($0) },markIsDirectory:snapshot.markIsDirectory)
    }
    func performConflict(_ action:RepositoryAction,menu:StatusFileMenuSnapshot) {
        guard canUseConflictFiles,[RepositoryAction.editConflict,.resolveCurrent,.resolveMine,.resolveTheirs].contains(action),action != .editConflict || menu.entries.count == 1 else { return }
        conflictFileActions.withFileMenu(menu) { onConflictAction(action,menu.entries.map(\.path)) }
    }
    func performConflictFile(_ command:StatusFileCommand,menu:StatusFileMenuSnapshot) {
        guard canUseConflictFiles,[StatusFileCommand.log,.editor,.open,.openWith,.reveal].contains(command) else { return }
        conflictFileActions.fileAction(command,snapshot:menu)
    }
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
        Self.activeInlineOperations += 1
        defer { historyParentRequests.removeValue(forKey: id);Self.activeInlineOperations -= 1 }
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
        let sourceTab=tab,reviewedResults=resultGeneration
        let attempt=beginInlineAttempt(request,command:false)
        Task {
            defer {releaseInlineAttempt(attempt)}
            defer { if token === request { token = nil; busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result = try await repository.commitChangeSets(first: first, second: second, cancellation: request)
                guard !closed,!confirmingQuit,tab==sourceTab,resultGeneration==reviewedResults,token === request,!request.isCancelled else { return }
                let key = "Sync change sets " + UUID().uuidString
                let viewer = FileComparisonWindowController(repository: repository, access: access, changeSets: result)
                viewer.model.captureToolChoice(alternateTool)
                viewer.model.comparisonDefaults = preferences
                viewer.onClosed = { [weak child] in child?.comparisonWindows.removeValue(forKey: key) }
                child.comparisonWindows[key] = viewer; viewer.model.load(); viewer.showWindow(nil)
            } catch {
                guard !closed,!confirmingQuit,tab==sourceTab,resultGeneration==reviewedResults,token === request,!request.isCancelled else { return }
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
        let sourceTab=tab,reviewedResults=resultGeneration
        let attempt=beginInlineAttempt(request,command:false)
        Task {
            defer {releaseInlineAttempt(attempt)}
            defer { if token === request { token = nil; busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let bytes = try await repository.run(diff.arguments, cancellation: request).stdout
                guard !closed,!confirmingQuit,tab==sourceTab,resultGeneration==reviewedResults,token === request,!request.isCancelled else { return }
                if case .extraChanges(let hash) = diff {
                    let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
                    guard lines.count > 1, lines[0] == hash, !lines[1].isEmpty else {
                        await presentHistoryNotice("No extra changes after merge"); return
                    }
                }
                if try await UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: preferences, title: diff.title, permissions: access.map { [$0] } ?? [], cancellation: request) { return }
                guard !closed,!confirmingQuit,tab==sourceTab,resultGeneration==reviewedResults,token === request,!request.isCancelled else { return }
                let key = "Sync revision diff " + diff.arguments.joined(separator: "\0")
                let viewer = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access,
                    existing: child.unifiedWindows[key], title: diff.title,
                    onClosed: { [weak child] in child?.unifiedWindows.removeValue(forKey: key) })
                child.unifiedWindows[key] = viewer
            } catch {
                guard !closed,!confirmingQuit,tab==sourceTab,resultGeneration==reviewedResults,token === request,!request.isCancelled else { return }
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
            let sourceTab=tab,reviewedResults=resultGeneration
            let attempt=beginInlineAttempt(request,command:false)
            Task {
                defer {releaseInlineAttempt(attempt)}
                defer { if token === request { token = nil; busy = false } }
                do {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    var text = ""
                    for entry in entries {
                        text += try await repository.commitLogText(revision: entry.hash, includePaths: kind == .details, cancellation: request, dateSettings: dates)
                    }
                    guard !closed,!confirmingQuit,tab==sourceTab,resultGeneration==reviewedResults,token === request,!request.isCancelled else { return }
                    publish(text)
                } catch {
                    guard !closed,!confirmingQuit,tab==sourceTab,resultGeneration==reviewedResults,token === request,!request.isCancelled else { return }
                    self.error = error.localizedDescription
                }
            }
        }
    }
    @Published private(set) var historyReferenceContext = HistoryReferenceContext()
    var historyRegexExecutable:URL?
    @Published private(set) var hasGitSVN=false
    @Published private(set) var historySVNRevisions:[String:String]=[:]
    private var historySVNRequest:OperationCancellation?
    private var historySVNGeneration=UUID()
    private var historyQuestionCount=0
    private var historyActionWorkers=0
    var historyListRetirements:[UUID:()->Void]=[:]
    func beginHistoryQuestion(){historyQuestionCount += 1;beginFileListQuestion();objectWillChange.send()}
    func endHistoryQuestion(){historyQuestionCount -= 1;endFileListQuestion();objectWillChange.send()}
    private func prepareHistorySVN() {
        guard !closed else{return}
        historySVNRequest?.cancel()
        let request=OperationCancellation(),generation=UUID(),entries=(outgoing?.commits ?? [])+(incomingCommits ?? []),executable=historyRegexExecutable
        historySVNRequest=request;historySVNGeneration=generation
        let attempt=beginInlineAttempt(request,command:false,preserveFormFocus:true)
        Task {
            defer {releaseInlineAttempt(attempt);if historySVNRequest === request {historySVNRequest=nil}}
            do {
                let available=try await repository.referenceLogHasGitSVN(cancellation:request)
                let messages=entries.map {$0.historySubject+"\n"+$0.historyBody}
                let values=available ? try await Task.detached {try IssueRegexRuntime.svnRevisions(messages,executable:executable,cancellation:request)}.value:[]
                guard !closed,!request.isCancelled,historySVNGeneration==generation else{return}
                hasGitSVN=available;historySVNRevisions=Dictionary(zip(entries.map(\.hash),values),uniquingKeysWith:{_,last in last})
            } catch {
                guard !closed,!request.isCancelled,historySVNGeneration==generation else{return}
                self.error=error.localizedDescription
            }
        }
    }
    @Published private(set) var historyIssueProperties = IssueTrackerProperties()
    @Published private(set) var historyActions: [String: LogRevisionActions] = [:]
    @Published private(set) var historyActionFailures = Set<String>()
    private var historyActionToken: OperationCancellation?
    private var historyActionQueue: [LogEntry] = []
    private var activeHistoryAction: String?
    private var historyActionGeneration = 0
    private func cancelHistoryActions() {
        for request in historyParentRequests.values { request.cancel() }
        // Requests remain owned until their actual worker returns.
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
        historyActionToken = request;historyActionWorkers += 1;Self.activeInlineOperations += 1
        Task {
            defer {historyActionWorkers -= 1;Self.activeInlineOperations -= 1}
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
    private(set) var fileListGeneration=UUID()
    lazy var outgoingFileList=SynchronizationFileListState(owner:self,incoming:false)
    lazy var incomingFileList=SynchronizationFileListState(owner:self,incoming:true)
    var displayedFileList:SynchronizationFileListState {tab==5 ? incomingFileList:outgoingFileList}
    var fileSelection:GitPathSet {get {displayedFileList.selection} set {displayedFileList.selection=newValue}}
    func beginFileListQuestion(){Self.activeInlineOperations += 1}
    func endFileListQuestion(){Self.activeInlineOperations -= 1}
    private(set) var resultGeneration=UUID()
    @Published private(set) var referenceChanges: [SynchronizationReferenceChange] = [] {didSet {resultGeneration=UUID()}}
    @Published var hideUnchangedReferences = false
    var referenceRows: [SynchronizationReferenceChange] {
        referenceChanges.filter { !hideUnchangedReferences || $0.kind != .same }.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return SynchronizationResultPresentation.compare($0.name.rawValue,$1.name.rawValue,logical:!preferences.bool(forKey:"NoStrCmpLogical")) == .orderedAscending
        }
    }
    @Published private(set) var outgoing: SynchronizationOutgoing? {didSet {resultGeneration=UUID();prepareHistorySVN();if tab==1 && outgoing?.comparison==nil {tab=0}}}
    @Published private(set) var graph: [CommitGraphRow] = []
    @Published private(set) var busy = false { didSet {
        if busy != oldValue {fileListGeneration=UUID();resultGeneration=UUID()}
        if busy { cancelHistoryActions() }
        else if tab == 6 { conflictFileActionsStorage?.requestReload() }
    } }
    @Published private(set) var error: String?
    @Published private(set) var historyNoteWarning: String?
    @Published private(set) var transportRunning = false { didSet { updateInlineDock() } }
    @Published private(set) var confirmingCancellation = false { didSet { updateInlineDock() } }
    @Published private(set) var cancelling = false
    @Published private(set) var commandOutput = ""
    @Published private(set) var commandSucceeded = false
    @Published private(set) var commandCompleted = false
    @Published private(set) var completionRange: NSRange?
    @Published private(set) var commandCancelled = false
    @Published private(set) var inlineCommandFinished = false
    @Published private(set) var inlineCompletionSucceeded = false
    @Published private(set) var percentage: Int? { didSet { updateInlineDock() } }
    @Published private(set) var currentWork = ""
    var showsInlineProgress: Bool { transportRunning && inlineAttempts.values.contains { $0.displaysCommand } }
    var inlineDockProgress: DockProgressState? {
        guard !closed else { return nil }
        if inlineCommandFinished { return inlineCompletionSucceeded ? nil : .init(.failed, percentage: 100) }
        guard showsInlineProgress else { return nil }
        return .command(busy: true, success: false, waiting: confirmingCancellation, percentage: percentage)
    }
    private func updateInlineDock() {
        for attempt in inlineAttempts.values where attempt.displaysCommand {
            // Retired UI cannot release a still-running producer's Dock owner.
            let value: DockProgressState?
            if closed { value = attempt.receipt.read() == nil && !attempt.completed ? .init(.running, percentage: percentage) : nil }
            else { value = inlineDockProgress }
            DockProgressRegistry.shared.update(attempt.dockOwner, value)
        }
    }
    private func beginInlineAttempt(_ request: OperationCancellation, command: Bool, preserveFormFocus:Bool=false,notificationCommand:String="Fetch") -> SynchronizationInlineAttempt {
        let attempt = SynchronizationInlineAttempt(cancellation: request, displaysCommand: command,notificationCommand:notificationCommand)
        if !preserveFormFocus {window?.makeFirstResponder(nil)}
        if command {formRevision=UUID()}
        inlineAttempts[attempt.identity] = attempt; Self.activeInlineOperations += 1
        if command {
            completionRange = nil; commandCancelled = false; inlineCommandFinished = false; inlineCompletionSucceeded = false
            percentage = nil; currentWork = "Preparing synchronization…"
            DockProgressRegistry.shared.update(attempt.dockOwner, .init(.running))
        }
        return attempt
    }
    private func releaseInlineAttempt(_ attempt: SynchronizationInlineAttempt) {
        guard inlineAttempts.removeValue(forKey: attempt.identity) != nil else { return }
        DockProgressRegistry.shared.remove(attempt.dockOwner); Self.activeInlineOperations -= 1
        withExtendedLifetime(access) {}
    }
    private func clippedInlineText(_ text: String, bytes limit: Int) -> String {
        let data = Data(text.utf8); guard data.count > max(0,limit) else { return text }
        var end = max(0,limit)
        while end > 0, data[end] & 0xc0 == 0x80 { end -= 1 }
        return String(decoding: data.prefix(end), as: UTF8.self)
    }
    private func boundedInlineBody(_ text: String, bytes limit: Int) -> String {
        guard text.utf8.count > max(0,limit) else { return text }
        let marker = "\n[Output truncated at about \(outputState.limit / 1024) KiB]\n"
        return clippedInlineText(text, bytes: max(0,limit-marker.utf8.count)) + clippedInlineText(marker, bytes: max(0,limit))
    }
    private func appendInlineDiagnostic(_ text: String) {
        guard !text.isEmpty else { return }
        if let range = completionRange {
            let value = commandOutput as NSString
            guard range.location >= 0, NSMaxRange(range) <= value.length else { return }
            let footer = value.substring(with: range), suffix = value.substring(from: NSMaxRange(range))
            let diagnostic = GitProgressFailureOutput.renderDetails(text, existing: suffix, limit: max(256,outputState.limit-footer.utf8.count))
            let prefix = boundedInlineBody(value.substring(to: range.location), bytes: outputState.limit-footer.utf8.count-diagnostic.utf8.count)
            commandOutput = prefix + footer + diagnostic
            completionRange = NSRange(location: (prefix as NSString).length, length: (footer as NSString).length)
        } else {
            commandOutput = GitProgressFailureOutput.renderDetails(text, existing: commandOutput, limit: outputState.limit)
        }
    }
    private func completeInlineCommand(_ attempt: SynchronizationInlineAttempt, success: Bool, cancelled: Bool, exitCode: Int32?) {
        guard !closed, inlineAttempts[attempt.identity] === attempt, attempt.displaysCommand, !attempt.completed else { return }
        drainNotifications(attempt)
        attempt.producerFinished(); attempt.completed = true
        let receipt = attempt.receipt.read()
        let succeeded = receipt?.success ?? success, cancelled = receipt?.cancelled ?? cancelled
        let code = receipt == nil ? exitCode : receipt?.exitCode
        let completion = SubmoduleProgressCompletion(success: succeeded, cancelled: cancelled, exitCode: code,
            elapsed: receipt?.elapsed ?? attempt.elapsed ?? 0, finished: receipt?.finished ?? attempt.finishedAt ?? Date(), preferences: preferences, showTimings: true)
        commandOutput = boundedInlineBody(commandOutput, bytes: outputState.limit-completion.text.utf8.count)
        completionRange = completion.append(to: &commandOutput)
        if showsNotifications,notificationAttemptID==attempt.identity {
            notifications.append("Finished",completion.text.trimmingCharacters(in:.newlines),kind:.finished)
        }
        commandCancelled = cancelled; inlineCompletionSucceeded = succeeded; inlineCommandFinished = true
        attempt.completedWork = completion.currentWork; currentWork = completion.currentWork; percentage = 100
        OperationSounds.report(failed: !succeeded, preferences: preferences)
    }
    private func failInlineCommand(_ attempt: SynchronizationInlineAttempt, error: Error, request: OperationCancellation) {
        guard !closed, inlineAttempts[attempt.identity] === attempt else { return }
        let cancelled = request.isCancelled || error is OperationCancellationFailure || error is GitCommandCancellationFailure
        let message: String
        if cancelled { message = "Synchronization cancelled." }
        else if let failure = error as? GitFailure, outputState.hasOutput { message = "Git command failed (\(failure.code))." }
        else { message = error.localizedDescription }
        drainNotifications(attempt)
        if showsNotifications,notificationAttemptID==attempt.identity {notifications.appendBeforeCompletion("Error",boundedInlineBody(message,bytes:outputState.limit),kind:.error)}
        if attempt.completed { appendInlineDiagnostic(message) }
        else {
            commandOutput = GitProgressFailureOutput.render(error, existing: commandOutput, limit: outputState.limit)
            if cancelled || error is GitFailure && outputState.hasOutput { appendInlineDiagnostic(message) }
            let exitCode = (error as? GitFailure)?.code ?? (error as? GitCommandCancellationFailure)?.result.exitCode
            completeInlineCommand(attempt, success: false, cancelled: cancelled, exitCode: exitCode)
        }
        self.error = message
    }
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
    @Published var choosingBranch = false {didSet {if choosingBranch != oldValue {formRevision=UUID()}}}
    var onManageRemotes: () -> Void = {}
    @Published var managingRemotes = false {didSet {if managingRemotes != oldValue {formRevision=UUID()}}}
    var onStashOptions: () -> Void = {}
    var onSubmoduleOptions: (SynchronizationSubmoduleAction) -> Void = { _ in }
    var onResultLog: ((String) -> Void)?
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
        let repository = self.repository.capturingDiffBackend(preferences: preferences)
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
                    let resolved = try await repository.revisionLookup(name,requirement:.commit,cancellation:request).objectID
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
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
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
                        let resolved=try await repository.revisionLookup(reference,requirement:.commit,cancellation:request).objectID
                        return resolved == entry.hash ? reference:entry.hash
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
    var hasBlockingChild: Bool { fileActionBusy || historyQuestionCount > 0 || conflictFileActionsStorage?.busy == true || conflictFileActionsStorage?.unifiedViewerBusy == true || hasOtherBlockingChild }
    private var hasOtherBlockingChild: Bool {
        outgoingFileList.resettingColumns || incomingFileList.resettingColumns || historyReferencesBlocking() || operatingHistory || exportingHistory || creatingHistoryReference || emailingPatches || importingPatches || choosingBranch || managingRemotes || NSApp.modalWindow != nil || [comparison, incomingComparison].contains { child in
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
        notifications=FileOperationProgressState(preferences:preferences)
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
        if waitingForInput {return "Waiting for input"}
        if busy { return "Loading…" }
        if [1,5].contains(tab),let fileError=displayedComparison.error {return fileError}
        if let historyNoteWarning { return historyNoteWarning + (error.map { "\n\n" + $0 } ?? "") }
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
    func invalidate() { notifications.retire();notificationAttemptID=nil;formRevision=UUID();fileListGeneration=UUID();resultGeneration=UUID();outgoingFileList.retire();incomingFileList.retire(); inlineAttempts.values.forEach { $0.cancellation.cancel() }; combineSelectionReads.values.forEach {$0.cancel()};historySVNRequest?.cancel();Array(historyListRetirements.values).forEach {$0()};closed = true; conflictFilesSubscription?.cancel();conflictFilesSubscription=nil;conflictFileActionsStorage?.invalidate(); clientHooks.retire(); historyDeletionCoordinator?.close(); historyDeletionCoordinator = nil; cancelHistoryActions(); token?.cancel(); token = nil; comparison.invalidate(); incomingComparison.invalidate(); busy = false; transportRunning = false; cancelling = false; confirmingCancellation = false; cancellationQuestion = nil; transportID = nil }
    func reload(selectTracking: Bool = false, initial: Bool = false, preserveError: Bool = false, refreshRemoteSelection: Bool = false) {
        guard !closed, !confirmingQuit, !confirmingCancellation, !transportRunning, !hasBlockingChild, window?.attachedSheet==nil else { return }
        formRevision=UUID()
        historyNoteWarning = nil
        token?.cancel()
        comparingTags = false; tagSnapshot = nil; if tab == 7 { tab = 0 }
        let retainedError = preserveError ? error : nil
        let request = OperationCancellation(); token = request; formReadToken=request; busy = true; error = retainedError
        outgoing = nil; graph = []; fileSelection = []; comparison.snapshot = nil;comparison.error=nil
        let local = localBranch, selectedRemote = remote, selectedBranch = remoteBranch, forced = force
        let selectedChoice = remoteWasSelected
        if refreshRemoteSelection { urlHistory = FetchDialogHistory.load(preferences, key: historyKey + ".urls", caseSensitive: true, maxItems: Int(Int32.max)) }
        let attempt = beginInlineAttempt(request, command: false,preserveFormFocus:true)
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        Task {
            defer { releaseInlineAttempt(attempt) }
            defer { if formReadToken === request {formReadToken=nil};if token === request { token = nil; busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let catalog = try await repository.synchronizationBranches(localBranch: initial ? nil : local, cancellation: request)
                guard !closed, token === request, !request.isCancelled else { return }
                let branch = initial ? catalog.currentBranch : local
                let destination = selectTracking || initial ? catalog.trackedBranch : selectedBranch
                var url = selectTracking || initial ? (catalog.trackedRemote.isEmpty ? (initial ? (urlHistory.first ?? catalog.remotes.first ?? "") : selectedRemote) : catalog.trackedRemote) : selectedRemote
                formCatalogLoaded=true
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
                let head = try await repository.revisionLookup("HEAD",requirement:.sourceObject,cancellation:request).objectID
                guard !closed, token === request, !request.isCancelled else { return }
                historyReferenceContext = references; historyIssueProperties = properties
                historyBare = bare; historyMergeActive = mergeActive; historyBisectActive = bisectActive; historyCurrentBranch = catalog.currentBranch
                historyHead = head ?? ""
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
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        let attempt = beginInlineAttempt(request, command: false)
        Task {
            defer { releaseInlineAttempt(attempt) }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                guard let hash=try await repository.revisionLookup("HEAD",requirement:.commit,cancellation:request).objectID else{throw SynchronizationFailure.invalidInput}
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
        let attempt = beginInlineAttempt(request, command: false)
        Task {
            defer { releaseInlineAttempt(attempt) }
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
        incomingFromPatch = true; incomingCommits = nil; incomingGraph = []; incomingComparison.snapshot = nil;incomingComparison.error=nil
        let attempt = beginInlineAttempt(request, command: false)
        Task {
            defer { releaseInlineAttempt(attempt) }
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
    func refresh() { guard !closed,!confirmingQuit,!confirmingCancellation,!transportRunning,!hasBlockingChild,window?.attachedSheet==nil else{return}; historyNoteWarning = nil; if tab == 6 { refreshConflictFiles() } else if comparingTags { compareTags() } else { reload(refreshRemoteSelection: true) } }
    func finishNoteEditing(warning: String?) {
        guard !closed else { return }
        refresh()
        // Loading clears ordinary errors. Publish the completed-write warning
        // after scheduling it so it remains visible when the refresh finishes.
        historyNoteWarning = warning
    }
    func compareTags(shift: Bool = false) {
        guard !closed, !confirmingQuit, !busy, !hasBlockingChild, window?.attachedSheet == nil else { return }
        let backend = captureTagBackend?() ?? GitLibGit2Configuration.load(from:preferences,helperURL:repository.libgit2Configuration?.helperURL)
        tagBackend = backend
        compareTagsSelected = true; preferences.set(6, forKey: historyKey + ".pullAction")
        if shift { return }
        let request = OperationCancellation(); token = request; busy = true; transportRunning = true
        resetNotifications();comparingTags = true; tagSnapshot = nil; tab = 7; error = nil; commandOutput = ""; referenceChanges = []
        completionRange = nil; commandCancelled = false; inlineCommandFinished = false; inlineCompletionSucceeded = false
        commandCompleted = false; percentage = nil; currentWork = ""
        incomingFromPatch = false; incomingCommits = nil; incomingGraph = []; incomingComparison.snapshot = nil;incomingComparison.error=nil; conflicts = []
        let repository=self.repository.capturingBackend(backend)
        let selectedRemote = remote
        sshSettings.save(preferences, key: historyKey + ".autoload")
        let attempt = beginInlineAttempt(request, command: false)
        Task {
            defer { releaseInlineAttempt(attempt) }
            defer { if token === request { token = nil; busy = false; transportRunning = false } }
            do {
                try checkTagAccess()
                guard try await repository.revisionLookup("HEAD",requirement:.existingObject,cancellation:request).objectID != nil else{throw SynchronizationFailure.invalidInput}
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
        let factory = sshSettings.capture(),backend=captureTagBackend?() ?? GitLibGit2Configuration.load(from:preferences)
        tagBackend=backend
        sshSettings.save(preferences, key: historyKey + ".autoload")
        let attempt = beginInlineAttempt(request, command: false)
        let reviewedGeneration=resultGeneration
        Task {
            defer { releaseInlineAttempt(attempt) }
            let coordinator = action == .deleteLocal ? factory?() : nil
            defer { coordinator?.close() }
            var finalRequest = request
            defer { if token === finalRequest { token = nil; busy = false; transportRunning = false } }
            do {
                try checkTagAccess()
                if action == .deleteLocal || action == .deleteRemote {
                    let accepted = await confirmTagDeletion(action, row, snapshot)
                    guard !closed, !confirmingQuit, resultGeneration==reviewedGeneration, token === request, !request.isCancelled, accepted,
                          GitReferenceName(remote)==GitReferenceName(snapshot.remote),tagSnapshot?.rows.contains(row)==true,tagSnapshot.map({GitReferenceName($0.remote)})==GitReferenceName(snapshot.remote) else { return }
                }
                let result: Result<SynchronizationProgressResult, Error>
                if action == .deleteLocal {
                    // The source deletes locally without a command progress dialog.
                    do { result = .success(.tag(try await repository.synchronizeTag(.deleteLocal, row: row, snapshot: snapshot, deletionAuthorized: true, cancellation: request,backend:backend))) }
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
                    do { updated = .success(.tags(try await repository.synchronizationTags(remote: snapshot.remote, cancellation: refresh, prepareTransport: coordinator?.preparation,backend:backend))) }
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
            let attempt = beginInlineAttempt(request, command: false)
            Task {
                defer { releaseInlineAttempt(attempt) }
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
                    onTransportFinished(actionLogOutput); reload(preserveError: true)
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
        resetNotifications();outputState.reset(); commandOutput = ""; percentage = nil; currentWork = ""; error = nil; tab = 2
        let forced = force
        let attempt = beginInlineAttempt(request, command: true)
        Task {
            defer { releaseInlineAttempt(attempt) }
            defer { if transportID == operationID { token = nil; busy = false; transportRunning = false; cancelling = false; transportID = nil } }
            let parser = GitCliOutputParser(limit: outputState.limit)
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                attempt.startCommand(); let receipt = attempt.receipt
                let operation = Task {
                    defer { attempt.producerFinished(); continuation.finish() }
                    return try await repository.synchronizeSubmodules(selected, force: forced, cancellation: request,
                        onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) },
                        onCommandFinished: { completion in receipt.record(completion); continuation.yield(()) })
                }
                for await _ in updates { consume(parser.processPending(), parser: parser, request: request, attempt: attempt) }
                consume(parser.processPending(), parser: parser, request: request, attempt: attempt); consume(parser.finish(), parser: parser, request: request, attempt: attempt)
                let result = try await operation.value
                guard !closed, token === request else { return }
                if !outputState.hasOutput, !attempt.completed { commandOutput = GitProgressFailureOutput.renderDetails(result.text, existing: "", limit: outputState.limit) }
                commandSucceeded = true
                completeInlineCommand(attempt, success: true, cancelled: false, exitCode: result.exitCode)
            } catch {
                guard !closed, token === request else { return }
                failInlineCommand(attempt, error: error, request: request)
            }
            guard !closed, token === request else { return }
            commandCompleted = true; cancelling = false; transportRunning = false; busy = false; token = nil; transportID = nil
            // Source Submodule completion leaves Command Log selected, without
            // Fetch's reference/incoming/outgoing refill phases.
            onTransportFinished(actionLogOutput)
        }
    }
    func stash(_ action: SynchronizationStashAction? = nil, shift: Bool = NSEvent.modifierFlags.contains(.shift)) {
        guard !closed, !confirmingQuit, !confirmingCancellation, !busy, !hasBlockingChild, window?.attachedSheet == nil else { return }
        let selected = action ?? stashAction; stashAction = selected
        if shift { if selected == .save { onStashOptions() }; return }
        incomingFromPatch = false; incomingCommits = nil; incomingGraph = []; incomingComparison.snapshot = nil;incomingComparison.error=nil; conflicts = []
        comparingTags = false; tagSnapshot = nil
        let operationID = UUID(); transportID = operationID
        let request = OperationCancellation(); token = request; busy = true; transportRunning = true
        cancelling = false; commandCompleted = false; commandSucceeded = false
        resetNotifications();outputState.reset(); commandOutput = ""; percentage = nil; currentWork = ""; error = nil; tab = 2
        let attempt = beginInlineAttempt(request, command: true)
        Task {
            defer { releaseInlineAttempt(attempt) }
            defer { if transportID == operationID { token = nil; busy = false; transportRunning = false; cancelling = false; transportID = nil } }
            let parser = GitCliOutputParser(limit: outputState.limit)
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                attempt.startCommand(); let receipt = attempt.receipt
                let operation = Task {
                    defer { attempt.producerFinished(); continuation.finish() }
                    return try await repository.synchronizationStash(selected, cancellation: request,
                        onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) },
                        onCommandFinished: { completion in receipt.record(completion); continuation.yield(()) })
                }
                for await _ in updates { consume(parser.processPending(), parser: parser, request: request, attempt: attempt) }
                consume(parser.processPending(), parser: parser, request: request, attempt: attempt); consume(parser.finish(), parser: parser, request: request, attempt: attempt)
                let result = try await operation.value
                guard !closed, token === request else { return }
                if !outputState.hasOutput, !attempt.completed { commandOutput = GitProgressFailureOutput.renderDetails(result.command.text, existing: "", limit: outputState.limit) }
                commandSucceeded = result.command.exitCode == 0
                if !commandSucceeded { self.error = result.conflictCheckError ?? "Git exited with status \(result.command.exitCode)." }
                completeInlineCommand(attempt, success: result.command.exitCode == 0, cancelled: false, exitCode: result.command.exitCode)
                if let message = result.conflictCheckError { appendInlineDiagnostic("Checking for conflicts failed: " + message) }
                conflicts = result.conflicts; if !conflicts.isEmpty { tab = 6 }
            } catch {
                guard !closed, token === request else { return }
                failInlineCommand(attempt, error: error, request: request)
            }
            guard !closed, token === request else { return }
            commandCompleted = true; cancelling = false; transportRunning = false; busy = false; token = nil; transportID = nil
            // Stash leaves the outgoing/reference projection unchanged. Failed
            // restore shows Conflicts only for actual unmerged entries.
            onTransportFinished(actionLogOutput)
        }
    }
    private func runTransport(_ action: SynchronizationTransportAction, shift: Bool) {
        let pushing = [.push, .pushTags, .pushNotes].contains(action)
        comparingTags = false; tagSnapshot = nil
        let operationID = UUID(); transportID = operationID
        let request = OperationCancellation(); token = request; busy = true; transportRunning = true
        cancelling = false; commandCompleted = false; commandSucceeded = false; referenceChanges = []
        incomingFromPatch = false; incomingCommits = nil; incomingGraph = []; incomingComparison.snapshot = nil;incomingComparison.error=nil; conflicts = []
        resetNotifications();outputState.reset(); commandOutput = ""; percentage = nil; currentWork = ""; error = nil; tab = 2
        if shift { completionRange = nil; commandCancelled = false; inlineCommandFinished = false; inlineCompletionSucceeded = false }
        var options = SynchronizationTransportOptions(action: action)
        options.localBranch = localBranch; options.remote = remote; options.remoteBranch = remoteBranch; options.force = force
        options.fetchVerbose = GitCommandPresentation(defaults: preferences).fetchVerbose
        let capturedBackend=GitLibGit2Configuration.load(from:preferences,helperURL:repository.libgit2Configuration?.helperURL)
        let repository=self.repository.capturingBackend(capturedBackend)
        acceptedOperationRepository=repository
        let factory = sshSettings.capture()
        sshSettings.save(preferences, key: historyKey + ".autoload")
        if pushing { Self.activePushWorkflows += 1 }
        // This source-style caption is display-only. Capture accepted options
        // before any checkout/authentication can suspend; a rebuilt Pull→Fetch
        // keeps those same remote/branch options and receives its actual mode
        // separately from Core. Fetch All intentionally has no single refspec.
        let selectedRefspec=action == .fetchAllBranches || options.remoteBranch.isEmpty ? "":"refs/heads/"+options.remoteBranch+":refs/remotes/"+options.remote+"/"+options.remoteBranch
        let notificationCommand=["Fetch",options.remote,selectedRefspec].filter{!$0.isEmpty}.joined(separator:" ")
        let attempt = beginInlineAttempt(request, command: !shift,notificationCommand:notificationCommand)
        notificationBackend=capturedBackend
        if !shift {notificationAttemptID=attempt.identity}
        Task {
            defer { releaseInlineAttempt(attempt) }
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
                        checkout = try await performCheckout(repository, plan, request)
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
                                try await repository.setSynchronizationTracking(localBranch: options.localBranch, remote: options.remote, remoteBranch: destination, cancellation: request)
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
                    let entries:[StatusEntry]
                    if try await repository.hasWorkingTreeConflicts(cancellation:request) {entries=try await repository.status(refreshIndex:false,cancellation:request).filter {$0.state == .conflicted}} else {entries=[]}
                    guard !closed, token === request else { return }
                    if entries.isEmpty { incomingRevision = "HEAD" }
                    // Conflicts are loaded below, after refreshing references.
                    commandSucceeded = true
                } else {
                    pushAttempted=pushing
                    let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    attempt.startCommand(); let receipt = attempt.receipt
                    let typed=attempt.notifications,presentation=attempt.presentation
                    let notify:@Sendable(GitTransferNotification)->Void = {value in typed.append(value);continuation.yield(())}
                    let announce:@Sendable(SynchronizationCommandPresentation)->Void = {value in presentation.record(value);continuation.yield(())}
                    let operation = Task {
                        defer { attempt.producerFinished(); continuation.finish() }
                        if let checkout {
                            return try await repository.synchronize(checkout, cancellation: request,
                                onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }, prepareTransport: coordinator?.preparation,
                                onCommandFinished: { completion in receipt.record(completion); continuation.yield(()) },backend:capturedBackend,onNotification:notify,onCommandPresentation:announce)
                        }
                        return try await repository.synchronize(plan, deletionAuthorized: deletionAuthorized, cancellation: request,
                            onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }, prepareTransport: coordinator?.preparation,
                                onCommandFinished: { completion in receipt.record(completion); continuation.yield(()) },backend:capturedBackend,onNotification:notify,onCommandPresentation:announce)
                    }
                    for await _ in updates { drainNotifications(attempt);consume(parser.processPending(), parser: parser, request: request, attempt: attempt) }
                    drainNotifications(attempt)
                    consume(parser.processPending(), parser: parser, request: request, attempt: attempt)
                    consume(parser.finish(), parser: parser, request: request, attempt: attempt)
                    let result = try await operation.value
                    guard !closed, token === request else { return }
                    if !outputState.hasOutput, !attempt.completed { commandOutput = GitProgressFailureOutput.renderDetails(result.command.text, existing: "", limit: outputState.limit) }
                    completeInlineCommand(attempt, success: true, cancelled: false, exitCode: result.command.exitCode)
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
                                if case .failure(let error) = merge { followUpSucceeded = false; self.error = error.localizedDescription; appendInlineDiagnostic("Fast-forward failed.\n" + error.localizedDescription) }
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
                failInlineCommand(attempt, error: error, request: request)
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
                    appendInlineDiagnostic("Reading reference changes failed.\n" + error.localizedDescription)
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
                        let entries:[StatusEntry]
                        if try await repository.hasWorkingTreeConflicts(cancellation:inspection) {entries=try await repository.status(refreshIndex:false,cancellation:inspection).filter {$0.state == .conflicted}} else {entries=[]}
                        guard !closed, token === inspection else { return }; conflicts = entries; tab = entries.isEmpty ? 2 : 6
                        if !entries.isEmpty, !preferences.bool(forKey: MergeProgressWindowModel.conflictHintPreference) {
                            let suppress = await presentConflictHint()
                            guard !closed, token === inspection, !inspection.isCancelled else { return }
                            if suppress { preferences.set(true, forKey: MergeProgressWindowModel.conflictHintPreference) }
                        }
                    }
                } catch {
                    guard !closed, token === inspection else { return }
                    appendInlineDiagnostic("Reading Pull results failed.\n" + error.localizedDescription)
                }
                guard !closed, token === inspection else { return }
            }
            if let ignoredPreHook {
                appendInlineDiagnostic("Pre-push hook failure was continued.\n" + (ignoredPreHook.error.isEmpty ? ignoredPreHook.output : ignoredPreHook.error))
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
                    appendInlineDiagnostic(text);self.error=(self.error.map { $0+"\n\n" } ?? "")+text
                }
                guard !closed,token === postRequest else { return };currentWork=attempt.completedWork
            }
            commandCompleted = true; cancelling = false; transportRunning = false; busy = false; token = nil; transportID = nil
            onTransportFinished(actionLogOutput)
            // Fetch completion refreshes outgoing projection, not incoming HEAD.
            // A cancelled/failed Git command can still have updated references.
            reload(preserveError: true)
        }
    }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser, request: OperationCancellation, attempt: SynchronizationInlineAttempt) {
        if closed, attempt.receipt.read() != nil { DockProgressRegistry.shared.remove(attempt.dockOwner) }
        guard !closed, token === request, inlineAttempts[attempt.identity] === attempt, !attempt.completed else { return }
        drainNotifications(attempt)
        outputState.consume(emission, parser: parser)
        if attempt.receipt.read() != nil {
            // Core emitted the receipt only after draining all producer output.
            // Flush the parser now even if its follow-up metadata read is held.
            outputState.consume(parser.processPending(), parser: parser); outputState.consume(parser.finish(), parser: parser)
        }
        commandOutput = outputState.output; percentage = outputState.percentage; currentWork = outputState.currentWork
        if let receipt = attempt.receipt.read() {
            completeInlineCommand(attempt, success: receipt.success, cancelled: receipt.cancelled, exitCode: receipt.exitCode)
        }
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
        let list=displayedFileList
        guard let receipt=list.capture(list.selection) else{return}
        list.compare(receipt,unified:unified,alternate:ComparisonToolInvocation.capture)
    }
}

private struct SynchronizationDialog: View {
    @ObservedObject var model: SynchronizationWindowModel
    var body: some View {
        let context=model.formContext
        let branches=model.branchHistory,urls=model.remoteChoices
        VStack(spacing: 10) {
            if model.showsInlineProgress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        GitCommandActivity(animate: model.progressPresentation.animateActivity).frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.cancelling ? "Cancelling…" : model.currentWork.isEmpty ? "Running Git…" : model.currentWork)
                                .lineLimit(1).help(model.currentWork)
                            GitCommandProgressBar(percentage: model.percentage, animate: model.progressPresentation.animateActivity)
                                .accessibilityLabel("Git synchronization progress")
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            } else {
            GroupBox {
                VStack(spacing: 10) {
                    DialogCommandRows {
                        HStack {
                        Text("Local Branch:")
                        Picker("Local Branch", selection: Binding(get: { GitReferenceName(model.localBranch) }, set: { model.formString(\.localBranch,context:context,tracking:true).wrappedValue=$0.rawValue })) {
                            ForEach(model.localBranches.map { GitReferenceName($0) }, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().disabled(!model.canEditForm)
                        Button("…") { model.browseBranch(.local) }.accessibilityLabel("Browse local branches").disabled(!model.canEditForm)
                        }.frame(minWidth:280,idealWidth:320,maxWidth:.infinity,alignment:.leading).layoutValue(key:DialogCommandRows.Flexible.self,value:true)
                        HStack {
                        Text("Remote Branch:")
                        FetchHistoryCombo(value: model.formString(\.remoteBranch,context:context), choices: branches, label: "Remote Branch", onDelete: {model.deleteFormHistory($0,remoteURL:false,context:context,entries:branches)})
                        Button("…") { model.browseBranch(.remote) }.accessibilityLabel("Browse remote branches").disabled(!model.canEditForm)
                        }.frame(minWidth:300,idealWidth:400,maxWidth:.infinity,alignment:.leading).layoutValue(key:DialogCommandRows.Flexible.self,value:true)
                    }
                    DialogCommandRows {
                        Text("Remote URL:").fixedSize()
                        FetchHistoryCombo(value: model.formString(\.remote,context:context), choices: urls, label: "Remote URL", onDelete: {model.deleteFormHistory($0,remoteURL:true,context:context,entries:urls)}, onSelectionState: {model.setRemoteSelection($0,context:context)})
                            .frame(minWidth:280,idealWidth:460).layoutValue(key:DialogCommandRows.Flexible.self,value:true)
                        Button { model.manageRemotes() } label: { CommandLabel(title: "Manage", icon: .settings) }
                            .disabled(model.busy || model.confirmingQuit)
                    }
                    DialogCommandRows(spacing:24) {
                        SSHAutoloadToggle(settings: model.sshSettings)
                        Toggle("Force", isOn: model.formForce(context:context)).disabled(!model.canEditForm)
                    }.padding(.leading, 100)
                }.padding(6)
            }.disabled(!model.canEditText)
            }
            if model.tab == 7 {
                SynchronizationTagTable(model: model)
            } else if model.tab == 3 {
                SynchronizationReferenceTable(model: model)
            } else if model.tab == 2 {
                if model.showsNotifications {
                    VStack(spacing:4) {
                        FileOperationProgressTable(state:model.notifications,icon:.fetch,available:model.notificationActionsAvailable,repository:model.repository.root,keyboardAvailable:model.notificationKeyboardAvailable,fileRowIcons:true,actionAvailability:{model.notificationActionsAvailable},keyboardAvailability:{model.notificationKeyboardAvailable},performRow:model.onNotificationFileAction)
                            .frame(minHeight:180,maxHeight:.infinity).layoutPriority(1)
                        SubmoduleProgressOutputView(text:model.commandOutput,completed:model.inlineCommandFinished,completionRange:model.completionRange,success:model.inlineCompletionSucceeded,preferences:model.preferences).frame(height:100)
                    }
                } else {
                    SubmoduleProgressOutputView(text: model.commandOutput, completed: model.inlineCommandFinished,
                        completionRange: model.completionRange, success: model.inlineCompletionSucceeded, preferences: model.preferences)
                }
            } else if model.tab == 0 || model.tab == 4 {
                SynchronizationHistoryTable(model: model)
                    .id(model.tab)
                    .overlay { if model.tab == 4, model.incomingUpToDate { Text(model.incomingFromPatch ? "No commits get from patch" : "Up to date.").foregroundStyle(.secondary) } }
            } else if model.tab == 6 {
                SynchronizationConflictFiles(model:model,actions:model.conflictFileActions)
            } else {
                SynchronizationFiles(model: model).id(model.tab)
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
                    if !model.conflicts.isEmpty || model.tab == 6 { Text("Conflicts").tag(6) }
                    Text("Out Commits").tag(0); if model.outgoing?.comparison != nil {Text("Out Changelist").tag(1)}; Text("Ref List").tag(3)
                }
            }.labelsHidden().pickerStyle(.segmented)
            DialogCommandRows {
                SynchronizationActionControl(model:model,group:.pull)
                SynchronizationActionControl(model:model,group:.push)
                SynchronizationActionControl(model:model,group:.submodule)
                Button { model.applyPatch() } label: { CommandLabel(title: "Apply Patch", icon: .patch) }.disabled(model.busy || model.hasBlockingChild)
                Button { model.emailPatch() } label: { CommandLabel(title: "Email Patch", icon: .sendMail) }.disabled(!model.canEmailPatch)
            }
            DialogCommandRows {
                Button { model.onLog(model.localBranch) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(model.busy || model.localBranch.isEmpty)
                Button { model.onCommit() } label: { CommandLabel(title: "Commit", icon: .commit) }.disabled(model.busy)
                SynchronizationActionControl(model:model,group:.stash)
                Button("Refresh") { model.refresh() }.disabled(model.transportRunning || model.hasBlockingChild)
            }
            HStack {
                if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
                Text(model.status).foregroundStyle(model.error == nil && model.historyNoteWarning == nil && (![1,5].contains(model.tab) || model.displayedComparison.error==nil) ? Color.secondary : Color.red).textSelection(.enabled)
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
        .gitDockProgress(model.inlineDockProgress)
    }
}

private struct SynchronizationConflictRow: Identifiable {
    let value: StatusRow
    var id: String { GitPathRowIdentity.encode(value.id) }
    var file: WorkingTreeFile { value.file }
    var path: String { value.path }
    var fileExtension: String { value.fileExtension }
    var addedText: String { value.addedText }
    var removedText: String { value.removedText }
}
private struct SynchronizationConflictSort: SortComparator {
    var column: StatusListColumn
    var order: SortOrder = .forward
    func compare(_ lhs:SynchronizationConflictRow,_ rhs:SynchronizationConflictRow)->ComparisonResult {
        StatusFileSort(column:column,order:order).compare(lhs.value,rhs.value)
    }
}
struct SynchronizationConflictFiles: View {
    @ObservedObject var model: SynchronizationWindowModel
    @ObservedObject var actions: StatusWindowModel
    @ObservedObject private var colors = StatusColorUpdates.shared
    @State private var focusedIdentity: GitReferenceName?
    private var focusedPath: String? { focusedIdentity?.rawValue }
    private var focusBinding: Binding<String?> {
        Binding(get:{ focusedIdentity?.rawValue },set:{ focusedIdentity = $0.map { GitReferenceName($0) } })
    }
    var body: some View {
        let rows = actions.sortedRows.map(SynchronizationConflictRow.init)
        let lookup = GitPathMap(rows.map { ($0.path,$0.value) },uniquingKeysWith:{_,last in last})
        VStack(alignment:.leading,spacing:6) {
            Table(rows,selection:$actions.nativeFileSelection,sortOrder:Binding(get:{actions.sortOrder.map { SynchronizationConflictSort(column:$0.column,order:$0.order) }},set:{actions.setSortOrder($0.map {StatusFileSort(column:$0.column,order:$0.order)})})) {
                TableColumn("Path",sortUsing:SynchronizationConflictSort(column:.path)) { row in
                    HStack { Image(nsImage:row.file.state.icon.image() ?? NSImage()); Text(StatusListClipboard.displayedPath(row.file.entry)).foregroundStyle(row.file.entry.statusTextColor(selected:actions.selection.contains(row.path),preferences:actions.colorPreferences)) }
                        .repositoryFileHelp(repository:actions.repository.root,path:row.path,preferences:actions.colorPreferences)
                }.width(min:240,ideal:440)
                TableColumn("Extension",sortUsing:SynchronizationConflictSort(column:.fileExtension)) { Text($0.fileExtension) }.width(min:50,ideal:70)
                TableColumn("Status",sortUsing:SynchronizationConflictSort(column:.status)) { row in Text("Conflicted").foregroundStyle(row.file.entry.statusTextColor(selected:actions.selection.contains(row.path),preferences:actions.colorPreferences)) }.width(min:100,ideal:140)
                TableColumn("Lines added",sortUsing:SynchronizationConflictSort(column:.added)) { Text($0.addedText).frame(maxWidth:.infinity,alignment:.trailing) }.width(min:65,ideal:85)
                TableColumn("Lines removed",sortUsing:SynchronizationConflictSort(column:.removed)) { Text($0.removedText).frame(maxWidth:.infinity,alignment:.trailing) }.width(min:70,ideal:95)
            }.fileListFont()
            .background(CommitFileInteraction(rows:rows.map { .file($0.file.entry) },leadingColumnCount:0,keyboardDeleteEnabled:false,
                captureWorkingDrag:{actions.captureWorkingDrag($0)},workingDragOrigin:actions.workingDragOrigin,
                nativeColumns:[.path,.fileExtension,.status,.added,.removed],configureRefresh:{actions.fileListRefresh.attach($0)},watermarkIcon:.resolve,preferences:model.preferences,
                visibleColumns:actions.fileColumns.visible.intersection(SynchronizationWindowModel.conflictColumns),availableColumns:SynchronizationWindowModel.conflictColumns,
                columnText:{entry,column in lookup[entry.path].map { actions.columnText($0,column) } ?? ""},savedOrder:actions.fileColumns.order,savedWidths:actions.fileColumns.widths,
                saveLayout:{order,widths in guard model.canUseConflictFiles else {return false};return actions.saveColumnLayout(order:order,widths:widths)},
                setColumnVisible:{column,visible in if model.canUseConflictFiles {actions.setColumn(column,visible:visible)}},
                resetColumns:{choose,accepted in actions.requestResetColumns(choose:choose,onAccepted:accepted)},focusedPath:focusBinding,
                enabled:model.canUseConflictFiles && !actions.busy,delete:{_,_,_ in},
                copy:{entries,status in let target=model.conflictMenu(GitPathSet(entries.map(\.path)),mark:focusedPath);actions.withFileMenu(target) {actions.copy(GitPathSet(entries.map(\.path)),information:status ? .pathsAndStatus : .relativePaths)}},
                copyColumn:{entries,column in let target=model.conflictMenu(GitPathSet(entries.map(\.path)),mark:focusedPath);actions.withFileMenu(target) {actions.copy(GitPathSet(entries.map(\.path)),information:.column(column))}},toggleCheck:{_,_ in}))
            .contextMenu(forSelectionType:String.self) { nativeIDs in
                let ids = GitPathRowIdentity.paths(nativeIDs)
                let target = model.conflictMenu(ids,mark:focusedPath)
                TurtleGitContextMenu {
                    ResolveSelectionMenu(paths:target.entries.map(\.path),rebase:actions.conflictRebase,canEdit:target.entries.count == 1) {action,_ in model.performConflict(action,menu:target)}
                    Divider()
                    ForEach(target.commands,id:\.self) { command in Button {model.performConflictFile(command,menu:target)} label: {CommandLabel(title:command.rawValue,icon:command.icon)} }
                    Menu {
                        Button {actions.withFileMenu(target) {actions.copy(ids,information:.relativePaths)}} label: {CommandLabel(title:"Relative paths",icon:.copy)}
                        Button {actions.withFileMenu(target) {actions.copy(ids,information:.fullPaths)}} label: {CommandLabel(title:"Full paths",icon:.copy)}
                        Button {actions.withFileMenu(target) {actions.copy(ids,information:.names)}} label: {CommandLabel(title:"File/folder names",icon:.copy)}
                        Button {actions.withFileMenu(target) {actions.copy(ids,information:.all)}} label: {CommandLabel(title:"Copy all information to clipboard",icon:.copy)}
                    } label: {CommandLabel(title:"Copy to Clipboard",icon:.copy)}.disabled(target.entries.isEmpty)
                }
            } primaryAction: {nativeIDs in
                let ids = GitPathRowIdentity.paths(nativeIDs)
                if !ids.isEmpty, let mark=model.conflictMenu(ids,mark:focusedPath).mark {model.performConflict(.editConflict,menu:model.conflictMenu([mark.path],mark:mark.path))}
            }
            .disabled(!model.canUseConflictFiles || actions.busy)
            if actions.busy {HStack {ProgressView().controlSize(.small);Text(actions.currentOperation).font(.caption)}}
            if let error=actions.error {Text(error).foregroundStyle(.red).textSelection(.enabled)}
        }.onAppear {model.refreshConflictFiles()}.defaultAppStorage(model.preferences)
    }
}
