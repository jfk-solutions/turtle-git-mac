import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers
import Darwin

/// Settings already presents the reason for refusing a context replacement.
/// Keep that refusal separate from Git/cancellation failures while draining the
/// ordinary repository-opening operation and restoring its original monitoring.
private struct RepositorySettingsContextRefusal: Error {}

/// The accepted command carries its output engine through permission and
/// repository-discovery tasks without mutating shared preferences.
private enum HistoricalMaterializationContext {
    @TaskLocal static var backend:GitLibGit2Configuration?
}

/// Async preparation inherits its originating Services request, never the
/// workspace's later selection or another concurrently prepared child.
private struct FinderServiceDispatchIdentity:@unchecked Sendable {
    let action:RepositoryAction
    let root:URL
    var preferences:UserDefaults? = nil
}
private enum FinderServicePresentationContext {
    @TaskLocal static var current:FinderServiceDispatchIdentity?
}

/// Filesystem forms remain independent windows after Services preparation.
/// A native presentation callback must not revive a retired captured form.
@MainActor private protocol FinderFilesystemWorkflowWindow:AnyObject {
    var finderServiceCanPresent:Bool {get}
}
extension RenameWindowController:FinderFilesystemWorkflowWindow {}
extension RemoveWindowController:FinderFilesystemWorkflowWindow {}
extension CleanWindowController:FinderFilesystemWorkflowWindow {}
extension CleanProgressWindowController:FinderFilesystemWorkflowWindow {}
extension LogWindowController:FinderFilesystemWorkflowWindow {var finderServiceCanPresent:Bool {!model.isInvalidated}}
extension WorktreeListWindowController:FinderFilesystemWorkflowWindow {}
extension WorktreeCreateWindowController:FinderFilesystemWorkflowWindow {}
extension SubmoduleAddWindowController:FinderFilesystemWorkflowWindow {}
extension SubmoduleAddProgressWindowController:FinderFilesystemWorkflowWindow {}
extension SubmoduleUpdateWindowController:FinderFilesystemWorkflowWindow {}
extension SubmoduleUpdateProgressWindowController:FinderFilesystemWorkflowWindow {}
extension SubmoduleSyncWindowController:FinderFilesystemWorkflowWindow {}
extension ReferenceLogWindowController:FinderFilesystemWorkflowWindow {var finderServiceCanPresent:Bool {canReuse}}
extension ReferenceBrowserWindowController:FinderFilesystemWorkflowWindow {var finderServiceCanPresent:Bool {canReuse}}
extension RepositoryBrowserWindowController:FinderFilesystemWorkflowWindow {var finderServiceCanPresent:Bool {canReuse}}
extension RevisionGraphWindowController:FinderFilesystemWorkflowWindow {var finderServiceCanPresent:Bool {canReuse}}
extension GitDaemonWindowController:FinderFilesystemWorkflowWindow {var finderServiceCanPresent:Bool {canReuse}}
extension ExportWindowController:FinderFilesystemWorkflowWindow {var finderServiceCanPresent:Bool {canReuse}}
extension FormatPatchWindowController:FinderFilesystemWorkflowWindow {var finderServiceCanPresent:Bool {canReuse}}
extension ImportPatchWindowController:FinderFilesystemWorkflowWindow {var finderServiceCanPresent:Bool {canReuse}}
extension RequestPullWindowController:FinderFilesystemWorkflowWindow {var finderServiceCanPresent:Bool {canReuse}}


/// Delayed repository work belongs to the window that launched it, even when
/// that window closes before preparation or creation reports completion.
@MainActor private final class RepositoryWindowOwner {
    let cancellation = OperationCancellation()
    var onCancelled: () -> Void = {}
    private var observer: NSObjectProtocol?
    init(window: NSWindow?) {
        if let window {
            let token = cancellation
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                token.cancel()
                Task { @MainActor [weak self] in self?.onCancelled() }
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

/// UserDefaults' typed getters call object(forKey:). Keep that primitive and
/// writes in an instance-local dictionary: a custom volatile domain is not in
/// the search list, while NSArgumentDomain is shared across defaults instances.
private final class CommandGraphPreferences: UserDefaults, @unchecked Sendable {
    private let valuesLock = NSLock()
    private var values: [String: Any]
    init(capturing preferences: UserDefaults) {
        values = preferences.dictionaryRepresentation()
        super.init(suiteName: nil)!
    }
    override func object(forKey key: String) -> Any? {
        valuesLock.lock(); defer { valuesLock.unlock() }; return values[key]
    }
    override func dictionaryRepresentation() -> [String: Any] {
        valuesLock.lock(); defer { valuesLock.unlock() }; return values
    }
    override func set(_ value: Any?, forKey key: String) {
        valuesLock.lock(); defer { valuesLock.unlock() }; values[key] = value
    }
    override func removeObject(forKey key: String) {
        valuesLock.lock(); defer { valuesLock.unlock() }; values.removeValue(forKey: key)
    }
}

/// A command's graph rendering choices are captured across permission panels
/// and repository discovery. Hidden-model preference writes stay memory-only.
@MainActor private final class CommandGraphOutputHandoff: @unchecked Sendable {
    let id: UUID, owner: RepositoryWindowOwner, preferences: UserDefaults
    let backend: GitLibGit2Configuration
    let appearance: NSAppearance?
    var handedOff = false, started = false
    init(id: UUID, owner: RepositoryWindowOwner, preferences: UserDefaults, window: NSWindow?) {
        self.id = id; self.owner = owner
        let snapshot = CommandGraphPreferences(capturing: preferences)
        self.preferences = snapshot; self.backend = .load(from: snapshot)
        self.appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
    }
}
private enum CommandGraphOutputContext {
    @TaskLocal static var current: CommandGraphOutputHandoff?
}

/// Source-modal successors belong to the same captured root. Independent Log,
/// Commit and similar commands deliberately run outside this chain.
@MainActor private protocol TransportBatchWindow:AnyObject {
    var onClosed:()->Void {get set}
    var transportBatchWorkPending:Bool {get}
}
extension FetchWindowController:TransportBatchWindow {}
extension PushWindowController:TransportBatchWindow {}
extension ResetWindowController:TransportBatchWindow {}
extension SwitchWindowController:TransportBatchWindow {}
extension RebaseWindowController:TransportBatchWindow {}
extension StashWindowController:TransportBatchWindow {}
extension StashRestoreWindowController:TransportBatchWindow {}
extension MergeWindowController:TransportBatchWindow {}
extension RequestPullWindowController:TransportBatchWindow {}
extension FormatPatchWindowController:TransportBatchWindow {}
extension RebaseCompletionMailWindowController:TransportBatchWindow {}
extension RebaseCompletionMailWindowController:FinderFilesystemWorkflowWindow {var finderServiceCanPresent:Bool {canPresent}}
private enum TransportBatchPresentationContext {
    @TaskLocal static var chain:RepositoryTransportBatchChain?
}
@MainActor private final class RepositoryTransportBatchChain {
    @MainActor private final class Node {
        let controller:NSWindowController
        let pending:()->Bool
        var closed=false
        init(_ controller:NSWindowController,pending:@escaping()->Bool){self.controller=controller;self.pending=pending}
    }
    let command:Bool
    let root:URL
    private let allowed:()->Bool
    private var nodes:[Node]=[]
    private var closingFences=0
    private(set) var cancelled=false
    init(root:URL,command:Bool,allowed:@escaping()->Bool){self.root=root;self.command=command;self.allowed=allowed}
    var controller:NSWindowController? {nodes.first?.controller}
    var canPresent:Bool {!cancelled && allowed()}
    func capture(_ controller:NSWindowController) {
        guard !nodes.contains(where:{$0.controller === controller}),let owned=controller as? any TransportBatchWindow else{return}
        let node=Node(controller,pending:{owned.transportBatchWorkPending || controller.window?.sheetParent != nil || controller.window?.attachedSheet != nil});nodes.append(node)
        let original=owned.onClosed
        owned.onClosed={ [weak self,weak node] in
            // Reserve before original cleanup: a source modal callback can
            // launch its successor immediately after onClosed returns.
            self?.closingFences += 1
            original();node?.closed=true
            DispatchQueue.main.async { [weak self] in self?.closingFences -= 1 }
        }
    }
    var hasPendingWork:Bool {closingFences>0 || nodes.contains{!$0.closed || $0.pending()}}
    func handoff(_ action:()->Void) {
        guard canPresent else{return}
        closingFences += 1
        defer{closingFences -= 1}
        TransportBatchPresentationContext.$chain.withValue(self,operation:action)
    }
    func releaseCompleted(){guard !hasPendingWork else{return};nodes.removeAll()}
    func cancel(){guard !cancelled else{return};cancelled=true;for node in nodes where !node.closed {if let window=node.controller.window {window.sheetParent?.endSheet(window,returnCode:.abort)};node.controller.close()}}
}

/// One folder chooser, captured before any modal/native reply can arrive.
@MainActor private final class RepositoryCreationFolderChoice {
    let owner: RepositoryWindowOwner
    let panel = NSOpenPanel()
    private weak var window: NSWindow?
    private var completed = false
    var onFinished: (URL?) -> Void = { _ in }
    init(window: NSWindow?, owner: RepositoryWindowOwner) {
        self.window = window; self.owner = owner
        owner.onCancelled = { [weak self] in self?.cancel() }
    }
    func begin(present: ((NSOpenPanel, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?, selected: @escaping (NSOpenPanel) -> URL?) {
        let reply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self,!self.completed else { return }
            self.finish(response == .OK && !self.owner.cancellation.isCancelled ? selected(self.panel) : nil)
        }
        if let present { present(panel, window, reply) }
        else if let window { panel.beginSheetModal(for: window, completionHandler: reply) }
        else { NSApp.activate(ignoringOtherApps:true);panel.begin(completionHandler: reply) }
    }
    private func finish(_ selected: URL?) {
        guard !completed else { return }; completed = true
        if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: selected == nil ? .cancel : .OK) }
        panel.orderOut(nil); panel.close()
        let reply = onFinished; onFinished = { _ in }; reply(selected)
    }
    func cancel() { owner.cancellation.cancel(); finish(nil) }
}

/// Finder's source selection outlives its native destination panel. Publish the
/// accepted URL only after AppKit has detached the actual sheet.
@MainActor private final class FinderTransferDestinationChoice {
    let owner: RepositoryWindowOwner
    let panel = NSOpenPanel()
    private weak var window: NSWindow?
    private var completed = false, delivered = false
    private var accepted: URL?
    private var releaseObserver: NSObjectProtocol?
    var onFinished: (URL?) -> Void = { _ in }
    init(window: NSWindow?, owner: RepositoryWindowOwner) {
        self.window = window; self.owner = owner
        panel.alphaValue = window?.alphaValue ?? 1; panel.appearance = window?.appearance
        owner.onCancelled = { [weak self] in self?.cancel() }
    }
    func begin(present: ((NSOpenPanel, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?, selected: @escaping (NSOpenPanel) -> URL?) {
        let reply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.finish(response == .OK && !self.owner.cancellation.isCancelled ? selected(self.panel) : nil)
        }
        if let present { present(panel, window, reply) }
        else if let window { panel.beginSheetModal(for: window, completionHandler: reply) }
        else { panel.begin(completionHandler: reply) }
    }
    private func finish(_ result: URL?) {
        guard !completed else { return }; completed = true; accepted = result
        releaseObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.drain() }
        }
        if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: result == nil ? .cancel : .OK) }
        panel.orderOut(nil); panel.close(); drain()
        DispatchQueue.main.async { [self] in drain() }
    }
    private func drain() {
        guard completed, !delivered, panel.sheetParent == nil, window?.attachedSheet !== panel else { return }
        delivered = true
        if let releaseObserver { NotificationCenter.default.removeObserver(releaseObserver); self.releaseObserver = nil }
        let reply = onFinished; onFinished = { _ in }
        reply(owner.cancellation.isCancelled ? nil : accepted)
    }
    func cancel() { owner.cancellation.cancel(); finish(nil); drain() }
}

@MainActor final class RepositoryModel: ObservableObject {
    private let autotextTester = AutotextTesterOwner()
    func showAutotextTester() {
        guard !busy, !confirmingQuit else { return }
        autotextTester.show(preferences: fileComparisonPreferences)
    }
    private var issueTester: IssueRegexTesterController?
    private var issueTesterRequest: OperationCancellation?
    func showIssueRegexTester() {
        guard !busy, !confirmingQuit else { return }
        if let issueTester { issueTester.showWindow(nil); issueTester.window?.makeKeyAndOrderFront(nil); return }
        guard issueTesterRequest == nil else { return }
        let request=OperationCancellation(),repository=repository,access=activeAccess;issueTesterRequest=request
        Task {
            defer{if issueTesterRequest === request {issueTesterRequest=nil};withExtendedLifetime(access){}}
            do {
                if GitRuntime.isAppStoreBuild,let repository {guard access?.hasSecurityScope==true,access?.contains(repository.root)==true else{throw RepositoryAccessFailure.securityScopeUnavailable}}
                let properties:IssueTrackerProperties
                if let repository {properties=try await repository.issueTrackerProperties(cancellation:request)} else{properties=IssueTrackerProperties()}
                guard issueTesterRequest === request,!confirmingQuit else{return}
                let controller=IssueRegexTesterController(model:IssueRegexTesterModel(check:properties.checkExpression,extract:properties.extractionExpression))
                controller.completed={ [weak self,weak controller] _ in if self?.issueTester === controller {self?.issueTester=nil} }
                issueTester=controller;controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
            } catch {if !request.isCancelled {self.error=error.localizedDescription}}
        }
    }
    private var mergeOpener: MergeOpenWindowController?
    private(set) var mergeToolLaunches: [UUID: MergeToolLaunchSession] = [:]
    var configureMergeToolLaunch: (MergeToolLaunchSession) -> Void = { _ in }
    func closeMergeToolLaunchesAfterApprovedQuit() { for session in Array(mergeToolLaunches.values) { session.closeAfterApprovedQuit() } }
    @discardableResult func handleMergeToolCommandLine(arguments: [String], currentDirectory: String, completion: ((Int32) -> Void)? = nil) -> Bool {
        do {
            guard let invocation = try MergeToolInvocation.parse(arguments: arguments, currentDirectory: currentDirectory) else { return false }
            guard !retired, !confirmingQuit else { completion?(1); return true }
            let id = UUID(), session = MergeToolLaunchSession(invocation: invocation, preferences: fileComparisonPreferences, owner: workspaceWindow, permissions: activeAccess.map { [$0] } ?? [])
            configureMergeToolLaunch(session)
            session.onError = { [weak self] message in
                self?.error = message
                if completion != nil { fputs("TurtleGitMerge: " + message + "\n", stderr) }
            }
            session.onFinished = { [weak self, weak session] status in
                guard let self, let session, self.mergeToolLaunches[id] === session else { return }
                self.mergeToolLaunches.removeValue(forKey: id); completion?(status)
            }
            mergeToolLaunches[id] = session; session.start(); return true
        } catch {
            self.error = error.localizedDescription
            if completion != nil { fputs("TurtleGitMerge: " + error.localizedDescription + "\n", stderr) }
            completion?(2); return true
        }
    }
    func showMergeOpen() {
        guard !busy, !confirmingQuit, workspaceWindow?.attachedSheet == nil else { return }
        if let mergeOpener { mergeOpener.window?.makeKeyAndOrderFront(nil); return }
        let opener = MergeOpenWindowController(permissions: activeAccess.map { [$0] } ?? [])
        mergeOpener = opener
        opener.onAccepted = { [weak self] request, permissions in
            guard let self else { return }
            switch request {
            case .compare(let base, let mine, let single):
                let key = "open-" + UUID().uuidString
                let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: permissions)
                controller.model.singleFileMode = single; controller.model.useInternalMergeViewer()
                controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.fileComparisonWindows[key] === controller else { return }; self.fileComparisonWindows.removeValue(forKey: key) }
                self.fileComparisonWindows[key] = controller; controller.showWindow(nil)
            case .merge(let base, let theirs, let mine):
                let key = "open-merge-" + UUID().uuidString
                let workingMerge = try WorkingTextMerge(base: base, theirs: theirs, mine: mine)
                let context = GitRepository(root: mine.deletingLastPathComponent(), executable: try GitRuntime.executable())
                let controller = TextConflictWindowController(repository: context, access: nil, path: mine.lastPathComponent, workingMerge: workingMerge, permissions: permissions)
                controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.textConflictWindows[key] === controller else { return }; self.textConflictWindows.removeValue(forKey: key) }
                self.textConflictWindows[key] = controller; controller.showWindow(nil)
            case .patch(let file, let target, let bytes):
                let workflow = ReviewPatchWorkflow(file: file, target: target, preferred: target ?? self.root, grants: permissions,
                    executable: try GitRuntime.executable(), preferences: self.reviewPatchPreferences, clipboardBytes: bytes)
                self.presentReview(workflow)
            }
        }
        opener.onClosed = { [weak self] in self?.mergeOpener = nil }
        opener.present(parent: workspaceWindow)
    }
    func showLoadImages() {
        guard !busy, !confirmingQuit, imageLoader == nil, workspaceWindow?.attachedSheet == nil else { return }
        let loader = ImageLoadWindowController(leftPath: "", permissions: [])
        imageLoader = loader
        loader.onAccepted = { [weak self] images, permissions in
            guard let self else { return }
            let key = "images-" + UUID().uuidString
            let controller = FileComparisonWindowController(images: images, permissions: permissions)
            controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.fileComparisonWindows[key] === controller else { return }; self.fileComparisonWindows.removeValue(forKey: key) }
            self.fileComparisonWindows[key] = controller; controller.showWindow(nil)
        }
        loader.onClosed = { [weak self] in self?.imageLoader = nil }
        loader.present(parent: workspaceWindow)
    }
    weak var workspaceWindow: NSWindow? { didSet { retireWorkspaceMenus() } }
    var onUpdateCheck: (Bool, Bool) -> Void = { _, _ in }
    var onAutotextTest: () -> Void = {}
    var onIntroduction: () -> Void = {}
    var onSettingsPage: (Bool, String?) -> Void = { _, _ in }
    var onFirstStart: (Int) -> Void = { _ in }
    var onCommandHelp: () -> Void = {}
    var onSettings: (Bool) -> Void = { _ in }
    var canChangeSettingsContext: () -> Bool = { true }
    var onHelp: () -> Void = {}
    var onAbout: () -> Void = {}
    @Published var root: URL? { didSet { retireWorkspaceMenus(); pendingWorkspaceSelection=nil } }
    @Published var branch = ""
    @Published var hasGitSVN = false
    @Published var bare = false { didSet { retireWorkspaceMenus() } }
    @Published var conflictRebase = false { didSet { retireWorkspaceMenus() } }
    @Published var mergeActive = false { didSet { retireWorkspaceMenus() } }
    @Published var submodules = GitPathSet() { didSet { retireWorkspaceMenus() } }
    @Published var entries: [StatusEntry] = [] { didSet { retireWorkspaceMenus() } }
    private var workspaceSelectedPaths = GitPathSet()
    private var pendingWorkspaceSelection:GitPathSet?
    private var settingWorkspaceSelection=false
    @Published var nativeSelection = Set<String>() {
        didSet {
            guard nativeSelection != oldValue else{return}
            if !settingWorkspaceSelection {pendingWorkspaceSelection=nil}
            workspaceSelectedPaths = GitPathRowIdentity.paths(nativeSelection).intersection(visibleEntries.map(\.path))
            let valid = Set(workspaceSelectedPaths.map(GitPathRowIdentity.encode))
            if nativeSelection != valid {nativeSelection=valid}
            retireWorkspaceMenus()
        }
    }
    var selection:GitPathSet {
        get {workspaceSelectedPaths}
        set {settingWorkspaceSelection=true;defer{settingWorkspaceSelection=false};nativeSelection = Set(newValue.intersection(visibleEntries.map(\.path)).map(GitPathRowIdentity.encode))}
    }
    private let workspaceMenuOwner = UUID()
    private var workspaceMenuEpoch = UUID()
    private func retireWorkspaceMenus() { workspaceMenuEpoch = UUID() }
    final class FileMenuSnapshot {
        fileprivate let owner:UUID, epoch:UUID
        fileprivate var used = false
        let entries:[StatusEntry]
        let bare:Bool, rebase:Bool, merging:Bool
        let gitlinks:GitPathSet
        var paths:[String] { entries.map(\.path) }
        var canRevert:Bool { !bare && !entries.isEmpty && entries.allSatisfy {![FileState.untracked,.ignored].contains($0.state)} }
        var canRename:Bool { !bare && entries.count == 1 && ![FileState.untracked,.ignored,.deleted].contains(entries[0].state) }
        var canBlame:Bool {canRename && entries[0].index != "A" && entries[0].index != "D" && entries[0].worktree != "A" && !gitlinks.contains(entries[0].path)}
        var canMove:Bool { !bare && !entries.isEmpty && entries.allSatisfy {![FileState.untracked,.ignored,.deleted].contains($0.state)} }
        var canRemove:Bool { !bare && !entries.isEmpty && entries.allSatisfy {$0.index != "A" && $0.index != "D" && ![FileState.untracked,.ignored].contains($0.state)} }
        var canResolve:Bool { !bare && entries.contains {$0.state == .conflicted} }
        func canIgnore(_ action:RepositoryAction) -> Bool {
            !bare && !entries.isEmpty && entries.allSatisfy {action.removesWhenIgnoring ? ![FileState.untracked,.ignored,.deleted].contains($0.state) : [FileState.untracked,.deleted].contains($0.state)}
        }
        fileprivate init(owner:UUID,epoch:UUID,entries:[StatusEntry],bare:Bool,rebase:Bool,merging:Bool,gitlinks:GitPathSet) {self.owner=owner;self.epoch=epoch;self.entries=entries;self.bare=bare;self.rebase=rebase;self.merging=merging;self.gitlinks=gitlinks}

    }
    func captureWorkspaceMenu(_ requested:GitPathSet? = nil) -> FileMenuSnapshot {
        let ids = requested ?? selection
        return .init(owner:workspaceMenuOwner,epoch:workspaceMenuEpoch,entries:visibleEntries.filter {ids.contains($0.path)},bare:bare,rebase:conflictRebase,merging:mergeActive,gitlinks:submodules)
    }
    func claimWorkspaceMenu(_ context:FileMenuSnapshot) -> Bool {
        guard !context.used,context.owner==workspaceMenuOwner,context.epoch==workspaceMenuEpoch,!busy,!confirmingQuit,let window=workspaceWindow,window.isVisible,window.attachedSheet==nil,repository != nil else{return false}
        context.used=true;return true
    }

    @Published var output = "Open a repository to get started."
    @Published var busy = false { didSet { if busy != oldValue { retireWorkspaceMenus() };repositoryAccessWindow?.model.objectWillChange.send();if !busy { eventRefresh?.kick(); scheduleCompletedRepositoryHandoff() } } }
    @Published var confirmingQuit = false { didSet {
        if confirmingQuit != oldValue {
            retireWorkspaceMenus()
            for controller in dropTransfers.values {controller.model.confirmingQuit=confirmingQuit}
            for controller in moveWindows.values {controller.model.confirmingQuit=confirmingQuit}
            for controller in copyWindows.values {controller.model.confirmingQuit=confirmingQuit}
            for controller in worktreeCreateWindows.values {controller.model.confirmingQuit=confirmingQuit}
            for controller in addProgressWindows.values {controller.model.confirmingQuit=confirmingQuit}
            for controller in revertProgressWindows.values {controller.model.confirmingQuit=confirmingQuit}
            for controller in resolveWindows.values {controller.model.confirmingQuit=confirmingQuit}
            for controller in synchronizationWindows.values {controller.model.confirmingQuit=confirmingQuit}
            for controller in formatPatchWindows.values {controller.model.confirmingQuit=confirmingQuit}
            for controller in rebaseCompletionMailWindows.values {controller.confirmingQuit=confirmingQuit}
            for controller in requestPullWindows.values {controller.model.confirmingQuit=confirmingQuit}
            if confirmingQuit {
                for session in fileComparisonSessions.values { session.cancel() }
                cancelFinderServicePreparation()
                commandImportOwner?.cancellation.cancel();commandImportFolderChoice?.cancel()
                for handoff in commandGraphHandoffs.values { handoff.owner.cancellation.cancel(); handoff.owner.onCancelled() }
            }
            for controller in worktreeListWindows.values {controller.createWindow?.model.confirmingQuit=confirmingQuit}
            if confirmingQuit {cancelFinderWorktreeCreation()}
        }
        repositoryAccessWindow?.model.objectWillChange.send()
        if !confirmingQuit {eventRefresh?.kick();scheduleCompletedRepositoryHandoff()}
    } }
    @Published var error: String? { didSet {retireWorkspaceMenus()} }
    @Published var section = RepositoryAction.status { didSet { if section != oldValue {retireWorkspaceMenus()} } }
    @Published var dialog: RepositoryAction? { didSet {retireWorkspaceMenus()} }
    @Published var message = ""
    @Published var stagedDiff = false { didSet { if stagedDiff != oldValue { retireWorkspaceMenus() } } }
    @Published var showIgnored = false { didSet { if showIgnored != oldValue { retireWorkspaceMenus() };selection.formIntersection(visibleEntries.map(\.path)) } }
    @Published var finderStatus = "Finder cache not configured"
    @Published var workingComparisonMark: WorkingComparisonMarkSnapshot? { didSet {retireWorkspaceMenus()} }
    private let comparisonMarkStore:WorkingComparisonMarkStore
    var comparisonMarkTitle: String { workingComparisonMark.map { "Compare with " + $0.path } ?? RepositoryAction.diffLater.title }
    @Published var recentRepositories: [SavedRepository] = [] { didSet { repositoryAccessWindow?.model.refresh() } }
    private var repositoryAccessWindow:RepositoryAccessWindowController?
    private var accessStore: RepositoryAccessStore?
    private var activeAccess: RepositoryAccessLease?
    var requiresRepositoryScope = GitRuntime.isAppStoreBuild
    var repositoryBookmarkProvider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()
    var chooseRepositoryMetadataFolder:((RepositoryMetadataAccessRequirement,OperationCancellation) async throws -> URL?)?
    private var adoptionCancellation:OperationCancellation?
    private var repositoryPermissionPrompt:RepositoryMetadataPermissionPrompt?
    private var repository: GitRepository?
    var settingsContextOverride: (repository:GitRepository,access:RepositoryAccessLease?,localAvailable:Bool)?
    private var gitPropertyWindows: [String:GitPropertiesWindowController] = [:]
    private var commitWindows: [String: CommitWindowController] = [:]
    var commitWindowFactory:((GitRepository,RepositoryAccessLease?)->CommitWindowController)?
    private var combineWindows: [UUID: HistoryCombineWindowController] = [:]
    private var historyRevertWindows: [UUID: HistoryRevertWindowController] = [:]
    private var logWindows = GitPathMap<LogWindowController>()
    private struct ConfiguredLog { weak var model:LogWindowModel? }
    private var configuredLogModels:[ObjectIdentifier:ConfiguredLog]=[:]
    var logWindowFactory:((GitRepository,RepositoryAccessLease?)->LogWindowController)?
    private var revisionGraphWindows: [String: RevisionGraphWindowController] = [:]
    private var referenceBrowserWindows: [String: ReferenceBrowserWindowController] = [:]
    private var browserWindows = GitPathMap<RepositoryBrowserWindowController>()
    private var worktreeListWindows: [String: WorktreeListWindowController] = [:]
    var worktreeCreateWindowFactory: ((GitRepository, RepositoryAccessLease?, UserDefaults, URL?) -> WorktreeCreateWindowController)?
    var worktreeListWindowFactory: ((GitRepository, RepositoryAccessLease?, UserDefaults) -> WorktreeListWindowController)?
    private var worktreeCreateWindows: [String: WorktreeCreateWindowController] = [:]
    var requestPullPresentation: ((RequestPullWindowController) -> Void)?
    var makeRequestPull: ((GitRepository, RepositoryAccessLease?, String?, String?) -> RequestPullWindowController)?
    private var requestPullWindows: [String: RequestPullWindowController] = [:]
    private var importPatchWindows: [String: ImportPatchWindowController] = [:]
    private var formatPatchWindows: [String: FormatPatchWindowController] = [:]
    private(set) var rebaseCompletionMailWindows:[UUID:RebaseCompletionMailWindowController]=[:]
    private(set) var blameWindows = GitPathMap<BlameWindowController>()
    var blameRecentDocuments:BlameRecentDocuments?
    private var rebaseWindows: [String: RebaseWindowController] = [:]
    private var fetchWindows: [String: FetchWindowController] = [:]
    private var pushWindows: [String: PushWindowController] = [:]
    var pushWindowFactory:((GitRepository,RepositoryAccessLease?,UserDefaults)->PushWindowController)?
    private var synchronizationWindows: [String: SynchronizationWindowController] = [:]
    private var referenceWindows: [String: BranchTagWindowController] = [:]
    private var switchProgressWindows: [UUID: SwitchProgressWindowController] = [:]
    private var switchWindows: [String: SwitchWindowController] = [:]
    private var revertProgressWindows: [UUID: RevertProgressWindowController] = [:]
    private var addWindows: [String: AddWindowController] = [:]
    private var addUnifiedWindows: [String: PatchWindowController] = [:]
    private var svnWindows: [String: SVNWindowController] = [:]
    var svnPresentation: ((SVNWindowController) -> Void)?
    var svnWindowFactory:((GitRepository,RepositoryAccessLease?,GitSVNOperation)->SVNWindowController)?
    private var daemonWindows: [String: GitDaemonWindowController] = [:]
    var daemonConfiguration = GitDaemonConfiguration()
    var daemonPresentation: ((GitDaemonWindowController) -> Void)?
    private var lfsLocksWindows = GitPathMap<LFSLocksWindowController>()
    private var lfsFileOperations: [UUID: LFSFileOperationController] = [:]
    private var reviewPatchWorkflows: [UUID: ReviewPatchWorkflow] = [:]
    private(set) var patchDocumentWindows: [UUID: PatchWindowController] = [:]
    private var patchDocumentOpeningPaths: [UUID: Data] = [:]
    var patchDocumentPresentation: ((PatchWindowController) -> Void)?
    var configurePatchDocument: (PatchWindowController) -> Void = { _ in }
    var reviewPatchPreferences: UserDefaults = .standard
    private(set) var inaccessibleWindows: [Data: InaccessibleRepositoryWindowController] = [:]
    var inaccessiblePresentation: ((InaccessibleRepositoryWindowController) -> Void)?
    var configureInaccessibleWindow: ((InaccessibleRepositoryWindowController) -> Void)?
    var inaccessibleFolderPermission: ((URL, OperationCancellation) async throws -> RepositoryAccessLease?)?
    var inaccessibleReadDiagnosis: ((GitRepository, OperationCancellation) async throws -> GitRepositoryDiagnosis)?
    private var inaccessiblePreparations: [UUID: OperationCancellation] = [:]
    private var inaccessibleFolderPrompts: [UUID: RepositoryMetadataPermissionPrompt] = [:]
    static private(set) var activeInaccessiblePreparations = 0
    var finderPatchHandoff: FinderPatchHandoff? = .current
    private var finderPatchReceipts: [String] = []
    var reviewPatchPreparation: ((ReviewPatchWorkflow) -> Void)?
    var reviewPatchPresentation: ((WorkingTreePatchWindowController) -> Void)?
    private(set) var finderMailWorkflows: [UUID: SendMailWorkflow] = [:]
    var finderMailPresentation: ((NSWindowController) -> Void)?
    private var addProgressWindows: [UUID: AddProgressWindowController] = [:]
    var addProgressWindowFactory: ((GitRepository, RepositoryAccessLease?, [String], WorkingFileAddMode, UserDefaults, GitLibGit2Configuration, Bool) -> AddProgressWindowController)?
    var addProgressWindowPresentation: ((AddProgressWindowController) -> Void)?
    private var cleanWindows: [String: CleanWindowController] = [:]
    var cleanWindowFactory:((GitRepository)->CleanWindowController)?
    private var cleanProgressWindows: [UUID: CleanProgressWindowController] = [:]
    private var revertWindows: [String: RevertWindowController] = [:]
    private var statusWindows: [String: StatusWindowController] = [:]
    private var bisectWindows: [String: BisectWindowController] = [:]
    private var exportWindows: [String: ExportWindowController] = [:]
    private var mergeAbortWindows: [UUID: MergeAbortWindowController] = [:]
    var mergeAbortWindowFactory:((GitRepository,RepositoryAccessLease?)->MergeAbortWindowController)?
    private var mergeWindows: [String: MergeWindowController] = [:]
    private var referenceLogWindows: [String: ReferenceLogWindowController] = [:]
    private var stashRestoreWindows: [String: StashRestoreWindowController] = [:]
    private var stashWindows: [String: StashWindowController] = [:]
    var stashRestoreWindowFactory: ((GitRepository, RepositoryAccessLease?, Bool, String?, Int) -> StashRestoreWindowController)?
    private var cloneWindows: [UUID: CloneWindowController] = [:]
    private var createWindows: [String: CreateRepositoryWindowController] = [:]
    var createWindowFactory: ((URL, RepositoryAccessLease) -> CreateRepositoryWindowController)?
    var presentFinderServiceFolderPanel:((NSOpenPanel,NSWindow?,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    var selectedFinderServiceFolderURL:(NSOpenPanel)->URL? = {$0.url}
    var presentFinderServiceFilePanel:((NSOpenPanel,NSWindow?,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    var selectedFinderServiceFileURL:(NSOpenPanel)->URL? = {$0.url}
    /// File-only Services carry independent grants and have no invented Git root.
    var finderServiceFileWorkflowPresentation:((RepositoryAction,NSWindowController,[RepositoryAccessLease])->Void)?
    var finderServiceFileInspection:(([URL],OperationCancellation) async throws -> Void)?
    var finderServiceFilePermission:((URL,OperationCancellation) async throws -> RepositoryAccessLease?)?
    var finderServiceComparisonRead:((WorkingFileComparison,OperationCancellation) async throws -> FileComparisonDocument)?
    /// Receives the actual captured Services child before native presentation.
    /// Production uses ordinary windows; native verification can keep owned
    /// children offscreen without replacing their models or Git operations.
    var finderServiceWorkflowPresentation:((RepositoryAction,NSWindowController,GitRepository,RepositoryAccessLease?)->Void)?
    private var finderServiceDispatch:FinderServiceDispatchIdentity? {FinderServicePresentationContext.current}
    private var finderWorkflowPreferences:UserDefaults {finderServiceDispatch?.preferences ?? fileComparisonPreferences}
    var commandTransportWorkflowPresentation:((RepositoryAction,NSWindowController,GitRepository,RepositoryAccessLease?)->Void)?
    @discardableResult private func prepareFinderServiceWorkflow(_ controller:NSWindowController,repository:GitRepository,access:RepositoryAccessLease?)->Bool {
        let filesystem=controller as? any FinderFilesystemWorkflowWindow
        guard filesystem?.finderServiceCanPresent != false else{return false}
        if let chain=TransportBatchPresentationContext.chain,GitReferenceName.equal(chain.root.standardizedFileURL.resolvingSymlinksInPath().path,repository.root.standardizedFileURL.resolvingSymlinksInPath().path),controller is any TransportBatchWindow {
            chain.capture(controller)
            guard chain.canPresent else{return false}
            let action:RepositoryAction
            switch controller {
            case let fetch as FetchWindowController:action=fetch.model.isPull ? .pull:.fetch
            case is PushWindowController:action = .push
            case is ResetWindowController:action = .reset
            case is SwitchWindowController:action = .switchBranch
            case is RebaseWindowController:action = .rebase
            case is StashWindowController:action = .stash
            case let restore as StashRestoreWindowController:action=restore.model.pop ? .stashPop:.stashApply
            case is MergeWindowController:action = .merge
            case is RequestPullWindowController:action = .requestPull
            default:action = .formatPatch
            }
            if chain.command {commandTransportWorkflowPresentation?(action,controller,repository,access)}
            else {finderServiceWorkflowPresentation?(action,controller,repository,access)}
            return true
        }
        guard let context=finderServiceDispatch,GitReferenceName.equal(context.root.standardizedFileURL.resolvingSymlinksInPath().path,repository.root.standardizedFileURL.resolvingSymlinksInPath().path) else{return true}
        finderServiceWorkflowPresentation?(context.action,controller,repository,access)
        return filesystem == nil || (!retired && !confirmingQuit && filesystem?.finderServiceCanPresent == true)
    }
    private var finderServiceTransportStep:RepositoryTransportBatchChain?
    private var finderServiceOwner:RepositoryWindowOwner?
    private var finderServiceImportOwner:RepositoryWindowOwner?
    private var finderServiceFolderChoice:RepositoryCreationFolderChoice?
    private var finderServiceWorkers=0
    private var finderRegistrations:[UUID:OperationCancellation]=[:]
    var hasPendingFinderServiceWork:Bool {!finderRegistrations.isEmpty || finderServiceOwner != nil || finderServiceImportOwner != nil || finderServiceFolderChoice != nil || finderServiceWorkers>0}
    private func cancelFinderServicePreparation(){finderServiceOwner?.cancellation.cancel();finderServiceImportOwner?.cancellation.cancel();finderServiceFolderChoice?.cancel();if finderServiceImportOwner != nil{commandImportFolderChoice?.cancel()};finderServiceTransportStep?.cancel()}
    var presentCreationFolderPanel: ((NSOpenPanel, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    var selectedCreationFolderURL: (NSOpenPanel) -> URL? = { $0.url }
    private var creationFolderChoice: RepositoryCreationFolderChoice?
    var presentTransferDestinationPanel: ((NSOpenPanel, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    var selectedTransferDestinationURL: (NSOpenPanel) -> URL? = { $0.url }
    private var sourceTransferOwner: RepositoryWindowOwner?
    private var sourceTransferFolderChoice: FinderTransferDestinationChoice?
    var presentWorktreeFolderPanel: ((NSOpenPanel, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    var selectedWorktreeFolderURL: (NSOpenPanel) -> URL? = { $0.url }
    var worktreeSourceAccessProvider: (([URL]) throws -> RepositoryAccessLease?)?
    private var sourceWorktreeOwner: RepositoryWindowOwner?
    private var sourceWorktreeFolderChoice: FinderTransferDestinationChoice?
    var finderTransferPresentation: ((FinderRequest, GitRepository, RepositoryAccessLease) -> Void)?
    private var copyWindows: [UUID: FileCopyWindowController] = [:]
    private(set) var moveWindows: [String: FileMoveWindowController] = [:]
    private var renameWindows: [String: RenameWindowController] = [:]
    private(set) var imageConflictWindows = GitPathMap<ImageConflictWindowController>()
    private(set) var textConflictWindows = GitPathMap<TextConflictWindowController>()
    private(set) var submoduleDiffWindows = GitPathMap<SubmoduleDiffWindowController>()
    private var revisionComparisonWindows = GitPathMap<RevisionComparisonWindowController>()
    private var imageLoader: ImageLoadWindowController?
    private(set) var fileComparisonWindows = GitPathMap<FileComparisonWindowController>()
    private var submoduleSyncWindows: [UUID: SubmoduleSyncWindowController] = [:]
    private var submoduleAddWindows: [String: SubmoduleAddWindowController] = [:]
    private var submoduleAddProgressWindows: [UUID: SubmoduleAddProgressWindowController] = [:]
    private var submoduleUpdateProgressWindows: [UUID: SubmoduleUpdateProgressWindowController] = [:]
    private var submoduleUpdateWindows: [String: SubmoduleUpdateWindowController] = [:]
    private var submoduleConflictWindows = GitPathMap<SubmoduleConflictWindowController>()
    private var deleteConflictWindows = GitPathMap<DeleteConflictWindowController>()
    private var resetWindows: [String: ResetWindowController] = [:]
    private var resolveWindows = GitPathMap<ResolveWindowController>()
    private var ignoreWindows: [String: IgnoreWindowController] = [:]
    var ignoreWindowFactory: ((GitRepository, RepositoryAccessLease?, [String], Bool, Bool) throws -> IgnoreWindowController)?
    private var removeWindows: [String: RemoveWindowController] = [:]
    var removeWindowFactory: ((GitRepository, RepositoryAccessLease?, RemovalRequest) -> RemoveWindowController)?
    private var adoptionGeneration = 0
    private var retired = false
    // Settings presentation can outlive an accepted asynchronous close. A clean
    // Quit retires this workspace before confirmingQuit necessarily changes.
    var isRetired: Bool { retired }
    private struct CompletedRepositoryHandoff {
        let id = UUID()
        let generation: Int
        let root: URL
        let access: RepositoryAccessLease
        let owner: RepositoryWindowOwner
        let output: String
    }
    private var completedRepositoryHandoff: CompletedRepositoryHandoff?
    var hasPendingRepositoryHandoff: Bool { completedRepositoryHandoff != nil }
    var hasPendingRepositoryWork: Bool { !inaccessiblePreparations.isEmpty || !fileComparisonSessions.isEmpty || hasPendingFinderServiceWork || commandRepositoryBatchCancellation != nil || commandTransportFolderChoice != nil || mergeToolLaunches.values.contains { $0.hasPendingWork } || hasPendingRepositoryHandoff || !addPreparations.isEmpty || !lfsPreparations.isEmpty || !mailPreparations.isEmpty || resolutionCommandPreparation != nil || !silentResolveSessions.isEmpty || conflictEditorPreparationCount > 0 || settingsPreparation != nil || transferPreparation != nil || creationFolderChoice != nil || sourceTransferOwner != nil || sourceWorktreeOwner != nil || commandImportOwner != nil || !commandOutputOwners.isEmpty }
    private var resolutionCommandPreparation: RepositoryWindowOwner?
    private var resolutionCommandFolderChoice: RepositoryCreationFolderChoice?
    private var silentResolveSessions = GitPathMap<FileListComparisonSession>()
    var resolveWindowPresentation: ((ResolveWindowController) -> Void)?
    var executeSilentResolve: ((GitRepository, [String], OperationCancellation) async throws -> String)?
    var conflictWindowPresentation: ((NSWindowController) -> Void)?
    private var transferPreparation: RepositoryWindowOwner?
    private var transferFolderChoice: RepositoryCreationFolderChoice?
    var movePresentation: ((FileMoveWindowController) -> Void)?
    var copyPresentation: ((FileCopyWindowController) -> Void)?
    var fileCopySourceProvider: any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()
    private var settingsPreparation: RepositoryWindowOwner?
    private var settingsFolderChoice: RepositoryCreationFolderChoice?
    private var mailPreparations: [UUID: RepositoryWindowOwner] = [:]
    private var mailPermissionPanels: [UUID: NSOpenPanel] = [:]
    var mailFilePermission: (([URL], OperationCancellation) async throws -> [RepositoryAccessLease]?)?
    var mailFileInspection: (([URL], OperationCancellation) async throws -> Void)?
    private var lfsPreparations: [UUID: RepositoryWindowOwner] = [:]
    var lfsSelectionPreflight: ((GitRepository, [String], Bool, OperationCancellation) async throws -> [String])?
    var lfsLocksWindowFactory: ((GitRepository, RepositoryAccessLease?, UserDefaults) -> LFSLocksWindowController)?
    var lfsFileOperationFactory: ((GitRepository, RepositoryAccessLease?, UserDefaults) -> LFSFileOperationController)?
    private var addPreparations: [UUID: RepositoryWindowOwner] = [:]
    private var commandOutputOwners: [UUID: RepositoryWindowOwner] = [:]
    private var commandGraphWindows: [UUID: RevisionGraphWindowController] = [:]
    private var commandGraphHandoffs: [UUID: CommandGraphOutputHandoff] = [:]
    private var commandReferenceWindows: [UUID: CommitContainingReferencesWindowController] = [:]
    var revisionGraphWindowFactory: ((GitRepository, RepositoryAccessLease?, UserDefaults, Bool) -> RevisionGraphWindowController)?
    private var commandImportOwner: RepositoryWindowOwner?
    private var commandImportFolderChoice: RepositoryCreationFolderChoice?
    var commandLinePatchPermission: ((URL) throws -> RepositoryAccessLease?)?
    var presentCommandImportFolderPanel: ((NSOpenPanel, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    var selectedCommandImportFolderURL: (NSOpenPanel) -> URL? = { $0.url }
    var addSelectionPreflight: ((GitRepository, [String], OperationCancellation) async throws -> Bool)?
    private var cloneKeyAccess: [String: RepositoryAccessLease] = [:]
    private let repositoryFactory:((URL) throws -> GitRepository)?
    private let snapshotWriter:(@Sendable (FinderSnapshot) throws -> Bool)?
    private let snapshotStore:FinderSnapshotStore?
    private var finderPublicationSession:FinderPublicationSession?
    private var finderPublicationReads:[UUID:OperationCancellation]=[:]
    private(set) var finderPublicationShutdownPending = false
    private var finderPublicationShutdownTask:Task<Void,Never>?
    var hasPendingFinderPublication:Bool { !finderPublicationReads.isEmpty || finderPublicationSession != nil || finderPublicationShutdownPending }
    private func publicationSession(_ store:FinderSnapshotStore,cancellation:OperationCancellation) throws -> FinderPublicationSession {
        if let finderPublicationSession { return finderPublicationSession }
        let session=try store.startSession(cancellation:cancellation)
        finderPublicationSession=session;return session
    }
    /// Keep the live writer lease until every owned Git reader and publication
    /// settles. Retiring this owner must preserve other active app/helper owners.
    func shutdownFinderPublication() async {
        if let finderPublicationShutdownTask { await finderPublicationShutdownTask.value;return }
        let task=Task { [self] in await finishFinderPublication() }
        finderPublicationShutdownTask=task
        await task.value
    }
    private func finishFinderPublication() async {
        finderPublicationShutdownPending=true
        defer { finderPublicationShutdownPending=false }
        for token in finderPublicationReads.values { token.cancel() }
        while !finderPublicationReads.isEmpty { try? await Task.sleep(nanoseconds:10_000_000) }
        if let store=snapshotStore,let session=finderPublicationSession {
            finderPublicationSession=nil
            do {
                let updated=try await Task.detached { try store.endSession(session) }.value
                if let failure=updated.persistenceFailure { finderStatus="Finder live status retired; saved cache unavailable: "+failure }
                notifyFinder()
            }
            catch { finderStatus="Finder cache shutdown unavailable: "+error.localizedDescription }
        }
    }
    var notifyFinder:()->Void = { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification),object:nil) }
    private(set) var finderWatches:FinderWatchManager?
    private let monitoringEnabled:Bool
    private var fileMonitor:RepositoryFileEventMonitor?
    private var eventRefresh:RepositoryEventRefresh?
    private var watchIdentity=UUID()
    private var watchPaths:[URL]=[]
    func stopMonitoringForTermination() { retired = true;for controller in Array(rebaseCompletionMailWindows.values) {controller.close()};for token in finderRegistrations.values {token.cancel()}; for token in inaccessiblePreparations.values { token.cancel() };for prompt in inaccessibleFolderPrompts.values { prompt.cancel() };for controller in Array(inaccessibleWindows.values) { controller.close() }; for session in fileComparisonSessions.values { session.cancel() };cancelFinderServicePreparation(); for token in finderPublicationReads.values { token.cancel() }; for session in mergeToolLaunches.values { session.cancel() }; for session in silentResolveSessions.values { session.cancel() }; resolutionCommandPreparation?.cancellation.cancel(); resolutionCommandFolderChoice?.cancel(); transferPreparation?.cancellation.cancel(); transferFolderChoice?.cancel(); settingsPreparation?.cancellation.cancel(); settingsFolderChoice?.cancel(); completedRepositoryHandoff = nil; creationFolderChoice?.cancel(); cancelFinderSourceTransfer(); cancelFinderWorktreeCreation(); for controller in Array(dropTransfers.values) { controller.close() }; commandImportOwner?.cancellation.cancel(); commandImportFolderChoice?.cancel(); for owner in addPreparations.values { owner.cancellation.cancel() }; for owner in lfsPreparations.values { owner.cancellation.cancel() }; for owner in mailPreparations.values { owner.cancellation.cancel(); owner.onCancelled() }; commandLineInputCancellation?.cancel(); cancelCommandTransportBatch(); for token in commandLineOutputOperations.values { token.cancel() };for owner in commandOutputOwners.values { owner.cancellation.cancel(); owner.onCancelled() };for controller in Array(commandReferenceWindows.values) { controller.close() }; repositoryAccessWindow?.model.retire();repositoryAccessWindow?.close();adoptionCancellation?.cancel();repositoryPermissionPrompt?.cancel();cancelConflictEditorPreparations(); stopFileMonitoring() }
    private func stopFileMonitoring() {
        watchIdentity=UUID();fileMonitor?.stop();fileMonitor=nil;watchPaths=[];eventRefresh?.retire();eventRefresh=nil
    }
    private func monitorFiles(_ directories:[URL]) {
        guard monitoringEnabled,watchPaths != directories else { return }
        stopFileMonitoring()
        let permitted=directories.filter { !GitRuntime.isAppStoreBuild || activeAccess?.permits($0)==true }
        guard !permitted.isEmpty else { return }
        let identity=watchIdentity
        let refresh=RepositoryEventRefresh(available:{ [weak self] in
            self?.repository != nil && self?.busy==false && self?.confirmingQuit==false
        },refresh:{ [weak self] in await self?.refresh(refreshStatus:true) })
        do {
            let monitor=try RepositoryFileEventMonitor(roots:permitted) { [weak self] events in
                guard !events.isEmpty else { return }
                Task { @MainActor [weak self] in
                    guard let self,self.watchIdentity==identity else { return }
                    self.eventRefresh?.invalidate()
                }
            }
            eventRefresh=refresh;fileMonitor=monitor;watchPaths=directories
        } catch { refresh.retire();finderStatus="Filesystem monitoring unavailable: "+error.localizedDescription }
    }
    private var cacheStates: GitPathMap<FileState> = [:]
    private var cacheOverlayEntries: GitPathMap<FileState>?
    private var cacheIndexFlags: GitPathMap<FinderIndexFlags>?
    private var cacheOverlayPolicies:GitPathMap<FinderOverlayPolicyMetadata> = [:]
    private let finderStatusPolicyProvider:(() throws -> FinderStatusPolicy)?
    private var finderPolicyObservers:[NSObjectProtocol]=[]
    private func finderPolicyChanged(operation:Bool) {
        guard !retired else{return}
        if operation {
            guard let policy=try? finderStatusPolicyProvider?(),policy.blockStatus,
                  policy.cacheMode == .shell || policy.cacheMode == .shellExtended,
                  !FinderStatusOperationLease.isBlocked() else{return}
        }
        eventRefresh?.invalidate()
        finderWatches?.reloadStatusPolicy(operation:operation)
    }
    private var cacheRepositories: GitPathMap<FinderRepositoryMetadata> = [:]
    private var monitoredRoots: [String] = []
    var visibleEntries: [StatusEntry] { entries.filter { showIgnored || $0.state != .ignored } }
    var selectedPaths: [String] { entries.filter { selection.contains($0.id) }.map(\.path) }
    var canRevertSelection: Bool {
        let selected = entries.filter { selection.contains($0.id) }
        return !selected.isEmpty && selected.allSatisfy { ![FileState.untracked, .ignored].contains($0.state) }
    }
    var canRenameSelection: Bool {
        let selected = entries.filter { selection.contains($0.id) }
        return !bare && !busy && selected.count == 1 && ![FileState.untracked, .ignored, .deleted].contains(selected[0].state)
    }
    var canRemoveSelection: Bool {
        let selected = entries.filter { selection.contains($0.id) }
        return !bare && !busy && !selected.isEmpty && selected.allSatisfy { $0.index != "A" && $0.index != "D" && ![FileState.untracked, .ignored].contains($0.state) }
    }

    var canResolveSelection: Bool { !bare && !busy && entries.contains { $0.state == .conflicted && (selection.isEmpty || selection.contains($0.id)) } }
    func canIgnoreSelection(_ action: RepositoryAction) -> Bool {
        let selected = entries.filter { selection.contains($0.id) }
        guard !bare, !busy, !selected.isEmpty else { return false }
        let eligible = selected.allSatisfy { action.removesWhenIgnoring ? ![FileState.untracked, .ignored, .deleted].contains($0.state) : [.untracked, .deleted].contains($0.state) }
        return eligible && (!action.ignoresByExtension || selected.contains { !($0.path as NSString).pathExtension.isEmpty })
    }

    init(startMonitoring: Bool = true,initializePreferences:Bool = true,repositoryFactory:((URL) throws -> GitRepository)? = nil,snapshotWriter:(@Sendable (FinderSnapshot) throws -> Bool)? = nil,snapshotStore:FinderSnapshotStore? = nil,finderWatches:FinderWatchManager? = nil,savedAccessStore:RepositoryAccessStore? = nil,comparisonMarks:WorkingComparisonMarkStore? = nil,cachePersistenceDefaults:UserDefaults = .standard,
         finderStatusPolicyProvider:(() throws -> FinderStatusPolicy)? = nil,
         publishCachePersistence:(FinderCachePersistencePreferences) throws -> Void = { if try $0.write() { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderCachePersistencePreferences.notification),object:nil) } }) {
        comparisonMarkStore=comparisonMarks ?? WorkingComparisonMarkStore(storageURL:WorkingComparisonMarkStore.defaultStorageURL)
        self.accessStore=savedAccessStore;recentRepositories=savedAccessStore?.repositories ?? []
        self.finderWatches=finderWatches
        self.repositoryFactory=repositoryFactory;self.snapshotWriter=snapshotWriter
        self.snapshotStore=snapshotStore ?? FinderIntegration.snapshotURL.map { FinderSnapshotStore(url:$0) }
        let policyURL=self.snapshotStore?.url
        self.finderStatusPolicyProvider=finderStatusPolicyProvider ?? (startMonitoring && initializePreferences ? {try FinderStatusPolicy.read(from:policyURL)}:nil)
        if self.snapshotStore != nil { finderStatus = "Finder cache ready" }
        monitoringEnabled=startMonitoring
        guard startMonitoring && initializePreferences else { return }
        cachePersistenceDefaults.set(true,forKey:AdvancedSettingsModel.cachePersistencePendingKey)
        do {
            try publishCachePersistence(FinderCachePersistencePreferences.from(defaults:cachePersistenceDefaults))
            cachePersistenceDefaults.removeObject(forKey:AdvancedSettingsModel.cachePersistencePendingKey)
        } catch { finderStatus="Finder cache persistence preferences unavailable: "+error.localizedDescription }
        do { if self.finderWatches==nil { self.finderWatches=try FinderWatchManager.production(startup:.allSavedRepositories) } else {self.finderWatches?.restore()} }
        catch { finderStatus="Watched repositories unavailable: "+error.localizedDescription }
        do { _ = try FinderMenuSettings.from().write() }
        catch { finderStatus = "Finder menu preferences unavailable: " + error.localizedDescription }
        do { _ = try FinderCacheTrayPreferences.from().write() }
        catch { finderStatus = "Finder cache menu preferences unavailable: " + error.localizedDescription }
        do {
            if let policyURL {
                let overlayURL=policyURL.deletingLastPathComponent().appendingPathComponent("overlay-settings.json")
                var bootstrap:FinderOverlaySettings?
                let configure=FinderStatusSettingsPublication.transaction(statusURL:policyURL,ownedURL:overlayURL)
                try configure({
                    let accepted=try FinderOverlaySettings.readChecked(from:overlayURL)
                    var info=stat();let missing=lstat(overlayURL.path,&info) != 0 && errno==ENOENT
                    let value=missing ? FinderOverlaySettings.from(defaults:cachePersistenceDefaults):accepted
                    if missing {bootstrap=value}
                    return FinderStatusPolicy(settings:value,preferences:try FinderStatusPolicyPreferences.read(from:policyURL))
                },{if let bootstrap {_ = try bootstrap.write(to:overlayURL)}},{})
            }
        }
        catch { finderStatus = "Finder overlay preferences unavailable: " + error.localizedDescription }
        do {
            if let policyURL,let readPolicy=self.finderStatusPolicyProvider {
                var bootstrap:FinderStatusPolicyPreferences?
                let configure=FinderStatusSettingsPublication.transaction(statusURL:policyURL,ownedURL:policyURL.appendingPathExtension("policy"))
                try configure({
                    if !FileManager.default.fileExists(atPath:policyURL.appendingPathExtension("policy").path) {
                        let preferences=FinderStatusPolicyPreferences.from(defaults:cachePersistenceDefaults);bootstrap=preferences
                        return FinderStatusPolicy(settings:try FinderOverlaySettings.readChecked(from:policyURL.deletingLastPathComponent().appendingPathComponent("overlay-settings.json")),preferences:preferences)
                    }
                    return try readPolicy()
                },{if let bootstrap {_ = try bootstrap.write(to:policyURL)}},{})
            }
        } catch {finderStatus="Finder status policy unavailable: "+error.localizedDescription}
        for (name,operation) in [(FinderStatusPolicyPreferences.notification,false),(FinderStatusOperationLease.notification,true)] {
            finderPolicyObservers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name(name),object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.finderPolicyChanged(operation:operation) }
            })
        }
        do { workingComparisonMark = try comparisonMarkStore.snapshot() } catch { self.error = error.localizedDescription }
        do {
            let store = try savedAccessStore ?? RepositoryAccessStore(storageURL: RepositoryAccessStore.defaultStorageURL)
            accessStore = store; recentRepositories = store.repositories
        } catch { self.error = "Saved repository permissions could not be loaded: " + error.localizedDescription }
        Task {
            if let snapshot = await Task.detached(operation: { FinderSnapshot.readLive() }).value, root == nil {
                cacheStates = snapshot.states; monitoredRoots = snapshot.roots; cacheRepositories = snapshot.repositories
                cacheOverlayEntries = snapshot.overlayEntries
                cacheIndexFlags = snapshot.indexFlags
                cacheOverlayPolicies = snapshot.overlayPolicies
            }
        }

    }
    deinit {for observer in finderPolicyObservers {DistributedNotificationCenter.default().removeObserver(observer)}}
    func configureSettingsRemote(_ model: RemoteSettingsWindowModel) {
        let repository = model.repository, access = model.access
        model.onFetch = { [weak self] remote in self?.showFetch(repository: repository, access: access, remote: remote) }
        model.onRemotesChanged = { [weak self] _ in
            self?.refreshRepositoryLogs(repository.root)
            if self?.root == repository.root { Task { await self?.refresh() } }
        }
    }
    func gitConfigurationContext(globalOnly: Bool = false) throws -> (repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool) {
        if globalOnly { return (try makeRepository(TurtleGitTemporaryStorage.root), nil, false) }
        if let settingsContextOverride { return settingsContextOverride }
        if let repository { return (repository, activeAccess, true) }
        return (try makeRepository(FileManager.default.homeDirectoryForCurrentUser), nil, false)
    }
    private func makeRepository(_ url: URL) throws -> GitRepository {
        try repositoryFactory?(url) ?? GitRepository(root:url,executable:GitRuntime.executable())
    }
    /// A command router has no workspace view. Reuse real saved authority and
    /// the live publisher when a workspace exists, without adopting its root.
    private var actionRoutingAccessEnabled=false
    /// Only the production delegate factory opts into loading application
    /// bookmarks. Injected/direct model consumers keep their supplied stores.
    func enableActionRoutingAccess() {actionRoutingAccessEnabled=true}
    /// Promoting a general action process to a workspace must keep its existing
    /// bookmark archive and Finder publisher rather than create competing owners.
    func makeWorkspaceSharingActionAccess() -> RepositoryModel {
        RepositoryModel(finderWatches: finderWatches, savedAccessStore: accessStore,
                        comparisonMarks: comparisonMarkStore)
    }
    func configureActionRouting(from workspace:RepositoryModel? = nil,loadSavedAccess:Bool = true) {
        if accessStore == nil {
            if let store=workspace?.accessStore {accessStore=store}
            else if loadSavedAccess && actionRoutingAccessEnabled {do {accessStore=try RepositoryAccessStore(storageURL:RepositoryAccessStore.defaultStorageURL)} catch {self.error=error.localizedDescription}}
            recentRepositories=accessStore?.repositories ?? []
        }
        if finderWatches == nil {
            finderWatches=workspace?.finderWatches
            if finderWatches == nil,loadSavedAccess,actionRoutingAccessEnabled {
                // Loading saved authority for one action dialog must not crawl
                // every watched repository. A later workspace promotion keeps
                // this same manager and explicitly restores the complete set.
                do {finderWatches=try FinderWatchManager.production(startup:.deferred)}
                catch {self.error="Watched repositories unavailable: "+error.localizedDescription}
            }
        }
    }
    /// The public Service opens a workspace, not an implicit Status operation.
    /// An unknown selection starts an explicit folder chooser before Git reads.
    @discardableResult func handleOpenServiceSelection(_ submitted:[URL])->Bool {
        guard !retired,!confirmingQuit,!busy,!hasPendingRepositoryWork,workspaceWindow?.attachedSheet == nil else{return false}
        let paths:[URL]
        do {paths=try FinderServiceCommand.status.request(paths:submitted).paths} catch {self.error=error.localizedDescription;return false}
        configureActionRouting()
        if let root,let activeAccess,paths.allSatisfy({RepositoryAccessLease.pathIsContained($0,by:root) && activeAccess.contains($0)}),!requiresRepositoryScope || activeAccess.hasSecurityScope {
            openSession(activeAccess,requestedLocation:paths[0]);return true
        }
        if let store=accessStore {
            for saved in store.repositories where paths.allSatisfy({RepositoryAccessLease.pathIsContained($0,by:URL(fileURLWithPath:saved.lastKnownPath))}) {
                if let lease=try? store.acquire(saved.id,requireSecurityScope:requiresRepositoryScope),paths.allSatisfy({lease.contains($0)}) {openSession(lease,requestedLocation:paths[0]);return true}
            }
        }
        let owner=RepositoryWindowOwner(window:workspaceWindow),generation=adoptionGeneration
        let choice=RepositoryCreationFolderChoice(window:workspaceWindow,owner:owner),panel=choice.panel
        finderServiceOwner=owner;finderServiceFolderChoice=choice;finderServiceWorkers += 1;busy=true
        panel.title="Open Repository";panel.prompt="Open repository"
        panel.message="Choose a repository folder to open in TurtleGit. The selected files or folders do not grant repository access."
        panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false;panel.showsHiddenFiles=true
        panel.directoryURL=paths.first.map{$0.hasDirectoryPath ? $0:$0.deletingLastPathComponent()};panel.alphaValue=workspaceWindow?.alphaValue ?? 1;panel.appearance=workspaceWindow?.appearance
        choice.onFinished={ [weak self,weak choice] selected in
            guard let self,let choice else{return}
            Task { @MainActor [self,choice] in
                defer {self.finderServiceWorkers -= 1;if self.finderServiceFolderChoice === choice {self.finderServiceFolderChoice=nil};if self.finderServiceOwner === owner {self.finderServiceOwner=nil}}
                while choice.panel.sheetParent != nil || choice.panel.attachedSheet != nil {try? await Task.sleep(nanoseconds:5_000_000)}
                guard !self.retired,!self.confirmingQuit,!owner.cancellation.isCancelled,generation==self.adoptionGeneration else{return}
                self.busy=false
                guard let selected else{return}
                self.openSession(RepositoryAccessLease(url:selected,provider:self.repositoryBookmarkProvider),handoffOwner:owner)
            }
        }
        choice.begin(present:presentFinderServiceFolderPanel,selected:selectedFinderServiceFolderURL)
        return true
    }
    func chooseRepository(preferred: URL? = nil) {
        guard !busy, !confirmingQuit else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Open repository"
        panel.message = "Choose the repository’s root folder. TurtleGit remembers your permission to work in this folder."
        panel.directoryURL = preferred
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL, onOpened: (() -> Void)? = nil) { openSession(RepositoryAccessLease(url: url,provider:repositoryBookmarkProvider), onOpened: onOpened) }
    func openRecent(_ saved: SavedRepository) {
        guard !busy, !confirmingQuit else { return }
        do {
            guard let store = accessStore else { throw RepositoryAccessFailure.unknownRepository }
            let lease = try store.acquire(saved.id, requireSecurityScope: requiresRepositoryScope)
            recentRepositories = store.repositories
            openSession(lease)
        } catch {
            self.error = "Could not reopen “\(saved.name)”. Select its folder with Open Repository to renew access.\n" + error.localizedDescription
        }
    }
    func forgetRepository(_ saved: SavedRepository) {
        do { try accessStore?.forget(saved.id); recentRepositories = accessStore?.repositories ?? [] }
        catch { self.error = error.localizedDescription }
    }
    func showRepositoryAccess(selected:UUID? = nil) {
        guard !busy,!confirmingQuit,let store=accessStore else { return }
        let controller:RepositoryAccessWindowController
        if let existing=repositoryAccessWindow {
            controller=existing;existing.model.refresh()
            if let selected { existing.model.selection=selected }
        } else {
            let editor=RepositoryAccessWindowModel(store:store,provider:repositoryBookmarkProvider,requireScope:requiresRepositoryScope,selected:selected)
            editor.mayChange={ [weak self] in self?.busy==false && self?.confirmingQuit==false }
            editor.onChanged={ [weak self] in self?.recentRepositories=store.repositories }
            editor.open={ [weak self] saved in self?.openRecent(saved) }
            controller=RepositoryAccessWindowController(model:editor)
            controller.onClosed={ [weak self] in self?.repositoryAccessWindow=nil }
            repositoryAccessWindow=controller
        }
        controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
    }
    func closeRepository() {
        guard !busy, !confirmingQuit else { return }
        guard root == nil || canChangeSettingsContext() else { return }
        stopFileMonitoring()
        completedRepositoryHandoff = nil
        adoptionGeneration += 1; hasGitSVN = false; bare = false; mergeActive = false
        repository = nil; activeAccess = nil; root = nil; entries = []; selection = []
        branch = ""; message = ""; output = "Open a repository to get started."
    }
    private func rememberAccess(_ lease: RepositoryAccessLease, repositoryRoot: URL? = nil) {
        do { try accessStore?.remember(repositoryRoot ?? lease.url); recentRepositories = accessStore?.repositories ?? [] }
        catch { self.error = "The repository is open, but its permission could not be saved: " + error.localizedDescription }
    }
    private func prepareRepositoryMetadataAccess(at location:URL,primary:RepositoryAccessLease,cancellation:OperationCancellation) async throws -> (scopes:[RepositoryAccessLease],newFolders:[URL]) {
        try await prepareRepositoryMetadataAccess(at:location,primary:primary,cancellation:cancellation,owner:workspaceWindow)
    }
    private func prepareRepositoryMetadataAccess(at location:URL,primary:RepositoryAccessLease,cancellation:OperationCancellation,owner:NSWindow?) async throws -> (scopes:[RepositoryAccessLease],newFolders:[URL]) {
        guard requiresRepositoryScope else { return ([],[]) }
        guard primary.hasSecurityScope,primary.contains(location) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        var scopes:[RepositoryAccessLease]=[],newFolders:[URL]=[]
        if let store=accessStore,let saved=store.repositories.filter({RepositoryAccessLease.pathIsContained(location,by:URL(fileURLWithPath:$0.lastKnownPath))}).max(by:{$0.lastKnownPath.count<$1.lastKnownPath.count}) {
            scopes=try store.acquireAdditionalPermissions(saved.id,requireSecurityScope:true,skipUnavailable:true)
        }
        for _ in 0..<64 {
            try cancellation.check()
            let folders=([primary]+scopes).flatMap { $0.permittedFolders() }
            let requirement=try await Task.detached(priority:.userInitiated) { try RepositoryMetadataAccess.next(at:location,authorizedFolders:folders,cancellation:cancellation) }.value
            try cancellation.check()
            guard let requirement else { return (scopes,newFolders) }
            let selected:URL?
            if let chooseRepositoryMetadataFolder { selected=try await chooseRepositoryMetadataFolder(requirement,cancellation) }
            else {
                let prompt=RepositoryMetadataPermissionPrompt();repositoryPermissionPrompt=prompt
                defer { if repositoryPermissionPrompt === prompt { repositoryPermissionPrompt=nil } }
                selected=await prompt.choose(requirement,owner:owner,cancellation:cancellation)
            }
            try cancellation.check()
            guard let selected else { cancellation.cancel();throw OperationCancellationFailure.cancelled }
            let scope=RepositoryAccessLease(url:selected,provider:repositoryBookmarkProvider)
            guard scope.hasSecurityScope,scope.contains(requirement.folder) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(requirement.folder.path) }
            scopes.append(scope);newFolders.append(selected)
        }
        throw RepositoryMetadataAccessFailure.tooManyDependencies
    }
    private func openSession(_ lease: RepositoryAccessLease, selected: FinderRequest? = nil, action: RepositoryAction? = nil, actionPaths: [String]? = nil, invocation: PrimaryCommandInvocation? = nil, messageAccess: RepositoryAccessLease? = nil, outputAccess: RepositoryAccessLease? = nil, commandRootOnly: Bool = false, onFinished: ((Bool) -> Void)? = nil, handoffOwner suppliedHandoffOwner: RepositoryWindowOwner? = nil, serviceCommand: FinderServiceCommand? = nil, servicePreferences:UserDefaults? = nil, onOpened: (() -> Void)? = nil, requestedLocation: URL? = nil) {
        let handoffOwner = suppliedHandoffOwner ?? (invocation?.request.action == .revisionGraph && invocation?.outputFile != nil ? CommandGraphOutputContext.current?.owner : nil)
        guard !busy, !confirmingQuit, !retired, handoffOwner?.cancellation.isCancelled != true else { onFinished?(false); return }
        let restoreState:()->Void = { [repository,activeAccess,root,entries,selection,branch,bare,hasGitSVN,mergeActive,conflictRebase,submodules,section,output] in
            self.repository=repository;self.activeAccess=activeAccess;self.root=root;self.entries=entries;self.selection=selection
            self.branch=branch;self.bare=bare;self.hasGitSVN=hasGitSVN;self.mergeActive=mergeActive;self.conflictRebase=conflictRebase;self.submodules=submodules;self.section=section;self.output=output
        }
        completedRepositoryHandoff = nil
        stopFileMonitoring()
        adoptionGeneration += 1
        let adoption = adoptionGeneration
        busy = true
        let cancellation=handoffOwner?.cancellation ?? OperationCancellation();adoptionCancellation=cancellation
        let owner=handoffOwner == nil ? workspaceWindow : nil
        let ownerObserver=owner.map { NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:$0,queue:.main) { _ in cancellation.cancel() } }
        Task {
            var opened = false, holdsBusy = true
            var diagnosticLocation = requestedLocation ?? selected?.paths.first ?? lease.url
            var diagnosticAccess = lease
            defer { onFinished?(opened) }
            defer { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) };if adoptionCancellation === cancellation { adoptionCancellation=nil;if holdsBusy { busy=false } };withExtendedLifetime((lease,handoffOwner)) {} }
            do {
                var commandSelectedRevision: String?
                let commandMessage: String?
                if let invocation {
                    if let file = invocation.messageFile {
                        guard let messageAccess, messageAccess.contains(file), !GitRuntime.isAppStoreBuild || messageAccess.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                    }
                    commandMessage = try await Task.detached { try invocation.readMessageFile(cancellation: cancellation) }.value
                    try cancellation.check()
                } else { commandMessage = nil }
                defer { withExtendedLifetime(messageAccess) {} }
                let first = requestedLocation ?? selected?.paths.first ?? lease.url
                let submoduleLocation = invocation?.submoduleDiscoveryURL
                var location = submoduleLocation ?? first
                // Blame attributes the named Git blob. A symbolic-link leaf is
                // never a repository discovery directory or an access target.
                let blameSelection = action == .blame || invocation?.request.action == .blame
                var directory: ObjCBool = false
                let literalSymlink = (try? FileManager.default.attributesOfItem(atPath:location.path))?[.type] as? FileAttributeType == .typeSymbolicLink
                if blameSelection || literalSymlink || !FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) || !directory.boolValue {
                    location.deleteLastPathComponent()
                }
                let historicalSelection = blameSelection || (invocation.map { [.cat, .showCompare].contains($0.request.action) } ?? false)
                if historicalSelection {
                    while location.path != "/" {
                        var existingDirectory: ObjCBool = false
                        if FileManager.default.fileExists(atPath: location.path, isDirectory: &existingDirectory), existingDirectory.boolValue { break }
                        let parent = location.deletingLastPathComponent()
                        guard lease.contains(parent) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(parent.path) }
                        location = parent
                    }
                }
                diagnosticLocation = location
                let prepared=try await prepareRepositoryMetadataAccess(at:location,primary:lease,cancellation:cancellation)
                try cancellation.check();guard adoption==adoptionGeneration else { return }
                var sessionAccess=lease.retainingRelatedScopes(prepared.scopes)
                diagnosticAccess = sessionAccess
                var discoveredPermissionFolders=prepared.newFolders
                let candidate = try makeRepository(location)
                var serviceSelectionSnapshot:FinderSnapshot?
                if serviceCommand?.action == .logSubmodule {
                    let childRoot=try await candidate.discoverRoot(cancellation:cancellation)
                    let child=try makeRepository(childRoot)
                    let metadata=try await child.finderMetadata(cancellation:cancellation)
                    try cancellation.check()
                    serviceSelectionSnapshot=FinderSnapshot(roots:[childRoot.path],states:[childRoot.path:.normal],repositories:[childRoot.path:metadata])
                }
                let resolved: URL
                if submoduleLocation != nil {
                    resolved = try await candidate.discoverRoot(cancellation: cancellation)
                    guard FileManager.default.fileExists(atPath: resolved.appendingPathComponent(".gitmodules").path) else {
                        throw PrimaryCommandInvocation.Failure("Could not find a superproject with a .gitmodules file.")
                    }
                } else { resolved = try await candidate.discoverSelectionRoot(for: action ?? .status, selected: first,cancellation:cancellation) }
                if commandRootOnly {
                    let requested = first.standardizedFileURL.resolvingSymlinksInPath().path
                    guard GitReferenceName.equal(location.standardizedFileURL.resolvingSymlinksInPath().path, requested), GitReferenceName.equal(resolved.standardizedFileURL.resolvingSymlinksInPath().path, requested) else { throw PrimaryCommandInvocation.Failure("Batch transport commands require repository-root folders.") }
                }
                if let serviceCommand,[RepositoryAction.logSubmodule,.submoduleUpdate,.submoduleSync].contains(serviceCommand.action),!sessionAccess.contains(resolved) {
                    guard let handoffOwner else{throw RepositoryAccessFailure.repositoryRootOutsidePermission(resolved.path)}
                    let parentAccess=try await finderServiceRepositoryAccess(resolved,related:prepared.scopes,owner:handoffOwner,cancellation:cancellation)
                    sessionAccess=parentAccess.retainingRelatedScopes([lease]+prepared.scopes)
                    diagnosticAccess = sessionAccess
                    let parentMetadata=try await prepareRepositoryMetadataAccess(at:resolved,primary:sessionAccess,cancellation:cancellation)
                    sessionAccess=sessionAccess.retainingRelatedScopes(parentMetadata.scopes)
                    diagnosticAccess = sessionAccess
                    discoveredPermissionFolders += parentMetadata.newFolders
                    try cancellation.check();guard adoption==adoptionGeneration else{return}
                }
                if (requiresRepositoryScope && !sessionAccess.hasSecurityScope) || ((requiresRepositoryScope || submoduleLocation != nil) && !sessionAccess.contains(resolved)) {
                    throw RepositoryAccessFailure.repositoryRootOutsidePermission(resolved.path)
                }
                if let selected {
                    for item in selected.paths {
                        let literalSymlink = (try? FileManager.default.attributesOfItem(atPath:item.path))?[.type] as? FileAttributeType == .typeSymbolicLink
                        let permissionTarget = blameSelection || literalSymlink ? item.standardizedFileURL.deletingLastPathComponent() : item
                        guard sessionAccess.contains(permissionTarget), item.path == resolved.path || item.path.hasPrefix(resolved.path + "/") else {
                            throw FinderSelectionFailure.multipleRepositories
                        }
                        if submoduleLocation != nil || historicalSelection { continue }
                        var location = item
                        var directory: ObjCBool = false
                        if (try? FileManager.default.attributesOfItem(atPath:location.path))?[.type] as? FileAttributeType == .typeSymbolicLink || !FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) || !directory.boolValue { location.deleteLastPathComponent() }
                        let itemRoot = try await makeRepository(location).discoverSelectionRoot(for: action ?? .status, selected: item,cancellation:cancellation)
                        guard GitReferenceName.equal(itemRoot.standardizedFileURL.path,resolved.standardizedFileURL.path) else { throw FinderSelectionFailure.multipleRepositories }
                    }
                }
                try cancellation.check();guard adoption == adoptionGeneration else { return }
                let preparedRepository = try makeRepository(resolved)
                // Validate a requested historical selection before publishing
                // its repository to Settings. A failed/delayed lookup must not
                // create a transient editable context that rollback discards.
                if invocation?.request.action == .log, let revision = invocation?.selectedRevision {
                    commandSelectedRevision = try await preparedRepository.rebaseCommit(revision, cancellation: cancellation).hash
                    try cancellation.check(); guard adoption == adoptionGeneration else { return }
                }
                // Discovery can await permission/helper work while Settings
                // acquires drafts. Decide against the resolved repository at
                // adoption, not the clicked folder (which may be a child or an
                // alias of the existing root). Same-root reloads retain pages.
                if root.map({ !GitReferenceName.equal($0.path, resolved.path) }) ?? true {
                    guard canChangeSettingsContext() else { throw RepositorySettingsContextRefusal() }
                }
                repository = preparedRepository; activeAccess = sessionAccess; root = resolved
                restoreCloneKeyAccess(root: resolved)
                selection = []; entries = []; branch = ""; mergeActive = false
                section = .status
                output = "Repository: \(resolved.path)"
                try await reload(cancellation:cancellation)
                try cancellation.check();guard adoption == adoptionGeneration else { return }
                if bare { section = .log }
                if let selected { selection = selected.selectedStatusPaths(root: resolved, entries: entries) }
                if let serviceCommand,serviceCommand.requiresSourceEligibility,let selected {
                    // reload collected this root's actual status and operation
                    // metadata; no Finder cache or prior workspace decides an
                    // unmonitored repository's Services eligibility.
                    let live=FinderSnapshot(roots:[resolved.path],states:cacheStates,repositories:cacheRepositories,overlayEntries:cacheOverlayEntries,indexFlags:cacheIndexFlags,overlayPolicies:cacheOverlayPolicies)
                    guard serviceCommand.isEligible(paths:selected.paths,snapshot:serviceSelectionSnapshot ?? live) else {
                        throw FinderServiceCommand.Failure("\(serviceCommand.action.title) is not available for this selection and the repository's current state.")
                    }
                }
                rememberAccess(sessionAccess, repositoryRoot: resolved)
                if let store=accessStore,let saved=store.repositories.first(where:{$0.lastKnownPath==resolved.standardizedFileURL.resolvingSymlinksInPath().path}) {
                    do { for folder in discoveredPermissionFolders { try store.addPermission(saved.id,url:folder) };recentRepositories=store.repositories }
                    catch { self.error="The repository is open, but additional folder access could not be saved: "+error.localizedDescription }
                }
                holdsBusy = false; busy = false
                if let invocation {
                    activateCommandLine(invocation, message: commandMessage, selectedRevision: commandSelectedRevision, repository: repository!, access: sessionAccess, outputAccess: outputAccess)
                } else if let action {
                    let paths = actionPaths ?? selected?.relativePaths(root: resolved) ?? []
                    if serviceCommand != nil,let selected {
                        guard !paths.isEmpty,paths.count==selected.paths.count else {
                            throw FinderServiceCommand.Failure("Every selected item must belong to the captured repository.")
                        }
                    }
                    let serviceContext=serviceCommand.map{_ in FinderServiceDispatchIdentity(action:action,root:resolved,preferences:servicePreferences)}
                    FinderServicePresentationContext.$current.withValue(serviceContext) {
                        if action.isFileTransfer, let request = selected, let repository, let destination = request.paths.first {
                            if let finderTransferPresentation { finderTransferPresentation(request, repository, sessionAccess) }
                            else if action == .transferFiles { showTransferSelection(repository: repository, access: sessionAccess, sources: request.sources, destination: destination, owner: workspaceWindow, preferences: fileComparisonPreferences) }
                            else if action == .pasteCopy { showCopy(repository: repository, access: sessionAccess, sources: request.sources, paste: true, folder: destination) }
                            else { showMove(repository: repository, access: sessionAccess, paths: [], clipboard: request.sources, destination: destination) }
                        } else if action == .requestPull, let repository {
                            showRequestPull(repository: repository, access: sessionAccess, end: selected?.requestPullEnd, repositoryURL: selected?.requestPullURL)
                        } else { activate(action, paths: paths) }
                    }
                }
                opened = true; onOpened?()
            } catch {
                guard adoption == adoptionGeneration else { return }
                restoreState()
                let originalError = error
                var showedDiagnosis = false
                if !(originalError is RepositorySettingsContextRefusal), !(originalError is RepositoryAccessFailure),
                   !retired, !cancellation.isCancelled, diagnosticAccess.contains(diagnosticLocation),
                   !requiresRepositoryScope || diagnosticAccess.hasSecurityScope {
                    do {
                        let failedRepository = try makeRepository(diagnosticLocation)
                        let diagnostic: GitRepositoryDiagnosis
                        if let read = inaccessibleReadDiagnosis { diagnostic = try await read(failedRepository, cancellation) }
                        else { diagnostic = try await failedRepository.diagnoseRepositoryAccess(cancellation: cancellation) }
                        guard adoption == adoptionGeneration, !retired, !cancellation.isCancelled else { return }
                        if diagnostic.reason == .ownershipDenied || diagnostic.reason == .inaccessible {
                            presentInaccessibleRepository(repository: failedRepository, access: diagnosticAccess, diagnosis: diagnostic)
                            showedDiagnosis = true
                        }
                    } catch { /* Keep the original adoption error if diagnosis is unavailable. */ }
                }
                if !showedDiagnosis, !(originalError is RepositorySettingsContextRefusal), !cancellation.isCancelled { self.error=originalError.localizedDescription }
                if !retired,monitoringEnabled,let repository,let directories=try? await repository.finderWatchDirectories() { monitorFiles(directories) }
                holdsBusy = false; busy=false
            }
        }
    }
    func refresh(refreshStatus: Bool = true) async {
        guard !busy, !confirmingQuit else { return }
        busy = true; defer { busy = false }
        do { try await reload() } catch { self.error = error.localizedDescription }
        if refreshStatus, let root { refreshStatusWindows(root) }
    }
    private func reload(cancellation:OperationCancellation? = nil) async throws {
        guard !retired,let repository, let root else { return }
        let token=cancellation ?? OperationCancellation(),readID=UUID()
        finderPublicationReads[readID]=token
        defer { finderPublicationReads.removeValue(forKey:readID) }
        let store=snapshotStore
        let policy=try finderStatusPolicyProvider?()
        var ticket:FinderPublicationTicket?,publicationError:String?,persistenceWarning:String?
        if snapshotWriter==nil,let store {
            do {
                let session=try publicationSession(store,cancellation:token)
                persistenceWarning=session.persistenceFailure
                ticket=try await Task.detached { try store.begin(root:root,session:session,cancellation:token,policy:policy) }.value
            }
            catch { publicationError=error.localizedDescription }
            persistenceWarning=ticket?.persistenceFailure ?? persistenceWarning
        }
        let collected=try await repository.collectFinderRepository(authorizedRoot:activeAccess?.url ?? root,cancellation:token,watchReady:{ [weak self] directories in if !token.isCancelled { await self?.monitorFiles(directories) } },policy:policy)
        try token.check()
        bare=collected.bare;entries=collected.entries;conflictRebase=collected.conflictIsRebase;submodules=collected.submodules
        selection = (pendingWorkspaceSelection ?? selection).intersection(visibleEntries.map(\.path));pendingWorkspaceSelection=nil
        branch=collected.branch;hasGitSVN=collected.metadata.hasGitSVN;mergeActive=collected.metadata.mergeActive
        var cached=FinderSnapshot(roots:monitoredRoots,states:cacheStates,repositories:cacheRepositories,overlayEntries:cacheOverlayEntries,indexFlags:cacheIndexFlags,overlayPolicies:cacheOverlayPolicies)
        cached.replaceSubtree(root:root,snapshots:collected.snapshots)
        monitoredRoots = cached.roots; cacheStates = cached.states; cacheRepositories = cached.repositories
        cacheOverlayEntries = cached.overlayEntries
        cacheIndexFlags = cached.indexFlags
        cacheOverlayPolicies = cached.overlayPolicies
        do {
            if let publicationError { finderStatus="Finder cache unavailable: "+publicationError;return }
            let written:Bool
            if let writer=snapshotWriter { written=try await Task.detached { try writer(cached) }.value }
            else if let store,let ticket {
                let update=try await Task.detached { try store.publish(ticket,snapshots:collected.snapshots,cancellation:token) }.value
                cached=update.snapshot
                persistenceWarning=update.persistenceFailure
                monitoredRoots=cached.roots;cacheStates=cached.states;cacheRepositories=cached.repositories
                cacheOverlayEntries=cached.overlayEntries;cacheIndexFlags=cached.indexFlags;cacheOverlayPolicies=cached.overlayPolicies
                guard update.published else { finderStatus="Finder cache update superseded";eventRefresh?.invalidate();return }
                written=true
            } else { written=false }
            finderStatus = written ? (collected.failures.isEmpty ? "Finder cache updated" : "Finder cache updated; \(collected.failures.count) submodule scan(s) failed: " + collected.failures.sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value }.joined(separator: "; ")) : "Finder cache unavailable: App Group access required"
            if written { if let persistenceWarning { finderStatus += "; saved cache unavailable: "+persistenceWarning };notifyFinder() }
        } catch { finderStatus = "Finder cache unavailable: " + error.localizedDescription }
    }
    func perform(_ operation: @escaping (GitRepository) async throws -> String) {
        guard let repository, !busy, !confirmingQuit else { return }
        busy = true
        let access = activeAccess
        let finderOwner=UUID();FinderCommandStatusActivity.update(finderOwner,active:true)
        Task {
            defer { FinderCommandStatusActivity.update(finderOwner,active:false);busy = false; withExtendedLifetime(access) {} }
            do { output = try await operation(repository);FinderCommandStatusActivity.update(finderOwner,active:false);try await reload() }
            catch {FinderCommandStatusActivity.update(finderOwner,active:false);self.error = error.localizedDescription;try? await reload() }
            if let root { refreshStatusWindows(root) }
        }
    }
    func stage(paths requested:[String]? = nil) { let paths = requested ?? selectedPaths; guard !paths.isEmpty else {return}; perform { try await $0.stage(paths); return "Staged \(paths.count) file(s)." } }
    func unstage(paths requested:[String]? = nil) { let paths = requested ?? selectedPaths; guard !paths.isEmpty else {return}; perform { try await $0.unstage(paths); return "Unstaged \(paths.count) file(s)." } }
    func showDiff(paths requested: [String]? = nil) {
        let paths = requested ?? selectedPaths, staged = stagedDiff
        if paths.count == 1, submodules.contains(paths[0]), let repository {
            showSubmoduleDiff(repository: repository, access: activeAccess, path: paths[0]); return
        }
        perform { repo in
            let text = try await repo.diff(paths: paths, staged: staged)
            return text.isEmpty ? "No diff in this view. Untracked files must be staged before Git can show their diff." : text
        }
    }
    func didMoveWorkspacePath(_ source:String,to destination:String) {
        let mapped = GitPathSet((pendingWorkspaceSelection ?? selection).map {FileTransferPaths.remapping($0,source:source,destination:destination)})
        pendingWorkspaceSelection=mapped;selection=mapped
    }
    var workspaceClipboard:NSPasteboard = .general
    var revealWorkspaceFiles:([URL])->Void = {NSWorkspace.shared.activateFileViewerSelecting($0)}
    func workspaceURLs(_ paths:[String]) -> [URL] {
        guard let root else{return []};return paths.map {FileTransferPaths.fileURL(root.path + "/" + $0)}
    }
    func copyWorkspaceFiles(_ paths:[String]) { FileTransferClipboard.copy(workspaceURLs(paths),pasteboard:workspaceClipboard) }
    func copyWorkspacePaths(_ paths:[String],full:Bool = false,names:Bool = false) {
        guard !paths.isEmpty else{return}
        let values = full ? workspaceURLs(paths).map(\.path) : names ? paths.map {$0.split(separator:"/").last.map(String.init) ?? $0} : paths
        workspaceClipboard.clearContents();workspaceClipboard.setString(values.joined(separator:"\n"),forType:.string)
    }
    func copyWorkspaceItems(_ paths:[String]) {guard let repository else{return};showCopy(repository:repository,access:activeAccess,sources:workspaceURLs(paths))}
    func showCommit(_ hash: String) { perform { try await $0.run(["show", "--no-ext-diff", "--no-color", hash, "--"]).text } }
    func commit() {
        let text = message
        perform { repo in let result = try await repo.commit(message: text); await MainActor.run { self.message = "" }; return result }
    }
    func activate(_ action: RepositoryAction, paths: [String] = []) {
        guard !confirmingQuit else { return }
        guard !bare || !action.requiresWorkingTree else { error = "\(action.title) requires a working tree. This repository is bare."; return }
        switch action {
        case .inaccessible:
            guard let root else { return }; openInaccessibleRepository(root, invocation: nil, completion: nil)
        case .cat, .showCompare: error = "Use the command-line revision and destination options for this operation."
        case .commitIsOnRefs:
            if let repository { showCommandContainingReferences(repository: repository, access: activeAccess, revision: "") }
        case .svnDCommit, .svnRebase, .svnFetch, .svnIgnore: showSVN(action.svnOperation!)
        case .reviewPatch:
            showReviewPatch(files: (paths.isEmpty ? selectedPaths : paths).map { repository?.root.appendingPathComponent($0) }.compactMap { $0 })
        case .daemon: showDaemon()
        case .lfs: error = "Choose an operation from the Git LFS submenu."
        case .lfsLocks: showLFSLocks()
        case .lfsLock, .lfsUnlock:
            guard let repository else { return }
            showFinderLFSOperation(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths, locked: action == .lfsLock)
        case .sendMail:
            guard let root else { return }
            showFinderSendMail(files: (paths.isEmpty ? selectedPaths : paths).map { root.appendingPathComponent($0) })
        case .properties:
            guard let repository else { return }; showGitProperties(repository:repository,access:activeAccess,paths:paths.isEmpty ? selectedPaths : paths)
        case .dropMove, .dropCopyAdd: break // Command sources/target are carried by PrimaryCommandInvocation.
        case .updateCheck: onUpdateCheck(true, false)
        case .autotextTest: onAutotextTest()
        case .introduction: onIntroduction()
        case .firstStartWizard: onFirstStart(0)
        case .settings: onSettings(false)
        case .help: onHelp()
        case .about: onAbout()
        case .synchronize: showSynchronization()
        case .blame:
            guard let repository else { return }
            let selected = paths.isEmpty ? selectedPaths : paths
            guard selected.count == 1, selected[0] != "." else { error = "Select one versioned file to blame."; return }
            showBlame(repository: repository, access: activeAccess, path: selected[0], revision: "HEAD")
        case .previousDiff:
            guard let repository else { return }
            let selected = paths.isEmpty ? selectedPaths : paths
            guard selected.count == 1 else { error = FinderCommandFailure.selection.localizedDescription; return }
            showPreviousDiff(repository: repository, access: activeAccess, path: selected[0])
        case .logSubmodule:
            guard let repository else { return }
            guard paths.count == 1, paths[0] != "." else { error = FinderCommandFailure.submodule.localizedDescription; return }
            showLog(repository: repository, access: activeAccess, paths: paths)
        case .diffLater:
            let selected = paths.isEmpty ? selectedPaths : paths
            if selected.count == 1, let root { handleComparisonMark(file: FileTransferPaths.fileURL(root.path + "/" + selected[0])) }
            else {
                let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
                panel.prompt = workingComparisonMark == nil ? "Mark for comparison" : "Compare"
                if panel.runModal() == .OK, let file = panel.url { handleComparisonMark(file: file, permission: RepositoryAccessLease(url: file)) }
            }
        case .clearComparisonMark: clearComparisonMark()
        case .registerRepository:
            if let root {_ = handleFinderService(FinderRequest(action:.registerRepository,paths:[root]))}
        case .clone: showClone()
        case .initialize: showCreateRepository()
        case .rename:
            guard let repository else { return }
            let selected = paths.isEmpty ? selectedPaths : paths
            guard selected.count == 1, selected[0] != "." else { error = RenameFailure.source.localizedDescription; return }
            showRename(repository: repository, access: activeAccess, source: selected[0])
        case .transferFiles:
            guard let root else { return }
            let urls = (paths.isEmpty ? selectedPaths : paths).map { root.appendingPathComponent($0) }
            let request = FinderRequest(action: .transferFiles, paths: urls)
            guard request.url != nil else { error = "Select files or folders to transfer."; return }
            prepareFinderSourceTransfer(request)
        case .pasteCopy, .pasteMove:
            showFileTransfer(copy: action == .pasteCopy); return
        case .move:
            guard let repository else { return }
            let selected = paths.isEmpty ? selectedPaths : paths
            guard !selected.isEmpty, !selected.contains(".") else { error = FileMoveFailure.selection.localizedDescription; return }
            showMove(repository: repository, access: activeAccess, paths: selected)
        case .editConflict:
            guard let repository else { return }
            let selected = paths.isEmpty ? selectedPaths : paths
            guard let first = selected.first, first != "." else { error = "Select a conflict to edit."; return }
            showConflictEditor(repository: repository, access: activeAccess, path: first)
        case .resolve, .resolveCurrent, .resolveMine, .resolveTheirs:
            guard let repository else { return }
            showResolve(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths, quick: action.resolveChoice)
        case .ignore, .ignoreMask, .ignoreDelete, .ignoreDeleteMask:
            guard let repository else { return }
            showIgnore(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths, action: action)
        case .remove, .removeKeep:
            guard let repository else { return }
            showRemove(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths, keepLocal: action == .removeKeep)
        case .submoduleSync:
            guard let repository else { return }
            showSubmoduleSync(repository: repository, access: activeAccess, scope: paths)
        case .submoduleAdd:
            guard let repository else { return }
            showSubmoduleAdd(repository: repository, access: activeAccess, path: paths.first ?? "")
        case .submoduleUpdate:
            guard let repository else { return }
            showSubmoduleUpdate(repository: repository, access: activeAccess, scope: paths.isEmpty ? selectedPaths : paths)
        case .add:
            guard let repository else { return }
            showAdd(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths)
        case .clean:
            guard !busy, let repository else { return }
            showClean(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths)
        case .revert:
            guard let repository else { return }
            showRevert(repository: repository, access: activeAccess, paths: paths.isEmpty ? selectedPaths : paths)
        case .status:
            guard let repository else { return }
            showStatus(repository: repository, access: activeAccess, paths: paths)
        case .commit:
            guard let repository else { return }
            showCommitDialog(repository: repository, access: activeAccess, paths: paths)
        case .referenceBrowser:
            guard let repository else { return }
            showReferenceBrowser(repository: repository, access: activeAccess)
        case .repositoryBrowser:
            guard let repository else { return }
            showRepositoryBrowser(repository: repository, access: activeAccess)
        case .worktreeList:
            guard let repository else { return }
            showWorktreeList(repository: repository, access: activeAccess)
        case .worktreeCreate:
            guard let repository else { return }
            showWorktreeCreate(repository: repository, access: activeAccess)
        case .bisect, .bisectStart, .bisectGood, .bisectBad, .bisectSkip, .bisectReset:
            guard let repository else { return }
            showBisect(repository: repository, access: activeAccess, operation: action.bisectOperation, requireStart: action == .bisectStart)
        case .export:
            guard let repository else { return }
            showExport(repository: repository, access: activeAccess, revision: "HEAD", paths: paths)
        case .requestPull:
            guard let repository else { return }
            showRequestPull(repository: repository, access: activeAccess)
        case .importPatch:
            guard let repository else { return }
            showImportPatch(repository: repository, access: activeAccess, paths: paths)
        case .formatPatch:
            guard let repository else { return }
            showFormatPatch(repository: repository, access: activeAccess)
        case .log:
            guard let repository else { return }
            showLog(repository: repository, access: activeAccess, paths: paths)
        case .revisionGraph:
            guard let repository else { return }
            showRevisionGraph(repository: repository, access: activeAccess)

        case .mergeAbort:
            guard let repository else { return }
            showMergeAbort(repository: repository, access: activeAccess)
        case .merge:
            guard let repository else { return }
            showMerge(repository: repository, access: activeAccess)
        case .rebase:
            guard let repository else { return }
            showRebase(repository: repository, access: activeAccess)
        case .pull:
            guard let repository else { return }
            showFetch(repository: repository, access: activeAccess, isPull: true)
        case .fetch:
            guard let repository else { return }
            showFetch(repository: repository, access: activeAccess)
        case .push:
            guard let repository else { return }
            showPush(repository: repository, access: activeAccess)
        case .branch, .tag:
            guard let repository else { return }
            showReference(repository: repository, access: activeAccess, isTag: action == .tag)
        case .reset:
            guard let repository else { return }
            showReset(repository: repository, access: activeAccess)
        case .switchBranch:
            guard let repository else { return }
            showSwitch(repository: repository, access: activeAccess)
        case .diff:
            let selected = paths.isEmpty ? selectedPaths : paths
            guard let repository else { return }
            if selected.isEmpty || selected.contains(where: { path in
                if submodules.contains(path) { return false }
                var directory: ObjCBool = false
                return path == "." || FileManager.default.fileExists(atPath: repository.root.appendingPathComponent(path).path, isDirectory: &directory) && directory.boolValue
            }) { showStatus(repository: repository, access: activeAccess, paths: selected) }
            else { showWorkingFiles(repository: repository, access: activeAccess, paths: selected) }
        case .stashList, .reflog:
            guard let repository else { return }
            showReferenceLog(repository: repository, access: activeAccess, reference: action == .stashList ? "refs/stash" : "HEAD")
        case .stashApply, .stashPop:
            guard let repository else { return }
            showStashRestore(repository: repository, access: activeAccess, pop: action == .stashPop)
        case .stash:
            guard let repository else { return }
            showStash(repository: repository, access: activeAccess)
        }
    }
    private func restoreCloneKeyAccess(root: URL) {
        guard cloneKeyAccess[root.path] == nil, let data = UserDefaults.standard.data(forKey: "Clone.KeyBookmark." + root.path) else { return }
        do {
            let provider = SystemRepositoryBookmarkProvider()
            let resolved = try provider.resolve(data)
            let lease = RepositoryAccessLease(url: resolved.url)
            if GitRuntime.isAppStoreBuild && !lease.hasSecurityScope { throw RepositoryAccessFailure.securityScopeUnavailable }
            cloneKeyAccess[root.path] = lease
            if resolved.stale { UserDefaults.standard.set(try provider.create(for: resolved.url), forKey: "Clone.KeyBookmark." + root.path) }
        } catch { self.error = "The clone’s SSH-key permission could not be renewed.\n" + error.localizedDescription }
    }
    var cloneWindowFactory: ((URL?, RepositoryAccessLease?) -> CloneWindowController)?
    var creationClipboardText:()->String? = {NSPasteboard.general.string(forType:.string)}
    private func showClone(directory: URL? = nil, source: String? = nil, exactPath: Bool = false, directoryAccess:RepositoryAccessLease? = nil) {
        guard !retired, !confirmingQuit else { return }
        let id = UUID(), controller = cloneWindowFactory?(directory ?? root, directoryAccess ?? activeAccess) ?? CloneWindowController(directory: directory ?? root, access: directoryAccess ?? activeAccess,preferences:fileComparisonPreferences,clipboardText:source == nil ? creationClipboardText():nil)
        controller.onClosed = { [weak self, weak controller] in if self?.cloneWindows[id] === controller { self?.cloneWindows.removeValue(forKey: id) } }
        configureCloneInteractions(controller)
        cloneWindows[id] = controller
        controller.model.configureLaunch(source: source, exactPath: exactPath)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func configureCloneInteractions(_ controller: CloneWindowController) {
        let preferences = controller.model.pathCompletionPreferences
        controller.model.onNotificationLog={ [weak self] repository,access,paths,old,new in
            guard let self,!self.retired,!self.confirmingQuit else{return}
            self.showLog(repository:repository,access:access,paths:paths,endRevision:old == nil ? new:nil,revisionRange:old.map{HistoryRevisionRange(from:$0,to:new ?? "HEAD")},preferences:preferences)
        }
        controller.model.onLog = { [weak self, weak model = controller.model] repository, access in
            guard let self, !self.retired, !self.confirmingQuit, let model else { return }
            self.showLog(repository: repository, access: access, paths: [], preferences: preferences, presentation: model.handoffPresentation)
        }
        let handoffOwner = RepositoryWindowOwner(window: workspaceWindow)
        controller.model.onCloned = { [weak self,weak model=controller.model] repo, access, keyAccess, _, result in
            guard let self, !self.retired else { return }
            if let keyAccess {
                self.cloneKeyAccess[repo.root.path] = keyAccess
                do { UserDefaults.standard.set(try SystemRepositoryBookmarkProvider().create(for: keyAccess.url), forKey: "Clone.KeyBookmark." + repo.root.path) }
                catch { self.error = "The clone completed, but its SSH-key permission could not be saved.\n" + error.localizedDescription }
            }
            let generation=self.adoptionGeneration
            self.registerCompletedClone(repo,access:access,model:model) { [weak self] in
                guard let self,!handoffOwner.cancellation.isCancelled,self.adoptionGeneration==generation else {return}
                self.adoptRepository(repo,access:access,output:result,owner:handoffOwner)
            }
        }
    }
    var onFinderRegistrationSaved:()->Void = {}
    func refreshRegisteredRepositories() {guard !retired else{return};recentRepositories=accessStore?.repositories ?? []}
    /// Persist only the captured repository and metadata grants. Neither route
    /// grants authority from a Finder URL nor changes unrelated watch records.
    private func saveFinderRegistration(_ repository:GitRepository,access:RepositoryAccessLease,additionalFolders:[URL],cancellation:OperationCancellation) async throws {
        try cancellation.check();guard !retired else {throw OperationCancellationFailure.cancelled}
        configureActionRouting()
        if finderWatches == nil && actionRoutingAccessEnabled {finderWatches=try FinderWatchManager.production(startup:.deferred)}
        guard let store=accessStore,let watches=finderWatches else {throw RepositoryAccessFailure.securityScopeUnavailable}
        _=try await watches.register(root:repository.root,access:access,additionalFolders:additionalFolders,cancellation:cancellation,awaitInitialPublication:true)
        // A completed watch publication remains completed if Cancel arrives as
        // its receipt returns. Finish its paired recent record without recasting
        // the successful persistence as an unchanged/cancelled operation.
        let saved=try store.remember(repository.root)
        for folder in additionalFolders where !RepositoryAccessLease.pathIsContained(folder,by:repository.root) {try store.addPermission(saved.id,url:folder)}
        recentRepositories=store.repositories;onFinderRegistrationSaved()
    }
    private func registerFinderRepository(_ candidate:URL,access:RepositoryAccessLease,owner:RepositoryWindowOwner,generation:Int,completed:@escaping ()->Void) {
        let token=owner.cancellation
        finderServiceWorkers += 1;busy=true
        Task { [self,access,owner] in
            defer {finderServiceWorkers -= 1;if finderServiceOwner === owner {busy=false};completed();withExtendedLifetime(access) {}}
            do {
                try token.check();guard !retired,!confirmingQuit,generation==adoptionGeneration else {throw OperationCancellationFailure.cancelled}
                var directory:ObjCBool=false
                guard FileManager.default.fileExists(atPath:candidate.path,isDirectory:&directory),directory.boolValue else {throw PrimaryCommandInvocation.Failure("Select a repository folder to add to TurtleGit.")}
                let prepared=try await prepareRepositoryMetadataAccess(at:candidate,primary:access,cancellation:token)
                let accepted=access.retainingRelatedScopes(prepared.scopes)
                let repository=try makeRepository(candidate),root=try await repository.discoverRoot(cancellation:token)
                try token.check();guard !retired,!confirmingQuit,generation==adoptionGeneration else {throw OperationCancellationFailure.cancelled}
                guard accepted.contains(root) else {throw RepositoryAccessFailure.repositoryRootOutsidePermission(root.path)}
                let captured=try makeRepository(root)
                let folders=prepared.newFolders+accepted.permittedFolders(requireSecurityScope:requiresRepositoryScope).filter { !RepositoryAccessLease.pathIsContained(root,by:$0) }
                try await saveFinderRegistration(captured,access:accepted,additionalFolders:folders,cancellation:token)
                guard !retired,!token.isCancelled,generation==adoptionGeneration else {return}
                output="Added repository to TurtleGit: "+root.path
            } catch {if !retired,!token.isCancelled {self.error="Could not add this repository to TurtleGit.\n"+error.localizedDescription}}
        }
    }
    private func registerCompletedClone(_ repository:GitRepository,access:RepositoryAccessLease,model:CloneWindowModel?,completed:@escaping ()->Void) {
        let id=UUID(),token=OperationCancellation();finderRegistrations[id]=token
        Task { [self,access,repository,weak model] in
            defer {finderRegistrations.removeValue(forKey:id);if !retired {completed()};withExtendedLifetime(access) {}}
            do {
                try token.check();guard !retired else {throw OperationCancellationFailure.cancelled}
                // Clone completion already owns its destination/parent grant.
                // Validate the captured scopes without launching a second
                // permission chooser after a successful transport or during Quit.
                let allowed=access.permittedFolders(requireSecurityScope:requiresRepositoryScope)
                let missing=try await Task.detached {try RepositoryMetadataAccess.next(at:repository.root,authorizedFolders:allowed,cancellation:token)}.value
                if let missing {throw RepositoryAccessFailure.repositoryRootOutsidePermission(missing.folder.path)}
                let folders=allowed.filter { !RepositoryAccessLease.pathIsContained(repository.root,by:$0) }
                try await saveFinderRegistration(repository,access:access,additionalFolders:folders,cancellation:token)
            } catch {
                guard !retired else {return}
                let warning="The clone completed, but its Finder registration could not be saved. Open Icon Overlays settings and add this repository.\n"+error.localizedDescription
                self.error=warning;model?.reportFinderRegistrationFailure(warning)
            }
        }
    }
    private func adoptRepository(_ repo: GitRepository, access: RepositoryAccessLease, output: String, owner: RepositoryWindowOwner) {
        guard !retired, !owner.cancellation.isCancelled else { return }
        let handoff = CompletedRepositoryHandoff(generation: adoptionGeneration, root: repo.root, access: access, owner: owner, output: output)
        completedRepositoryHandoff = handoff
        let id = handoff.id
        owner.onCancelled = { [weak self] in
            if self?.completedRepositoryHandoff?.id == id { self?.completedRepositoryHandoff = nil }
        }
        // Keep the current operation's generation and busy ownership intact.
        // Stop a transport batch before it can adopt another captured root.
        if commandRepositoryBatchCancellation != nil {
            cancelCommandTransportBatch()
            adoptionCancellation?.cancel()
            repositoryPermissionPrompt?.cancel()
        }
        scheduleCompletedRepositoryHandoff()
    }
    private func scheduleCompletedRepositoryHandoff() {
        guard let pending = completedRepositoryHandoff, !busy, !confirmingQuit, !retired else { return }
        let id = pending.id
        // Defer until the releasing operation has completed its callbacks and
        // cleanup. An accepted Open/Close in the meantime supersedes this result.
        Task { @MainActor [weak self] in
            guard let self, let handoff = self.completedRepositoryHandoff, handoff.id == id else { return }
            guard !self.busy, !self.confirmingQuit else { return }
            self.completedRepositoryHandoff = nil
            guard !self.retired, handoff.generation == self.adoptionGeneration, !handoff.owner.cancellation.isCancelled else { return }
            self.openSession(handoff.access, selected: FinderRequest(action: .status, paths: [handoff.root]), handoffOwner: handoff.owner, onOpened: { [weak self] in self?.output = handoff.output })
        }
    }
    private func showCreateRepository(folder: URL? = nil, commandLaunch: Bool = false, cancellation: OperationCancellation? = nil) {
        guard !retired, !confirmingQuit, cancellation?.isCancelled != true else { return }
        guard creationFolderChoice == nil else { error = "Finish choosing a repository folder before opening another Create Repository dialog."; return }
        let owner = RepositoryWindowOwner(window: workspaceWindow)
        do {
            let directory = try folder.map { try CloneOptions.workingDirectory(for: $0) }
            if let folder, let directory {
                if let activeAccess, activeAccess.contains(folder), activeAccess.contains(directory), !requiresRepositoryScope || activeAccess.hasSecurityScope {
                    presentCreateRepository(folder: folder, lease: activeAccess, owner: owner); return
                }
                if commandLaunch, let permission = commandLineRepositoryPermission {
                    let lease = try permission([folder])
                    guard !retired, !owner.cancellation.isCancelled, cancellation?.isCancelled != true, let lease else { return }
                    guard lease.contains(folder), lease.contains(directory), !requiresRepositoryScope || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                    presentCreateRepository(folder: folder, lease: lease, owner: owner); return
                }
                if !requiresRepositoryScope {
                    presentCreateRepository(folder: folder, lease: RepositoryAccessLease(url: directory, provider: repositoryBookmarkProvider), owner: owner); return
                }
            }
            guard workspaceWindow?.attachedSheet == nil else { return }
            let choice = RepositoryCreationFolderChoice(window: workspaceWindow, owner: owner)
            let panel = choice.panel
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.showsHiddenFiles = true
            panel.prompt = folder == nil ? "Create repository here" : "Authorize repository folder"
            panel.message = folder.map { "Choose this folder or a containing parent to allow TurtleGit to create the repository: " + $0.path } ?? "Choose the folder that will contain the new repository."
            panel.directoryURL = directory ?? root?.deletingLastPathComponent()
            creationFolderChoice = choice
            choice.onFinished = { [weak self, weak choice] selected in
                guard let self, let choice, self.creationFolderChoice === choice else { return }
                self.creationFolderChoice = nil
                guard !self.retired, !self.confirmingQuit, !owner.cancellation.isCancelled, cancellation?.isCancelled != true, let selected else { return }
                let target = folder ?? selected
                do {
                    let lease = RepositoryAccessLease(url: selected, provider: self.repositoryBookmarkProvider)
                    let working = try CloneOptions.workingDirectory(for: target)
                    guard lease.contains(target), lease.contains(working), !self.requiresRepositoryScope || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                    self.presentCreateRepository(folder: target, lease: lease, owner: owner)
                } catch { self.error = error.localizedDescription }
            }
            choice.begin(present: presentCreationFolderPanel, selected: selectedCreationFolderURL)
        } catch { self.error = error.localizedDescription }
    }
    private func presentCreateRepository(folder: URL, lease: RepositoryAccessLease, owner: RepositoryWindowOwner) {
        guard !retired, !confirmingQuit, !owner.cancellation.isCancelled, lease.contains(folder), !requiresRepositoryScope || lease.hasSecurityScope else { return }
        let key = GitPathRowIdentity.encode(folder.path)
        if createWindows[key]?.model.retired == true { error = "The previous Create Repository window is still closing. Wait for it to finish."; return }
        let controller = createWindows[key] ?? createWindowFactory?(folder, lease) ?? CreateRepositoryWindowController(folder: folder, access: lease, preferences: fileComparisonPreferences)
        let fresh = createWindows[key] == nil
        controller.onClosed = { [weak self, weak controller] in if self?.createWindows[key] === controller { self?.createWindows.removeValue(forKey: key) } }
        if fresh {
            configureCreateRepositoryInteractions(controller, owner: owner)
        }
        createWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        if fresh { controller.model.prepare() }
    }
    func configureCreateRepositoryInteractions(_ controller: CreateRepositoryWindowController) {
        configureCreateRepositoryInteractions(controller, owner: RepositoryWindowOwner(window: workspaceWindow))
    }
    private func configureCreateRepositoryInteractions(_ controller: CreateRepositoryWindowController, owner: RepositoryWindowOwner) {
        controller.model.onInitialized = { [weak self] repo, access, _, output in
            self?.adoptRepository(repo, access: access, output: output, owner: owner)
        }
    }
    private func showRename(repository: GitRepository, access: RepositoryAccessLease?, source: String) {
        guard !retired,!confirmingQuit else{return}
        let root = repository.root, key = GitPathRowIdentity.encode(root.path + "\0" + source)
        guard renameWindows[key]?.model.retired != true else {error="The previous Rename window is still closing. Wait for its operation to finish.";return}
        let controller = renameWindows[key] ?? RenameWindowController(repository: repository, access: access, source: source, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.renameWindows.removeValue(forKey: key) }
        controller.model.onRenamed = { [weak self] old, new, output in
            guard let self else { return }
            self.revertWindows[root.path]?.model.didRename(old,to:new); self.renameStatusPaths(root, from: old, to: new)
            self.commitWindows[root.path]?.model.didRename(old, to: new)
            if self.root == root {
                self.didMoveWorkspacePath(old,to:new)
                self.output = output.isEmpty ? "Renamed \(old) to \(new)." : output
            }
        }
        controller.model.onChanged = { [weak self] in
            self?.revertWindows[root.path]?.model.requestReload(); self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
            if self?.root == root { Task { await self?.refresh() } }
        }
        renameWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func showMove(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], clipboard: [URL]? = nil, destination: URL? = nil, renameFirst: Bool = false, stopOnError: Bool = true, automaticallyStart: Bool = false, preferences: UserDefaults? = nil) {
        let root = repository.root, key = GitPathRowIdentity.encode(root.path + "\0" + (clipboard == nil ? paths.joined(separator: "\0") : UUID().uuidString))
        let controller = moveWindows[key] ?? FileMoveWindowController(repository: repository, access: access, paths: paths, preferences: preferences ?? fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.moveWindows.removeValue(forKey: key) }
        controller.model.onMoved = { [weak self] old, new, text in
            guard let self else { return }; self.revertWindows[root.path]?.model.didRename(old,to:new); self.renameStatusPaths(root, from: old, to: new); self.commitWindows[root.path]?.model.didRename(old, to: new)
            if self.root == root { self.didMoveWorkspacePath(old,to:new); self.output = text.isEmpty ? "Moved \(old) to \(new)." : text }
        }
        controller.model.onChanged = { [weak self] in
            self?.revertWindows[root.path]?.model.requestReload(); self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
            if self?.root == root { Task { await self?.refresh() } }
        }
        moveWindows[key] = controller
        if let movePresentation { movePresentation(controller) } else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        if let clipboard { controller.model.renameFirst = renameFirst; controller.model.loadClipboard(clipboard, destination: destination, stopOnError: stopOnError, automaticallyStart: automaticallyStart) }
    }
    func showCopy(repository: GitRepository, access: RepositoryAccessLease?, sources: [URL], paste: Bool = false, folder: URL? = nil, automaticallyStart: Bool = false, preferences: UserDefaults? = nil) {
        let id = UUID(), root = repository.root
        let controller = FileCopyWindowController(repository: repository, access: access, sources: sources, folder: folder, paste: paste, sourceProvider: fileCopySourceProvider, preferences: preferences ?? fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.copyWindows.removeValue(forKey: id) }
        controller.model.onChanged = { [weak self] in
            self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload(); self?.refreshRepositoryLogs(root)
            if self?.root == root { Task { await self?.refresh() } }
        }
        copyWindows[id] = controller
        if let copyPresentation { copyPresentation(controller) } else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        if automaticallyStart { controller.model.run() }
    }
    private var dropTransfers: [UUID: FileDropTransferWindowController] = [:]
    var canReceiveTransferDrop: Bool { repository != nil && !bare && !busy && !confirmingQuit && workspaceWindow?.attachedSheet == nil }
    var configureDropTransfer: (FileDropTransferWindowController) -> Void = { _ in }
    @discardableResult func receiveTransferDrop(_ providers: [NSItemProvider], repository captured: GitRepository? = nil, access capturedAccess: RepositoryAccessLease? = nil, owner capturedOwner: NSWindow? = nil) -> Bool {
        guard !confirmingQuit, captured != nil || canReceiveTransferDrop, !providers.isEmpty, providers.count <= 256, providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }), let repository = captured ?? repository, let owner = capturedOwner ?? workspaceWindow, owner.attachedSheet == nil else { return false }
        let id = UUID(), access = captured == nil ? activeAccess : capturedAccess, controller = FileDropTransferWindowController(repository: repository, access: access, preferences: fileComparisonPreferences)
        controller.receiveAllowed = { [weak self] in self?.retired == false && self?.confirmingQuit == false }
        controller.onClosed = { [weak self] in self?.dropTransfers.removeValue(forKey: id) }
        let preferences = fileComparisonPreferences
        controller.onAccepted = { [weak self] choice, urls, folder in
            guard let self, !self.retired, !self.confirmingQuit else { return }
            if choice == .copyAdd { self.showCopy(repository: repository, access: access, sources: urls, folder: folder, preferences: preferences) }
            else { self.showMove(repository: repository, access: access, paths: [], clipboard: urls, destination: folder, renameFirst: choice == .moveRename, stopOnError: false, preferences: preferences) }
        }
        configureDropTransfer(controller); dropTransfers[id] = controller
        guard controller.present(owner: owner) else { controller.close(); dropTransfers.removeValue(forKey: id); return false }
        controller.model.load(providers); return true
    }
    /// Source URLs are captured before the destination panel; neither Finder's
    /// later selection nor the general clipboard participates in this workflow.
    func cancelFinderSourceTransfer() { sourceTransferOwner?.cancellation.cancel(); sourceTransferFolderChoice?.cancel() }
    func cancelFinderWorktreeCreation() {
        guard let owner=sourceWorktreeOwner else {return}
        owner.cancellation.cancel();sourceWorktreeFolderChoice?.cancel()
        repositoryPermissionPrompt?.cancel()
    }
    /// A Finder source request captures one repository before asking for its
    /// destination. It never adopts another repository into the workspace.
    private func prepareFinderWorktreeCreation(_ request: FinderRequest, completion: ((Bool)->Void)? = nil) {
        guard request.action == .worktreeCreate,request.paths.count == 1,request.sources.isEmpty,
              !retired,!confirmingQuit,!busy,sourceWorktreeOwner == nil,workspaceWindow?.attachedSheet == nil else {completion?(false);return}
        let source=request.paths[0],window=workspaceWindow,preferences=fileComparisonPreferences
        let owner=RepositoryWindowOwner(window:window)
        sourceWorktreeOwner=owner;busy=true;Self.activeCommandFileOperations += 1
        Task {
            var opened=false
            var retained:[RepositoryAccessLease]=[]
            defer {
                if sourceWorktreeOwner === owner {sourceWorktreeOwner=nil;sourceWorktreeFolderChoice=nil}
                busy=false;Self.activeCommandFileOperations -= 1
                withExtendedLifetime(retained) {};completion?(opened)
            }
            @MainActor func live() -> Bool {!retired && !confirmingQuit && sourceWorktreeOwner === owner && !owner.cancellation.isCancelled}
            @MainActor func choose(title:String,prompt:String,message:String,directory:URL?,create:Bool) async -> URL? {
                guard live(),window?.attachedSheet == nil else {return nil}
                return await withCheckedContinuation { continuation in
                    let choice=FinderTransferDestinationChoice(window:window,owner:owner)
                    choice.panel.title=title;choice.panel.prompt=prompt;choice.panel.message=message
                    choice.panel.canChooseFiles=false;choice.panel.canChooseDirectories=true;choice.panel.allowsMultipleSelection=false
                    choice.panel.canCreateDirectories=create;choice.panel.directoryURL=directory
                    if window == nil {
                        let appearance=preferences.string(forKey:"appearance") ?? "system"
                        choice.panel.appearance=appearance == "dark" ? NSAppearance(named:.darkAqua) : appearance == "light" ? NSAppearance(named:.aqua) : nil
                    }
                    sourceWorktreeFolderChoice=choice
                    choice.onFinished={continuation.resume(returning:$0)}
                    choice.begin(present:presentWorktreeFolderPanel,selected:selectedWorktreeFolderURL)
                }
            }
            do {
                guard live() else {return}
                var sourceLease:RepositoryAccessLease?
                if let activeAccess,activeAccess.contains(source),!requiresRepositoryScope || activeAccess.hasSecurityScope {sourceLease=activeAccess}
                if sourceLease == nil,let store=accessStore {
                    for saved in store.repositories {
                        if let lease=try? store.acquire(saved.id,requireSecurityScope:requiresRepositoryScope),lease.contains(source) {sourceLease=lease;break}
                    }
                }
                if sourceLease == nil,let provider=worktreeSourceAccessProvider {sourceLease=try provider([source])}
                if sourceLease == nil,!requiresRepositoryScope {sourceLease=RepositoryAccessLease(url:source,provider:repositoryBookmarkProvider)}
                if sourceLease == nil {
                    guard let folder=await choose(title:String(localized:"New Worktree"),prompt:String(localized:"Authorize repository"),message:String(localized:"Choose this repository or a containing folder to allow New Worktree: ")+source.path,directory:source,create:false),live() else {return}
                    sourceLease=RepositoryAccessLease(url:folder,provider:repositoryBookmarkProvider)
                }
                guard let primary=sourceLease,primary.contains(source),!requiresRepositoryScope || primary.hasSecurityScope else {throw RepositoryAccessFailure.securityScopeUnavailable}
                retained.append(primary)
                let metadata=try await prepareRepositoryMetadataAccess(at:source,primary:primary,cancellation:owner.cancellation,owner:window)
                retained += metadata.scopes
                guard live() else {return}
                let context=try makeRepository(source)
                let actual=try await context.validateFinderWorktreeSource(cancellation:owner.cancellation)
                guard live(),primary.contains(actual) else {return}
                let repository=try makeRepository(actual),access=primary.retainingRelatedScopes(metadata.scopes)
                if worktreeCreateWindows[actual.path] != nil || worktreeListWindows[actual.path]?.createWindow != nil {
                    opened=showWorktreeCreate(repository:repository,access:access,commandLaunch:true,preferences:preferences) != nil;return
                }
                guard let folder=await choose(title:String(localized:"New Worktree"),prompt:String(localized:"Choose destination"),message:String(localized:"Choose a destination folder outside a working tree. The repository name will be appended in New Worktree."),directory:source.deletingLastPathComponent(),create:true),live() else {return}
                let destination=RepositoryAccessLease(url:folder,provider:repositoryBookmarkProvider)
                retained.append(destination)
                guard destination.contains(folder),!requiresRepositoryScope || destination.hasSecurityScope else {throw RepositoryAccessFailure.securityScopeUnavailable}
                // The source may have changed while its native chooser was open.
                let latestMetadata=try await prepareRepositoryMetadataAccess(at:source,primary:access,cancellation:owner.cancellation,owner:window)
                retained += latestMetadata.scopes
                let rechecked=try await context.validateFinderWorktreeSource(cancellation:owner.cancellation)
                guard live(),GitReferenceName.equal(rechecked.resolvingSymlinksInPath().path,actual.resolvingSymlinksInPath().path) else {return}
                let proposed=try await repository.finderWorktreeDestination(parent:folder,cancellation:owner.cancellation)
                guard live(),destination.contains(proposed),window?.attachedSheet == nil else {return}
                let combined=access.retainingRelatedScopes(latestMetadata.scopes)
                opened=showWorktreeCreate(repository:repository,access:combined,directory:proposed,commandLaunch:true,preferences:preferences,destinationAccess:destination) != nil
            } catch {
                if live(),!(error is OperationCancellationFailure),!(error is GitCommandCancellationFailure) {self.error=error.localizedDescription}
            }
        }
    }
    private func prepareFinderSourceTransfer(_ request: FinderRequest, completion: ((Bool) -> Void)? = nil) {
        guard request.isTransferSourceSelection, !retired, !confirmingQuit, !busy,
              sourceTransferOwner == nil, workspaceWindow?.attachedSheet == nil else { completion?(false); return }
        let sources = request.paths, window = workspaceWindow, preferences = fileComparisonPreferences
        let owner = RepositoryWindowOwner(window: window)
        sourceTransferOwner = owner; busy = true
        Task {
            var transferred = false
            defer {
                if !transferred {
                    if sourceTransferOwner === owner { sourceTransferOwner = nil; sourceTransferFolderChoice = nil }
                    busy = false; completion?(false)
                }
            }
            guard !retired, !confirmingQuit, !owner.cancellation.isCancelled else { return }
            let folder = await withCheckedContinuation { continuation in
                let choice = FinderTransferDestinationChoice(window: window, owner: owner)
                choice.panel.title = "Transfer files"; choice.panel.prompt = "Choose destination"
                choice.panel.message = "Choose the destination working tree (repository root). You can choose a subfolder in the transfer dialog."
                choice.panel.canChooseFiles = false; choice.panel.canChooseDirectories = true
                choice.panel.canCreateDirectories = false; choice.panel.directoryURL = root
                if window == nil {
                    let appearance = preferences.string(forKey: "appearance") ?? "system"
                    choice.panel.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua) : appearance == "light" ? NSAppearance(named: .aqua) : nil
                }
                sourceTransferFolderChoice = choice
                choice.onFinished = { continuation.resume(returning: $0) }
                choice.begin(present: presentTransferDestinationPanel, selected: selectedTransferDestinationURL)
            }
            guard !retired, !confirmingQuit, !owner.cancellation.isCancelled, let folder else { return }
            let destination = FinderRequest(action: .transferFiles, paths: [folder], sources: sources)
            guard destination.isTransferDestinationReview, destination.url != nil, canChangeSettingsContext() else { return }
            var permission = RepositoryAccessLease(url: folder)
            if let activeAccess, activeAccess.contains(folder), !requiresRepositoryScope || activeAccess.hasSecurityScope { permission = activeAccess }
            else if let store = accessStore {
                for saved in store.repositories {
                    if let access = try? store.acquire(saved.id, requireSecurityScope: requiresRepositoryScope), access.contains(folder) { permission = access; break }
                }
            }
            busy = false; transferred = true
            // openSession performs normal root/metadata/grant checks. The source
            // files are separately authorized by the accepted copy/move workflow.
            openSession(permission, selected: destination, onFinished: { [weak self] opened in
                if self?.sourceTransferOwner === owner { self?.sourceTransferOwner = nil; self?.sourceTransferFolderChoice = nil }
                completion?(opened)
            }, handoffOwner: owner, onOpened: { [weak self] in
                guard let self, !self.retired, !self.confirmingQuit, !owner.cancellation.isCancelled,
                      let repository = self.repository, let access = self.activeAccess else { return }
                guard !self.bare else { self.error = "File transfers require a working tree."; return }
                self.showTransferSelection(repository: repository, access: access, sources: sources, destination: folder, owner: window, preferences: preferences, allowed: { !owner.cancellation.isCancelled })
            })
        }
    }
    private func showTransferSelection(repository: GitRepository, access: RepositoryAccessLease?, sources: [URL], destination: URL, owner: NSWindow?, preferences: UserDefaults, allowed: @escaping () -> Bool = { true }) {
        guard !retired, !confirmingQuit, !sources.isEmpty, sources.count <= 256, owner?.attachedSheet == nil, allowed() else { return }
        let id = UUID(), controller = FileDropTransferWindowController(repository: repository, access: access, preferences: preferences, destination: destination)
        controller.receiveAllowed = { [weak self] in self?.retired == false && self?.confirmingQuit == false && allowed() }
        controller.onClosed = { [weak self] in self?.dropTransfers.removeValue(forKey: id) }
        controller.onAccepted = { [weak self] choice, urls, folder in
            guard let self, !self.retired, !self.confirmingQuit, allowed() else { return }
            if choice == .copyAdd { self.showCopy(repository: repository, access: access, sources: urls, folder: folder, preferences: preferences) }
            else { self.showMove(repository: repository, access: access, paths: [], clipboard: urls, destination: folder, renameFirst: choice == .moveRename, stopOnError: false, preferences: preferences) }
        }
        configureDropTransfer(controller); dropTransfers[id] = controller
        guard controller.present(owner: owner) else { controller.close(); return }
        controller.model.loadSources(sources, destination: destination)
    }
    func showFileTransfer(copy: Bool, repository captured: GitRepository? = nil, access: RepositoryAccessLease? = nil, urls: [URL]? = nil) {
        let snapshot = urls ?? FileTransferClipboard.urls()
        if captured == nil {
            if let owner = (NSApp.keyWindow ?? NSApp.mainWindow)?.delegate as? CommitWindowController { guard owner.model.messageFocusAvailable, !owner.model.inputsBlocked else { return }; owner.model.onPasteFiles(copy, snapshot); return }
            if let owner = (NSApp.keyWindow ?? NSApp.mainWindow)?.delegate as? StatusWindowController { guard !owner.model.retired, !owner.model.busy, !owner.model.confirmingQuit else { return }; owner.model.onPasteFiles(copy, snapshot); return }
        }
        guard let repository = captured ?? repository else { return }
        let sources = snapshot, lease = captured == nil ? activeAccess : access
        if copy { showCopy(repository: repository, access: lease, sources: sources, paste: urls == nil || !(urls?.isEmpty ?? true)) }
        else if !sources.isEmpty { showMove(repository: repository, access: lease, paths: [], clipboard: sources) }
    }
    enum ConflictEditorRoute: String { case deleteModify, submodule, image, text }
    var conflictEditorPresentation: ((ConflictEditorRoute, GitRepository, String, ImageConflictDocument?) -> Void)?
    var readConflictEditorEntry: ((GitRepository, String, OperationCancellation) async throws -> ConflictEntry)?
    var openExternalConflict: ((GitRepository, RepositoryAccessLease?, String, Bool, NSWindow?, ConflictEntry, OperationCancellation, @escaping () -> Void, MergeToolPreferences) async throws -> Bool)?
    private var conflictEditorPreparations = GitPathMap<ConflictEditorLaunch>()
    @Published private(set) var conflictEditorPreparationCount = 0
    func cancelConflictEditorPreparations() { for request in conflictEditorPreparations.values { request.cancel() } }
    func cancelConflictEditorPreparation(repository: GitRepository, path: String) { conflictEditorPreparations[repository.root.path + "\0" + path]?.cancel() }
    private func validateConflictEditorEntry(_ entry: ConflictEntry, repository: GitRepository, token: OperationCancellation) async throws {
        try token.check()
        guard !retired, !confirmingQuit, try await repository.conflictEditorEntry(path: entry.path, cancellation: token) == entry else { throw ResolveFailure.stale }
        try token.check()
    }
    func showConflictEditor(repository: GitRepository, access: RepositoryAccessLease?, path: String, owner: NSWindow? = nil, preferences: UserDefaults? = nil, alternateTool: Bool? = nil, commandLaunch: Bool = false) {
        guard !retired, !confirmingQuit else { return }
        let key = repository.root.path + "\0" + path
        guard conflictEditorPreparations[key] == nil else { return }
        let alternate = alternateTool ?? ComparisonToolInvocation.capture
        let owner = owner ?? (finderServiceDispatch != nil ? workspaceWindow : commandLaunch ? nil : NSApp.keyWindow ?? workspaceWindow)
        let defaults = preferences ?? fileComparisonPreferences
        let tools = MergeToolPreferences.load(from: defaults), identities = ConflictIdentityOptions(defaults: defaults)
        let external = openExternalConflict, readEntry = readConflictEditorEntry
        let request = ConflictEditorLaunch(owner: owner, preferences: defaults, alternateTool: alternate)
        conflictEditorPreparations[key] = request; conflictEditorPreparationCount = conflictEditorPreparations.count
        request.showProgress(path: path)
        Task {
            defer {
                request.dismissProgress(); if conflictEditorPreparations[key] === request { conflictEditorPreparations.removeValue(forKey: key); conflictEditorPreparationCount = conflictEditorPreparations.count }
                withExtendedLifetime(access) {}
            }
            do {
                try await request.session.run(selectedCount: 0) { [self] token in
                    try token.check(); guard !retired, !confirmingQuit else { return }
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let entry: ConflictEntry
                    if let readEntry { entry = try await readEntry(repository, path, token) }
                    else { entry = try await repository.conflictEditorEntry(path: path, cancellation: token) }
                    guard GitReferenceName.equal(entry.path,path) else { throw ResolveFailure.stale }; try token.check()
                if entry.isDeleteModify {
                    try await validateConflictEditorEntry(entry, repository: repository, token: token)
                    request.dismissProgress(); if let conflictEditorPresentation { conflictEditorPresentation(.deleteModify, repository, path, nil) }
                    else { showDeleteConflict(repository: repository, access: access, path: path, preferences: defaults) }; return
                }
                if !entry.isSubmodule {
                    let opened: Bool
                    if let external { opened = try await external(repository, access, path, alternate, owner, entry, token, { request.dismissProgress() }, tools) }
                    else { opened = try await MergeToolApplication.open(repository: repository, access: access, path: path, alternate: alternate, owner: owner, cancellation: token, onPrepared: { request.dismissProgress() }, preferences: tools, expectedEntry: entry, identityOptions: identities) }
                    if opened {
                        try token.check(); guard !retired, !confirmingQuit else { return }
                        let root = repository.root
                        refreshAfterConflictChange(root)
                        if self.root == root { await refresh() }; return
                    }
                    let root = repository.root, key = root.path + "\0" + path
                    if let document = try await repository.imageConflictDocument(path: path, identityOptions: identities, cancellation: token) {
                        guard document.entry == entry else { throw ResolveFailure.stale }
                        try await validateConflictEditorEntry(entry, repository: repository, token: token)
                        request.dismissProgress()
                        if let conflictEditorPresentation { conflictEditorPresentation(.image, repository, path, document); return }
                        let controller = imageConflictWindows[key] ?? ImageConflictWindowController(repository: repository, access: access, document: document, preferences: defaults)
                        controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.imageConflictWindows[key] === controller else { return }; self.imageConflictWindows.removeValue(forKey: key) }
                        controller.model.onChanged = { [weak self] output in
                            self?.refreshAfterConflictChange(root)
                            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
                        }
                        imageConflictWindows[key] = controller; guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; presentConflictWindow(controller); return
                    }
                    try await validateConflictEditorEntry(entry, repository: repository, token: token)
                    request.dismissProgress()
                    if let conflictEditorPresentation { conflictEditorPresentation(.text, repository, path, nil); return }
                    let controller = (textConflictWindows[key]?.window != nil ? textConflictWindows[key] : nil) ?? TextConflictWindowController(repository: repository, access: access, path: path, preferences: defaults)
                    controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.textConflictWindows[key] === controller else { return }; self.textConflictWindows.removeValue(forKey: key) }
                    controller.model.onChanged = { [weak self] output in
                        self?.refreshAfterConflictChange(root)
                        if let self, self.root == root { self.output = output; Task { await self.refresh() } }
                    }
                    textConflictWindows[key] = controller; guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; presentConflictWindow(controller); return
                }
                let root = repository.root, key = root.path + "\0" + path
                try await validateConflictEditorEntry(entry, repository: repository, token: token)
                request.dismissProgress()
                if let conflictEditorPresentation { conflictEditorPresentation(.submodule, repository, path, nil); return }
                let conflictKey=key+"\0git:"+repository.executable.path+"\0preferences:"+String(describing:ObjectIdentifier(defaults))
                let reusable=submoduleConflictWindows[conflictKey].flatMap{$0.canReuse ? $0:nil}
                let controller=reusable ?? SubmoduleConflictWindowController(repository:repository,access:access,path:path,preferences:defaults)
                controller.onClosed={ [weak self,weak controller] in guard let self,let controller,self.submoduleConflictWindows[conflictKey] === controller else{return};self.submoduleConflictWindows.removeValue(forKey:conflictKey) }
                controller.model.onChanged = { [weak self] output in
                    self?.refreshAfterConflictChange(root)
                    if let self, self.root == root { self.output = output; Task { await self.refresh() } }
                }
                let preferences=controller.model.operation.preferences
                controller.model.onLog={ [weak self] child,revision in self?.showLog(repository:child,access:access,paths:[],endRevision:revision,selectedRevision:revision,preferences:preferences) }
                controller.model.onReset={ [weak self,weak controller] child,revision,done in
                    guard let self,!self.retired,!self.confirmingQuit,let controller,controller.canReuse,!controller.model.confirmingQuit else{controller?.model.dismissReset();return}
                    self.showReset(repository:child,access:access,revision:revision,completion:done,dismissed:{[weak controller] in controller?.resetChildClosed()},preferences:preferences,onCreated:{[weak controller] in controller?.retainReset($0)})
                }
                submoduleConflictWindows[conflictKey] = controller; guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; presentConflictWindow(controller)
                }
            } catch { if !retired, !request.session.cancellation.isCancelled, !confirmingQuit { self.error = error.localizedDescription } }
        }
    }
    private func presentConflictWindow(_ controller: NSWindowController) {
        if let conflictWindowPresentation { conflictWindowPresentation(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
    }
    private func showDeleteConflict(repository: GitRepository, access: RepositoryAccessLease?, path: String, preferences: UserDefaults) {
        let root = repository.root, key = root.path + "\0" + path
        let controller = deleteConflictWindows[key] ?? DeleteConflictWindowController(repository: repository, access: access, path: path, preferences: preferences)
        controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.deleteConflictWindows[key] === controller else { return }; self.deleteConflictWindows.removeValue(forKey: key) }
        controller.model.onChanged = { [weak self] output in
            self?.refreshAfterConflictChange(root)
            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
        }
        controller.model.onLog = { [weak self] revision in self?.showLog(repository: repository, access: access, paths: [path], endRevision: revision) }
        deleteConflictWindows[key] = controller; guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; presentConflictWindow(controller)
    }
    func configureResetInteractions(_ controller: ResetWindowController, repository: GitRepository, access: RepositoryAccessLease?, completion: (() -> Void)? = nil) {
        let root = repository.root, preferences = controller.model.presentationPreferences
        controller.model.onNotificationLog={ [weak self] child,grant,paths,old,new in
            guard let self,!self.retired,!self.confirmingQuit else{return}
            self.showLog(repository:child,access:grant,paths:paths,endRevision:old == nil ? new:nil,revisionRange:old.map{HistoryRevisionRange(from:$0,to:new ?? "HEAD")},preferences:preferences)
        }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
        controller.configureCommitPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.configureModifiedComparison = { [weak self] model in
            self?.configureRevisionComparisonInteractions(model, repository: repository, access: access)
        }
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload(); self?.refreshStatusWindows(root)
            self?.refreshRepositoryLogs(root); self?.commitWindows[root.path]?.model.reload()
            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
        }
        controller.model.onReset = { _ in completion?() }
        controller.model.onPostAction = { [weak self, weak model = controller.model] action in
            guard let self, !self.retired, !self.confirmingQuit, let model else { return }
            let presentation = model.handoffPresentation
            switch action {
            case .submoduleUpdate: self.showSubmoduleUpdate(repository: repository, access: access, scope: [], preferences: preferences, presentation: presentation)
            case .clean: self.showClean(repository: repository, access: access, paths: [], preferences: preferences, presentation: presentation)
            case .bisectGood: self.showBisect(repository: repository, access: access, operation: .good, preferences: preferences, presentation: presentation)
            case .bisectBad: self.showBisect(repository: repository, access: access, operation: .bad, preferences: preferences, presentation: presentation)
            case .bisectSkip: self.showBisect(repository: repository, access: access, operation: .skip, preferences: preferences, presentation: presentation)
            case .bisectReset: self.showBisect(repository: repository, access: access, operation: .reset, preferences: preferences, presentation: presentation)
            case .retry: break
            }
        }
    }
    var resetWindowPresentation:((ResetWindowController)->Void)?
    private func showReset(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, mode: ResetMode? = nil, completion: (() -> Void)? = nil, dismissed: (() -> Void)? = nil, preferences: UserDefaults? = nil, onCreated:((ResetWindowController)->Void)?=nil) {
        guard !confirmingQuit else { return }
        let root = repository.root, key = root.path + "\0" + (revision.map { $0 + "\0" + UUID().uuidString } ?? "")
        if revision == nil, let existing = resetWindows[key] {
            if let completion { let previous = existing.model.onReset; existing.model.onReset = { output in previous(output); completion() } }
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return
        }
        let controller = ResetWindowController(repository: repository, access: access, revision: revision, preferences: preferences ?? fileComparisonPreferences)
        if let mode { controller.model.mode = mode }
        controller.onClosed = { [weak self] in self?.resetWindows.removeValue(forKey: key); dismissed?() }
        configureResetInteractions(controller, repository: repository, access: access, completion: completion)
        resetWindows[key]=controller;onCreated?(controller)
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        if let resetWindowPresentation {resetWindowPresentation(controller)}else{controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)}
    }
    private func refreshAfterConflictChange(_ root:URL) {
        ConflictListRefreshPolicy.perform(preferences:fileComparisonPreferences) {
            revertWindows[root.path]?.model.requestReload(); refreshStatusWindows(root);commitWindows[root.path]?.model.reload()
            for resolve in resolveWindows.values where resolve.model.repository.root == root {resolve.model.load()}
            synchronizationWindows[root.path]?.model.refreshConflictFiles()
        }
        rebaseWindows[root.path]?.model.refreshState();refreshRepositoryLogs(root)
    }
    private func showResolve(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], quick: ResolveChoice?, preferences: UserDefaults? = nil, commandOptions: ResolveCommandOptions? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let root = repository.root, defaults = preferences ?? fileComparisonPreferences
        let mode = commandOptions.map { "\0command:\($0.silent):\($0.noQuestion)" } ?? ""
        let key = root.path + "\0" + String(quick?.rawValue ?? -1) + "\0" + paths.joined(separator: "\0") + mode + "\0preferences:" + String(describing: ObjectIdentifier(defaults))
        let controller = resolveWindows[key] ?? ResolveWindowController(repository: repository, access: access, paths: paths, quick: quick, preferences: defaults, commandOptions: commandOptions)
        controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.resolveWindows[key] === controller else { return }; self.resolveWindows.removeValue(forKey: key) }
        controller.onChanged = { [weak self] output in
            self?.refreshAfterConflictChange(root)
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onEdit = { [weak self, weak controller] path in self?.showConflictEditor(repository: repository, access: access, path: path, owner: controller?.window, preferences: defaults) }
        controller.model.onSubmoduleReset = { [weak self, weak controller] child, revision, done in
            self?.showReset(repository: child, access: access, revision: revision, completion: done, dismissed: { [weak controller] in controller?.model.dismissSubmoduleReset() })
        }
        controller.model.onFileSubmoduleRevert = { [weak self] revision,paths in
            for path in paths {self?.showSubmoduleDiff(repository:repository,access:access,path:path,from:revision)}
        }
        controller.model.onFileLog = { [weak self] path in self?.showLog(repository:repository,access:access,paths:[path]) }
        controller.model.onFileBlame = { [weak self] path,revision in self?.showBlame(repository:repository,access:access,path:path,revision:revision) }
        controller.model.onFileSubmoduleLog = { [weak self] child in self?.showLog(repository:child,access:access,paths:[]) }
        controller.model.onFilePair = { [weak self,weak controller] paths in self?.showWorkingFilePair(repository:repository,access:access,paths:paths,owner:controller?.window) }
        let capturedPreferences = controller.model.preferences
        controller.model.confirmingQuit = confirmingQuit
        controller.model.externalAvailability = { [weak self] in self?.retired == false && self?.confirmingQuit == false }
        controller.onProgressLog = { [weak self] path in
            guard let self, !self.retired, !self.confirmingQuit else { return }
            self.showLog(repository: repository, access: access, paths: [path], preferences: capturedPreferences)
        }
        controller.onCommit = { [weak self, weak controller] in
            guard let self, !self.retired, !self.confirmingQuit else { return }
            self.showCommitDialog(repository: repository, access: access, paths: [], preferences: capturedPreferences, sourceWindow: controller?.window)
        }
        presentation?.apply(to: controller.window)
        resolveWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        if let resolveWindowPresentation { resolveWindowPresentation(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
    }
    private func showIgnore(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], action: RepositoryAction) {
        do {
            let root = repository.root, key = GitPathRowIdentity.encode(root.path + "\0" + action.rawValue + "\0" + paths.joined(separator: "\0"))
            let controller: IgnoreWindowController
            if let existing = ignoreWindows[key] { controller = existing }
            else if let factory = ignoreWindowFactory { controller = try factory(repository, access, paths, action.ignoresByExtension, action.removesWhenIgnoring) }
            else { controller = try IgnoreWindowController(repository: repository, access: access, paths: paths, mask: action.ignoresByExtension, delete: action.removesWhenIgnoring, preferences: fileComparisonPreferences) }
            controller.onClosed = { [weak self] in self?.ignoreWindows.removeValue(forKey: key) }
            controller.onChanged = { [weak self] output in
                self?.refreshRepositoryLogs(root)
                self?.revertWindows[root.path]?.model.requestReload(); self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
                guard let self, self.root == root else { return }
                self.output = output; Task { await self.refresh() }
            }
            ignoreWindows[key] = controller
            guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } catch { self.error = error.localizedDescription }
    }
    private func showRemove(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], keepLocal: Bool) {
        guard !retired,!confirmingQuit else{return}
        do {
            let request = try RemovalRequest(paths: paths, keepLocal: keepLocal)
            let root = repository.root, key = root.path + "\0" + String(keepLocal) + "\0" + request.paths.joined(separator: "\0")
            guard removeWindows[key]?.model.retired != true else {error="The previous Delete window is still closing. Wait for its operation to finish.";return}
            let controller = removeWindows[key] ?? removeWindowFactory?(repository, access, request) ?? RemoveWindowController(repository: repository, access: access, request: request, preferences: fileComparisonPreferences)
            controller.onClosed = { [weak self] in self?.removeWindows.removeValue(forKey: key) }
            controller.onChanged = { [weak self] output in
                self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
                guard let self, self.root == root else { return }
                self.output = output; Task { await self.refresh() }
            }
            removeWindows[key] = controller
            guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.start()
        } catch { self.error = error.localizedDescription }
    }
    private func showCommitDialog(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], invocation: PrimaryCommandInvocation? = nil, commandMessage: String? = nil, preferences: UserDefaults? = nil, sourceWindow: NSWindow? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let root = repository.root
        if let existing = commitWindows[root.path], !existing.canReuse {
            error = String(localized:"The previous Commit window is still closing. Wait for its operation to finish.")
            return
        }
        if invocation != nil, let existing = commitWindows[root.path] {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "A Commit dialog is already open. Close it before opening a command-line Commit with new presets."
            return
        }
        let controller = commitWindows[root.path] ?? commitWindowFactory?(repository,access) ?? CommitWindowController(repository: repository, access: access, defaults: preferences ?? fileComparisonPreferences)
        guard controller.canReuse else {
            error = String(localized:"The previous Commit window is still closing. Wait for its operation to finish.")
            return
        }
        let preferences = controller.presentationPreferences, access = controller.model.access
        presentation?.apply(to: controller.window)
        if let sourceWindow { controller.window?.alphaValue = sourceWindow.alphaValue; controller.window?.appearance = sourceWindow.effectiveAppearance }
        controller.onPullAfterLFSLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true, preferences: preferences) }
        controller.onClosed = { [weak self] in self?.commitWindows.removeValue(forKey: root.path) }
        controller.model.onCommitted = { [weak self] output in
            self?.refreshStatusWindows(root); self?.refreshRepositoryLogs(root)
            guard let self, self.root == root else { return }
            self.output = output
            Task { await self.refresh() }
        }
        controller.model.onPush = { [weak self] continuation in
            self?.showPush(repository:repository,access:access,preferences:preferences,commitContinuation:continuation)
        }
        controller.model.onPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true, followUp: PullFollowUp(showPush: true), preferences: preferences) }
        controller.model.onCreateTag = { [weak self] in self?.showReference(repository: repository, access: access, isTag: true, preferences: preferences) }
        controller.model.onSVNDCommit = { [weak self] in self?.showSVN(.dcommit, repository: repository, access: access) }
        configureCommitInteractions(controller.model, repository: repository, access: access)
        commitWindows[root.path] = controller
        if let invocation { controller.model.applyCommandLine(invocation, message: commandMessage) }
        controller.model.reload(paths: invocation?.wholeProject == true ? [] : paths)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showAdd(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], commandLaunch: Bool = false) {
        let id = UUID(), owner = RepositoryWindowOwner(window: workspaceWindow)
        let backend = GitLibGit2Configuration.load(from: fileComparisonPreferences)
        addPreparations[id] = owner
        let preflight = addSelectionPreflight
        Task { [self, access] in
            defer { addPreparations.removeValue(forKey: id); withExtendedLifetime(access) {} }
            do {
                try owner.cancellation.check()
                guard !retired, !confirmingQuit else { return }
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let files: Bool
                if let preflight { files = try await preflight(repository, paths, owner.cancellation) }
                else { files = try await repository.addSelectionIsFiles(paths, cancellation: owner.cancellation) }
                try owner.cancellation.check(); guard !retired, !confirmingQuit else { return }
                if files { showAddProgress(repository: repository, access: access, paths: paths, backend: backend); return }
                let key = repository.root.path
                if commandLaunch, let existing = addWindows[key] {
                    existing.window?.makeKeyAndOrderFront(nil)
                    error = "An Add dialog is already open. Close it before opening another command-line Add."
                    return
                }
                let controller = addWindows[key] ?? AddWindowController(repository: repository, access: access, defaults: fileComparisonPreferences)
                guard !controller.model.busy else { controller.window?.makeKeyAndOrderFront(nil); return }
                controller.onClosed = { [weak self] in self?.addWindows.removeValue(forKey: key) }
                controller.model.onAccepted = { [weak self, weak controller] paths in
                    guard let backend = controller?.model.acceptedBackend else { return }
                    self?.showAddProgress(repository: repository, access: access, paths: paths, backend: backend)
                }
                controller.onPullAfterLFSLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
                controller.model.onLFSChanged = { [weak self] in
                    self?.refreshStatusWindows(repository.root); self?.commitWindows[key]?.model.reload()
                    if let self, self.root == repository.root { Task { await self.refresh() } }
                }
                controller.model.onPreview = { [weak self, weak controller] path in guard let controller else { return }; self?.showWorkingFiles(repository: repository, access: access, paths: [path], owner: controller.window) }
                controller.model.onCompare = { [weak self, weak controller] paths in guard let controller else { return }; self?.showWorkingFiles(repository: repository, access: access, paths: paths, owner: controller.window) }
                controller.model.onCompareTwo = { [weak self, weak controller] paths in guard let controller else { return }; self?.showWorkingFilePair(repository: repository, access: access, paths: paths, owner: controller.window) }
                controller.model.unifiedViewerBusy = { [weak self] in self?.addUnifiedWindows[key]?.model.busy == true || self?.addUnifiedWindows[key]?.window?.attachedSheet != nil }
                controller.model.onUnifiedPatch = { [weak self] bytes, alternate in
                    guard let self else { return }
                    if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate, title: "HEAD → Working tree", permissions: access.map { [$0] } ?? []) {
                        self.addUnifiedWindows[key] = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: self.addUnifiedWindows[key], title: "HEAD → Working tree", onClosed: { [weak self] in self?.addUnifiedWindows.removeValue(forKey: key) })
                    }
                }
                controller.model.onLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path]) }
                controller.model.onBlame = { [weak self] path in self?.showBlame(repository: repository, access: access, path: path, revision: "HEAD") }
                controller.model.onIgnoreChanged = { [weak self] output in
                    self?.refreshStatusWindows(repository.root); self?.commitWindows[key]?.model.reload()
                    if let self, self.root == repository.root { self.output = output; Task { await self.refresh() } }
                }
                controller.model.onRevert = { [weak self, weak model = controller.model] entries, done in
                    guard let self else { done(false); return {} }
                    let progress = self.showRevertProgress(repository: repository, access: access, entries: entries, autoCloseSuccess: true, policy: model?.pendingRevertPolicy, completion: done)
                    return { [weak progress] in progress?.model.cancel() }
                }
                controller.model.onRestoreChanged = { [weak model = controller.model] in model?.onIgnoreChanged("Working copies restored.") }
                controller.model.onDeleteChanged = controller.model.onIgnoreChanged
                addWindows[key] = controller; controller.model.setScope(paths); controller.model.reload()
                guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
            } catch { if !retired, !owner.cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func showSVN(_ operation: GitSVNOperation) {
        guard !busy, !confirmingQuit, !bare, let repository else { return }
        showSVN(operation, repository: repository, access: activeAccess)
    }
    func showSVN(_ operation: GitSVNOperation, repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let key = repository.root.path
        if let existing = svnWindows[key] {
            if existing.model.busy || existing.model.hasQuestion || existing.model.confirmingCancellation || existing.model.phase == .options || existing.window?.attachedSheet != nil {
                if existing.model.operation != operation { error = "Finish " + existing.model.title + " before starting another SVN operation." }
                if let svnPresentation { svnPresentation(existing) } else { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil) }
                return
            }
            existing.window?.close()
        }
        if operation == .rebase, let existing = rebaseWindows[key] { existing.window?.makeKeyAndOrderFront(nil); error = "Close the existing Rebase dialog before starting SVN Rebase."; return }
        let controller = svnWindowFactory?(repository,access,operation) ?? SVNWindowController(repository: repository, access: access, operation: operation, preferences: preferences ?? fileComparisonPreferences)
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller, self.svnWindows[key] === controller else { return }
            self.svnWindows.removeValue(forKey: key)
        }
        let inherited = controller.model.outputPreferences
        controller.model.onChanged = { [weak self] in
            self?.refreshRepositoryLogs(repository.root)
            if self?.root == repository.root { Task { await self?.refresh() } }
        }
        controller.model.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: .revision(from), to: .revision(to), preferences: inherited) }
        controller.model.onLog = { [weak self] result in self?.showLog(repository: repository, access: access, paths: [], revisionRange: HistoryRevisionRange(from: result.oldHash, to: result.newHash), preferences: inherited) }
        controller.model.onRepositoryLog = { [weak self] in self?.showLog(repository: repository, access: access, paths: [], preferences: inherited) }
        controller.model.openRebase = { [weak self, weak controller] reference in
            guard let self, let window = controller?.window, window.attachedSheet == nil, self.rebaseWindows[key] == nil else { return false }
            return await withCheckedContinuation { continuation in
                self.showRebase(repository: repository, access: access, upstream: String(reference.dropFirst("refs/".count)), owner: window, onResult: { continuation.resume(returning: $0) }, onRequestedLog: { [weak controller] in controller?.model.pendingRebaseLog = true }, preferences: inherited)
            }
        }
        presentation?.apply(to: controller.window)
        svnWindows[key] = controller
        if let svnPresentation { svnPresentation(controller) } else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        controller.model.load()
    }
    func showDaemon(repository captured: GitRepository? = nil, access capturedAccess: RepositoryAccessLease? = nil) {
        guard !busy, !confirmingQuit, !retired, let repository = captured ?? repository else { return }
        let preferences=finderWorkflowPreferences,access=captured == nil ? activeAccess:capturedAccess
        let base=repository.root.path+"\0"+repository.executable.path
        let reusable=daemonWindows.first {_,controller in controller.canReuse && controller.model.repository.root.path==repository.root.path && controller.model.repository.executable.path==repository.executable.path && controller.model.preferences === preferences}
        if let existing=reusable?.value {
            guard prepareFinderServiceWorkflow(existing,repository:repository,access:access) else{return}
            if let daemonPresentation {daemonPresentation(existing)} else{existing.showWindow(nil);existing.window?.makeKeyAndOrderFront(nil)};return
        }
        let key=daemonWindows[base]==nil ? base:base+"\0"+UUID().uuidString
        let controller=GitDaemonWindowController(repository:repository,access:access,configuration:daemonConfiguration,preferences:preferences)
        controller.onClosed={ [weak self,weak controller] in guard let self,let controller,self.daemonWindows[key] === controller else{return};self.daemonWindows.removeValue(forKey:key)}
        daemonWindows[key]=controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        if let daemonPresentation {daemonPresentation(controller)} else{controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)}
        if controller.canReuse {controller.model.begin()}
    }
    func showLFSLocks() {
        guard !busy, !confirmingQuit, !bare, let repository else { return }
        showLFSLocks(repository: repository, access: activeAccess)
    }
    private func showLFSLocks(repository: GitRepository, access: RepositoryAccessLease?) {
        guard !retired, !confirmingQuit else { return }
        let key = repository.root.path
        // A later command focuses the existing list, preserving checks, Force,
        // column layout and any progress review already owned by that window.
        if let existing = lfsLocksWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = lfsLocksWindowFactory?(repository, access, fileComparisonPreferences) ?? LFSLocksWindowController(repository: repository, access: access, defaults: fileComparisonPreferences)
        controller.model.onProgressLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path]) }
        controller.onPullAfterLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.lfsLocksWindows[key] === controller else { return }; self.lfsLocksWindows.removeValue(forKey: key) }
        lfsLocksWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        Task { await controller.model.refresh() }
    }
    private func showFinderLFSOperation(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], locked: Bool, force: Bool = false, commandLaunch: Bool = false) {
        guard !retired, !busy, !confirmingQuit, workspaceWindow?.attachedSheet == nil else { return }
        let id = UUID(), window = workspaceWindow, owner = RepositoryWindowOwner(window: workspaceWindow)
        let preflight = lfsSelectionPreflight, preferences = fileComparisonPreferences, factory = lfsFileOperationFactory
        lfsPreparations[id] = owner; busy = true
        Task { [self, access] in
            defer { lfsPreparations.removeValue(forKey: id); busy = false; withExtendedLifetime(access) {} }
            do {
                try owner.cancellation.check()
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let targets: [String]
                if let preflight { targets = try await preflight(repository, paths, commandLaunch, owner.cancellation) }
                else if commandLaunch { targets = try await repository.lfsCommandPaths(paths, cancellation: owner.cancellation) }
                else { targets = try await repository.finderLFSPaths(paths, cancellation: owner.cancellation) }
                try owner.cancellation.check()
                guard !retired, !confirmingQuit, window?.attachedSheet == nil else { return }
                let controller = factory?(repository, access, preferences) ?? LFSFileOperationController(repository: repository, access: access, defaults: preferences)
                controller.model.onProgressLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path]) }
                controller.model.onPullAfterLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
                controller.onClosed = { [weak self] in
                    guard let self else { return }; self.lfsFileOperations.removeValue(forKey: id)
                    self.refreshStatusWindows(repository.root); self.commitWindows[repository.root.path]?.model.reload()
                    if self.root == repository.root { Task { await self.refresh() } }
                }
                lfsFileOperations[id] = controller
                if !controller.present(owner: window, paths: targets, locked: locked, force: force) { lfsFileOperations.removeValue(forKey: id) }
            } catch { if !retired, !owner.cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }

    /// Send Mail captures file grants and does not change the app's checkout.
    /// A known first-file repository supplies local sender identity; otherwise
    /// an owned no-repository context supplies Git's global identity.
    func showClipboardPatch(from pasteboard: NSPasteboard = .general) {
        guard !busy, !confirmingQuit else { return }
        guard let bytes = PatchClipboard.snapshot(from: pasteboard) else { error = "The clipboard does not contain a unified patch."; return }
        do {
            let workflow = ReviewPatchWorkflow(file: nil, target: root, preferred: root, grants: activeAccess.map { [$0] } ?? [],
                executable: try GitRuntime.executable(), preferences: reviewPatchPreferences, clipboardBytes: bytes)
            presentReview(workflow)
        } catch { self.error = error.localizedDescription }
    }
    private func showFinderClipboardPatch(_ request: FinderRequest, receipt: String) {
        guard !busy, !confirmingQuit, let selected = request.paths.first else { return }
        guard receipt != FinderPatchHandoff.unavailable, let handoff = finderPatchHandoff else {
            error = "Finder could not pass the clipboard patch. Use Review Clipboard Patch in TurtleGit to try again."; return
        }
        guard !finderPatchReceipts.contains(receipt) else { return }
        finderPatchReceipts.append(receipt); if finderPatchReceipts.count > 128 { finderPatchReceipts.removeFirst() }
        let known = FinderSnapshot.readLive()?.roots.first { selected.path == $0 || selected.path.hasPrefix($0 + "/") }
            ?? root.flatMap { selected.path == $0.path || selected.path.hasPrefix($0.path + "/") ? $0.path : nil }
        let target = known == nil ? nil : selected.deletingLastPathComponent()
        var grants = activeAccess.map { [$0] } ?? []
        if GitRuntime.isAppStoreBuild, let accessStore {
            for saved in accessStore.repositories {
                if let lease = try? accessStore.acquire(saved.id, requireSecurityScope: true), lease.contains(selected) { grants.append(lease) }
            }
        }
        do {
            let workflow = ReviewPatchWorkflow(file: nil, target: target, preferred: selected.deletingLastPathComponent(), grants: grants,
                executable: try GitRuntime.executable(), preferences: reviewPatchPreferences, clipboardLoader: { token in
                    try await Task.detached {
                        try token.check(); let bytes = try handoff.consume(receipt); try token.check(); return bytes
                    }.value
                })
            presentReview(workflow)
        } catch { self.error = error.localizedDescription }
    }
    private func presentReview(_ workflow: ReviewPatchWorkflow,allowed:(()->Bool)?=nil) {
        guard !retired,!confirmingQuit,workflow.canReuse,allowed?() != false else{workflow.close();return}
        let id = UUID(); reviewPatchWorkflows[id] = workflow
        workflow.presentation = { [weak self] controller in
            let root = controller.model.repository.root
            let refresh: () -> Void = { [weak self] in
                self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload(); self?.refreshRepositoryLogs(root)
                if self?.root == root { Task { await self?.refresh() } }
            }
            controller.model.onMutationStopped = refresh
            controller.model.onChanged = { [weak self] output in refresh(); if self?.root == root { self?.output = output } }
            if let presentation = self?.reviewPatchPresentation { presentation(controller) }
            else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        }
        workflow.onFinished = { [weak self] in self?.reviewPatchWorkflows.removeValue(forKey: id) }
        if let reviewPatchPreparation { reviewPatchPreparation(workflow) }
        else { workflow.showWindow(nil); workflow.window?.makeKeyAndOrderFront(nil) }
        if workflow.canReuse,!retired,!confirmingQuit,allowed?() != false {workflow.start()}else{workflow.close()}
    }
    func showReviewPatch(files: [URL]) {
        guard !busy, !confirmingQuit else { return }
        guard files.count <= 1 else { error = "Select one patch file to review."; return }
        let first = files.first
        let knownRoot = first.flatMap { first in
            FinderSnapshot.readLive()?.roots.sorted { $0.count > $1.count }.first { first.path == $0 || first.path.hasPrefix($0 + "/") }
                ?? root.flatMap { first.path == $0.path || first.path.hasPrefix($0.path + "/") ? $0.path : nil }
        }
        let patchFile = first.flatMap { ["patch", "diff"].contains($0.pathExtension.lowercased()) ? $0 : nil }
        let target = knownRoot != nil ? first?.deletingLastPathComponent() : first == nil ? root : nil
        var grants: [RepositoryAccessLease] = []
        if let activeAccess { grants.append(activeAccess) }
        if GitRuntime.isAppStoreBuild, let store = accessStore {
            for saved in store.repositories {
                if let lease = try? store.acquire(saved.id, requireSecurityScope: true),
                   first.map({ lease.contains($0) }) == true || target.map({ lease.contains($0) }) == true { grants.append(lease) }
            }
        }
        do {
            let workflow = ReviewPatchWorkflow(file: patchFile, target: target, preferred: first?.deletingLastPathComponent() ?? root,
                grants: grants, executable: try GitRuntime.executable(), preferences: reviewPatchPreferences)
            presentReview(workflow)
        } catch { self.error = error.localizedDescription }
    }

    private func chooseMailPermissions(_ targets: [URL], id: UUID, owner: RepositoryWindowOwner, window: NSWindow?, message: String) async -> [RepositoryAccessLease]? {
        guard !retired, !owner.cancellation.isCancelled, window?.attachedSheet == nil else { return nil }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = "Authorize mail files"; panel.message = message
        panel.directoryURL = targets.first?.deletingLastPathComponent(); mailPermissionPanels[id] = panel
        owner.onCancelled = { [weak self, weak panel] in
            guard let panel else { return }
            if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }
            else { panel.cancel(nil) }
            panel.orderOut(nil); self?.mailPermissionPanels.removeValue(forKey: id)
        }
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard !answered else { return }; answered = true
                self?.mailPermissionPanels.removeValue(forKey: id)
                guard !owner.cancellation.isCancelled, self?.retired == false, response == .OK else { continuation.resume(returning: nil); return }
                continuation.resume(returning: panel.urls.map { RepositoryAccessLease(url: $0) })
            }
            if let window { panel.beginSheetModal(for: window, completionHandler: reply) }
            else { panel.begin(completionHandler: reply) }
        }
    }
    private func showFinderSendMail(files: [URL], commandCancellation: OperationCancellation? = nil,preparedGrants:[RepositoryAccessLease]?=nil,capturedPreferences:UserDefaults?=nil,capturedWindow:NSWindow?=nil,capturedSenderRoot:URL?=nil) {
        let window=preparedGrants == nil ? workspaceWindow:capturedWindow
        guard !retired, !busy, !confirmingQuit, !files.isEmpty, window?.attachedSheet == nil else { return }
        let first = files[0], id = UUID(), owner = RepositoryWindowOwner(window: window)
        let requireScope = requiresRepositoryScope, preferences = capturedPreferences ?? fileComparisonPreferences
        let presentation:((NSWindowController)->Void)? = preparedGrants.map { accepted in
            { [weak self] (controller:NSWindowController) in
                controller.window?.alphaValue=window?.alphaValue ?? 1;controller.window?.appearance=window?.effectiveAppearance
                self?.finderServiceFileWorkflowPresentation?(.sendMail,controller,accepted)
                let reusable=(controller as? SendPatchWindowController)?.canReuse ?? (controller as? SendPatchProgressWindowController)?.canReuse ?? false
                guard reusable,self?.retired==false,self?.confirmingQuit==false,!owner.cancellation.isCancelled,commandCancellation?.isCancelled != true else{controller.close();return}
                if let present=self?.finderMailPresentation {present(controller)}else{controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)}
                let stillReusable=(controller as? SendPatchWindowController)?.canReuse ?? (controller as? SendPatchProgressWindowController)?.canReuse ?? false
                guard stillReusable,self?.retired==false,self?.confirmingQuit==false,!owner.cancellation.isCancelled,commandCancellation?.isCancelled != true else{controller.close();return}
            }
        } ?? finderMailPresentation
        let token = owner.cancellation
        let inspect = mailFileInspection, permission = mailFilePermission
        let knownRoot = preparedGrants == nil ? (FinderSnapshot.readLive()?.roots.sorted { $0.count > $1.count }.first { first.path == $0 || first.path.hasPrefix($0 + "/") }
            ?? root.flatMap { first.path == $0.path || first.path.hasPrefix($0.path + "/") ? $0.path : nil }):capturedSenderRoot?.path
        let rootURL = knownRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }.flatMap { root in
            preparedGrants == nil || preparedGrants!.contains(where:{$0.contains(root) && (!requireScope || $0.hasSecurityScope)}) ? root:nil
        }
        let targets = files + (rootURL.map { [$0] } ?? [])
        var grants = (preparedGrants ?? []) + (activeAccess.map { [$0] } ?? [])
        if requireScope, let store = accessStore {
            for saved in store.repositories {
                if let lease = try? store.acquire(saved.id, requireSecurityScope: true, recordingOpen: false), targets.contains(where: { lease.contains($0) }) {
                    let metadata = (try? store.acquireAdditionalPermissions(saved.id, requireSecurityScope: true, skipUnavailable: true)) ?? []
                    grants.append(lease.retainingRelatedScopes(metadata))
                }
            }
        }
        mailPreparations[id] = owner; busy = true
        Task { [self] in
            defer { mailPreparations.removeValue(forKey: id); mailPermissionPanels.removeValue(forKey: id); busy = false; withExtendedLifetime(grants) {} }
            @MainActor func check() throws { try token.check(); try commandCancellation?.check(); if retired || confirmingQuit { throw OperationCancellationFailure.cancelled } }
            func covered(_ target: URL) -> Bool { grants.contains { (!requireScope || $0.hasSecurityScope) && $0.contains(target) } }
            do {
                try check()
                if requireScope, !targets.allSatisfy(covered) {
                    let selected: [RepositoryAccessLease]?
                    if let permission { selected = try await permission(targets, token) }
                    else { selected = await chooseMailPermissions(targets, id: id, owner: owner, window: window, message: "Select these files or their containing folders. For a known repository, include its root folder to use the local sender identity.") }
                    try check(); guard let selected else { return }; grants += selected
                    guard targets.allSatisfy(covered) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                }
                if let inspect { try await inspect(files, token) }
                else {
                    // SendMailDlg lists orgPathList before reading checked files.
                    // A stale/missing/directory entry must remain available to uncheck by
                    // the user instead of rejecting an otherwise usable batch.
                    for file in files {
                        try check()
                        guard file.isFileURL, !file.path.contains("\0") else { throw MailPatchFailure.file }
                    }
                }
                try check()
                var senderRoot = rootURL
                let firstIsDirectory = await Task.detached { (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.value
                try check()
                let location = rootURL ?? (firstIsDirectory ? first : first.deletingLastPathComponent())
                if !requireScope || covered(location) {
                    if requireScope {
                        for index in 0..<64 {
                            try check()
                            let folders = grants.flatMap { $0.permittedFolders() }
                            let requirement = try await Task.detached { try RepositoryMetadataAccess.next(at: location, authorizedFolders: folders, cancellation: token) }.value
                            try check(); guard let requirement else { break }
                            guard index < 63 else { throw RepositoryMetadataAccessFailure.tooManyDependencies }
                            let selected: [RepositoryAccessLease]?
                            if let permission { selected = try await permission([requirement.folder], token) }
                            else { selected = await chooseMailPermissions([requirement.folder], id: id, owner: owner, window: window, message: requirement.explanation + "\n" + requirement.folder.path) }
                            try check(); guard let selected else { return }; grants += selected
                            guard covered(requirement.folder) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(requirement.folder.path) }
                        }
                    }
                    let candidate = try makeRepository(location)
                    senderRoot = try? await candidate.discoverRoot(cancellation: token)
                    try check()
                    if let senderRoot, requireScope, !covered(senderRoot) { throw RepositoryAccessFailure.repositoryRootOutsidePermission(senderRoot.path) }
                }
                let context = senderRoot == nil ? try ApplicationMailContext() : nil
                guard let directory = senderRoot ?? context?.root else { throw MailPatchFailure.file }
                let repository = try makeRepository(directory)
                let access = grants.first { $0.contains(repository.root) && (!requireScope || $0.hasSecurityScope) }?.retainingRelatedScopes(grants)
                try check()
                let workflow = SendMailWorkflow(files: files, repository: repository, access: access, fileAccess: grants, preferences: preferences, presentation: presentation, applicationContext: context) { [weak self] result in
                    self?.finderMailWorkflows.removeValue(forKey: id)
                    if let result { self?.error = result }
                }
                finderMailWorkflows[id] = workflow; workflow.start()
            } catch { if !retired, !token.isCancelled, commandCancellation?.isCancelled != true { self.error = error.localizedDescription } }
        }
    }

    func showSynchronization(sequence: Int? = nil) {
        guard !busy, !confirmingQuit, !bare, let repository else { return }
        let key = repository.root.path, access = activeAccess
        if let existing = synchronizationWindows[key] { guard prepareFinderServiceWorkflow(existing,repository:repository,access:access) else{existing.close();return}; if let synchronizationWindowPresentation {synchronizationWindowPresentation(existing)} else {existing.showWindow(nil);existing.window?.makeKeyAndOrderFront(nil)};return }
        let controller = SynchronizationWindowController(repository: repository, access: access, preferences: fileComparisonPreferences, sequence: sequence)
        let notificationPreferences = controller.model.preferences
        controller.model.onNotificationLog = { [weak self, weak controller] child, grant, paths, old, new in
            guard let self, !self.retired, !self.confirmingQuit, let controller,
                  controller.model.notificationActionsAvailable else { return }
            self.showLog(repository: child, access: grant, paths: paths,
                endRevision: old == nil ? new : nil,
                revisionRange: old.map { HistoryRevisionRange(from: $0, to: new ?? "HEAD") },
                preferences: notificationPreferences, sourceWindow: controller.window)
        }
        controller.configureExport = { [weak self] child in self?.configureExportInteractions(child, repository: repository, access: access) }
        controller.configureBranchPicker = { [weak self] model in self?.configureReferenceBrowser(model, repository: repository, access: access) }
        controller.configureHistoryReference = { [weak self] child in self?.configureReferenceInteractions(child, repository: repository, access: access) }
        controller.configureHistoryContainingReferences = { [weak self] child in
            child.onLog = { [weak self] name, select, range in self?.showLog(repository: repository, access: access, paths: [], endRevision: name, selectedRevision: select ? name : nil, revisionRange: range) }
            child.onBrowse = { [weak self] name in self?.showRepositoryBrowser(repository: repository, access: access, revision: name) }
            child.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: from, to: to) }
        }
        controller.model.onHistoryBrowseRepository = { [weak self] hash in self?.showRepositoryBrowser(repository: repository, access: access, revision: hash) }
        controller.model.onHistoryLog = { [weak self] hash in self?.showLog(repository: repository, access: access, paths: [], endRevision: hash, selectedRevision: hash) }
        controller.model.onHistoryLogRange = { [weak self] range in self?.showLog(repository: repository, access: access, paths: [], revisionRange: range) }
        configureRevisionComparisonInteractions(controller.model.comparison, repository: repository, access: access)
        configureRevisionComparisonInteractions(controller.model.incomingComparison, repository: repository, access: access)
        controller.configurePushOptions = { [weak self] child in self?.configurePushInteractions(child, repository: repository, access: access) }
        controller.model.onTransportFinished = { [weak self] text in
            guard let self else { return }
            self.output = text; self.refreshRepositoryLogs(repository.root)
            if self.root?.path == repository.root.path { Task { await self.refresh() } }
        }
        controller.model.onLog = { [weak self] revision in self?.showLog(repository: repository, access: access, paths: [], endRevision: revision) }
        controller.model.onCommit = { [weak self] in self?.showCommitDialog(repository: repository, access: access, paths: []) }
        controller.model.onStashOptions = { [weak self] in self?.showStash(repository: repository, access: access) }
        controller.model.onSubmoduleOptions = { [weak self] action in
            if action == .sync { self?.showSubmoduleSync(repository: repository, access: access, scope: []) }
            else { self?.showSubmoduleUpdate(repository: repository, access: access, scope: []) }
        }
        controller.model.onResultLog = { [weak self,weak controller] revision in
            guard let controller,!controller.model.closed else{return}
            self?.showLog(repository:repository,access:access,paths:[],endRevision:revision,selectedRevision:revision,preferences:controller.model.preferences,sourceWindow:controller.window)
        }
        controller.model.onTagLog = { [weak controller] revision in controller?.model.onResultLog?(revision) }
        controller.model.onTagsChanged = { [weak self] in
            guard let self else { return }
            self.refreshRepositoryLogs(repository.root)
            if self.root?.path == repository.root.path { Task { await self.refresh() } }
        }
        controller.model.onReferenceLog = { [weak self,weak controller] reference in
            guard let controller,!controller.model.closed else{return}
            self?.showReferenceLog(repository:repository,access:access,reference:reference,preferences:controller.model.preferences)
        }
        controller.model.onReferenceCompare = { [weak self,weak controller] old,new in
            guard let controller,!controller.model.closed else{return}
            let alternate=ComparisonToolInvocation.capture
            ComparisonToolInvocation.$alternate.withValue(alternate) {
                self?.showRevisionComparison(repository:repository,access:access,from:.revision(old),to:.revision(new),preferences:controller.model.preferences)
            }
        }
        controller.model.onHistoryCompare = { [weak self,weak controller] from,to in
            guard let controller,!controller.model.closed else{return}
            let alternate=ComparisonToolInvocation.capture
            ComparisonToolInvocation.$alternate.withValue(alternate) {
                self?.showRevisionComparison(repository:repository,access:access,from:from,to:to,preferences:controller.model.preferences)
            }
        }
        controller.model.onResolve = { [weak self] paths in self?.showResolve(repository: repository, access: access, paths: paths, quick: nil) }
        controller.model.onConflictAction = { [weak self, weak controller] action, paths in
            guard let self, let controller, !controller.model.closed else { return }
            if action == .editConflict, let path=paths.first { self.showConflictEditor(repository:repository,access:access,path:path,owner:controller.window) }
            else if action == .log { self.showLog(repository:repository,access:access,paths:paths) }
            else if action.resolveChoice != nil { self.showResolve(repository:repository,access:access,paths:paths,quick:action.resolveChoice) }
        }
        controller.configureOptions = { [weak self] child in
            self?.configureFetchInteractions(child, repository: repository, access: access, followUp: PullFollowUp())
        }
        controller.model.runRebase = { [weak self, weak controller] target, autoStart, preserve in
            guard let self, let controller, !controller.model.closed, let owner = controller.window,
                  owner.attachedSheet == nil, self.rebaseWindows[key] == nil else { throw SynchronizationFailure.invalidInput }
            let accepted=controller.model.acceptedOperationRepository ?? repository.capturingDiffBackend(preferences:controller.model.preferences)
            await withCheckedContinuation { continuation in
                self.showRebase(repository: accepted, access: access, upstream: target.isEmpty ? nil:target, autoStart: autoStart, preserveMerges: preserve,
                    afterFetch: true, owner: owner, onDismissed: { continuation.resume() },preferences:controller.model.preferences,acceptedRepository:accepted)
            }
        }
        controller.model.runHistoryReplay = { [weak self, weak controller] upstream, commits in
            guard let self, let controller, !controller.model.closed, let owner = controller.window,
                  owner.attachedSheet == nil, self.rebaseWindows[key] == nil else { throw SynchronizationFailure.invalidInput }
            await withCheckedContinuation { continuation in
                self.showRebase(repository: repository, access: access, upstream: upstream, cherryPick: commits,
                    fromLog: true, owner: owner, onDismissed: { continuation.resume() })
            }
        }
        controller.configureHistoryOperation = { [weak self] child in
            switch child {
            case let child as MergeWindowController: self?.configureMergeInteractions(child, repository: repository, access: access)
            case let child as ResetWindowController: self?.configureResetInteractions(child, repository: repository, access: access)
            case let child as SwitchWindowController: self?.configureSwitchInteractions(child, repository: repository, access: access)
            case let child as HistoryCombineWindowController:
                child.configureCommit = { [weak self] commit in self?.configureCommitInteractions(commit.model, repository: repository, access: access) }
                child.model.onChanged = { [weak self] output in
                    self?.refreshRepositoryLogs(repository.root); self?.refreshStatusWindows(repository.root); self?.commitWindows[key]?.model.reload()
                    if self?.root == repository.root { self?.output = output; Task { await self?.refresh() } }
                }
            case let child as HistoryNotesWindowController:
                child.model.onChanged = { [weak self] output in
                    guard let self, !self.retired else { return }
                    self.refreshRepositoryLogs(repository.root)
                    if self.root == repository.root { self.output = output }
                }
            case let child as HistoryRevertWindowController:
                child.model.onChanged = { [weak self] output in
                    self?.refreshRepositoryLogs(repository.root); self?.refreshStatusWindows(repository.root); self?.commitWindows[key]?.model.reload()
                    if self?.root == repository.root { self?.output = output; Task { await self?.refresh() } }
                }
                child.model.onCommit = { [weak self] in self?.showCommitDialog(repository: repository, access: access, paths: []) }
            case let child as SwitchProgressWindowController:
                child.model.onFinished = { [weak self] output, _ in
                    self?.refreshRepositoryLogs(repository.root); self?.refreshStatusWindows(repository.root); self?.commitWindows[key]?.model.reload()
                    if self?.root == repository.root { self?.output = output; Task { await self?.refresh() } }
                }
                let inherited = child.model.presentationPreferences
                child.model.onPostAction = { [weak self, weak model = child.model] action, branch in guard let model else { return }; self?.performSwitchPostAction(action, previousBranch: branch, repository: repository, access: access, preferences: inherited, presentation: model.handoffPresentation) }
            default: break
            }
        }
        let bisectPreferences = controller.model.preferences
        controller.model.onHistoryBisect = { [weak self, weak controller] request in
            self?.showBisect(repository: repository, access: access, good: request.good, bad: request.bad, operation: request.operation, revisions: request.revisions, requireStart: request.operation == nil, onChanged: { [weak controller] in controller?.model.refresh() }, preferences: bisectPreferences)
        }
        controller.model.onHistoryPush = { [weak self] revision, preserveAllBranches in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: preserveAllBranches) }
        controller.model.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.model.onHistoryReferenceChanged = { [weak self] output in
            self?.refreshRepositoryLogs(repository.root); self?.refreshStatusWindows(repository.root); self?.commitWindows[key]?.model.reload()
            if self?.root == repository.root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onHistoryFormatPatch = { [weak self] preset in self?.showFormatPatch(repository: repository, access: access, preset: preset) }
        controller.model.detachRebase = { [weak self, weak controller] in
            guard let child = self?.rebaseWindows[key], let window = child.window,
                  let owner = controller?.window, window.sheetParent === owner else { return }
            owner.endSheet(window)
            if child.model.busy { child.showWindow(nil) } else { child.close() }
        }
        controller.onClosed = { [weak self] in self?.synchronizationWindows.removeValue(forKey: key) }
        synchronizationWindows[key] = controller; guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        if let synchronizationWindowPresentation {synchronizationWindowPresentation(controller)} else {controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)}
    }

    private func showAddProgress(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], mode: WorkingFileAddMode = .normal, backend: GitLibGit2Configuration? = nil, preservePathOrder: Bool = false) {
        guard !retired, !confirmingQuit else { return }
        let id = UUID(), preferences = fileComparisonPreferences
        let capturedBackend = backend ?? GitLibGit2Configuration.load(from: preferences)
        let controller = addProgressWindowFactory?(repository, access, paths, mode, preferences, capturedBackend, preservePathOrder) ?? AddProgressWindowController(repository: repository, access: access, paths: paths, mode: mode, preferences: preferences, backend: capturedBackend, preservePathOrder: preservePathOrder)
        let capturedPreferences = controller.model.preferences
        controller.model.confirmingQuit = confirmingQuit
        controller.model.externalAvailability = { [weak self] in self?.retired == false && self?.confirmingQuit == false }
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller, self.addProgressWindows[id] === controller else { return }
            self.addProgressWindows.removeValue(forKey: id)
        }
        controller.model.onFinished = { [weak self] text, _ in
            self?.refreshRepositoryLogs(repository.root)
            self?.refreshStatusWindows(repository.root)
            self?.commitWindows[repository.root.path]?.model.reload()
            if self?.root?.path == repository.root.path { self?.output = text; Task { await self?.refresh() } }
        }
        controller.model.onCommit = { [weak self, weak controller] in
            guard let self, !self.retired, !self.confirmingQuit else { return }
            self.showCommitDialog(repository: repository, access: access, paths: [], preferences: capturedPreferences, sourceWindow: controller?.window)
        }
        controller.onProgressLog = { [weak self] path in
            guard let self, !self.retired, !self.confirmingQuit else { return }
            self.showLog(repository: repository, access: access, paths: [path], preferences: capturedPreferences)
        }
        addProgressWindows[id] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        if let presentation = addProgressWindowPresentation { presentation(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        controller.model.start()
    }
    private func showClean(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], commandLaunch: Bool = false, preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        if commandLaunch, let existing = cleanWindows.values.first(where: { GitReferenceName.equal($0.model.repository.root.path, repository.root.path) }) {
            existing.window?.makeKeyAndOrderFront(nil)
            error = "A Cleanup dialog is already open. Close it before opening another command-line Cleanup."; return
        }
        let root = repository.root, defaults = preferences ?? fileComparisonPreferences
        let reusable = cleanWindows.first { _, value in !value.model.retired && GitReferenceName.equal(value.model.repository.root.path, root.path) && value.model.presentationPreferences === defaults && value.window?.attachedSheet == nil }
        let key = reusable?.key ?? (cleanWindows[root.path] == nil ? root.path : root.path + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? cleanWindowFactory?(repository) ?? CleanWindowController(repository: repository, defaults: defaults)
        presentation?.apply(to: controller.window)
        let inherited = controller.model.presentationPreferences
        let inheritedPresentation = controller.window.map(MergeWindowPresentation.init)
        let serviceContext=finderServiceDispatch
        controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.cleanWindows[key] === controller else { return }; self.cleanWindows.removeValue(forKey: key) }
        controller.model.setScope(paths)
        controller.model.onAccepted = { [weak self] request in
            guard let self, !self.retired, !self.confirmingQuit else { return }
            let id = UUID(), progress = CleanProgressWindowController(repository: repository, access: access, request: request, preferences: inherited)
            progress.onClosed = { [weak self] in self?.cleanProgressWindows.removeValue(forKey: id) }
            progress.model.onFinished = { [weak self] output, changed in
                guard let self else { return }
                if changed {
                    self.refreshStatusWindows(root)
                    self.commitWindows[root.path]?.model.reload()
                    self.refreshRepositoryLogs(root)
                    if self.root == root { Task { await self.refresh() } }
                }
                if self.root == root { self.output = output }
            }
            inheritedPresentation?.apply(to: progress.window)
            self.cleanProgressWindows[id] = progress
            FinderServicePresentationContext.$current.withValue(serviceContext) {
                guard self.prepareFinderServiceWorkflow(progress,repository:repository,access:access) else{progress.close();return}
                progress.showWindow(nil); progress.window?.makeKeyAndOrderFront(nil); progress.model.start()
            }
        }
        cleanWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showRevert(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        let root = repository.root
        let controller = revertWindows[root.path] ?? RevertWindowController(repository: repository, access: access, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.revertWindows.removeValue(forKey: root.path) }
        controller.model.onFileLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path]) }
        controller.model.onAccepted = { [weak self] entries in self?.showRevertProgress(repository: repository, access: access, entries: entries) }
        controller.model.onCompare = { [weak self,weak controller] paths in self?.showWorkingFiles(repository:repository,access:access,paths:paths,owner:controller?.window) }
        controller.model.importWorkingComparisonMark(try? comparisonMarkStore.acquire(requireSecurityScope:GitRuntime.isAppStoreBuild))
        controller.model.onPreparedFileCompare = { [weak self,weak controller] marked,current in
            guard let controller,!controller.model.retired else {return}
            self?.showPreparedFileComparison(repository:repository,access:access,marked:marked,current:current,owner:controller.window)
        }
        controller.model.commands.onBlame = { [weak self] path in self?.showBlame(repository:repository,access:access,path:path,revision:"HEAD") }
        controller.model.commands.onCompareTwoFiles = { [weak self,weak controller] paths in self?.showWorkingFilePair(repository:repository,access:access,paths:paths,owner:controller?.window) }
        controller.model.commands.onSubmoduleLog = { [weak self] child in self?.showLog(repository:child,access:access,paths:[]) }
        controller.model.onHandleSubmodules = { [weak self] revision,paths in for path in paths {self?.showSubmoduleDiff(repository:repository,access:access,path:path,from:revision)} }
        controller.model.onAction = { [weak self,weak controller] action,paths in
            guard let self,let controller,!controller.model.retired else {return}
            if action.isIgnore {self.showIgnore(repository:repository,access:access,paths:paths,action:action);return}
            if action.isResolve {
                if action == .editConflict,let path = paths.first {self.showConflictEditor(repository:repository,access:access,path:path,owner:controller.window)}
                else {self.showResolve(repository:repository,access:access,paths:paths,quick:action.resolveChoice)}
                return
            }
            switch action {
            case .rename:if let path = paths.first {self.showRename(repository:repository,access:access,source:path)}
            case .move:self.showMove(repository:repository,access:access,paths:paths)
            case .pull:self.showFetch(repository:repository,access:access,isPull:true)
            default:break
            }
        }
        controller.model.onChanged = { [weak self] in
            self?.refreshRepositoryLogs(root);self?.refreshStatusWindows(root);self?.commitWindows[root.path]?.model.reload()
        }

        revertWindows[root.path] = controller
        controller.model.setScope(paths)
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    var submoduleDiffPresentation:((SubmoduleDiffWindowController)->Void)?
    private func showSubmoduleDiff(repository: GitRepository, access: RepositoryAccessLease?, path: String, from: String = "HEAD", to: String? = nil, fromPath: String? = nil, fromIndex: Bool = false, preferences: UserDefaults? = nil, appearance: NSAppearance? = nil, alpha: CGFloat? = nil) {
        guard !retired, !confirmingQuit else { return }
        let defaults = preferences ?? fileComparisonPreferences
        let key = repository.root.path + "\0" + path + "\0" + from + "\0" + (to ?? "Working tree") + "\0" + (fromPath ?? path) + "\0" + String(fromIndex) + "\0git:" + repository.executable.path + "\0preferences:" + String(describing: ObjectIdentifier(defaults))
        let reusable=submoduleDiffWindows[key].flatMap{$0.canReuse ? $0:nil}
        let controller = reusable ?? SubmoduleDiffWindowController(repository: repository, access: access, path: path, from: from, to: to, fromPath:fromPath,fromIndex:fromIndex,preferences:defaults)
        controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.submoduleDiffWindows[key] === controller else { return }; self.submoduleDiffWindows.removeValue(forKey: key) }
        controller.model.onLog = { [weak self] child, hash in self?.showLog(repository: child, access: access, paths: [], endRevision: hash, selectedRevision: hash, preferences: defaults) }
        controller.model.onStatus = { [weak self] child in self?.showStatus(repository: child, access: access, preferences: defaults) }
        controller.model.onCompare = { [weak self] child, old, new in self?.showRevisionComparison(repository: child, access: access, from: old, to: new, preferences: defaults) }
        controller.model.onConflict={ [weak self,weak controller] in
            guard let controller else{return}
            controller.closeForConflict { [weak self] in
                guard let self,!self.retired,!self.confirmingQuit else{return}
                self.showConflictEditor(repository:repository,access:access,path:path,preferences:defaults,commandLaunch:true)
            }
        }
        controller.onAttemptCompleted = { [weak self] result in
            guard !result.entries.isEmpty else { return }
            self?.refreshAfterSubmoduleMutation(repository.root, output: result.output)
        }
        controller.onBisect = { [weak self] in self?.showBisect(repository: repository, access: access, operation: $0, preferences: defaults) }
        submoduleDiffWindows[key] = controller
        if let appearance { controller.window?.appearance = appearance }
        if let alpha { controller.window?.alphaValue = alpha }
        if let submoduleDiffPresentation {submoduleDiffPresentation(controller)} else {controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)}
        controller.model.load()
    }
    func showRevisionComparison(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision, paths: [String] = [], preferences: UserDefaults? = nil) {
        let baseKey = repository.root.path + "\0" + from.label + "\0" + to.label + "\0scope\0" + paths.joined(separator: "\0")
        let reusable = revisionComparisonWindows.first { _, controller in
            controller.model.repository.root == repository.root && controller.model.repository.executable == repository.executable &&
            controller.model.preferences === (preferences ?? fileComparisonPreferences) && controller.model.alternateTool == ComparisonToolInvocation.alternate && controller.window?.attachedSheet == nil && controller.model.canReuseForComparison(from: from, to: to, paths: paths)
        }
        let key = reusable?.key ?? (revisionComparisonWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? RevisionComparisonWindowController(repository: repository, access: access, from: from, to: to, paths: paths, preferences: preferences ?? fileComparisonPreferences)
        controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.revisionComparisonWindows[key] === controller else { return }; self.revisionComparisonWindows.removeValue(forKey: key) }
        configureRevisionComparisonInteractions(controller.model, repository: repository, access: access)
        revisionComparisonWindows[key] = controller
        controller.model.load()
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        if let revisionComparisonWindowPresentation {revisionComparisonWindowPresentation(controller)} else {controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)}
    }
    private func showRevisionGraph(repository: GitRepository, access: RepositoryAccessLease?) {
        guard !retired,!confirmingQuit else{return}
        let preferences=finderWorkflowPreferences,base=repository.root.path+"\0"+repository.executable.path
        let reusable=revisionGraphWindows.first {_,controller in controller.canReuse && controller.model.repository.root.path==repository.root.path && controller.model.repository.executable.path==repository.executable.path && controller.model.preferences === preferences}
        if let existing=reusable?.value {guard prepareFinderServiceWorkflow(existing,repository:repository,access:access) else{return};existing.showWindow(nil);existing.window?.makeKeyAndOrderFront(nil);return}
        let key=revisionGraphWindows[base]==nil ? base:base+"\0"+UUID().uuidString
        let controller=revisionGraphWindowFactory?(repository,access,preferences,false) ?? RevisionGraphWindowController(repository:repository,access:access,preferences:preferences,automaticallyLoad:false)
        controller.onClosed={ [weak self,weak controller] in guard let self,let controller,self.revisionGraphWindows[key] === controller else{return};self.revisionGraphWindows.removeValue(forKey:key)}
        let serviceContext=finderServiceDispatch
        let show:(()->Void)->Void={body in FinderServicePresentationContext.$current.withValue(serviceContext){body()}}
        controller.model.onLog = { [weak self,weak controller] hash in show {self?.showLog(repository: repository, access: access, paths: [], endRevision: hash, selectedRevision: hash, preferences: preferences, sourceWindow: controller?.window)} }
        controller.model.onBrowse = { [weak self] hash in show {self?.showRepositoryBrowser(repository: repository, access: access, revision: hash, preferences: preferences)} }
        controller.model.onCompare = { [weak self] from, to in show {self?.showRevisionComparison(repository: repository, access: access, from: from, to: to, preferences: preferences)} }
        controller.model.onCheckout = { [weak self] hash in show {self?.showSwitch(repository: repository, access: access, revision: hash, preferences: preferences)} }
        controller.model.onLogRange = { [weak self] range in show {self?.showLog(repository: repository, access: access, paths: [], revisionRange: range, preferences: preferences)} }
        controller.model.onSwitchBranch = { [weak self, weak controller] reference in
            guard let parent = controller?.window, parent.attachedSheet == nil else { return }
            self?.showSwitchProgress(repository: repository, access: access, reference: reference, parent: parent, preferences: preferences, completion: { [weak controller] in controller?.model.load() })
        }
        revisionGraphWindows[key]=controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
        if controller.canReuse {controller.model.load()}
    }
    private func configureSelectableLog(_ log: LogWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        let preferences = log.colorPreferences
        configureLogMenus(log, repository: repository, access: access)
        configureLogBisect(log, repository: repository, access: access, refreshPicker: true)
        log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        log.onHistoryPush = { [weak self] revision, all in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: all) }
        log.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        log.onCreateReference = { [weak self] tag, revision in self?.showReference(repository: repository, access: access, isTag: tag, revision: revision) }
        log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision, preferences: preferences) }
        log.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision) }
        configureLogIntegration(log,repository:repository,access:access)
        log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision, preferences: preferences) }
        log.onCherryPick = { [weak self] revisions in self?.showRebase(repository: repository, access: access, cherryPick: revisions) }
        log.onCombineRevisions = { [weak self, weak log] entries, offset, head in self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: log?.window) }
        configureLogRevert(log,repository:repository,access:access)
        log.onFormatPatch={ [weak self] preset in self?.showFormatPatch(repository:repository,access:access,preset:preset) }
        log.onBrowseRepository={ [weak self] hash in self?.showRepositoryBrowser(repository:repository,access:access,revision:hash) }
        log.onContainingLog={ [weak self] name,select,range in
            self?.showLog(repository:repository,access:access,paths:[],endRevision:name,selectedRevision:select ? name:nil,revisionRange:range)
        }
        log.importWorkingComparisonMark(try? comparisonMarkStore.acquire(requireSecurityScope:GitRuntime.isAppStoreBuild))
        log.onPreparedFileCompare={ [weak self,weak log] marked,current in
            guard let owner=log?.window else {return};self?.showPreparedFileComparison(repository:repository,access:access,marked:marked,current:current,owner:owner)
        }
        log.onFilePairCompare={ [weak self,weak log] revision,files in
            guard let owner=log?.window else {return};self?.showHistoricalFilePair(repository:repository,access:access,revision:revision,files:files,owner:owner)
        }
        log.onFileCompare={ [weak self,weak log] from,to,paths in
            guard let owner=log?.window else {return};self?.showHistoricalFiles(repository:repository,access:access,from:from,to:to,paths:paths,owner:owner)
        }
        log.onFileComparisons={ [weak self,weak log] requests in
            guard let owner=log?.window else {return};self?.showGroupedHistoricalFiles(repository:repository,access:access,requests:requests,owner:owner)
        }
        log.onFileLog={ [weak self] path,hash in self?.showLog(repository:repository,access:access,paths:[path],endRevision:hash) }
        log.onSubmoduleFileLog={ [weak self,weak log] checkout,hash in
            let child=log?.acceptedNavigationRepository ?? GitRepository(root:checkout,executable:repository.executable,askpass:repository.askpass,diffDetection:repository.diffDetection,libgit2Configuration:repository.libgit2Configuration)
            self?.showLog(repository:child,access:access,paths:[],endRevision:hash,selectedRevision:hash,preferences:log?.colorPreferences)
        }
        log.onBlame={ [weak self] path,hash in self?.showBlame(repository:repository,access:access,path:path,revision:hash) }
        log.onRevisionChanged={ [weak self] output in
            guard let self else {return}
            self.refreshRepositoryLogs(repository.root)
            self.refreshStatusWindows(repository.root);self.commitWindows[repository.root.path]?.model.reload();self.rebaseWindows[repository.root.path]?.model.refreshState()
            if self.root==repository.root {self.output=output;Task{await self.refresh()}}
        }
    }
    private func configureRevisionComparisonInteractions(_ model: RevisionComparisonWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        let preferences = model.preferences
        model.configureReferencePicker = { [weak self] picker in self?.configureReferenceBrowser(picker, repository: repository, access: access) }
        model.configureLogPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        model.onBlame={ [weak self] path,revision in self?.showBlame(repository:repository,access:access,path:path,revision:revision,preferences:preferences) }
        model.onSubmoduleLog={ [weak self,weak model] checkout,revision in
            let child=model?.acceptedNavigationRepository ?? GitRepository(root:checkout,executable:repository.executable,askpass:repository.askpass,diffDetection:repository.diffDetection,libgit2Configuration:repository.libgit2Configuration)
            self?.showLog(repository:child,access:access,paths:[],endRevision:revision,selectedRevision:revision,preferences:preferences)
        }
        model.onFilesChanged={ [weak self] in
            self?.refreshRepositoryLogs(repository.root);self?.refreshStatusWindows(repository.root);self?.commitWindows[repository.root.path]?.model.reload()
            if self?.root==repository.root {Task{await self?.refresh()}}
        }
        model.onLogRange = { [weak self] range in self?.showLog(repository:repository,access:access,paths:[],revisionRange:range,preferences:preferences) }
        model.onLog = { [weak self] hash in self?.showLog(repository: repository, access: access, paths: [], endRevision: hash,preferences:preferences) }
        model.onFileLog = { [weak self] path, hash in self?.showLog(repository: repository, access: access, paths: [path], endRevision: hash,preferences:preferences) }
        model.onSubmoduleCompare = { [weak self] path, oldPath, old, new in
            let from = old == .emptyTree ? "" : old == .workingTree ? "Working tree" : old.label
            let to = new == .emptyTree ? "" : new == .workingTree ? nil : new.label
            self?.showSubmoduleDiff(repository: repository, access: access, path: path, from: from, to: to,fromPath:oldPath,preferences:preferences)
        }
    }
    var browserWindowPresentation: ((RepositoryBrowserWindowController) -> Void)?
    var fileComparisonWindowPresentation: ((FileComparisonWindowController) -> Void)?
    var logWindowPresentation: ((LogWindowController) -> Void)?
    var referenceLogWindowPresentation: ((ReferenceLogWindowController) -> Void)?
    var synchronizationWindowPresentation: ((SynchronizationWindowController) -> Void)?
    var revisionComparisonWindowPresentation: ((RevisionComparisonWindowController) -> Void)?
    var submoduleUpdateWindowPresentation: ((SubmoduleUpdateWindowController) -> Void)?
    var bisectWindowPresentation: ((BisectWindowController) -> Void)?
    var exportWindowPresentation: ((ExportWindowController) -> Void)?
    var captureCommandMaterializationBackend:(()->GitLibGit2Configuration)?
    var fileComparisonPreferences: UserDefaults = .standard
    var fileComparisonQuestion: ((Int) async -> Bool)?
    var fileComparisonPresentation: ((RevisionComparisonSnapshot, CommitFile) -> Void)?
    var commitChangeSetPresentation: ((CommitChangeSetComparison) -> Void)?
    private func showCommitChangeSets(repository:GitRepository,access:RepositoryAccessLease?,comparison:CommitChangeSetComparison,preferences:UserDefaults? = nil) {
        let defaults=preferences ?? fileComparisonPreferences
        guard !confirmingQuit else { return }
        if let commitChangeSetPresentation { commitChangeSetPresentation(comparison);return }
        let key=repository.root.path+"\0changesets\0"+comparison.snapshot.from.label+"\0"+comparison.snapshot.to.label+"\0"+ComparisonToolInvocation.cacheKey+"\0preferences:"+String(describing:ObjectIdentifier(defaults))
        let cached=fileComparisonWindows[key].flatMap { $0.model.inputEncodingOwnerRetired ? nil:$0 }
        let controller=cached ?? FileComparisonWindowController(repository:repository,access:access,changeSets:comparison,preferences:defaults)
        controller.model.comparisonDefaults=defaults
        controller.onClosed={ [weak self,weak controller] in
            guard let self,let controller,self.fileComparisonWindows[key] === controller else { return }
            self.fileComparisonWindows.removeValue(forKey:key)
        }
        fileComparisonWindows[key]=controller;controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
    }
    private var fileComparisonSessions: [UUID: FileListComparisonSession] = [:]
    private func prepareFileComparisons(repository: GitRepository, access: RepositoryAccessLease?, selectedCount: Int, owner: NSWindow?, preferences: UserDefaults? = nil, capturedOwner: Bool = false, operation: @escaping (OperationCancellation) async throws -> Void) {
        guard !retired, !busy, !confirmingQuit else { return }
        let id = UUID(), session = FileListComparisonSession(window: capturedOwner ? owner : owner ?? (finderServiceDispatch != nil ? workspaceWindow : NSApp.keyWindow ?? workspaceWindow), preferences: preferences ?? fileComparisonPreferences)
        session.confirmation = fileComparisonQuestion
        fileComparisonSessions[id] = session; busy = true
        Task {
            defer { fileComparisonSessions.removeValue(forKey: id); busy = false; withExtendedLifetime(access) {} }
            do {
                try await session.run(selectedCount: selectedCount) { [self] token in
                    guard !confirmingQuit else { return }
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    try await operation(token)
                }
            } catch { if !session.cancellation.isCancelled, !confirmingQuit { self.error = error.localizedDescription } }
        }
    }
    func showFileComparisons(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, owner: NSWindow? = nil, preferences: UserDefaults? = nil) {
        prepareFileComparisons(repository: repository, access: access, selectedCount: snapshot.files.count, owner: owner, preferences: preferences) { [self] token in
            presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token, preferences: preferences)
        }
    }
    /// A Blame parent can attribute several files, each with its own old path.
    /// Accept the complete ordered request once: individual workspace launches
    /// would set busy on the first file and silently reject every later origin.
    func showOwnedFileComparisons(repository: GitRepository, access: RepositoryAccessLease?, snapshots: [RevisionComparisonSnapshot], owner: NSWindow?, preferences: UserDefaults, alternate: Bool, cancellation: OperationCancellation) async throws {
        try cancellation.check()
        guard !retired, !busy, !confirmingQuit, !snapshots.isEmpty,
              snapshots.allSatisfy({ $0.root == repository.root && !$0.files.isEmpty }),
              let owner, owner.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        let capturedRepository = repository.capturingDiffBackend(preferences: preferences)
        let appearance = owner.effectiveAppearance, alpha = owner.alphaValue
        let id = UUID(), session = FileListComparisonSession(window: owner, preferences: preferences, cancellation: cancellation, alternateTool: alternate)
        session.confirmation = fileComparisonQuestion
        fileComparisonSessions[id] = session; busy = true
        defer { fileComparisonSessions.removeValue(forKey: id); busy = false; withExtendedLifetime(access) {} }
        try await session.run(selectedCount: snapshots.reduce(0) { $0 + $1.files.count }) { [self] token in
            try token.check()
            guard !retired, !confirmingQuit else { throw OperationCancellationFailure.cancelled }
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            for snapshot in snapshots {
                try token.check()
                guard !retired, !confirmingQuit else { throw OperationCancellationFailure.cancelled }
                presentFileComparisons(repository: capturedRepository, access: access, snapshot: snapshot, cancellation: token, preferences: preferences, appearance: appearance, alpha: alpha)
            }
        }
    }
    func showWorkingFiles(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], amendToParent: Bool = false, owner: NSWindow? = nil, line: Int? = nil) {
        let conflicts = paths.filter { path in entries.contains { GitReferenceName.equal($0.path,path) && $0.state == .conflicted } }
        let conflictPaths = GitPathSet(conflicts)
        let ordinary = paths.filter { !conflictPaths.contains($0) }
        prepareFileComparisons(repository: repository, access: access, selectedCount: paths.count, owner: owner) { [self] token in
            for path in conflicts {
                guard !token.isCancelled, !confirmingQuit else { return }
                showConflictEditor(repository: repository, access: access, path: path, owner: owner)
            }
            guard !ordinary.isEmpty else { return }
            let snapshot = try await repository.workingFileComparison(paths: ordinary, amendToParent: amendToParent, cancellation: token)
            if snapshot.files.isEmpty { output = "No changes for the selected files."; return }
            presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token, line: line)
        }
    }
    func showPreviousDiff(repository: GitRepository, access: RepositoryAccessLease?, path: String, owner: NSWindow? = nil, unified: Bool = false) {
        let alternate = ComparisonToolInvocation.capture, preferences = fileComparisonPreferences
        let repository=repository.capturingDiffBackend(preferences:preferences)
        prepareFileComparisons(repository: repository, access: access, selectedCount: 1, owner: owner) { [self] token in
            let base = try await repository.previousDiffBase(path: path, cancellation: token)
            guard !confirmingQuit, !token.isCancelled else { return }
            if base.directory {
                showRevisionComparison(repository: repository, access: access, from: .revision(base.revision), to: .workingTree, paths: [path])
            } else if unified {
                let bytes = try await repository.commandUnifiedDiff(from: base.revision, to: nil, paths: [path], cancellation: token)
                try await presentCommandUnifiedDiff(bytes, title: base.revision + " → Working tree", repository: repository, access: access, alternate: alternate, preferences: preferences, cancellation: token)
            } else {
                let snapshot = try await repository.revisionFileComparison(from: .revision(base.revision), to: .workingTree, paths: [path], cancellation: token)
                guard !confirmingQuit, !token.isCancelled else { return }
                presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token)
            }
        }
    }
    func showWorkingFilePair(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], owner: NSWindow? = nil) {
        prepareFileComparisons(repository: repository, access: access, selectedCount: paths.count, owner: owner) { [self] token in
            let snapshot = try await repository.workingFilePairComparison(paths: paths, cancellation: token)
            presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token)
        }
    }
    func showPreparedFileComparison(repository: GitRepository, access: RepositoryAccessLease?, marked: PreparedFileComparisonMark, current: PreparedFileComparisonMark, owner: NSWindow? = nil, preferences: UserDefaults? = nil) {
        let defaults = preferences ?? fileComparisonPreferences
        let appearance = owner?.effectiveAppearance, alpha = owner?.alphaValue
        prepareFileComparisons(repository: repository, access: access, selectedCount: 2, owner: owner, preferences: defaults, capturedOwner: owner != nil) { [self] token in
            if current.isDirectory || marked.isDirectory {
                guard current.isDirectory,marked.workingAccess == nil else {throw SubmoduleComparisonFailure.unsupported}
                try token.check()
                showSubmoduleDiff(repository:repository,access:access,path:current.path,
                    from:marked.revision.isEmpty ? "Working tree":marked.revision,
                    to:current.revision.isEmpty ? nil:current.revision,
                    fromPath:marked.path,fromIndex:marked.revision.isEmpty && current.revision.isEmpty,preferences:defaults,appearance:appearance,alpha:alpha)
                return
            }
            if let workingAccess = marked.workingAccess {
                if GitRuntime.isAppStoreBuild && (!workingAccess.permission.hasSecurityScope || !workingAccess.permission.contains(workingAccess.file)) { throw RepositoryAccessFailure.securityScopeUnavailable }
                guard !retired, !token.isCancelled, !confirmingQuit else { return }
                let key = "historical-working:" + UUID().uuidString
                let controller: FileComparisonWindowController
                if current.revision.isEmpty {
                    let file = repository.root.appendingPathComponent(current.path)
                    if GitRuntime.isAppStoreBuild && access?.contains(file) != true { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let comparison = try WorkingFileComparison(base: workingAccess.file, destination: file)
                    _ = try comparison.read()
                    controller = FileComparisonWindowController(comparison: comparison, permissions: [workingAccess.permission] + [access].compactMap { $0 }, preferences: defaults)
                } else {
                    let comparison = try await repository.historicalWorkingFileComparison(revision: current.revision, path: current.path, workingFile: workingAccess.file, cancellation: token)
                    controller = FileComparisonWindowController(repository: repository, access: access, comparison: comparison, permission: workingAccess.permission, preferences: defaults)
                }
                guard !retired, !token.isCancelled, !confirmingQuit else { return }
                controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.fileComparisonWindows[key] === controller else { return }; self.fileComparisonWindows.removeValue(forKey: key) }
                fileComparisonWindows[key] = controller
                controller.window?.appearance = appearance
                if let alpha { controller.window?.alphaValue = alpha }
                if let fileComparisonWindowPresentation { fileComparisonWindowPresentation(controller) }
                else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
                _ = try comparisonMarkStore.consume(workingAccess.mark.id)
                try publishComparisonMark()
            } else {
                let snapshot = try await repository.preparedPathComparison(from: marked.revision.isEmpty ? .workingTree : .revision(marked.revision), fromPath: marked.path, to: current.revision.isEmpty ? .workingTree : .revision(current.revision), toPath: current.path, cancellation: token)
                presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token, preferences: defaults, appearance: appearance, alpha: alpha)
            }
        }
    }
    func showHistoricalFilePair(repository: GitRepository, access: RepositoryAccessLease?, revision: String, files: [CommitFile], owner: NSWindow? = nil) {
        prepareFileComparisons(repository: repository, access: access, selectedCount: files.count, owner: owner) { [self] token in
            let snapshot = try await repository.historicalFilePairComparison(revision: revision, files: files, cancellation: token)
            presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token)
        }
    }
    func showGroupedHistoricalFiles(repository: GitRepository, access: RepositoryAccessLease?, requests: [(ComparisonRevision, ComparisonRevision, [String])], owner: NSWindow? = nil) {
        guard !requests.isEmpty else { return }
        prepareFileComparisons(repository: repository, access: access, selectedCount: requests.reduce(0) { $0 + $1.2.count }, owner: owner) { [self] token in
            var snapshots: [RevisionComparisonSnapshot] = []
            for (from, to, paths) in requests {
                guard !token.isCancelled, !confirmingQuit else { return }
                snapshots.append(try await repository.revisionFileComparison(from: from, to: to, paths: paths, cancellation: token))
            }
            for snapshot in snapshots { presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token) }
        }
    }
    func showHistoricalFiles(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision, paths: [String], owner: NSWindow? = nil, line: Int? = nil, preferences: UserDefaults? = nil) {
        let defaults = preferences ?? fileComparisonPreferences
        let appearance = owner?.effectiveAppearance, alpha = owner?.alphaValue
        prepareFileComparisons(repository: repository, access: access, selectedCount: paths.count, owner: owner, preferences: defaults, capturedOwner: owner != nil) { [self] token in
            let snapshot = try await repository.revisionFileComparison(from: from, to: to, paths: paths, cancellation: token)
            if snapshot.files.isEmpty { output = "No files exist at the selected comparison paths."; return }
            presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token, line: line, preferences: defaults, appearance: appearance, alpha: alpha)
        }
    }
    private func presentFileComparisons(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, cancellation: OperationCancellation, line: Int? = nil, preferences: UserDefaults? = nil, appearance: NSAppearance? = nil, alpha: CGFloat? = nil) {
        let defaults = preferences ?? fileComparisonPreferences
        for file in snapshot.files {
            guard !retired, !confirmingQuit, !cancellation.isCancelled else { return }
            if let fileComparisonPresentation { fileComparisonPresentation(snapshot, file); continue }
            if file.isSubmodule {
                showSubmoduleDiff(repository: repository, access: access, path: file.path, from: snapshot.from == .emptyTree ? "" : snapshot.from.label, to: snapshot.to == .workingTree ? nil : snapshot.to == .emptyTree ? "" : snapshot.to.label,fromPath:file.oldPath,preferences:defaults,appearance:appearance,alpha:alpha)
                continue
            }
            let key = repository.root.path + "\0" + file.path + "\0" + (file.oldPath ?? file.path) + "\0action\0" + file.action + "\0" + snapshot.from.label + "\0" + snapshot.to.label + "\0" + ComparisonToolInvocation.cacheKey + "\0preferences:" + String(describing: ObjectIdentifier(defaults)) + (line.map { "\0line\0" + String($0) + "\0" + UUID().uuidString } ?? "")
            let cached = fileComparisonWindows[key].flatMap { $0.model.inputEncodingOwnerRetired ? nil : $0 }
            let controller = cached ?? FileComparisonWindowController(repository: repository, access: access, snapshot: snapshot, path: file.path, preferences: defaults, line: line)
            controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.fileComparisonWindows[key] === controller else { return }; self.fileComparisonWindows.removeValue(forKey: key) }
            fileComparisonWindows[key] = controller
            controller.model.comparisonDefaults = defaults
            if let appearance { controller.window?.appearance = appearance }
            if let alpha { controller.window?.alphaValue = alpha }
            guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
            if let fileComparisonWindowPresentation { fileComparisonWindowPresentation(controller) }
            else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        }
    }
    private func refreshAfterSubmoduleMutation(_ root: URL, output: String) {
        refreshRepositoryLogs(root)
        refreshStatusWindows(root)
        commitWindows[root.path]?.model.reload()
        rebaseWindows[root.path]?.model.refreshState()
        if self.root == root { self.output = output; Task { await self.refresh() } }
    }
    private func showSubmoduleSync(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], commandLaunch: Bool = false) {
        guard !retired,!confirmingQuit else { return }
        if let existing = submoduleSyncWindows.values.first(where: { $0.model.repository.root == repository.root && $0.model.activeOperation }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            if commandLaunch { error = "A Submodule Sync operation is already running. Wait for it before opening another command." }; return
        }
        let id = UUID(), controller = SubmoduleSyncWindowController(repository: repository, access: access, scope: scope, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.submoduleSyncWindows.removeValue(forKey: id) }
        controller.model.onAttemptCompleted = { [weak self] result in
            guard !result.entries.isEmpty else { return }
            self?.refreshAfterSubmoduleMutation(repository.root, output: result.output)
        }
        submoduleSyncWindows[id] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
    }
    private func showSubmoduleAdd(repository: GitRepository, access: RepositoryAccessLease?, path: String, commandLaunch: Bool = false) {
        guard !retired,!confirmingQuit else { return }
        let key = repository.root.path + (finderServiceDispatch == nil ? "":"\0service:"+path)
        if commandLaunch, let existing = submoduleAddWindows[key] {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "A Submodule Add dialog is already open. Close it before opening another command-line Submodule Add."; return
        }
        if commandLaunch, let existing = submoduleAddProgressWindows.values.first(where: { $0.model.repository.root == repository.root && $0.model.activeOperation }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "A Submodule Add operation is already running. Wait for it before opening another command."; return
        }
        guard submoduleAddWindows[key]?.finderServiceCanPresent != false else{error="The previous Submodule Add window is still closing. Wait for it to finish.";return}
        let controller = submoduleAddWindows[key] ?? SubmoduleAddWindowController(repository: repository, access: access, path: path, preferences: fileComparisonPreferences, clipboardText:creationClipboardText())
        controller.onClosed = { [weak self] in self?.submoduleAddWindows.removeValue(forKey: key) }
        let serviceContext=finderServiceDispatch
        controller.model.onSubmit = { [weak self] progress in
            FinderServicePresentationContext.$current.withValue(serviceContext){self?.showSubmoduleAddProgress(model:progress,access:access)}
        }
        submoduleAddWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showSubmoduleAddProgress(model: SubmoduleAddProgressWindowModel,access:RepositoryAccessLease?) {
        guard !retired,!confirmingQuit else{return}
        let root = model.repository.root, id = UUID()
        let controller = SubmoduleAddProgressWindowController(model: model)
        controller.onClosed = { [weak self] in self?.submoduleAddProgressWindows.removeValue(forKey: id) }
        model.onAttemptCompleted = { [weak self] result in
            guard result.attempted else { return }
            self?.refreshAfterSubmoduleMutation(root, output: result.output)
        }
        submoduleAddProgressWindows[id] = controller
        guard prepareFinderServiceWorkflow(controller,repository:model.repository,access:access) else{controller.close();return}
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); model.start()
    }
    private func showSubmoduleUpdate(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], selected: [String] = [], commandLaunch: Bool = false, completion: (() -> Void)? = nil, preferences: UserDefaults? = nil, sourceWindow: NSWindow? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let preferences = preferences ?? fileComparisonPreferences
        let root = repository.root, key = root.path + "\0" + scope.joined(separator: "\0") + "\0" + selected.joined(separator: "\0") + "\0preferences:" + String(describing: ObjectIdentifier(preferences))
        if commandLaunch, let existing = submoduleUpdateWindows.values.first(where: { $0.model.repository.root == root }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "A Submodule Update dialog is already open. Close it before opening another command-line Submodule Update."; return
        }
        if commandLaunch, let existing = submoduleUpdateProgressWindows.values.first(where: { $0.model.repository.root == root && $0.model.activeOperation }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "A Submodule Update operation is already running. Wait for it before opening another command."; return
        }
        guard submoduleUpdateWindows[key]?.finderServiceCanPresent != false else{error="The previous Submodule Update window is still closing. Wait for it to finish.";return}
        let controller = submoduleUpdateWindows[key] ?? SubmoduleUpdateWindowController(repository: repository, access: access, scope: scope, selected: selected, preferences: preferences)
        presentation?.apply(to: controller.window)
        if let sourceWindow {controller.window?.alphaValue=sourceWindow.alphaValue;controller.window?.appearance=sourceWindow.effectiveAppearance}
        controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.submoduleUpdateWindows[key] === controller else { return }; self.submoduleUpdateWindows.removeValue(forKey: key) }
        let progressPreferences = controller.model.presentationPreferences
        let progressPresentation = controller.window.map(MergeWindowPresentation.init)
        let serviceContext=finderServiceDispatch
        controller.model.onSubmit = { [weak self] paths, options in
            FinderServicePresentationContext.$current.withValue(serviceContext){
                self?.showSubmoduleUpdateProgress(repository:repository,access:access,paths:paths,options:options,completion:completion,preferences:progressPreferences,presentation:progressPresentation)
            }
        }
        submoduleUpdateWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        if let submoduleUpdateWindowPresentation { submoduleUpdateWindowPresentation(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
    }
    private func showSubmoduleUpdateProgress(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], options: SubmoduleUpdateOptions, completion: (() -> Void)? = nil, preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let root = repository.root, id = UUID()
        let controller = SubmoduleUpdateProgressWindowController(repository: repository, access: access, paths: paths, options: options, preferences: preferences ?? fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.submoduleUpdateProgressWindows.removeValue(forKey: id) }
        controller.model.onAttemptCompleted = { [weak self] result in
            guard !result.entries.isEmpty else { return }
            self?.refreshAfterSubmoduleMutation(root, output: result.output)
        }
        controller.model.onUpdated = { _ in completion?() }
        let inherited = controller.model.presentationPreferences
        controller.model.onBisect = { [weak self] operation in self?.showBisect(repository: repository, access: access, operation: operation, preferences: inherited) }
        presentation?.apply(to: controller.window)
        submoduleUpdateProgressWindows[id] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
    }
    @discardableResult private func showRevertProgress(repository: GitRepository, access: RepositoryAccessLease?, entries: [StatusEntry], amend: Bool = false, againstHead: Bool = false, autoCloseSuccess: Bool = false, policy: WorkingFileRevertPolicy? = nil, completion: @escaping (Bool) -> Void = { _ in }) -> RevertProgressWindowController {
        let root = repository.root, id = UUID()
        let controller = RevertProgressWindowController(repository: repository, access: access, entries: entries, amend: amend, againstHead: againstHead, autoCloseSuccess: autoCloseSuccess, preferences:fileComparisonPreferences, policy: policy)
        controller.model.confirmingQuit=confirmingQuit
        controller.model.externalAvailability={ [weak self] in self?.retired == false && self?.confirmingQuit == false }
        let preferences=controller.model.preferences
        controller.onProgressLog={ [weak self] path in
            guard let self,!self.retired,!self.confirmingQuit else{return}
            self.showLog(repository:repository,access:access,paths:[path],preferences:preferences)
        }
        controller.onClosed = { [weak self] in self?.revertProgressWindows.removeValue(forKey: id) }
        controller.model.onFinished = { [weak self] output, succeeded in
            completion(succeeded)
            self?.refreshRepositoryLogs(root)
            self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onHandleSubmodules = { [weak self] revision, paths in
            for path in paths { self?.showSubmoduleDiff(repository: repository, access: access, path: path, from: revision) }
        }
        revertProgressWindows[id] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
        return controller
    }
    private func refreshStatusWindows(_ root: URL) {
        finderWatches?.refresh(repository:root)
        for controller in statusWindows.values where controller.model.repository.root == root { controller.model.requestReload() }
    }
    private func renameStatusPaths(_ root: URL, from source: String, to destination: String) {
        for controller in statusWindows.values where controller.model.repository.root == root { controller.model.didRename(source, to: destination) }
    }
    private func showStatus(repository: GitRepository, access: RepositoryAccessLease?, paths: [String] = [], preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let root = repository.root, preferences = preferences ?? fileComparisonPreferences
        section = .status
        let reusable = statusWindows.first { _, controller in
            controller.model.repository.root == root && controller.model.repository.executable == repository.executable &&
            controller.model.colorPreferences === preferences && !controller.model.retired
        }
        let key = reusable?.key ?? (statusWindows[root.path] == nil ? root.path : root.path + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? StatusWindowController(repository: repository, access: access, defaults: preferences)
        controller.onPullAfterLFSLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.onClosed = { [weak self, weak controller] in if self?.statusWindows[key] === controller { self?.statusWindows.removeValue(forKey: key) } }
        controller.model.onCopyAdd = { [weak self] paths in self?.showCopy(repository: repository, access: access, sources: paths.map { repository.root.appendingPathComponent($0) }) }
        controller.model.onPasteFiles = { [weak self] copy, urls in self?.showFileTransfer(copy: copy, repository: repository, access: access, urls: urls) }
        controller.model.onTransferDrop = { [weak self, weak controller] providers in
            guard let controller, !controller.model.retired, !controller.model.busy, !controller.model.confirmingQuit else { return false }
            return self?.receiveTransferDrop(providers, repository: repository, access: access, owner: controller.window) ?? false
        }
        controller.model.onAction = { [weak self, weak controller] action, paths in
            guard let self else { return }
            if action == .diff { self.showWorkingFiles(repository: repository, access: access, paths: paths, owner: controller?.window); return }
            guard let controller, !controller.model.retired else { return }
            // Working Tree belongs to this repository even when the workspace is displaying another one.
            switch action {
            case .remove, .removeKeep: self.showRemove(repository: repository, access: access, paths: paths, keepLocal: action == .removeKeep); return
            case .move: self.showMove(repository: repository, access: access, paths: paths); return
            case .stash: self.showStash(repository: repository, access: access, preferences: preferences); return
            case .stashPop: self.showStashRestore(repository: repository, access: access, pop: true, showChanges: 2, preferences: preferences); return
            case .stashApply: self.showStashRestore(repository: repository, access: access, pop: false, showChanges: 0, preferences: preferences); return
            case .stashList: self.showReferenceLog(repository: repository, access: access, reference: "refs/stash"); return
            case .switchBranch: self.showSwitch(repository: repository, access: access); return
            case .commit: self.showCommitDialog(repository: repository, access: access, paths: paths); return
            default: break
            }
            if self.root != root, let access {
                self.openSession(access, action: action, actionPaths: paths); return
            }
            self.activate(action, paths: paths)
            if action != .clean && action != .add && action != .diff && action != .submoduleSync && action != .submoduleAdd && action != .submoduleUpdate && action != .commit && action != .revert && action != .log && action != .switchBranch && action != .branch && action != .tag && action != .push && action != .fetch && action != .pull && action != .rebase && action != .merge && action != .mergeAbort && action != .export && action != .bisect && action != .bisectStart && action.bisectOperation == nil && action != .stash && action != .stashApply && action != .stashPop && action != .stashList && action != .reflog && action != .rename && !action.isIgnore && !action.isResolve && action != .reset { self.workspaceWindow?.makeKeyAndOrderFront(nil) }
        }
        controller.model.onAddFiles = { [weak self] paths, mode in self?.showAddProgress(repository:repository, access:access, paths:paths, mode:mode, preservePathOrder:true) }
        controller.model.onSubmoduleLog = { [weak self] child in self?.showLog(repository: child, access: access, paths: []) }
        controller.model.onBlame = { [weak self] path in self?.showBlame(repository: repository, access: access, path: path, revision: "HEAD") }
        controller.model.onCompareTwoFiles = { [weak self, weak controller] paths in guard let controller else { return }; self?.showWorkingFilePair(repository: repository, access: access, paths: paths, owner: controller.window) }
        controller.model.onChanged = { [weak self] in Task { await self?.refresh() } }
        presentation?.apply(to: controller.window)
        statusWindows[key] = controller
        controller.model.setScope(paths)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showReferenceLog(repository: GitRepository, access: RepositoryAccessLease?, reference: String, preferences:UserDefaults?=nil) {
        let root=repository.root,requestedPreferences=preferences ?? finderWorkflowPreferences
        let reusable=referenceLogWindows.first {_,controller in
            controller.canReuse && controller.model.repository.root.path==root.path && controller.model.repository.executable.path==repository.executable.path && controller.model.preferences === requestedPreferences && controller.model.canRefresh && controller.window?.attachedSheet==nil
        }
        let key=reusable?.key ?? (referenceLogWindows[root.path]==nil ? root.path:root.path+"\0context\0"+UUID().uuidString)
        let controller=reusable?.value ?? ReferenceLogWindowController(repository:repository,access:access,reference:reference,preferences:requestedPreferences)
        let operationPreferences=controller.model.preferences
        controller.onClosed = { [weak self,weak controller] in guard let self,let controller,self.referenceLogWindows[key] === controller else{return};self.referenceLogWindows.removeValue(forKey:key) }
        let serviceContext=finderServiceDispatch
        let show:(()->Void)->Void={body in FinderServicePresentationContext.$current.withValue(serviceContext){body()}}
        controller.model.onLog = { [weak self,weak controller] hash in show {self?.showLog(repository: repository, access: access, paths: [], endRevision: hash, selectedRevision: hash, preferences: operationPreferences, sourceWindow: controller?.window)} }
        controller.model.onLogRange = { [weak self] range in show {self?.showLog(repository: repository, access: access, paths: [], revisionRange: range, preferences: operationPreferences)} }
        controller.model.onBrowseRepository = { [weak self] hash in show {self?.showRepositoryBrowser(repository: repository, access: access, revision: hash, preferences: operationPreferences)} }
        controller.model.onCreateReference = { [weak self] isTag, hash in show {self?.showReference(repository: repository, access: access, isTag: isTag, revision: hash, preferences: operationPreferences)} }
        controller.model.onExport = { [weak self] hash in show {self?.showExport(repository: repository, access: access, revision: hash, preferences: operationPreferences)} }
        controller.model.onCompare = { [weak self] from, to in show {self?.showRevisionComparison(repository: repository, access: access, from: from, to: to, preferences: operationPreferences)} }
        controller.model.onCheckout = { [weak self] hash in show {self?.showSwitch(repository: repository, access: access, revision: hash, preferences: operationPreferences)} }
        controller.model.onReset = { [weak self] hash in show {self?.showReset(repository: repository, access: access, revision: hash, preferences: operationPreferences)} }
        controller.model.onSwitchBranch = { [weak self, weak controller] reference in
            guard let parent = controller?.window, parent.attachedSheet == nil else { return }
            self?.showSwitchProgress(repository: repository, access: access, reference: reference, parent: parent, preferences: operationPreferences)
        }
        controller.model.onTransport = { [weak self] request in
            show {switch request.command {
            case .push: self?.showPush(repository: repository, access: access, source: request.source, preserveAllBranches: true, preferences: operationPreferences)
            case .pull: self?.showFetch(repository: repository, access: access, isPull: true, preferences: operationPreferences)
            case .svnDCommit: self?.showSVN(.dcommit, repository: repository, access: access, preferences: operationPreferences)
            }}
        }
        controller.model.onBisect = { [weak self] request in show {self?.showBisect(repository: repository, access: access, good: request.good, bad: request.bad, operation: request.operation, revisions: request.revisions, requireStart: request.operation == nil, preferences: operationPreferences)} }
        controller.model.onCombineRevisions = { [weak self, weak controller] entries, offset, head in guard let controller else { return }; show {self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: controller.window, preferences: operationPreferences)} }
        controller.model.onFormatPatch = { [weak self] preset in show {self?.showFormatPatch(repository: repository, access: access, preset: preset, preferences: operationPreferences)} }
        controller.model.onMergeRevision = { [weak self] hash in show {self?.showMerge(repository: repository, access: access, revision: hash, preferences: operationPreferences)} }
        controller.model.onRebaseRevision = { [weak self] upstream in show {self?.showRebase(repository: repository, access: access, upstream: upstream, preferences: operationPreferences)} }
        controller.model.onCherryPick = { [weak self] commits in show {self?.showRebase(repository: repository, access: access, cherryPick: commits, preferences: operationPreferences)} }
        controller.model.onRevertRevisions = { [weak self, weak controller] entries, mainline in guard let controller else { return }; show {self?.showHistoryRevert(repository: repository, access: access, entries: entries, mainline: mainline, owner: controller.window,preferences:operationPreferences)} }
        controller.model.onApply = { [weak self] hash in show {self?.showStashRestore(repository: repository, access: access, pop: false, reference: hash, preferences: operationPreferences)} }
        controller.model.onChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        referenceLogWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{if reusable==nil {controller.close()};return}
        controller.model.reference=reference;controller.model.reload()
        if let referenceLogWindowPresentation {referenceLogWindowPresentation(controller)} else {controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)}
    }
    private func showStashRestore(repository: GitRepository, access: RepositoryAccessLease?, pop: Bool, reference: String? = nil, showChanges: Int = 1, preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let preferences = preferences ?? fileComparisonPreferences
        let root = repository.root, baseKey = repository.root.path + (pop ? ":pop" : ":apply:" + (reference ?? "latest")) + ":show:" + String(showChanges)
        let independentServiceRequest=finderServiceDispatch.map{[RepositoryAction.stashApply,.stashPop].contains($0.action)} ?? false
        if !independentServiceRequest,let existing = stashRestoreWindows.first(where: { key, controller in
            (key == baseKey || key.hasPrefix(baseKey + "\0")) && controller.model.preferences === preferences
        })?.value { guard prepareFinderServiceWorkflow(existing,repository:repository,access:access) else{existing.close();return}; existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        guard !stashMutationIsBusy(repository.root) else { error = "Wait for the current stash operation to finish."; return }
        let key = stashRestoreWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString
        let controller = stashRestoreWindowFactory?(repository, access, pop, reference, showChanges) ?? StashRestoreWindowController(repository: repository, access: access, pop: pop, reference: reference, showChanges: showChanges, preferences: preferences)
        controller.onClosed = { [weak self, weak controller] in if self?.stashRestoreWindows[key] === controller { self?.stashRestoreWindows.removeValue(forKey: key) } }
        controller.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.refreshStatusWindows(root); self?.refreshRepositoryLogs(root)
            self?.commitWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        let inherited = controller.model.preferences
        controller.onViewChanges = { [weak self, weak model = controller.model] in
            guard let self, !self.retired, !self.confirmingQuit, let model else { return }
            self.showStatus(repository: repository, access: access, preferences: inherited, presentation: model.handoffPresentation)
        }
        presentation?.apply(to: controller.window)
        stashRestoreWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.start()
    }
    private func showWorktreeList(repository: GitRepository, access: RepositoryAccessLease?) {
        guard !retired,!confirmingQuit else{return}
        let serviceContext=finderServiceDispatch
        let key = repository.root.path
        guard worktreeListWindows[key]?.finderServiceCanPresent != false else{error="The previous Worktree List window is still closing. Wait for it to finish.";return}
        let controller = worktreeListWindows[key] ?? worktreeListWindowFactory?(repository, access, fileComparisonPreferences) ?? WorktreeListWindowController(repository: repository, access: access, preferences: fileComparisonPreferences)
        controller.externalAvailability = { [weak self] in self?.retired == false && self?.confirmingQuit == false }
        controller.onClosed = { [weak self,weak controller] in
            guard let self,let controller,self.worktreeListWindows[key] === controller else {return}
            self.worktreeListWindows.removeValue(forKey:key)
        }
        let inherited=controller.model.preferences
        controller.onSubmodules = { [weak self,weak controller] path, lease in
            guard let self,!self.retired,!self.confirmingQuit else {return}
            let successor=serviceContext.map{FinderServiceDispatchIdentity(action:$0.action,root:path)}
            FinderServicePresentationContext.$current.withValue(successor){
                self.showSubmoduleUpdate(repository:GitRepository(root:path,executable:repository.executable),access:lease,scope:[],preferences:inherited,sourceWindow:controller?.window)
            }
        }
        controller.onCreatePresentation={ [weak self] child in
            guard let self else{return false}
            return FinderServicePresentationContext.$current.withValue(serviceContext){self.prepareFinderServiceWorkflow(child,repository:repository,access:access)}
        }
        worktreeListWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    @discardableResult private func showWorktreeCreate(repository: GitRepository, access: RepositoryAccessLease?, directory: URL? = nil, commandLaunch: Bool = false, preferences: UserDefaults? = nil, destinationAccess: RepositoryAccessLease? = nil) -> WorktreeCreateWindowController? {
        guard !retired,!confirmingQuit else {return nil}
        let key = repository.root.path
        if let existing=worktreeCreateWindows[key] ?? worktreeListWindows[key]?.createWindow,
           !existing.model.active || existing.model.handoffPending {
            error=String(localized:"A previous New Worktree window is still closing. Wait for it to finish before opening another.")
            return nil
        }
        if commandLaunch, let existing = worktreeCreateWindows[key] ?? worktreeListWindows[key]?.createWindow {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let inherited=preferences ?? fileComparisonPreferences
        let controller = worktreeCreateWindows[key] ?? worktreeCreateWindowFactory?(repository, access, inherited, directory) ?? WorktreeCreateWindowController(repository: repository, access: access, preferences: inherited, initialDirectory: directory)
        let presentedPreferences=controller.model.preferences
        let serviceContext=finderServiceDispatch
        controller.externalAvailability = { [weak self] in self?.retired == false && self?.confirmingQuit == false }
        controller.model.confirmingQuit=confirmingQuit
        if let destinationAccess {controller.model.destinationAccess=destinationAccess}
        controller.onClosed = { [weak self,weak controller] in
            guard let self,let controller,self.worktreeCreateWindows[key] === controller else {return}
            self.worktreeCreateWindows.removeValue(forKey:key)
        }
        controller.model.onCreated = { [weak self] output in
            self?.worktreeListWindows[key]?.model.requestReload()
            if self?.root?.path == key { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onSubmodules = { [weak self,weak controller] path, lease in
            guard let self,!self.retired,!self.confirmingQuit else {return}
            let successor=serviceContext.map{FinderServiceDispatchIdentity(action:$0.action,root:path)}
            FinderServicePresentationContext.$current.withValue(successor){
                self.showSubmoduleUpdate(repository:GitRepository(root:path,executable:repository.executable),access:lease,scope:[],preferences:presentedPreferences,sourceWindow:controller?.window)
            }
        }
        controller.configureCommitPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
        worktreeCreateWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return nil}
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }
    private func showRequestPull(repository: GitRepository, access: RepositoryAccessLease?, end: String? = nil, repositoryURL: String? = nil, commandLaunch: Bool = false,preferences:UserDefaults?=nil) {
        guard !retired, !confirmingQuit else { return }
        let key = repository.root.path + ":requestPull:" + (commandLaunch ? "command" : UUID().uuidString)
        if let existing = requestPullWindows[key] { if existing.canReuse { existing.window?.makeKeyAndOrderFront(nil) }; return }
        let defaults=preferences ?? finderWorkflowPreferences
        let controller = makeRequestPull?(repository, access, end, repositoryURL) ?? RequestPullWindowController(repository: repository, access: access, end: end, repositoryURL: repositoryURL, preferences: defaults)
        controller.configureLogPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller, self.requestPullWindows[key] === controller else { return }
            self.requestPullWindows.removeValue(forKey: key)
        }
        requestPullWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        if let requestPullPresentation { requestPullPresentation(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
    }
    private func showImportPatch(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        let files = paths.map { repository.root.appendingPathComponent($0) }.filter { ["patch", "diff"].contains($0.pathExtension.lowercased()) }
        showImportPatchFiles(repository: repository, access: access, files: files)
    }
    private func showImportPatchFiles(repository: GitRepository, access: RepositoryAccessLease?, files: [URL], grants: [RepositoryAccessLease] = [], commandLaunch: Bool = false,preferences:UserDefaults?=nil) {
        guard !retired,!confirmingQuit else{return}
        let defaults=preferences ?? finderWorkflowPreferences,rootKey=repository.root.path
        let baseKey=rootKey+"\0"+repository.executable.path+"\0preferences:"+String(describing:ObjectIdentifier(defaults))
        let reusable=importPatchWindows.first{($0.key==baseKey || $0.key.hasPrefix(baseKey+"\0")) && $0.value.canReuse}
        let key=reusable?.key ?? (importPatchWindows[baseKey] == nil ? baseKey:baseKey+"\0"+UUID().uuidString)
        if commandLaunch, let existing = importPatchWindows[key], existing.activeOperation {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "Wait for the current patch operation to finish."; return
        }
        let controller = importPatchWindows[key] ?? ImportPatchWindowController(repository: repository, access: access, preferences: defaults)
        controller.model.onMutationStopped = { [weak self] in
            self?.refreshStatusWindows(repository.root); self?.commitWindows[rootKey]?.model.reload()
            if self?.root?.path == rootKey { Task { await self?.refresh() } }
        }
        controller.onClosed = { [weak self,weak controller] in guard let self,let controller,self.importPatchWindows[key] === controller else{return};self.importPatchWindows.removeValue(forKey:key) }
        controller.model.onChanged = { [weak self] output in
            self?.refreshStatusWindows(repository.root)
            if self?.root?.path == rootKey { self?.output = output; Task { await self?.refresh() } }
        }
        var existingPaths = GitPathSet(controller.model.items.map { FileTransferPaths.lexicalPath($0.file.path) })
        let accepted = commandLaunch ? files.filter { existingPaths.insert(FileTransferPaths.lexicalPath($0.path)).inserted } : files
        importPatchWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        controller.model.add(accepted, retaining: grants)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showFormatPatch(repository: GitRepository, access: RepositoryAccessLease?, preset: FormatPatchPreset? = nil, sendMail: Bool = false, commandLaunch: Bool = false, preferences: UserDefaults? = nil) {
        guard !retired, !confirmingQuit else { return }
        let rootKey = repository.root.path
        let suffix: String
        switch preset?.selection {
        case .since(let revision): suffix = "\0since\0" + revision
        case .range(let from, let to): suffix = "\0range\0" + from + "\0" + to
        case .number(let count): suffix = "\0number\0" + String(count)
        case nil: suffix = ""
        }
        let defaults=preferences ?? finderWorkflowPreferences
        let baseKey = rootKey + (commandLaunch ? "\0command-format-patch" : suffix)+"\0"+repository.executable.path+"\0preferences:"+String(describing:ObjectIdentifier(defaults))
        let reusable=formatPatchWindows.first{($0.key==baseKey || $0.key.hasPrefix(baseKey+"\0")) && $0.value.canReuse}
        let key=reusable?.key ?? (formatPatchWindows[baseKey] == nil ? baseKey:baseKey+"\0"+UUID().uuidString)
        let existing = formatPatchWindows[key]
        let controller = existing ?? FormatPatchWindowController(repository: repository, access: access, preset: preset, sendMail: sendMail, preferences: defaults)
        if sendMail && controller.model.optionsAvailable { controller.model.sendMail = true }
        controller.configureReferencePicker = { [weak self] picker in self?.configureReferenceBrowser(picker, repository: repository, access: access) }
        controller.configureLogPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller, self.formatPatchWindows[key] === controller else { return }
            self.formatPatchWindows.removeValue(forKey: key)
        }
        controller.model.onOutputChanged = { [weak self] output in
            self?.refreshStatusWindows(repository.root)
            if self?.root?.path == rootKey { self?.output = output; Task { await self?.refresh() } }
        }
        formatPatchWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showRebaseCompletionMail(repository:GitRepository,access:RepositoryAccessLease?,preset:FormatPatchPreset,preferences:UserDefaults) {
        guard !retired,!confirmingQuit else{return}
        let id=UUID(),controller=RebaseCompletionMailWindowController(repository:repository,access:access,preset:preset,preferences:preferences)
        controller.onClosed={ [weak self,weak controller] in
            guard let self,let controller,self.rebaseCompletionMailWindows[id] === controller else{return}
            self.rebaseCompletionMailWindows.removeValue(forKey:id)
            self.refreshStatusWindows(repository.root)
        }
        rebaseCompletionMailWindows[id]=controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        controller.start()
    }
    func configureBrowserRevisionPicker(_ controller:RepositoryBrowserWindowController,repository:GitRepository,access:RepositoryAccessLease?) {
        controller.configureLogPicker={ [weak self] log in self?.configureSelectableLog(log,repository:repository,access:access) }
    }
    func showRepositoryBrowser(repository: GitRepository, access: RepositoryAccessLease?, revision: String = "HEAD", preferences: UserDefaults? = nil, initialFile: String? = nil, sourceWindow: NSWindow? = nil) {
        guard !retired, !confirmingQuit else { return }
        let defaults = preferences ?? finderWorkflowPreferences
        let baseKey = repository.root.path + "\0" + revision
        let reusable = browserWindows.first { _, controller in
            initialFile == nil && controller.canReuse && controller.model.repository.root == repository.root && controller.model.repository.executable == repository.executable &&
            controller.model.preferences === defaults && controller.window?.attachedSheet == nil && controller.model.canReuseForRevision(revision)
        }
        let key = reusable?.key ?? (browserWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? RepositoryBrowserWindowController(repository: repository, access: access, revision: revision, preferences:defaults, initialFile:initialFile)
        configureBrowserRevisionPicker(controller,repository:repository,access:access)
        controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.browserWindows[key] === controller else { return }; self.browserWindows.removeValue(forKey: key) }
        let serviceContext=finderServiceDispatch
        let show:(()->Void)->Void={body in FinderServicePresentationContext.$current.withValue(serviceContext){body()}}
        controller.model.onLog = { [weak self, weak controller] path, hash in guard let controller, controller.model.active else { return }; show {self?.showLog(repository: repository, access: access, paths: path.isEmpty ? [] : [path], endRevision: hash, preferences: defaults, sourceWindow: controller.window)} }
        controller.model.onBlame = { [weak self] path, hash in show {self?.showBlame(repository: repository, access: access, path: path, revision: hash, preferences: defaults)} }
        controller.model.onCompare = { [weak self, weak controller] path, hash in
            guard let controller, controller.model.active else { return }
            let accepted=controller.model.acceptedNavigationRepository ?? repository.capturingDiffBackend(preferences:defaults)
            show {self?.showHistoricalFiles(repository:accepted,access:access,from:.revision(hash),to:.workingTree,paths:[path],owner:controller.window,preferences:defaults)}
        }
        controller.model.onChanged = { [weak self] in
            guard let self else { return }
            self.refreshStatusWindows(repository.root)
            self.commitWindows[repository.root.path]?.model.reload()
            if self.root == repository.root { Task { await self.refresh() } }
        }
        controller.model.currentWorkingComparisonMark = { [weak self] in
            guard let self, !self.retired, !self.confirmingQuit else { return nil }
            return try? self.comparisonMarkStore.acquire(requireSecurityScope: GitRuntime.isAppStoreBuild)
        }
        controller.model.importWorkingComparisonMark(try? comparisonMarkStore.acquire(requireSecurityScope: GitRuntime.isAppStoreBuild))
        controller.model.onPreparedFileCompare = { [weak self, weak controller] marked, current in
            guard let controller, controller.model.active else { return }
            let accepted=controller.model.acceptedNavigationRepository ?? repository.capturingDiffBackend(preferences:defaults)
            show {self?.showPreparedFileComparison(repository:accepted,access:access,marked:marked,current:current,owner:controller.window,preferences:defaults)}
        }
        controller.model.onSubmoduleUpdate = { [weak self, weak controller] path in
            guard let controller, controller.model.active else { return }
            self?.showSubmoduleUpdate(repository:repository,access:access,scope:[],selected:[path],preferences:defaults,sourceWindow:controller.window)
        }
        controller.model.onSubmodule = { [weak self,weak controller,weak model=controller.model] module,entry,showLog in
            guard let self, !self.retired, !self.confirmingQuit, let controller, let model, model.active else { return }
            guard let checkout=module.checkout, module.from.available else {
                if showLog { model.error="Cannot show submodule history at " + entry.objectID + ". The child repository is not initialized or the revision is unavailable." }
                else { model.offerSubmoduleUpdate(entry) }
                return
            }
            let accepted=model.acceptedNavigationRepository ?? repository.capturingDiffBackend(preferences:defaults)
            let child=GitRepository(root:checkout,executable:accepted.executable,askpass:accepted.askpass,diffDetection:accepted.diffDetection,libgit2Configuration:accepted.libgit2Configuration)
            if showLog { self.showLog(repository:child,access:access,paths:[],endRevision:entry.objectID,preferences:defaults,sourceWindow:controller.window) }
            else { self.showRepositoryBrowser(repository:child,access:access,revision:entry.objectID,preferences:defaults,sourceWindow:controller.window) }
        }
        browserWindows[key] = controller
        if let sourceWindow { controller.window?.appearance = sourceWindow.effectiveAppearance; controller.window?.alphaValue = sourceWindow.alphaValue }
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{if reusable==nil {controller.close()};return}
        if let browserWindowPresentation { browserWindowPresentation(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
    }
    private func configureBlameRoutes(_ controller:BlameWindowController) {
        let repository=controller.model.repository,access=controller.model.repositoryAccess,preferences=controller.model.labelDefaults
        controller.model.onHistoryExport={ [weak self] hash in self?.showExport(repository:repository,access:access,revision:hash,preferences:preferences) }
        controller.model.onHistoryReference={ [weak self] tag,hash in self?.showReference(repository:repository,access:access,isTag:tag,revision:hash,preferences:preferences) }
        controller.model.onHistorySwitch={ [weak self] hash in self?.showSwitch(repository:repository,access:access,revision:hash,preferences:preferences) }
        controller.model.onHistoryBrowse={ [weak self,weak controller] hash in self?.showRepositoryBrowser(repository:repository,access:access,revision:hash,preferences:preferences,initialFile:controller?.model.path) }
        controller.configureContainingReferences={ [weak self] child in
            child.onLog={ [weak self] name,select,range in self?.showLog(repository:repository,access:access,paths:[],endRevision:name,selectedRevision:select ? name : nil,revisionRange:range,preferences:preferences) }
            child.onBrowse={ [weak self] name in self?.showRepositoryBrowser(repository:repository,access:access,revision:name,preferences:preferences) }
            child.onCompare={ [weak self] from,to in self?.showRevisionComparison(repository:repository,access:access,from:from,to:to,preferences:preferences) }
        }
        controller.model.onLog={ [weak self] origin,hash in self?.showLog(repository:repository,access:access,paths:[origin],endRevision:hash,selectedRevision:hash,preferences:preferences) }
        controller.model.onChanges=nil
        controller.model.onOwnedChanges={ [weak self, weak controller] snapshots,alternate,token in
            guard let self,let controller else { throw OperationCancellationFailure.cancelled }
            try await self.showOwnedFileComparisons(repository:repository,access:access,snapshots:snapshots,owner:controller.window,preferences:preferences,alternate:alternate,cancellation:token)
        }
        controller.model.onPrevious={ [weak self] origin,hash,number,inherited in self?.showBlame(repository:repository,access:access,path:origin,revision:hash,line:number,options:inherited,preferences:preferences) }
    }
    private func showBlame(repository:GitRepository,access:RepositoryAccessLease?,path:String,revision:String,line:Int? = nil,options:GitBlameOptions? = nil,commandLaunch:Bool = false,preferences:UserDefaults? = nil) {
        let defaults=preferences ?? fileComparisonPreferences
        let baseKey=GitPathRowIdentity.encode(repository.root.path+"\0"+path+"\0"+revision)
        let key=baseKey+(commandLaunch || (blameWindows[baseKey].map { $0.model.labelDefaults !== defaults } ?? false) ? UUID().uuidString:"")
        var recentFailure:String?
        if blameRecentDocuments==nil { do { blameRecentDocuments=try BlameRecentDocuments.production() } catch { recentFailure="Recent files could not be loaded: "+error.localizedDescription } }
        let reusable=blameWindows[key].flatMap {$0.model.retired ? nil:$0}
        let controller=reusable ?? BlameWindowController(repository:repository,access:access,path:path,revision:revision,options:options ?? GitBlamePreferences.load(from:defaults),preferences:defaults,recentDocuments:blameRecentDocuments)
        controller.model.recentHistoryError=recentFailure
        configureBlameRoutes(controller)
        controller.onClosed={ [weak self,weak controller] in guard let self,let controller else { return };self.blameWindows=self.blameWindows.filter { $0.value !== controller } }
        controller.onDocumentChanged={ [weak self,weak controller] in
            guard let self,let controller else { return };self.configureBlameRoutes(controller)
            self.blameWindows=self.blameWindows.filter { $0.value !== controller }
            let newKey=GitPathRowIdentity.encode(controller.model.repository.root.path+"\0"+controller.model.path+"\0HEAD")
            // Another window may already display this file; retain both without
            // corrupting either owner's lifecycle or discarding its work.
            let available=self.blameWindows[newKey]==nil ? newKey : newKey+"\0"+UUID().uuidString
            self.blameWindows[available]=controller
        }
        if let options { controller.model.configure(options:options,line:line) } else if let line { controller.model.selectOriginalLine(line) }
        blameWindows[key]=controller;guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return};controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
    }
    private func refreshRepositoryLogs(_ root: URL) {
        configuredLogModels=configuredLogModels.filter { $0.value.model?.isInvalidated == false }
        var refreshed=Set<ObjectIdentifier>()
        for model in logWindows.values.map(\.model)+configuredLogModels.values.compactMap(\.model) where model.repository.root == root && !model.isInvalidated {
            if refreshed.insert(ObjectIdentifier(model)).inserted { model.requestRepositoryRefresh() }
        }
        for replay in rebaseWindows.values where replay.model.repository.root == root && !replay.model.retired { replay.model.refreshRevisionHistoryContext() }
        for graph in revisionGraphWindows.values where graph.model.repository.root == root && !graph.model.closed { graph.requestRepositoryRefresh() }
    }
    private func showHistoryRevert(repository: GitRepository, access: RepositoryAccessLease?, entries: [LogEntry], mainline: Int?, owner: NSWindow?,preferences:UserDefaults) {
        guard owner?.attachedSheet == nil else { return }
        let id = UUID(), root = repository.root
        let child = HistoryRevertWindowController(repository: repository, access: access, entries: entries, mainline: mainline, preferences: preferences)
        child.model.onChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root); self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        child.model.onCommit = { [weak self] in self?.showCommitDialog(repository: repository, access: access, paths: [],preferences:preferences) }
        child.onClosed = { [weak self, weak owner, weak child] in
            if let window = child?.window, window.sheetParent === owner { owner?.endSheet(window) }
            self?.historyRevertWindows.removeValue(forKey: id)
        }
        historyRevertWindows[id] = child
        if let owner, let window = child.window { window.alphaValue = owner.alphaValue; window.appearance = owner.appearance; owner.beginSheet(window) }
        else { child.showWindow(nil) }
        child.model.start()
    }
    private func showHistoryCombine(repository: GitRepository, access: RepositoryAccessLease?, entries: [LogEntry], offset: Int, head: String, owner: NSWindow?, preferences:UserDefaults?=nil) {
        guard owner?.attachedSheet == nil else { return }
        let id = UUID(), root = repository.root
        let child = HistoryCombineWindowController(repository: repository, access: access, entries: entries, firstOffset: offset, expectedHead: head, preferences: preferences ?? fileComparisonPreferences)
        child.configureCommit = { [weak self] commit in self?.configureCommitInteractions(commit.model, repository: repository, access: access) }
        child.model.onChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root); self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        child.onClosed = { [weak self, weak owner, weak child] in
            if let window = child?.window, window.sheetParent === owner { owner?.endSheet(window) }
            self?.combineWindows.removeValue(forKey: id)
        }
        combineWindows[id] = child
        if let owner, let window = child.window { window.alphaValue = owner.alphaValue; window.appearance = owner.appearance; owner.beginSheet(window) }
        else { child.showWindow(nil) }
        child.model.start()
    }
    private func showGitProperties(repository:GitRepository,access:RepositoryAccessLease?,paths:[String]) {
        let selection = paths.isEmpty ? ["."] : paths
        let key = repository.root.path + "\0" + selection.map { Data($0.utf8).base64EncodedString() }.joined(separator:"\0")
        if let existing = gitPropertyWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let contexts = [GitPropertiesContext(repository:repository,paths:selection,access:access,submodule:false)]
        let controller = GitPropertiesWindowController(contexts:contexts)
        controller.onClosed = { [weak self,weak controller] in guard self?.gitPropertyWindows[key] === controller else { return }; self?.gitPropertyWindows.removeValue(forKey:key) }
        controller.model.onLog = { [weak self] context in self?.showLog(repository:context.repository,access:context.access,paths:context.paths == ["."] ? [] : context.paths) }
        controller.model.onChanged = { [weak self] changed in
            self?.refreshStatusWindows(changed.root); self?.commitWindows[changed.root.path]?.model.reload()
            if self?.root == changed.root { Task { await self?.refresh() } }
        }
        gitPropertyWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func showLog(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], endRevision: String? = nil, selectedRevision: String? = nil, revisionRange: HistoryRevisionRange? = nil, invocation: PrimaryCommandInvocation? = nil, outputAccess: RepositoryAccessLease? = nil, preferences: UserDefaults? = nil, sourceWindow: NSWindow? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let defaults = preferences ?? fileComparisonPreferences
        let root = repository.root
        var baseKey = root.path
        if let revisionRange { baseKey += "\0range\0" + revisionRange.expression }
        else if let endRevision { baseKey += "\0" + endRevision }
        if !paths.isEmpty { baseKey += "\0paths\0" + paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.joined(separator: "\0") }
        if invocation != nil { baseKey += "\0command\0" + UUID().uuidString }
        if let preferences { baseKey += "\0preferences\0" + String(describing: ObjectIdentifier(preferences)) }
        let reusable: (key: String, value: LogWindowController)?
        if let revisionRange, invocation == nil {
            reusable = logWindows.first { _, controller in
                controller.model.repository.root == root && controller.model.repository.executable == repository.executable &&
                controller.model.colorPreferences === defaults && controller.window?.attachedSheet == nil && controller.model.canReuseForRange(revisionRange,paths:paths)
            }
        } else { reusable = logWindows[baseKey].map { (key: baseKey, value: $0) } }
        let key = reusable?.key ?? (logWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller: LogWindowController
        if let output = invocation?.outputFile, let outputAccess {
            let completion: (LogEntry?) -> Void = { [weak self] revision in self?.writeCommandSelection(revision, file: output, permission: outputAccess) }
            controller = commandLineSelectionWindowFactory?(repository, access, completion) ?? LogWindowController(repository: repository, access: access, onChoose: completion, labelDefaults: defaults, loadsImmediately: false)
        } else { controller = reusable?.value ?? logWindowFactory?(repository,access) ?? LogWindowController(repository: repository, access: access, labelDefaults: defaults, loadsImmediately: invocation == nil) }
        let operationPreferences = controller.model.colorPreferences
        controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.logWindows[key] === controller else { return }; self.logWindows.removeValue(forKey: key) }
        controller.model.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        controller.model.onHistoryPush = { [weak self] revision, preserveAllBranches in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: preserveAllBranches) }
        controller.model.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.model.onCombineRevisions = { [weak self, weak controller] entries, offset, head in guard let controller else { return }; self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: controller.window) }
        configureLogRevert(controller.model,repository:repository,access:access)
        controller.model.onFormatPatch = { [weak self] preset in self?.showFormatPatch(repository: repository, access: access, preset: preset) }
        controller.model.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
        controller.model.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision, preferences: operationPreferences) }
        configureLogMenus(controller.model, repository: repository, access: access)
        controller.model.onCherryPick = { [weak self] commits in self?.showRebase(repository: repository, access: access, cherryPick: commits) }
        controller.model.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision, paths: paths) }
        configureLogIntegration(controller.model,repository:repository,access:access)
        configureLogBisect(controller.model, repository: repository, access: access)
        controller.model.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision, preferences: operationPreferences) }
        controller.model.onContainingLog = { [weak self] name, select, range in
            self?.showLog(repository: repository, access: access, paths: [], endRevision: name, selectedRevision: select ? name : nil, revisionRange: range)
        }
        controller.model.importWorkingComparisonMark(try? comparisonMarkStore.acquire(requireSecurityScope: GitRuntime.isAppStoreBuild))
        controller.model.onPreparedFileCompare = { [weak self, weak controller] marked, current in guard let controller else { return }; self?.showPreparedFileComparison(repository: repository, access: access, marked: marked, current: current, owner: controller.window) }
        controller.model.onFilePairCompare = { [weak self, weak controller] revision, files in guard let controller else { return }; self?.showHistoricalFilePair(repository: repository, access: access, revision: revision, files: files, owner: controller.window) }
        controller.model.onWorkingFiles = { [weak self] action, paths in
            if action == .add { self?.showAdd(repository: repository, access: access, paths: paths) }
            else if action == .commit { self?.showCommitDialog(repository: repository, access: access, paths: paths) }
            else if action == .revert { self?.showRevert(repository: repository, access: access, paths: paths) }
        }
        controller.model.onWorkingAdd = { [weak self] paths, mode in
            self?.showAddProgress(repository: repository, access: access, paths: paths, mode: mode, preservePathOrder:true)
        }
        controller.model.onIgnoreFiles = { [weak self] action, paths in
            self?.showIgnore(repository: repository, access: access, paths: paths, action: action)
        }
        controller.model.onWorkingFilePairCompare = { [weak self, weak controller] paths in guard let controller else { return }; self?.showWorkingFilePair(repository: repository, access: access, paths: paths, owner: controller.window) }
        controller.model.onConflictAction = { [weak self, weak controller] action, paths in
            if action == .editConflict, let path = paths.first { self?.showConflictEditor(repository: repository, access: access, path: path, owner: controller?.window) }
            else { self?.showResolve(repository: repository, access: access, paths: paths, quick: action.resolveChoice) }
        }
        controller.model.onFileCompare = { [weak self, weak controller] from, to, paths in guard let controller else { return }; self?.showHistoricalFiles(repository: repository, access: access, from: from, to: to, paths: paths, owner: controller.window) }
        controller.model.onFileComparisons = { [weak self, weak controller] requests in guard let controller else { return }; self?.showGroupedHistoricalFiles(repository: repository, access: access, requests: requests, owner: controller.window) }
        controller.model.onFileLog = { [weak self] path, hash in self?.showLog(repository: repository, access: access, paths: [path], endRevision: hash) }
        controller.model.onSubmoduleFileLog = { [weak self,weak model=controller.model] checkout, hash in
            let child = model?.acceptedNavigationRepository ?? GitRepository(root:checkout,executable:repository.executable,askpass:repository.askpass,diffDetection:repository.diffDetection,libgit2Configuration:repository.libgit2Configuration)
            self?.showLog(repository: child, access: access, paths: [], endRevision: hash,selectedRevision:hash,preferences:model?.colorPreferences)
        }
        controller.model.onBlame = { [weak self] path, hash in self?.showBlame(repository: repository, access: access, path: path, revision: hash) }
        controller.model.onRevisionChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onBrowseRepository = { [weak self] hash in self?.showRepositoryBrowser(repository: repository, access: access, revision: hash) }
        logWindows[key] = controller
        controller.model.endRevision = endRevision
        controller.model.revisionRange = revisionRange
        let location = paths.count == 1 ? root.lastPathComponent + "/" + paths[0] : root.lastPathComponent
        controller.window?.title = location + " – Log Messages" + (endRevision.map { " at " + $0.prefix(7) } ?? "") + " – TurtleGit"
        if let invocation { controller.model.applyCommandLine(invocation, paths: paths, selectedRevision: selectedRevision) }
        else {
            controller.model.setPathScope(paths)
            if let selectedRevision { ReferenceLogWindowModel.configureRevisionLog(controller.model, revision: selectedRevision) }
        }
        if let revisionRange {
            ReferenceLogWindowModel.configureRangeLog(controller.model, range: revisionRange)
            controller.model.historyPaths=paths;controller.model.showWholeProject=paths.isEmpty
            controller.window?.title = location + " – Log Messages " + revisionRange.expression + " – TurtleGit"
        }
        controller.model.reload()
        if let sourceWindow { controller.window?.appearance = sourceWindow.effectiveAppearance; controller.window?.alphaValue = sourceWindow.alphaValue }
        presentation?.apply(to: controller.window)
        if finderServiceDispatch?.action == .logSubmodule {
            guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        }
        if let logWindowPresentation { logWindowPresentation(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
    }

    private func configureLogMenus(_ model: LogWindowModel, repository: GitRepository, access: RepositoryAccessLease?, registerRefresh: Bool = true) {
        let preferences=model.colorPreferences
        model.onFollowedFileComparison = { [weak self] snapshot, token in
            self?.presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token, preferences: preferences)
        }
        configuredLogModels=configuredLogModels.filter { $0.value.model?.isInvalidated == false }
        if registerRefresh { configuredLogModels[ObjectIdentifier(model)]=ConfiguredLog(model:model) }
        model.onCommit={ [weak self,weak model] in
            guard let model else { return }
            self?.showCommitDialog(repository:repository,access:access,paths:model.historyPaths)
        }
        model.onWorkingCommand={ [weak self,weak model] action in
            switch action {
            case .commit:model?.onCommit()
            case .clean:self?.showClean(repository:repository,access:access,paths:[])
            case .mergeAbort:self?.showMergeAbort(repository:repository,access:access)
            case .stash:self?.showStash(repository:repository,access:access)
            case .stashPop:self?.showStashRestore(repository:repository,access:access,pop:true)
            case .stashList:self?.showReferenceLog(repository:repository,access:access,reference:"refs/stash")
            case .pull,.fetch:self?.showFetch(repository:repository,access:access,isPull:action == .pull)
            case .submoduleUpdate:self?.showSubmoduleUpdate(repository:repository,access:access,scope:[])
            default:break
            }
        }
        model.onCompare={ [weak self,weak model] from,to in
            guard let model else { return }
            self?.showRevisionComparison(repository:repository,access:access,from:from,to:to,paths:model.showWholeProject ? [] : model.historyPaths,preferences:preferences)
        }
        model.onShowHistory={ [weak self] hash in self?.showLog(repository:repository,access:access,paths:[],endRevision:hash,selectedRevision:hash,preferences:preferences) }
        model.onShowHistoryRange={ [weak self,weak model] range in
            guard let model else { return }
            self?.showLog(repository:repository,access:access,paths:model.historyPaths,revisionRange:range,preferences:preferences)
        }
        model.onCommitChangeSets={ [weak self] comparison in self?.showCommitChangeSets(repository:repository,access:access,comparison:comparison,preferences:preferences) }
        model.onHistorySVNDCommit={ [weak self] in self?.showSVN(.dcommit,repository:repository,access:access) }
        model.configureStartReferenceBrowser = { [weak self] picker in self?.configureReferenceBrowser(picker, repository: repository, access: access) }
        model.onSwitchBranch = { [weak self, weak model] reference in
            guard let parent = model?.window, parent.attachedSheet == nil else { return }
            self?.showSwitchProgress(repository: repository, access: access, reference: reference, parent: parent, preferences: preferences)
        }
    }
    private func configureLogBisect(_ model: LogWindowModel, repository: GitRepository, access: RepositoryAccessLease?, refreshPicker: Bool = false) {
        model.onBisect = { [weak self, weak model] request in
            self?.showBisect(repository: repository, access: access, good: request.good, bad: request.bad, operation: request.operation, revisions: request.revisions, requireStart: request.operation == nil, sourceLog: refreshPicker ? model : nil, preferences: model?.colorPreferences)
        }
    }
    private func showBisect(repository: GitRepository, access: RepositoryAccessLease?, good: String? = nil, bad: String? = nil, operation: BisectOperation? = nil, revisions: [String] = [], requireStart: Bool = false, sourceLog: LogWindowModel? = nil, onChanged: (() -> Void)? = nil, command: BisectCommandRequest? = nil, preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let root = repository.root, defaults = preferences ?? fileComparisonPreferences
        if bisectWindows.values.contains(where: { GitReferenceName.equal($0.model.repository.root.path,root.path) && !$0.canReuse && $0.hasPendingWork }) {
            error = "Wait for the current bisect operation to finish.";return
        }
        if let active = bisectWindows.values.first(where: { GitReferenceName.equal($0.model.repository.root.path, root.path) && $0.canReuse && $0.activeOperation }) {
            presentBisectWindow(active)
            if operation != nil || command != nil { error = "Wait for the current bisect operation to finish." }
            return
        }
        let reusable = bisectWindows.first { _, value in value.canReuse && GitReferenceName.equal(value.model.repository.root.path, root.path) && value.model.preferences === defaults && value.window?.attachedSheet == nil }
        let key = reusable?.key ?? (bisectWindows[root.path] == nil ? root.path : root.path + "\0" + UUID().uuidString)
        let controller: BisectWindowController
        if let existing = reusable?.value {
            if command != nil && existing.activeOperation {
                presentBisectWindow(existing)
                error = "Wait for the current bisect operation to finish."; return
            }
            controller = existing
            if !existing.activeOperation { existing.model.load(good: good, bad: bad, operation: operation, revisions: revisions, requireStart: requireStart, command: command, preserveStartDraft: command != nil && existing.model.hasStartReview && !existing.model.showingProgress) }
        } else { controller = BisectWindowController(repository: repository, access: access, good: good, bad: bad, operation: operation, revisions: revisions, requireStart: requireStart, command: command, preferences: defaults) }
        if let sourceLog { controller.model.observeLog(sourceLog) }
        controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.bisectWindows[key] === controller else { return }; self.bisectWindows.removeValue(forKey: key) }
        controller.model.onAttemptCompleted = { [weak self] result in
            guard result.attempted else { return }
            let output = result.output
            onChanged?()
            guard let self else { return }
            self.refreshRepositoryLogs(root)
            self.commitWindows[root.path]?.model.reload(); self.refreshStatusWindows(root); self.rebaseWindows[root.path]?.model.refreshState()
            if self.root == root { self.output = output; Task { await self.refresh() } }
        }
        let inherited = controller.model.preferences
        controller.model.onSubmoduleUpdate = { [weak self,weak controller] in
            let presentation=controller?.window.map(MergeWindowPresentation.init)
            self?.showSubmoduleUpdate(repository:repository,access:access,scope:[],preferences:inherited,presentation:presentation)
        }
        presentation?.apply(to: controller.window)
        bisectWindows[key] = controller; presentBisectWindow(controller)
    }
    private func presentBisectWindow(_ controller:BisectWindowController) {
        if let bisectWindowPresentation {bisectWindowPresentation(controller)}
        else {controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)}
    }
    func configureExportInteractions(_ controller: ExportWindowController, repository: GitRepository, access: RepositoryAccessLease?) {
        controller.configureCommitPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.configureReferencePicker = { [weak self] picker in self?.configureReferenceBrowser(picker, repository: repository, access: access) }
    }
    private func showExport(repository: GitRepository, access: RepositoryAccessLease?, revision: String, paths: [String] = [], commandLaunch: Bool = false, preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let defaults = preferences ?? finderWorkflowPreferences
        let commandKey = repository.root.path + "\0command-export"
        if commandLaunch, let existing = exportWindows[commandKey] {
            guard existing.canReuse else {
                error = "The previous Export window is still closing. Wait for it to finish.";return
            }
            guard prepareFinderServiceWorkflow(existing,repository:repository,access:access) else{return};presentExportWindow(existing);return
        }
        let root = repository.root
        let directory = ExportWindowModel.directoryScope(root: root, paths: paths)
        let baseKey = root.path + "\0" + revision + "\0" + directory
        let reusable = exportWindows.first { key, controller in
            !commandLaunch && key != commandKey && controller.canReuse &&
            controller.model.repository.root == repository.root && controller.model.repository.executable == repository.executable &&
            controller.model.presentationPreferences === defaults && controller.window?.attachedSheet == nil && controller.model.canReuseForRevision(revision, directory: directory)
        }
        let key = commandLaunch ? commandKey : reusable?.key ?? (exportWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? ExportWindowController(repository: repository, access: access, revision: revision, directory: directory, preferences: defaults)
        configureExportInteractions(controller, repository: repository, access: access)
        controller.onClosed = { [weak self, weak controller] in if self?.exportWindows[key] === controller { self?.exportWindows.removeValue(forKey: key) } }
        presentation?.apply(to: controller.window)
        exportWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        presentExportWindow(controller)
    }
    private func presentExportWindow(_ controller:ExportWindowController) {
        if let exportWindowPresentation {exportWindowPresentation(controller)}
        else {controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)}
    }
    private func showMergeAbort(repository: GitRepository, access: RepositoryAccessLease?, commandLaunch: Bool = false, preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        if commandLaunch, let existing = mergeAbortWindows.values.first(where: { $0.model.repository.root == repository.root }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return
        }
        let id = UUID(), root = repository.root
        let controller = mergeAbortWindowFactory?(repository,access) ?? MergeAbortWindowController(repository: repository, access: access, preferences: preferences ?? fileComparisonPreferences)
        controller.configureModifiedComparison={ [weak self] model in self?.configureRevisionComparisonInteractions(model,repository:repository,access:access) }
        controller.onClosed = { [weak self] in self?.mergeAbortWindows.removeValue(forKey: id) }
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.refreshStatusWindows(root)
            self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPostAction = { [weak self] action in
            if let operation = action.bisectOperation { self?.showBisect(repository: repository, access: access, operation: operation) }
            else if action == .submoduleUpdate { self?.showSubmoduleUpdate(repository: repository, access: access, scope: []) }
            else if action == .clean { self?.showClean(repository: repository, access: access, paths: []) }
        }
        presentation?.apply(to: controller.window)
        mergeAbortWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func configureMergeInteractions(_ controller: MergeWindowController, repository: GitRepository, access: RepositoryAccessLease?, showStashPop: Bool = false) {
        let transportChain=TransportBatchPresentationContext.chain
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
        let root = repository.root, preferences = controller.model.presentationPreferences
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.refreshStatusWindows(root); self?.refreshRepositoryLogs(root)
            self?.commitWindows[root.path]?.model.reload()
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.configureLogPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.model.showStashPop = showStashPop
        controller.model.onAbortRequested = { [weak self, weak model = controller.model] in
            guard let self, !self.retired, !self.confirmingQuit, let model else { return }
            self.showMergeAbort(repository: repository, access: access, preferences: preferences, presentation: model.handoffPresentation)
        }
        controller.model.onPostAction = { [weak self, weak model = controller.model] action, request in
            self?.performTransportHandoff(transportChain,modal:![MergePostAction.resolve,.commit,.svnDCommit].contains(action)) {
                guard let self, !self.retired, !self.confirmingQuit, let model else { return }
                let presentation = model.handoffPresentation
                switch action {
                case .resolve: self.showResolve(repository: repository, access: access, paths: [], quick: nil, preferences: preferences, presentation: presentation)
                case .commit: self.showCommitDialog(repository: repository, access: access, paths: [], preferences: preferences, presentation: presentation)
                case .stash:
                    var followUp = StashSaveFollowUp(); followUp.mergeRevision = request.revision
                    self.showStash(repository: repository, access: access, followUp: followUp, preferences: preferences, presentation: presentation)
                case .stashPop: self.showStashRestore(repository: repository, access: access, pop: true, preferences: preferences, presentation: presentation)
                case .push: self.showPush(repository: repository, access: access, preferences: preferences, presentation: presentation)
                case .svnDCommit: self.showSVN(.dcommit, repository: repository, access: access, preferences: preferences, presentation: presentation)
                case .mergeUnrelated, .removeBranch: break

            }
        }
        }
    }
    func configureLogRevert(_ log:LogWindowModel,repository:GitRepository,access:RepositoryAccessLease?) {
        log.onPreparedRevert={ [weak self,weak log] selection in
            self?.showHistoryRevert(repository:repository,access:access,entries:selection.rows,mainline:selection.mainline,owner:log?.window,preferences:log?.colorPreferences ?? self?.fileComparisonPreferences ?? .standard)
        }
    }
    func configureLogIntegration(_ log:LogWindowModel,repository:GitRepository,access:RepositoryAccessLease?) {
        let preferences = log.colorPreferences
        log.onMergeRevision = { [weak self,weak log] revision in
            let accepted=log?.acceptedNavigationRepository ?? repository.capturingDiffBackend(preferences:preferences)
            self?.showMerge(repository:accepted,access:access,revision:revision,preferences:preferences)
        }
        log.onPreparedRebase = { [weak self,weak log] prepared in
            let accepted=log?.acceptedNavigationRepository ?? repository.capturingDiffBackend(preferences:preferences)
            self?.showRebase(repository:accepted,access:access,upstream:prepared.canonicalRevision,fromLog:true,preferences:preferences,acceptedRepository:accepted)
        }
    }
    private func showMerge(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, showStashPop: Bool = false, commandLaunch: Bool = false, preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let key = repository.root.path + "\0" + (commandLaunch ? "command-merge" : UUID().uuidString)
        if let existing = mergeWindows[key] { guard prepareFinderServiceWorkflow(existing,repository:repository,access:access) else{existing.close();return}; existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = MergeWindowController(repository: repository, access: access, preferences: preferences ?? fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.mergeWindows.removeValue(forKey: key) }
        configureMergeInteractions(controller, repository: repository, access: access, showStashPop: showStashPop)
        presentation?.apply(to: controller.window)
        mergeWindows[key] = controller; controller.model.load(revision: revision)
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func stashMutationIsBusy(_ root: URL) -> Bool {
        stashWindows.values.contains { $0.model.repository.root == root && ($0.model.busy || $0.model.preparing || $0.model.confirmingUntracked || $0.model.hasIdentitySettings || $0.model.progress != nil) }
            || stashRestoreWindows.values.contains { $0.repository.root == root && ($0.model.busy || $0.model.prompt != nil) }
    }
    private func showStash(repository: GitRepository, access: RepositoryAccessLease?, followUp: StashSaveFollowUp = StashSaveFollowUp(), message: String? = nil, commandLaunch: Bool = false, preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let preferences = preferences ?? fileComparisonPreferences
        let root = repository.root, key = repository.root.path + "\0" + (commandLaunch ? "command-stash" : UUID().uuidString)
        if let existing = stashWindows[key] { guard prepareFinderServiceWorkflow(existing,repository:repository,access:access) else{existing.close();return}; existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        guard !stashMutationIsBusy(root) else { error = "Wait for the current stash operation to finish."; return }
        let controller = StashWindowController(repository: repository, access: access, preferences: preferences)
        if let message { controller.model.options.message = message }
        controller.model.canStart = { [weak self] in self.map { !$0.stashMutationIsBusy(root) } ?? false }
        controller.onClosed = { [weak self] in self?.stashWindows.removeValue(forKey: key) }
        configureStashInteractions(controller, repository: repository, access: access)
        controller.model.followUp = followUp
        presentation?.apply(to: controller.window)
        stashWindows[key] = controller
        controller.model.prepare()
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func configureStashInteractions(_ controller: StashWindowController, repository: GitRepository, access: RepositoryAccessLease?) {
        let transportChain=TransportBatchPresentationContext.chain
        let root = repository.root, preferences = controller.model.preferences
        let changed: (String) -> Void = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.refreshStatusWindows(root); self?.refreshRepositoryLogs(root)
            self?.commitWindows[root.path]?.model.reload()
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onSaved = { result in changed(result.output) }
        controller.model.onFailed = changed
        controller.model.onPostAction = { [weak self, weak model = controller.model] action, request in
            self?.performTransportHandoff(transportChain,modal:true) {
                guard let self, !self.retired, !self.confirmingQuit, let model else { return }
                let presentation = model.handoffPresentation
                switch action {
                case .pull: self.showFetch(repository: repository, access: access, isPull: true, followUp: PullFollowUp(stashSave: request), preferences: preferences, presentation: presentation)
                case .merge: if let revision = request.mergeRevision { self.showMerge(repository: repository, access: access, revision: revision, showStashPop: true, preferences: preferences, presentation: presentation) }
                case .pop, .apply: self.showStashRestore(repository: repository, access: access, pop: action == .pop, preferences: preferences, presentation: presentation)

            }
        }
        }
    }
    private func configureCommitInteractions(_ model: CommitWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        let preferences = model.colorPreferences
        model.onCommitSubmodule = { [weak self] checkout in
            guard !GitRuntime.isAppStoreBuild || access?.hasSecurityScope == true && access?.contains(checkout) == true else { self?.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
            self?.showCommitDialog(repository: GitRepository(root: checkout, executable: repository.executable), access: access, paths: [], preferences: preferences)
        }
        model.onCompare = { [weak self, weak model] paths, amendToParent in
            guard let model, model.messageFocusAvailable else { return }
            self?.showWorkingFiles(repository: repository, access: access, paths: paths, amendToParent: amendToParent, owner: model.comparisonWindow)
        }
        model.onCompareTwoFiles = { [weak self, weak model] paths in
            guard let model, model.messageFocusAvailable else { return }
            self?.showWorkingFilePair(repository: repository, access: access, paths: paths, owner: model.comparisonWindow)
        }
        model.onSubmoduleLog = { [weak self] child in self?.showLog(repository: child, access: access, paths: [], preferences: preferences) }
        model.onFileLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path], preferences: preferences) }
        model.onFileBlame = { [weak self] path in self?.showBlame(repository: repository, access: access, path: path, revision: "HEAD", preferences: preferences) }
        model.onResolve = { [weak self, weak model] action, paths in
            if action == .editConflict, let path = paths.first { self?.showConflictEditor(repository: repository, access: access, path: path, owner: model?.comparisonWindow) }
            else { self?.showResolve(repository: repository, access: access, paths: paths, quick: action.resolveChoice, preferences: preferences) }
        }
        model.onIgnore = { [weak self] action, paths in self?.showIgnore(repository: repository, access: access, paths: paths, action: action) }
        model.onRevert = { [weak self, weak model] entries, amend, againstHead, done in
            guard let self else { done(false); return }
            self.showRevertProgress(repository: repository, access: access, entries: entries, amend: amend, againstHead: againstHead, autoCloseSuccess: !entries.contains(where: { model?.submodules.contains($0.path) == true }), policy: model?.pendingRevertPolicy, completion: done)
        }
        model.onCopyAdd = { [weak self] paths in self?.showCopy(repository: repository, access: access, sources: paths.map { repository.root.appendingPathComponent($0) }) }
        model.onPasteFiles = { [weak self] copy, urls in self?.showFileTransfer(copy: copy, repository: repository, access: access, urls: urls) }
        model.onMove = { [weak self] paths in self?.showMove(repository: repository, access: access, paths: paths) }
        model.onRename = { [weak self] path in self?.showRename(repository: repository, access: access, source: path) }
        model.configureLogPicker = { [weak self] log in
            log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source, preferences: preferences) }
            log.onHistoryPush = { [weak self] revision, preserveAllBranches in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: preserveAllBranches, preferences: preferences) }
            log.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true, preferences: preferences) }
            log.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision, preferences: preferences) }
            log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision, preferences: preferences) }
            self?.configureLogMenus(log, repository: repository, access: access)
            log.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision, preferences: preferences) }
            self?.configureLogIntegration(log,repository:repository,access:access)
            log.onCombineRevisions = { [weak self, weak log] entries, offset, head in self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: log?.window) }
            self?.configureLogRevert(log,repository:repository,access:access)
            self?.configureLogBisect(log, repository: repository, access: access, refreshPicker: true)
            log.onCherryPick = { [weak self] commits in self?.showRebase(repository: repository, access: access, cherryPick: commits, preferences: preferences) }
            log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision, preferences: preferences) }
        }
    }
    private func showRebase(repository: GitRepository, access: RepositoryAccessLease?, upstream: String? = nil, autoStart: Bool = false, preserveMerges: Bool = false, cherryPick: [String]? = nil, afterFetch: Bool = false, fromLog: Bool = false, owner: NSWindow? = nil, force: Bool? = nil, commandLaunch: Bool = false, onDismissed: (() -> Void)? = nil, onResult: ((Bool) -> Void)? = nil, onRequestedLog: (() -> Void)? = nil, preferences: UserDefaults? = nil,acceptedRepository:GitRepository?=nil) {
        let transportChain=TransportBatchPresentationContext.chain
        let root = repository.root
        let existing = rebaseWindows[root.path]
        if acceptedRepository != nil,let existing,existing.model.active {
            error=RebaseFailure.active.localizedDescription
            onResult?(false);onDismissed?();return
        }
        if commandLaunch, let existing {
            guard prepareFinderServiceWorkflow(existing,repository:repository,access:access) else{existing.close();return}; existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "Close the existing Rebase dialog before launching another Rebase command."
            return
        }
        if let existing, existing.window?.sheetParent != nil { guard prepareFinderServiceWorkflow(existing,repository:repository,access:access) else{existing.close();return}; existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = existing ?? RebaseWindowController(repository: repository, access: access, preferences: preferences ?? fileComparisonPreferences)
        let inherited = controller.model.columnPreferences
        controller.configureReferencePicker = { [weak self] picker in self?.configureReferenceBrowser(picker, repository: repository, access: access) }
        var dismissed = false
        controller.onClosed = { [weak self, weak controller] in
            guard !dismissed else { return }; dismissed = true
            if let window = controller?.window { window.sheetParent?.endSheet(window) }
            let completed = controller?.model.completedSuccessfully == true
            self?.rebaseWindows.removeValue(forKey: root.path); onResult?(completed); onDismissed?()
        }
        controller.model.onChanged = { [weak self] in
            // Rebase publishes its own accepted state before this notification.
            // Feeding this back into refreshState re-enters onChanged forever.
            self?.refreshRepositoryLogs(root); self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload()
            if self?.root == root { Task { await self?.refresh() } }
        }
        controller.model.onShowStatus = { [weak self] in
            guard let self else { return }
            if self.root == root { self.activate(.status) }
            else if let access { self.openSession(access, action: .status) }
        }
        controller.model.onConflictAction = { [weak self, weak controller] action, paths in
            if action == .editConflict, let path = paths.first { self?.showConflictEditor(repository: repository, access: access, path: path, owner: controller?.window) }
            else { self?.showResolve(repository: repository, access: access, paths: paths, quick: action.resolveChoice, preferences: inherited) }
        }
        controller.model.onConflictRevertSubmodules={ [weak self] revision,paths in
            for path in paths {self?.showSubmoduleDiff(repository:repository,access:access,path:path,from:revision,preferences:inherited)}
        }
        controller.model.importConflictComparisonMark(try? comparisonMarkStore.acquire(requireSecurityScope:GitRuntime.isAppStoreBuild))
        controller.model.onConflictPreparedComparison={ [weak self,weak controller] marked,current in
            guard let controller else {return};self?.showPreparedFileComparison(repository:repository,access:access,marked:marked,current:current,owner:controller.window)
        }
        controller.model.onConflictSubmoduleLog={ [weak self] child in self?.showLog(repository:child,access:access,paths:[],preferences:inherited) }
        controller.model.onConflictFileLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path], preferences: inherited) }
        controller.model.onConflictFileBlame = { [weak self] path, revision in self?.showBlame(repository: repository, access: access, path: path, revision: revision, preferences: inherited) }
        controller.model.onConflictWorkingComparison = { [weak self, weak controller] paths,amendToParent in
            guard let self, let controller else { return }
            self.prepareFileComparisons(repository: repository, access: access, selectedCount: paths.count, owner: controller.window, preferences: inherited) { [weak self] token in
                let snapshot = try await repository.workingFileComparison(paths: paths,amendToParent:amendToParent, cancellation: token)
                self?.presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token, preferences: inherited)
            }
        }
        controller.model.onConflictWorkingPair = { [weak self, weak controller] paths in guard let controller else { return }; self?.showWorkingFilePair(repository: repository, access: access, paths: paths, owner: controller.window) }
        controller.model.completionAfterFetch = afterFetch
        controller.model.completionFromLog = fromLog
        controller.model.completionAutoStart = autoStart
        controller.model.onCompletedLog = onRequestedLog ?? { [weak self] in self?.showLog(repository: repository, access: access, paths: [], preferences: inherited) }
        controller.model.onCompletedPush = { [weak self] source in self?.performTransportHandoff(transportChain,modal:true) {self?.showPush(repository: repository, access: access, source: source, preferences: inherited)} }
        controller.model.onCompletedMail = { [weak self] preset in self?.performTransportHandoff(transportChain,modal:true) {self?.showRebaseCompletionMail(repository: repository, access: access, preset: preset, preferences: inherited)} }
        controller.model.configureCommitSelection = { [weak self] commit in self?.configureCommitInteractions(commit, repository: repository, access: access) }
        let revisionFiles=controller.model.revisionFiles
        revisionFiles.onFileLog={ [weak self] path,revision in self?.showLog(repository:repository,access:access,paths:[path],endRevision:revision,preferences:inherited) }
        revisionFiles.onBlame={ [weak self] path,revision in self?.showBlame(repository:repository,access:access,path:path,revision:revision,preferences:inherited) }
        revisionFiles.onSubmoduleLog={ [weak self,weak revisionFiles] checkout,revision in
            let child=revisionFiles?.acceptedNavigationRepository ?? GitRepository(root:checkout,executable:repository.executable,askpass:repository.askpass,diffDetection:repository.diffDetection,libgit2Configuration:repository.libgit2Configuration)
            self?.showLog(repository:child,access:access,paths:[],endRevision:revision,selectedRevision:revision,preferences:inherited)
        }
        revisionFiles.onSubmoduleCompare={ [weak self] path,oldPath,from,to in
            self?.showSubmoduleDiff(repository:repository,access:access,path:path,from:from == .emptyTree ? "" : from.label,to:to == .workingTree ? nil : to == .emptyTree ? "":to.label,fromPath:oldPath,preferences:inherited)
        }
        controller.configureContainingReferences = { [weak self] child in
            child.onLog = { [weak self] name, select, range in self?.showLog(repository: repository, access: access, paths: [], endRevision: name, selectedRevision: select ? name : nil, revisionRange: range, preferences: inherited) }
        }
        let revisionLog = controller.model.revisionMenuLog
        configureLogMenus(revisionLog, repository: repository, access: access, registerRefresh: false)
        configureLogBisect(revisionLog, repository: repository, access: access)
        revisionLog.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: from, to: to, preferences: inherited) }
        revisionLog.onBrowseRepository = { [weak self] hash in self?.showRepositoryBrowser(repository: repository, access: access, revision: hash, preferences: inherited) }
        revisionLog.onCreateReference = { [weak self] tag, hash in self?.showReference(repository: repository, access: access, isTag: tag, revision: hash, preferences: inherited) }
        revisionLog.onPush = { [weak self] hash in self?.showPush(repository: repository, access: access, source: hash, preferences: inherited) }
        revisionLog.onHistoryPush = { [weak self] revision, preserveAllBranches in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: preserveAllBranches, preferences: inherited) }
        revisionLog.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true, preferences: inherited) }
        revisionLog.onFormatPatch = { [weak self] preset in self?.showFormatPatch(repository: repository, access: access, preset: preset, preferences: inherited) }
        revisionLog.onExportRevision = { [weak self] hash in self?.showExport(repository: repository, access: access, revision: hash, preferences: inherited) }
        revisionLog.onShowHistoryRange = { [weak self] range in self?.showLog(repository: repository, access: access, paths: [], revisionRange: range, preferences: inherited) }
        revisionLog.onContainingLog = { [weak self] name, select, range in self?.showLog(repository: repository, access: access, paths: [], endRevision: name, selectedRevision: select ? name : nil, revisionRange: range, preferences: inherited) }

        revisionLog.onRevisionChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output }
        }
        controller.model.onShowRevisionLog = { [weak self] hash in self?.showLog(repository: repository, access: access, paths: [], endRevision: hash, preferences: inherited) }
        controller.model.configureLogPicker = { [weak self] log in
            log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source, preferences: inherited) }
            log.onHistoryPush = { [weak self] revision, preserveAllBranches in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: preserveAllBranches, preferences: inherited) }
            log.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true, preferences: inherited) }
            log.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision, preferences: inherited) }
            log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision, preferences: inherited) }
            self?.configureLogMenus(log, repository: repository, access: access)
            log.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision, preferences: inherited) }
            self?.configureLogIntegration(log,repository:repository,access:access)
            log.onCombineRevisions = { [weak self, weak log] entries, offset, head in self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: log?.window) }
            self?.configureLogRevert(log,repository:repository,access:access)
            self?.configureLogBisect(log, repository: repository, access: access, refreshPicker: true)
            log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision, preferences: inherited) }
        }
        rebaseWindows[root.path] = controller
        if existing == nil || controller.model.finished || upstream != nil || cherryPick != nil || acceptedRepository != nil { controller.model.load(upstream: upstream, autoStart: autoStart, preserveMerges: preserveMerges, cherryPick: cherryPick, force: force,acceptedRepository:acceptedRepository) }
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        if let owner, let child = controller.window { owner.beginSheet(child) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
    }
    private func performTransportHandoff(_ chain:RepositoryTransportBatchChain?,modal:Bool,operation:()->Void) {
        guard let chain else{operation();return}
        if modal {chain.handoff(operation)}
        else {TransportBatchPresentationContext.$chain.withValue(nil,operation:operation)}
    }
    private func configureFetchInteractions(_ controller: FetchWindowController, repository: GitRepository, access: RepositoryAccessLease?, followUp: PullFollowUp = PullFollowUp()) {
        let transportChain=TransportBatchPresentationContext.chain
        let root = repository.root, preferences = controller.model.presentationPreferences
        controller.model.onNotificationLog={ [weak self] child,grant,paths,old,new in
            guard let self,!self.retired,!self.confirmingQuit else{return}
            self.showLog(repository:child,access:grant,paths:paths,endRevision:old == nil ? new:nil,revisionRange:old.map{HistoryRevisionRange(from:$0,to:new ?? "HEAD")},preferences:preferences)
        }
        controller.model.onShowStatus = { [weak self] in
            guard let self else { return }
            if self.root == root { self.activate(.status) }
            else if let access { self.openSession(access, action: .status) }
        }
        controller.model.onFetched = { [weak self, weak controller] output in
            guard controller?.model.progress == nil, controller?.model.fetchProgress == nil else { return }
            self?.refreshRepositoryLogs(root)
            self?.refreshStatusWindows(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.followUp = followUp
        controller.model.onChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root); self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload(); self?.referenceLogWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPullPostAction = { [weak self] action, result in
            self?.performTransportHandoff(transportChain,modal:![PullPostAction.resolve,.commit,.diff,.log,.submoduleUpdate,.workingTree].contains(action)) {
                switch action {
                case .workingTree: self?.showStatus(repository: repository, access: access, paths: [], preferences: preferences)
                case .resolve: self?.showResolve(repository: repository, access: access, paths: [], quick: nil, preferences: preferences)
                case .commit: self?.showCommitDialog(repository: repository, access: access, paths: [], preferences: preferences)
                case .pull: self?.showFetch(repository: repository, access: access, isPull: true, preferences: preferences)
                case .stash:
                    var request = StashSaveFollowUp(); request.showPull = true
                    self?.showStash(repository: repository, access: access, followUp: request, preferences: preferences)
                case .reset: self?.showReset(repository: repository, access: access, revision: result.resetRevision.isEmpty ? "HEAD" : result.resetRevision, mode: .hard, preferences: preferences)
                case .stashPop: self?.showStashRestore(repository: repository, access: access, pop: true, preferences: preferences)
                case .diff: self?.showRevisionComparison(repository: repository, access: access, from: .revision(result.oldHead), to: .revision(result.newHead), preferences: preferences)
                case .log: self?.showLog(repository: repository, access: access, paths: [], revisionRange: HistoryRevisionRange(from: result.oldHead, to: result.newHead), preferences: preferences)
                case .push: self?.showPush(repository: repository, access: access, preferences: preferences)
                case .submoduleUpdate: self?.showSubmoduleUpdate(repository: repository, access: access, scope: [], preferences: preferences)
                case .mergeUnrelated: break
                }
            }
        }
        controller.model.onFetchPostAction = { [weak self] action, revision in
            self?.performTransportHandoff(transportChain,modal:![FetchPostAction.log,.resolve].contains(action)) {
                switch action {
                case .log: self?.showLog(repository: repository, access: access, paths: [], preferences: preferences)
                case .reset: self?.showReset(repository: repository, access: access, revision: revision.isEmpty ? "HEAD" : revision, mode: .hard, preferences: preferences)
                case .fetch: self?.showFetch(repository: repository, access: access, preferences: preferences)
                case .rebase: self?.showRebase(repository: repository, access: access, afterFetch: true, preferences: preferences)
                case .switchBranch: self?.showSwitch(repository: repository, access: access, preferences: preferences)
                case .resolve: self?.showCommitDialog(repository: repository, access: access, paths: [], preferences: preferences)
                case .retry: break
                }
            }
        }
        controller.model.onRebase = { [weak self,weak model=controller.model] upstream, autoStart, preserveMerges in
            let accepted=model?.acceptedOperationRepository ?? repository.capturingDiffBackend(preferences:preferences)
            self?.performTransportHandoff(transportChain,modal:true) {
                self?.showRebase(repository: accepted, access: access, upstream: upstream.isEmpty ? nil:upstream, autoStart: autoStart, preserveMerges: preserveMerges, afterFetch: true, preferences: preferences,acceptedRepository:accepted)
            }
        }
    }
    var transportClipboardText: () -> String? = { NSPasteboard.general.string(forType: .string) ?? NSPasteboard.general.string(forType: .fileURL) }
    private func showFetch(repository: GitRepository, access: RepositoryAccessLease?, isPull: Bool = false, followUp: PullFollowUp = PullFollowUp(), remote: String? = nil, allRemotes: Bool? = nil, preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let key = repository.root.path + (isPull ? ":pull:" : ":fetch:") + UUID().uuidString
        let controller = FetchWindowController(repository: repository, access: access, isPull: isPull, preferences: preferences ?? fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.fetchWindows.removeValue(forKey: key) }
        configureFetchInteractions(controller, repository: repository, access: access, followUp: followUp)
        controller.model.clipboardText = transportClipboardText
        presentation?.apply(to: controller.window)
        fetchWindows[key] = controller; controller.model.load(remote: remote, allRemotes: allRemotes)
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showPush(repository: GitRepository, access: RepositoryAccessLease?, source: String? = nil, preserveAllBranches: Bool = false, preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil,commitContinuation:CommitPushContinuation?=nil) {
        guard !retired, !confirmingQuit else { return }
        let root = repository.root, key = repository.root.path + ":push:" + UUID().uuidString
        let defaults=preferences ?? fileComparisonPreferences
        let controller = pushWindowFactory?(repository,access,defaults) ?? PushWindowController(repository: repository, access: access, preferences:defaults)
        controller.onClosed = { [weak self,weak controller] in
            guard let self,let controller,self.pushWindows[key] === controller else{return}
            self.pushWindows.removeValue(forKey:key)
        }
        configurePushInteractions(controller, repository: repository, access: access)
        controller.model.clipboardText = transportClipboardText
        presentation?.apply(to: controller.window)
        pushWindows[key] = controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        if let commitContinuation,commitContinuation.origin == .footer {
            controller.startCommitContinuation(usePushDialog:commitContinuation.amend)
        } else {
            controller.model.load(source:source,preserveAllBranches:preserveAllBranches)
            controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
        }
    }
    private func configurePushInteractions(_ controller: PushWindowController, repository: GitRepository, access: RepositoryAccessLease?) {
        let transportChain=TransportBatchPresentationContext.chain
        controller.configureReferencePicker = { [weak self] picker in self?.configureReferenceBrowser(picker, repository: repository, access: access) }
        controller.configureLogPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        let root = repository.root
        controller.model.onTransportResult = { [weak self] output, _ in
            self?.refreshRepositoryLogs(root); self?.refreshStatusWindows(root); self?.commitWindows[root.path]?.model.reload(); self?.referenceLogWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPostAction = { [weak self] action, options, superproject in
            self?.performTransportHandoff(transportChain,modal:action != .commitSuperproject) {
                guard let self else { return }
                switch action {
                case .requestPull: self.showRequestPull(repository: repository, access: access, end: options.destination)
                case .push: self.showPush(repository: repository, access: access, source: options.source)
                case .switchBranch: self.showSwitch(repository: repository, access: access)
                case .pull: self.showFetch(repository: repository, access: access, isPull: true, followUp: PullFollowUp(showPush: true))
                case .fetch: self.showFetch(repository: repository, access: access, remote: options.allRemotes ? nil : options.remote, allRemotes: options.allRemotes)
                case .commitSuperproject:
                    guard let superproject else { return }
                    if !GitRuntime.isAppStoreBuild || access?.hasSecurityScope == true && access?.contains(superproject) == true {
                        self.showCommitDialog(repository: GitRepository(root: superproject, executable: repository.executable), access: access, paths: [])
                    } else {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.directoryURL = superproject
                        panel.prompt = "Authorize super project"; panel.message = "Choose the super project folder to open its Commit dialog."
                        panel.begin { [weak self] response in
                            guard response == .OK, let folder = panel.url else { return }
                            let lease = RepositoryAccessLease(url: folder)
                            guard lease.hasSecurityScope, lease.contains(superproject) else { self?.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
                            self?.showCommitDialog(repository: GitRepository(root: superproject, executable: repository.executable), access: lease, paths: [])
                        }
                    }
                }
            }
        }
    }
    func configureReferenceInteractions(_ controller: BranchTagWindowController, repository: GitRepository, access: RepositoryAccessLease?) {
        let root = repository.root, preferences = controller.model.presentationPreferences
        controller.model.onCreated = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            self?.refreshStatusWindows(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onSwitch = { [weak self, weak controller] reference, done in
            guard let self, !self.retired, !self.confirmingQuit, let controller, controller.model.active, !controller.model.confirmingQuit, let parent = controller.window, parent.attachedSheet == nil else { done(); return }
            let progress = self.showSwitchProgress(repository: controller.model.operationRepository, access: access, reference: reference, parent: parent, preferences: preferences, completion: done)
            controller.model.awaitSwitchCloseOnRetirement = progress != nil
            controller.model.cancelSwitchPresentation = { [weak progress] in progress?.close() }
        }
        controller.model.onPushTag = { [weak self, weak model = controller.model] source in
            guard let self, !self.retired, !self.confirmingQuit, let model else { return }
            self.showPush(repository: repository, access: access, source: source, preferences: preferences, presentation: model.handoffPresentation)
        }
        controller.configureCommitPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
    }
    private func showReference(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool, revision: String? = nil, name: String? = nil, preferences: UserDefaults? = nil, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        let key = repository.root.path + (isTag ? ":tag:" : ":branch:") + UUID().uuidString
        let controller = referenceWindows[key] ?? BranchTagWindowController(repository: repository, access: access, isTag: isTag, preferences:preferences ?? fileComparisonPreferences)
        controller.onClosed = { [weak self, weak controller] in if self?.referenceWindows[key] === controller { self?.referenceWindows.removeValue(forKey: key) } }
        configureReferenceInteractions(controller, repository: repository, access: access)
        presentation?.apply(to: controller.window)
        referenceWindows[key] = controller; controller.model.load(revision: revision, name: name)
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    @discardableResult private func showSwitchProgress(repository: GitRepository, access: RepositoryAccessLease?, reference: String, parent: NSWindow, preferences: UserDefaults = .standard, completion: (() -> Void)? = nil) -> SwitchProgressWindowController? {
        let transportChain=TransportBatchPresentationContext.chain
        guard transportChain?.canPresent != false,!retired, !confirmingQuit else { completion?(); return nil }
        let id = UUID(), root = repository.root
        let controller = SwitchProgressWindowController(model: SwitchProgressWindowModel(repository: repository, access: access, reference: reference, preferences: preferences))
        controller.onClosed = { [weak self] in self?.switchProgressWindows.removeValue(forKey: id); completion?() }
        controller.model.onFinished = { [weak self] output, _ in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.commitWindows[root.path]?.model.reload(); self?.refreshStatusWindows(root)
            self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        let inherited = controller.model.presentationPreferences
        controller.model.onPostAction = { [weak self, weak model = controller.model] action, branch in guard let model else { return }; self?.performTransportHandoff(transportChain,modal:![SwitchPostAction.submoduleUpdate,.commit,.resolve].contains(action)) {self?.performSwitchPostAction(action, previousBranch: branch, repository: repository, access: access, preferences: inherited, presentation: model.handoffPresentation)} }
        switchProgressWindows[id] = controller
        if let window = controller.window { MergeWindowPresentation(parent).apply(to: window); parent.beginSheet(window) }
        controller.model.start(); return controller
    }
    private func performSwitchPostAction(_ action: SwitchPostAction, previousBranch: String, repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults, presentation: MergeWindowPresentation? = nil) {
        guard !retired, !confirmingQuit else { return }
        switch action {
        case .submoduleUpdate: showSubmoduleUpdate(repository: repository, access: access, scope: [], preferences: preferences, presentation: presentation)
        case .mergePreviousBranch: showMerge(repository: repository, access: access, revision: "refs/heads/" + previousBranch, preferences: preferences, presentation: presentation)
        case .pull: showFetch(repository: repository, access: access, isPull: true, preferences: preferences, presentation: presentation)
        case .commit, .resolve: showCommitDialog(repository: repository, access: access, paths: [], preferences: preferences, presentation: presentation)
        case .stash:
            var followUp = StashSaveFollowUp(); followUp.showPull = true
            showStash(repository: repository, access: access, followUp: followUp, preferences: preferences, presentation: presentation)
        case .retry, .switchWithMerge: break
        }
    }
    private func showReferenceBrowser(repository: GitRepository, access: RepositoryAccessLease?) {
        guard !retired,!confirmingQuit else{return}
        let preferences=finderWorkflowPreferences,base=repository.root.path+"\0"+repository.executable.path
        let reusable=referenceBrowserWindows.first {_,controller in controller.canReuse && controller.model.repository.root.path==repository.root.path && controller.model.repository.executable.path==repository.executable.path && controller.model.preferences === preferences}
        if let existing=reusable?.value {guard prepareFinderServiceWorkflow(existing,repository:repository,access:access) else{return};existing.showWindow(nil);existing.window?.makeKeyAndOrderFront(nil);return}
        let key=referenceBrowserWindows[base]==nil ? base:base+"\0"+UUID().uuidString
        let controller=ReferenceBrowserWindowController(repository:repository,access:access,initial:"HEAD",preferences:preferences,picking:false){_ in}
        controller.model.onReferencesChanged={ [weak self] in self?.refreshRepositoryLogs(repository.root);if self?.root==repository.root {Task {await self?.refresh()}}}
        configureReferenceBrowser(controller.model,repository:repository,access:access)
        let serviceContext=finderServiceDispatch
        controller.prepareChildPresentation={ [weak self,weak controller] child in
            guard let self,controller?.canReuse==true else{return false}
            return FinderServicePresentationContext.$current.withValue(serviceContext){self.prepareFinderServiceWorkflow(child,repository:repository,access:access)}
        }
        controller.configureTrackingPicker={ [weak self] child in
            FinderServicePresentationContext.$current.withValue(serviceContext){self?.configureReferenceBrowser(child.model,repository:repository,access:access)}
        }

        controller.onClosed={ [weak self,weak controller] in guard let self,let controller,self.referenceBrowserWindows[key] === controller else{return};self.referenceBrowserWindows.removeValue(forKey:key)}
        referenceBrowserWindows[key]=controller
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}
        controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
        if controller.canReuse {controller.model.load()}
    }
    func configureReferenceBrowser(_ model: ReferenceBrowserWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        let preferences=model.preferences,serviceContext=finderServiceDispatch
        let show:(()->Void)->Void={body in FinderServicePresentationContext.$current.withValue(serviceContext){body()}}
        model.configureComparison = { [weak self] comparison in show {self?.configureRevisionComparisonInteractions(comparison, repository: repository, access: access)} }
        model.onLogRange = { [weak self] range in show {self?.showLog(repository: repository, access: access, paths: [], revisionRange: range, preferences: preferences)} }
        model.onLog = { [weak self] name in show {self?.showLog(repository: repository, access: access, paths: [], endRevision: name, preferences: preferences)} }
        model.onBrowse = { [weak self] name in show {self?.showRepositoryBrowser(repository: repository, access: access, revision: name, preferences: preferences)} }
        model.onCompare = { [weak self] name in show {self?.showRevisionComparison(repository: repository, access: access, from: .revision(name), to: .workingTree, preferences: preferences)} }
        model.onCompareWithOptions = { [weak self] name, alternate in
            ComparisonToolInvocation.$alternate.withValue(alternate) {
                self?.showRevisionComparison(repository: repository, access: access, from: .revision(name), to: .workingTree, preferences: preferences)
            }
        }
        model.configureFetch = { [weak self] controller in show {self?.configureFetchInteractions(controller, repository: repository, access: access)} }
        model.configureBranch = { [weak self] controller in show {self?.configureReferenceInteractions(controller, repository: repository, access: access)} }
        model.configureMerge = { [weak self] controller in show {self?.configureMergeInteractions(controller, repository: repository, access: access)} }
        model.configureSwitch = { [weak self] controller in show {self?.configureSwitchInteractions(controller, repository: repository, access: access)} }
    }
    func configureSwitchInteractions(_ controller: SwitchWindowController, repository: GitRepository, access: RepositoryAccessLease?) {
        let transportChain=TransportBatchPresentationContext.chain
        let root = repository.root
        controller.model.onSwitched = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.commitWindows[root.path]?.model.reload()
            self?.refreshStatusWindows(root)
            self?.refreshRepositoryLogs(root)
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.refreshStatusWindows(root); self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        let inherited = controller.model.presentationPreferences
        controller.model.onPostAction = { [weak self, weak model = controller.model] action, branch in guard let model else { return }; self?.performTransportHandoff(transportChain,modal:![SwitchPostAction.submoduleUpdate,.commit,.resolve].contains(action)) {self?.performSwitchPostAction(action, previousBranch: branch, repository: repository, access: access, preferences: inherited, presentation: model.handoffPresentation)} }
        controller.configureCommitPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
    }
    private func showSwitch(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, preferences: UserDefaults? = nil) {
        guard !confirmingQuit else { return }
        let root = repository.root
        let key = root.path + ":switch:" + UUID().uuidString
        let controller = switchWindows[key] ?? SwitchWindowController(repository: repository, access: access, revision: revision, preferences:preferences ?? fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.switchWindows.removeValue(forKey: key) }
        configureSwitchInteractions(controller, repository: repository, access: access)
        switchWindows[key] = controller; controller.model.load(revision: revision)
        guard prepareFinderServiceWorkflow(controller,repository:repository,access:access) else{controller.close();return}; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func execute(_ action: RepositoryAction, value: String) {
        dialog = nil
        if action == .clone { showClone(source: value); return }
        if action == .initialize { showCreateRepository(); return }
        guard let args = action.arguments(value: value) else { return }
        guard !bare || !action.requiresWorkingTree else { error = "This operation requires a working tree."; return }
        perform { try await $0.run(args).text }
    }
    func refreshWorkingComparisonMark() throws {
        guard !retired, !confirmingQuit else { return }
        workingComparisonMark = try comparisonMarkStore.snapshot()
        let access = workingComparisonMark == nil ? nil : try? comparisonMarkStore.acquire(requireSecurityScope: GitRuntime.isAppStoreBuild)
        if let access { workingComparisonMark = access.mark }
        if workingComparisonMark != nil {
            for controller in logWindows.values { controller.model.importWorkingComparisonMark(access) }
            for controller in rebaseWindows.values { controller.model.importConflictComparisonMark(access) }
            for controller in revertWindows.values { controller.model.importWorkingComparisonMark(access) }
        }
        for controller in browserWindows.values { controller.model.importWorkingComparisonMark(access) }
    }
    var comparisonMarkPublication: ((WorkingComparisonMarkSnapshot?) throws -> Bool)?
    private func publishComparisonMark() throws {
        try refreshWorkingComparisonMark()
        let changed = try comparisonMarkPublication?(workingComparisonMark) ?? WorkingComparisonMarkSnapshot.publish(workingComparisonMark)
        if changed {
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification), object: nil)
        }
    }
    private func clearComparisonMark() {
        guard !retired,!busy, !confirmingQuit else { return }
        do { try comparisonMarkStore.clear(); try publishComparisonMark() }
        catch { self.error = error.localizedDescription }
    }
    private func comparisonPermission(for file: URL, messageFile: Bool = false, commandFile: Bool = false, commandOutput: Bool = false, commandDirectory: Bool = false, commandPatch: Bool = false) throws -> RepositoryAccessLease? {
        if let activeAccess, activeAccess.contains(file), !GitRuntime.isAppStoreBuild || activeAccess.hasSecurityScope { return activeAccess }
        if let accessStore {
            for saved in accessStore.repositories {
                if let lease = try? accessStore.acquire(saved.id, requireSecurityScope: GitRuntime.isAppStoreBuild), lease.contains(file) { return lease }
            }
        }
        if !GitRuntime.isAppStoreBuild { return RepositoryAccessLease(url: file) }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.directoryURL = file.deletingLastPathComponent(); panel.prompt = commandPatch ? "Authorize patch file" : commandOutput ? "Authorize output folder" : commandFile ? "Authorize path list" : messageFile ? "Authorize message file" : "Authorize comparison"
        panel.message = commandPatch ? "Choose the requested patch file or its containing folder to allow TurtleGit to import it." : commandOutput ? "Choose the output folder to allow TurtleGit to write the selected revision." : commandFile ? (commandDirectory ? "Choose the path-list folder to allow TurtleGit to read and delete the requested list." : "Choose the path-list file or its containing folder to allow TurtleGit to read the requested selections.") : messageFile ? "Choose the commit message file or its containing folder to allow TurtleGit to read it." : "Choose the requested file or its containing folder to allow TurtleGit to compare it."
        if commandOutput || commandDirectory { panel.canChooseFiles = false }
        guard panel.runModal() == .OK, let grant = panel.url else { return nil }
        let lease = RepositoryAccessLease(url: grant)
        guard lease.hasSecurityScope, lease.contains(file) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        return lease
    }
    private func handleComparisonMark(file: URL, permission: RepositoryAccessLease? = nil) {
        guard !retired,!busy,!confirmingQuit else{return}
        launchFinderFileWorkflow(FinderRequest(action:.diffLater,paths:[file]),permissions:permission.map{[$0]} ?? [])
    }
    private func handleFilePair(paths: [URL], line: Int? = nil, preferences: UserDefaults? = nil, serviceAccess:RepositoryAccessLease? = nil) {
        let alternateTool = ComparisonToolInvocation.capture
        do {
            guard let prepared = try WorkingFilePairAccess.prepare(paths: paths, requireSecurityScope: GitRuntime.isAppStoreBuild,
                acquire: { target in
                    if let serviceAccess {guard serviceAccess.contains(target) else{throw RepositoryAccessFailure.securityScopeUnavailable};return serviceAccess}
                    return try comparisonPermission(for:target) }) else { return }
            let key = "working-pair:" + UUID().uuidString
            let controller = FileComparisonWindowController(comparison: prepared.comparison, permissions: prepared.permissions,preferences:preferences ?? fileComparisonPreferences, line: line)
            controller.model.captureToolChoice(alternateTool)
            controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.fileComparisonWindows[key] === controller else { return }; self.fileComparisonWindows.removeValue(forKey: key) }
            fileComparisonWindows[key] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } catch { self.error = error.localizedDescription }
    }
    private func launchFinderServiceTransportBatch(_ request:FinderRequest,command:FinderServiceCommand,leases:[RepositoryAccessLease],owner:RepositoryWindowOwner) {
        let token=owner.cancellation
        finderServiceWorkers += 1
        let startingGeneration=adoptionGeneration
        owner.onCancelled={ [weak self] in self?.finderServiceTransportStep?.cancel() }
        Task { [self,leases,owner] in
            var expectedGeneration=startingGeneration
            var failures:[String]=[]
            defer {
                finderServiceTransportStep=nil
                if finderServiceOwner === owner {finderServiceOwner=nil}
                finderServiceWorkers -= 1
                if !retired,!token.isCancelled,!failures.isEmpty {error=failures.joined(separator:"\n")}
                withExtendedLifetime((leases,owner)){}
            }
            @MainActor func canContinue()->Bool {!retired && !confirmingQuit && !token.isCancelled && adoptionGeneration==expectedGeneration}
            for path in request.paths {
                // A result callback may have started an owned workspace refresh.
                // Let it settle without opening a second operation form.
                while busy,canContinue(){try? await Task.sleep(nanoseconds:10_000_000)}
                guard canContinue() else{return}
                guard let lease=leases.first(where:{$0.contains(path) && (!requiresRepositoryScope || $0.hasSecurityScope)}) else {
                    failures.append(path.path+": "+RepositoryAccessFailure.securityScopeUnavailable.localizedDescription);continue
                }
                let selected:FinderRequest
                do{selected=try command.request(paths:[path])}
                catch{failures.append(path.path+": "+error.localizedDescription);continue}
                let nextGeneration=expectedGeneration+1
                let step=RepositoryTransportBatchChain(root:path,command:false,allowed:{ [weak self] in self.map{!$0.retired && !$0.confirmingQuit && !token.isCancelled && $0.adoptionGeneration==nextGeneration} ?? false});finderServiceTransportStep=step
                defer{step.releaseCompleted()}
                let opened:Bool=await withCheckedContinuation { continuation in
                    TransportBatchPresentationContext.$chain.withValue(step) {
                        openSession(lease,selected:selected,action:request.action,commandRootOnly:true,onFinished:{continuation.resume(returning:$0)},handoffOwner:owner,serviceCommand:command)
                    }
                }
                guard adoptionGeneration==nextGeneration else {
                    token.cancel();step.cancel()
                    // Another adoption can win before the open continuation
                    // resumes even though this step already owns a real form.
                    // Keep its grants and batch accounting through forced drain.
                    if step.controller != nil {
                        while step.hasPendingWork {try? await Task.sleep(nanoseconds:10_000_000)}
                    }
                    return
                }
                expectedGeneration=nextGeneration
                if !opened || step.controller == nil {
                    if let failure=error {failures.append(path.path+": "+failure)}
                    if finderServiceTransportStep === step {finderServiceTransportStep=nil}
                    continue
                }
                while step.hasPendingWork {
                    if !canContinue(){token.cancel();step.cancel()}
                    try? await Task.sleep(nanoseconds:10_000_000)
                }
                if finderServiceTransportStep === step {finderServiceTransportStep=nil}
                guard canContinue() else{return}
            }
        }
    }
    /// Services carries only a captured selection. Obtain and retain folder
    /// authority before discovery, without blocking an unowned modal event loop.
    private func finderServiceRepositoryAccess(_ root:URL,related:[RepositoryAccessLease],owner:RepositoryWindowOwner,cancellation:OperationCancellation) async throws -> RepositoryAccessLease {
        try cancellation.check()
        if let value=([activeAccess].compactMap{$0}+related).first(where:{$0.contains(root) && (!requiresRepositoryScope || $0.hasSecurityScope)}){return value}
        if let store=accessStore {
            for saved in store.repositories {
                if let value=try? store.acquire(saved.id,requireSecurityScope:requiresRepositoryScope),value.contains(root){return value}
            }
        }
        let choice=RepositoryCreationFolderChoice(window:workspaceWindow,owner:owner),panel=choice.panel
        panel.title="Allow containing repository access";panel.prompt="Allow Access"
        panel.message="This selected submodule belongs to another repository. Choose that repository or a containing folder to perform the command.\n\n"+root.path
        panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.showsHiddenFiles=true;panel.directoryURL=root
        panel.alphaValue=workspaceWindow?.alphaValue ?? 1;panel.appearance=workspaceWindow?.appearance
        finderServiceFolderChoice=choice;finderServiceWorkers += 1
        defer{finderServiceWorkers -= 1;if finderServiceFolderChoice === choice{finderServiceFolderChoice=nil}}
        let selected:URL?=await withCheckedContinuation { continuation in
            choice.onFinished={selected in continuation.resume(returning:selected)}
            choice.begin(present:presentFinderServiceFolderPanel,selected:selectedFinderServiceFolderURL)
        }
        while panel.sheetParent != nil || panel.attachedSheet != nil{try? await Task.sleep(nanoseconds:5_000_000)}
        try cancellation.check();guard !retired,!confirmingQuit,let selected else{throw OperationCancellationFailure.cancelled}
        let lease=RepositoryAccessLease(url:selected,provider:repositoryBookmarkProvider)
        guard lease.contains(root),!requiresRepositoryScope || lease.hasSecurityScope else{throw RepositoryAccessFailure.repositoryRootOutsidePermission(root.path)}
        return lease
    }
    private func finderFileAccess(_ file:URL,owner:RepositoryWindowOwner,window:NSWindow?,leases:[RepositoryAccessLease]) async throws -> RepositoryAccessLease? {
        try owner.cancellation.check()
        if let lease=leases.first(where:{$0.contains(file) && (!requiresRepositoryScope || $0.hasSecurityScope)}) {return lease}
        if let activeAccess,activeAccess.contains(file),!requiresRepositoryScope || activeAccess.hasSecurityScope {return activeAccess}
        if let store=accessStore {
            for saved in store.repositories {
                if let lease=try? store.acquire(saved.id,requireSecurityScope:requiresRepositoryScope,recordingOpen:false),lease.contains(file) {return lease}
            }
        }
        if let permission=finderServiceFilePermission {
            let lease=try await permission(file,owner.cancellation)
            try owner.cancellation.check()
            guard let lease else{return nil}
            guard lease.contains(file),!requiresRepositoryScope || lease.hasSecurityScope else{throw RepositoryAccessFailure.securityScopeUnavailable}
            return lease
        }
        let choice=RepositoryCreationFolderChoice(window:window,owner:owner),panel=choice.panel
        panel.title="Allow file access";panel.prompt="Allow Access"
        panel.message="Choose the requested file or its containing folder to allow TurtleGit to read it.\n"+file.path
        panel.canChooseDirectories=true;panel.canChooseFiles=true;panel.allowsMultipleSelection=false;panel.showsHiddenFiles=true
        panel.directoryURL=file.deletingLastPathComponent();panel.alphaValue=window?.alphaValue ?? 1;panel.appearance=window?.appearance
        finderServiceFolderChoice=choice
        defer{if finderServiceFolderChoice === choice {finderServiceFolderChoice=nil}}
        let selected:URL?=await withCheckedContinuation { continuation in
            choice.onFinished={continuation.resume(returning:$0)}
            choice.begin(present:presentFinderServiceFilePanel,selected:selectedFinderServiceFileURL)
        }
        while panel.sheetParent != nil || panel.attachedSheet != nil || window?.attachedSheet === panel {try? await Task.sleep(nanoseconds:5_000_000)}
        try owner.cancellation.check()
        guard !retired,!confirmingQuit,let selected else{return nil}
        let lease=RepositoryAccessLease(url:selected,provider:repositoryBookmarkProvider)
        guard lease.contains(file),!requiresRepositoryScope || lease.hasSecurityScope else{throw RepositoryAccessFailure.securityScopeUnavailable}
        return lease
    }
    /// The mark decision, selected paths, preferences and originating owner are
    /// fixed before authorization. None of these routes adopts a repository.
    private func launchFinderFileWorkflow(_ request:FinderRequest,line:Int?=nil,permissions:[RepositoryAccessLease]=[]) {
        let window=workspaceWindow,owner=RepositoryWindowOwner(window:workspaceWindow)
        let preferences=request.action == .reviewPatch ? reviewPatchPreferences:fileComparisonPreferences
        let tool=request.alternateTool ?? ComparisonToolInvocation.capture
        let senderRoot=request.paths.first.flatMap { first in
            (FinderSnapshot.readLive()?.roots.sorted{$0.count>$1.count}.first{first.path==$0 || first.path.hasPrefix($0+"/")}).map{URL(fileURLWithPath:$0,isDirectory:true)}
                ?? root.flatMap{first.path==$0.path || first.path.hasPrefix($0.path+"/") ? $0:nil}
        }
        let initialMark:WorkingComparisonMarkSnapshot?
        do {initialMark=request.action == .diffLater ? try comparisonMarkStore.snapshot():nil}catch{self.error=error.localizedDescription;return}
        if request.action == .clearComparisonMark {clearComparisonMark();return}
        var grants:[RepositoryAccessLease]=permissions
        if let activeAccess {grants.append(activeAccess)}
        if let store=accessStore {
            for saved in store.repositories {
                if let lease=try? store.acquire(saved.id,requireSecurityScope:requiresRepositoryScope,recordingOpen:false) {grants.append(lease)}
            }
        }
        let inspection=finderServiceFileInspection
        let readComparison=finderServiceComparisonRead
        finderServiceOwner=owner;finderServiceWorkers += 1;busy=true;error=nil
        Task { [self,owner,window] in
            defer{finderServiceWorkers -= 1;if finderServiceOwner === owner {finderServiceOwner=nil;busy=false};withExtendedLifetime(grants){}}
            @MainActor func check()throws {try owner.cancellation.check();guard !retired,!confirmingQuit else{throw OperationCancellationFailure.cancelled}}
            do {
                try check()
                var selectedGrants:[RepositoryAccessLease]=[]
                for file in request.paths {
                    guard let lease=try await finderFileAccess(file,owner:owner,window:window,leases:grants) else{return}
                    try check();selectedGrants.append(lease);grants.append(lease)
                }
                if let inspection {try await inspection(request.paths,owner.cancellation);try check()}
                if let command=FinderServiceCommand(rawValue:request.action.rawValue) {
                    guard command.isEligible(paths:request.paths,snapshot:FinderSnapshot(roots:[],states:[:])) else{throw FinderServiceCommand.Failure("This Services command is not available for the selected files.")}
                }
                if request.action == .diffLater,initialMark == nil {
                    guard try comparisonMarkStore.snapshot()==nil else{throw FinderServiceCommand.Failure("The comparison mark changed while access was being authorized. Invoke the service again.")}
                    _=try comparisonMarkStore.remember(file:request.paths[0],permission:selectedGrants[0],requireSecurityScope:requiresRepositoryScope)
                    try publishComparisonMark();output="Marked for comparison: "+request.paths[0].path;return
                }
                if request.action == .diffLater || request.action == .diff {
                    let comparison:WorkingFileComparison
                    var permissions=selectedGrants
                    if request.action == .diffLater {
                        guard let initialMark,try comparisonMarkStore.snapshot()?.id==initialMark.id else{throw FinderServiceCommand.Failure("The comparison mark changed. Invoke the service again.")}
                        let marked=try comparisonMarkStore.acquire(requireSecurityScope:requiresRepositoryScope)
                        guard marked.mark.id==initialMark.id else{throw OperationCancellationFailure.cancelled}
                        comparison=try WorkingFileComparison(base:marked.file,destination:request.paths[0]);permissions.insert(marked.permission,at:0)
                    } else {
                        guard request.paths.count==2,request.paths[0] != request.paths[1] else{throw RevisionComparisonFailure.selection}
                        comparison=try WorkingFileComparison(base:request.paths[0],destination:request.paths[1])
                    }
                    let token=owner.cancellation
                    let document:FileComparisonDocument
                    if let readComparison {document=try await readComparison(comparison,token)}
                    else {document=try await Task.detached {try token.check();let value=try comparison.read();try token.check();return value}.value}
                    try check()
                    if request.action == .diffLater {guard try comparisonMarkStore.snapshot()?.id==initialMark?.id else{throw OperationCancellationFailure.cancelled}}
                    let key="working-service:"+UUID().uuidString
                    let controller=FileComparisonWindowController(comparison:comparison,permissions:permissions,preferences:preferences,deferInitialLoad:true,line:line)
                    try controller.model.prepareWorkingDocument(document)
                    controller.model.captureToolChoice(tool)
                    controller.window?.alphaValue=window?.alphaValue ?? 1;controller.window?.appearance=window?.effectiveAppearance
                    controller.onClosed={ [weak self,weak controller] in guard let self,let controller,self.fileComparisonWindows[key] === controller else{return};self.fileComparisonWindows.removeValue(forKey:key)}
                    fileComparisonWindows[key]=controller
                    finderServiceFileWorkflowPresentation?(request.action,controller,permissions)
                    do{try check()}catch{controller.close();throw error}
                    guard !controller.model.inputEncodingOwnerRetired else{controller.close();return}
                    if let fileComparisonWindowPresentation {fileComparisonWindowPresentation(controller)}else{controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)}
                    do{try check()}catch{controller.close();throw error}
                    guard !controller.model.inputEncodingOwnerRetired else{return}
                    controller.model.initialLoadDeferred=false;controller.model.load()
                    if request.action == .diffLater,let initialMark {_=try comparisonMarkStore.consume(initialMark.id);try publishComparisonMark()}
                    return
                }
                if request.action == .reviewPatch {
                    let workflow=ReviewPatchWorkflow(file:request.paths[0],target:senderRoot == nil ? nil:request.paths[0].deletingLastPathComponent(),preferred:request.paths[0].deletingLastPathComponent(),grants:selectedGrants,executable:try GitRuntime.executable(),preferences:preferences)
                    workflow.window?.alphaValue=window?.alphaValue ?? 1;workflow.window?.appearance=window?.effectiveAppearance
                    finderServiceFileWorkflowPresentation?(.reviewPatch,workflow,selectedGrants)
                    do{try check()}catch{workflow.close();throw error}
                    presentReview(workflow,allowed:{[weak self] in self?.retired==false && self?.confirmingQuit==false && !owner.cancellation.isCancelled});return
                }
                if request.action == .sendMail {
                    // Mail keeps unavailable paths in its checkbox list. The
                    // existing preparation validates lexical paths, not bytes.
                    if finderServiceOwner === owner {finderServiceOwner=nil;busy=false}
                    showFinderSendMail(files:request.paths,commandCancellation:owner.cancellation,preparedGrants:selectedGrants,capturedPreferences:preferences,capturedWindow:window,capturedSenderRoot:senderRoot)
                }
            }catch{if !retired,!owner.cancellation.isCancelled,!confirmingQuit {self.error=error.localizedDescription}}
        }
    }
    @discardableResult func handleFinderService(_ submitted:FinderRequest)->Bool {
        guard !retired,!busy,!confirmingQuit,!hasPendingRepositoryWork,workspaceWindow?.attachedSheet==nil,
              let command=FinderServiceCommand(rawValue:submitted.action.rawValue) else{return false}
        let request:FinderRequest
        do{request=try command.request(paths:submitted.paths,alternateTool:submitted.alternateTool)}catch{self.error=error.localizedDescription;return false}
        if !request.action.isApplicationUtility {configureActionRouting()}
        if command.selectionRoute == .patchImport {
            let folders=request.paths.filter{(try? FileManager.default.attributesOfItem(atPath:$0.path)[.type]) as? FileAttributeType == .typeDirectory}
            guard command.isEligible(paths:request.paths,snapshot:FinderSnapshot(roots:[],states:[:])) || request.paths.count==1 && !folders.isEmpty else{error="Select patch files or one repository folder to apply patches.";return false}
            preparePatchImport(request:request,serviceCommand:command,preferences:fileComparisonPreferences);return true
        }
        if [.diffLater,.clearComparisonMark,.reviewPatch,.sendMail].contains(request.action) || request.action == .diff && request.paths.count==2 {
            guard command.isEligible(paths:request.paths,snapshot:FinderSnapshot(roots:[],states:[:])) else{error="This Services command is not available for the selected files.";return false}
            launchFinderFileWorkflow(request);return true
        }
        let capturedPreferences:[RepositoryAction]=[.reflog,.referenceBrowser,.repositoryBrowser,.revisionGraph,.daemon,.export,.formatPatch,.importPatch,.requestPull]
        let preferences=capturedPreferences.contains(request.action) ? fileComparisonPreferences:nil
        let owner=RepositoryWindowOwner(window:workspaceWindow),generation=adoptionGeneration
        finderServiceOwner=owner;error=nil
        let creation=request.action == .clone || request.action == .initialize
        let registration=request.action == .registerRepository
        let transportBatch=request.paths.count>1 && [RepositoryAction.fetch,.pull,.push].contains(request.action)
        // Repository commands name Git paths; a selected symlink leaf belongs
        // to its parent, while a two-file Diff reads the actual target bytes.
        let filePair=request.action == .diff && request.paths.count==2
        var targets=request.paths.map { item in
            if registration {return item}
            let symlink=(try? FileManager.default.attributesOfItem(atPath:item.path))?[.type] as? FileAttributeType == .typeSymbolicLink
            return !creation && !filePair && symlink ? item.deletingLastPathComponent():item
        }
        if creation,let folder=request.paths.first,let parent=try? CloneOptions.workingDirectory(for:folder),!targets.contains(parent){targets.append(parent)}
        let permissionTargets=targets
        let tool=request.alternateTool ?? ComparisonToolInvocation.capture
        func finish(){if finderServiceOwner === owner{finderServiceOwner=nil}}
        func dispatch(_ lease:RepositoryAccessLease){
            guard !retired,!confirmingQuit,!owner.cancellation.isCancelled,generation==adoptionGeneration else{finish();return}
            guard permissionTargets.allSatisfy({lease.contains($0)}),!requiresRepositoryScope || lease.hasSecurityScope else{error=RepositoryAccessFailure.securityScopeUnavailable.localizedDescription;finish();return}
            if transportBatch {launchFinderServiceTransportBatch(request,command:command,leases:[lease],owner:owner);return}
            ComparisonToolInvocation.$alternate.withValue(tool){
                if registration {registerFinderRepository(request.paths[0],access:lease,owner:owner,generation:generation,completed:finish)}
                else if request.action == .clone {showClone(directory:request.paths[0],directoryAccess:lease);finish()}
                else if request.action == .initialize {presentCreateRepository(folder:request.paths[0],lease:lease,owner:owner);finish()}
                else if request.action == .diff,request.paths.count==2 {handleFilePair(paths:request.paths,serviceAccess:lease);finish()}
                else {openSession(lease,selected:request,action:request.action,onFinished:{_ in finish()},handoffOwner:owner,serviceCommand:command,servicePreferences:preferences)}
            }
        }
        if transportBatch {
            // Related metadata scopes never widen contains(). Keep each saved
            // repository's genuine primary lease and choose one per root.
            var leases:[RepositoryAccessLease]=[]
            if let activeAccess,!requiresRepositoryScope || activeAccess.hasSecurityScope {leases.append(activeAccess)}
            if let store=accessStore {
                for saved in store.repositories {
                    if let lease=try? store.acquire(saved.id,requireSecurityScope:requiresRepositoryScope),permissionTargets.contains(where:{lease.contains($0)}) {leases.append(lease)}
                }
            }
            if permissionTargets.allSatisfy({target in leases.contains{$0.contains(target)}}) {
                launchFinderServiceTransportBatch(request,command:command,leases:leases,owner:owner);return true
            }
        }
        if let activeAccess,permissionTargets.allSatisfy({activeAccess.contains($0)}),!requiresRepositoryScope || activeAccess.hasSecurityScope{dispatch(activeAccess);return true}
        if let store=accessStore {
            for saved in store.repositories {
                if let lease=try? store.acquire(saved.id,requireSecurityScope:requiresRepositoryScope),permissionTargets.allSatisfy({lease.contains($0)}){dispatch(lease);return true}
            }
        }
        let choice=RepositoryCreationFolderChoice(window:workspaceWindow,owner:owner),panel=choice.panel
        panel.title="Allow repository folder access";panel.prompt="Allow Access"
        panel.message="Choose a folder containing every selected item. TurtleGit needs repository access to perform this Services command."
        panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false;panel.showsHiddenFiles=true
        panel.directoryURL=permissionTargets.first?.deletingLastPathComponent();panel.alphaValue=workspaceWindow?.alphaValue ?? 1;panel.appearance=workspaceWindow?.appearance
        finderServiceFolderChoice=choice;finderServiceWorkers += 1;busy=true
        choice.onFinished={ [weak self,weak choice] selected in
            guard let self,let choice else{return}
            Task{@MainActor [self,choice] in
                defer{self.finderServiceWorkers -= 1;if self.finderServiceFolderChoice === choice{self.finderServiceFolderChoice=nil}}
                while choice.panel.sheetParent != nil || choice.panel.attachedSheet != nil{try? await Task.sleep(nanoseconds:5_000_000)}
                if self.finderServiceOwner === owner{self.busy=false}
                guard !self.retired,!self.confirmingQuit,!owner.cancellation.isCancelled,generation==self.adoptionGeneration,let selected else{finish();return}
                let lease=RepositoryAccessLease(url:selected,provider:self.repositoryBookmarkProvider)
                guard permissionTargets.allSatisfy({lease.contains($0)}),!self.requiresRepositoryScope || lease.hasSecurityScope else{self.error="The selected folder does not authorize every requested item.";finish();return}
                dispatch(lease)
            }
        }
        choice.begin(present:presentFinderServiceFolderPanel,selected:selectedFinderServiceFolderURL)
        return true
    }
    func handle(_ url: URL) {
        if url.isFileURL { openPatchDocument(url); return }
        guard !confirmingQuit, let request = FinderRequest(url: url) else { return }
        if !request.action.isApplicationUtility {configureActionRouting()}
        let choice=request.alternateTool ?? ComparisonToolInvocation.capture
        ComparisonToolInvocation.$alternate.withValue(choice) {handleFinderRequest(request)}
    }
    func openPatchDocument(_ url: URL) {
        guard !confirmingQuit else { return }
        guard url.isFileURL, ["patch", "diff"].contains(url.pathExtension.lowercased()) else {
            error = "Choose a .patch or .diff document to open in Unified Diff."; return
        }
        let file = FileTransferPaths.fileURL(FileTransferPaths.lexicalPath(url.path)), key = Data(file.path.utf8)
        if let entry = patchDocumentWindows.first(where: { id, controller in
            if let current = controller.documentSession.fileURL { return Data(FileTransferPaths.lexicalPath(current.path).utf8) == key }
            return patchDocumentOpeningPaths[id] == key
        }) {
            let existing = entry.value
            if existing.documentSession.fileURL == nil, !existing.model.busy, !existing.documentSession.dirty {
                existing.model.error = nil; existing.documentSession.openFile(file)
            }
            if let patchDocumentPresentation { patchDocumentPresentation(existing) }
            else { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil) }
            return
        }
        let controller = makePatchDocument(directory: file.deletingLastPathComponent(), title: file.lastPathComponent)
        patchDocumentOpeningPaths[controller.id] = key
        controller.owner.documentSession.openFile(file)
    }
    private func makePatchDocument(directory: URL, title: String, completion: (() -> Void)? = nil,
                                   standaloneCompletion:((Int32)->Void)? = nil) -> (id: UUID, owner: PatchWindowController) {
        let id = UUID(), controller = PatchWindowController(documentDirectory: directory, preferences: reviewPatchPreferences)
        controller.presentDocument(Data(), title: title + " – Unified Diff – TurtleGit", comparison: title, information: "")
        if let standaloneCompletion{controller.configureStandaloneInputCompletion(standaloneCompletion)}
        configurePatchDocument(controller)
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller, self.patchDocumentWindows[id] === controller else { return }
            self.patchDocumentWindows.removeValue(forKey: id); self.patchDocumentOpeningPaths.removeValue(forKey: id)
            completion?()
        }
        patchDocumentWindows[id] = controller
        if let patchDocumentPresentation { patchDocumentPresentation(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        return (id, controller)
    }
    @discardableResult func handleUnifiedDiffCommandLine(arguments: [String], currentDirectory: String, descriptor: Int32 = STDIN_FILENO, completion: ((Int32) -> Void)? = nil) -> Bool {
        do {
            guard let invocation = try UnifiedDiffInvocation.parse(arguments: arguments, currentDirectory: currentDirectory) else { return false }
            guard !retired, !confirmingQuit else { completion?(1); return true }
            let directory: URL
            if case .file(let url) = invocation.input { directory = url.deletingLastPathComponent() }
            else { directory = URL(fileURLWithPath: currentDirectory, isDirectory: true) }
            let title = invocation.title ?? {
                if case .file(let url) = invocation.input {return invocation.isStandaloneTool ? url.path:url.lastPathComponent}
                return invocation.isStandaloneTool ? String(localized:"diff from pipe"):"Unnamed"
            }()
            let entry: (id:UUID,owner:PatchWindowController)
            if invocation.isStandaloneTool {
                entry=makePatchDocument(directory:directory,title:title,standaloneCompletion:{completion?($0)})
            } else {entry=makePatchDocument(directory:directory,title:title,completion:{completion?(0)})}
            switch invocation.input {
            case .empty:entry.owner.startupInputReporter?(.success)
            case .file(let url):entry.owner.documentSession.openFile(url,title:invocation.isStandaloneTool ? title:invocation.title,authorizeIfNeeded:true,startupResult:entry.owner.startupInputReporter)
            case .standardInput:
                let input = UnifiedDiffInputSession()
                if !input.start(controller:entry.owner,descriptor:descriptor,title:title){entry.owner.startupInputReporter?(.cancelled)}
            }
            return true
        } catch {
            self.error = error.localizedDescription
            if completion != nil { fputs("TurtleGitUDiff: " + error.localizedDescription + "\n", stderr) }
            completion?(2); return true
        }
    }
    func completeStandaloneUnifiedDiffForTermination(){
        for owner in Array(patchDocumentWindows.values){owner.completeStandaloneInputForTermination()}
    }
    // Injected pickers are test-owned. Production keeps the same explicit
    // repository/file authorization as Finder and never trusts argv as a grant.
    var commandLineRepositoryPermission: (([URL]) throws -> RepositoryAccessLease?)?
    var commandLineMessagePermission: ((URL) throws -> RepositoryAccessLease?)?
    var commandLinePathListPermission: ((URL, Bool) throws -> RepositoryAccessLease?)?
    var commandLineOutputPermission: ((URL) throws -> RepositoryAccessLease?)?
    var commandLineSelectionWindowFactory: ((GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void) -> LogWindowController)?
    private var commandLineInputCancellation: OperationCancellation?
    private var commandLineOutputOperations: [UUID: OperationCancellation] = [:]
    static private(set) var activeCommandFileOperations = 0
    private func prepareCommandPathList(_ invocation: PrimaryCommandInvocation) throws {
        guard let file = invocation.pathFile else { return }
        let lease: RepositoryAccessLease?
        if let commandLinePathListPermission { lease = try commandLinePathListPermission(file, invocation.deletePathFile) }
        else { lease = try comparisonPermission(for: invocation.deletePathFile ? file.deletingLastPathComponent() : file, commandFile: true, commandDirectory: invocation.deletePathFile) }
        guard let lease else { return }
        guard lease.contains(file), !invocation.deletePathFile || lease.contains(file.deletingLastPathComponent()), !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
        busy = true
        let token = OperationCancellation(); commandLineInputCancellation = token
        let owner = workspaceWindow
        let observer = owner.map { NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: $0, queue: .main) { _ in token.cancel() } }
        Self.activeCommandFileOperations += 1
        Task {
            defer {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                Self.activeCommandFileOperations -= 1
                if commandLineInputCancellation === token { commandLineInputCancellation = nil }
                withExtendedLifetime(lease) {}
            }
            do {
                let resolved = try await Task.detached { try invocation.resolvingPathFile(cancellation: token) }.value
                try token.check(); busy = false
                try launchCommandLine(resolved, cancellation: token)
            } catch { busy = false; if !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func beginCommandOutput() -> (UUID, RepositoryWindowOwner) {
        let id = UUID(), owner = RepositoryWindowOwner(window: workspaceWindow)
        commandOutputOwners[id] = owner; commandLineOutputOperations[id] = owner.cancellation
        Self.activeCommandFileOperations += 1
        return (id, owner)
    }
    private func finishCommandOutput(_ id: UUID) {
        guard commandOutputOwners.removeValue(forKey: id) != nil else { return }
        commandLineOutputOperations.removeValue(forKey: id); commandGraphWindows.removeValue(forKey: id); commandGraphHandoffs.removeValue(forKey: id)
        Self.activeCommandFileOperations -= 1
    }
    private func publishCommandOutput(_ bytes: Data, file: URL, permission: RepositoryAccessLease, owner: RepositoryWindowOwner) async throws {
        let token = owner.cancellation
        try token.check()
        guard !retired, !confirmingQuit, permission.contains(file), permission.contains(file.deletingLastPathComponent()), !GitRuntime.isAppStoreBuild || permission.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let staged = try await Task.detached { try PreparedCommandFile.prepare(bytes, to: file, cancellation: token) }.value
        defer { staged.discard() }
        try token.check()
        guard !retired, !confirmingQuit else { throw OperationCancellationFailure.cancelled }
        // UI ownership and the final atomic rename share this MainActor turn.
        try staged.publish(cancellation: token)
    }
    private func writeCommandHistoricalFile(repository: GitRepository, access: RepositoryAccessLease, revision: String, path: String, file: URL, permission: RepositoryAccessLease) {
        let (id, owner) = beginCommandOutput()
        let backend=HistoricalMaterializationContext.backend ?? captureCommandMaterializationBackend?() ?? .load(from:fileComparisonPreferences)
        Task {
            defer { finishCommandOutput(id); withExtendedLifetime((access, permission)) {} }
            do {
                let bytes = try await repository.commandHistoricalFile(revision: revision, path: path, cancellation: owner.cancellation,backend:backend)
                try await publishCommandOutput(bytes, file: file, permission: permission, owner: owner)
                if root?.path == repository.root.path { output = "Saved historical file: " + file.path }
            } catch { if !retired, !owner.cancellation.isCancelled { self.error = "Could not save " + file.path + ": " + error.localizedDescription } }
        }
    }
    private func writeCommandGraph(repository: GitRepository, access: RepositoryAccessLease, file: URL, permission: RepositoryAccessLease, format: RevisionGraphFormat) {
        let handoff = CommandGraphOutputContext.current
        let (id, owner) = handoff.map { ($0.id, $0.owner) } ?? beginCommandOutput()
        handoff?.started = true
        guard !retired, !confirmingQuit, !owner.cancellation.isCancelled else { finishCommandOutput(id); return }
        let preferences = handoff?.preferences ?? fileComparisonPreferences
        let repository = GitRepository(root: repository.root, executable: repository.executable, askpass: repository.askpass,
            diffDetection: repository.diffDetection, libgit2Configuration: handoff?.backend ?? .load(from: preferences))
        let controller = revisionGraphWindowFactory?(repository, access, preferences, false) ?? RevisionGraphWindowController(repository: repository, access: access, preferences: preferences, automaticallyLoad: false)
        if let appearance = handoff?.appearance { controller.window?.appearance = appearance }
        commandGraphWindows[id] = controller
        owner.onCancelled = { [weak controller] in controller?.model.cancel(); controller?.close() }
        controller.onClosed = { owner.cancellation.cancel() }
        if !retired, !confirmingQuit, !owner.cancellation.isCancelled, !controller.model.closed { controller.model.load() }
        else { owner.cancellation.cancel(); controller.close() }
        Task {
            await controller.model.waitForCompletion()
            do {
                try owner.cancellation.check()
                guard !controller.model.closed else { throw OperationCancellationFailure.cancelled }
                if let failure = controller.model.error { throw PrimaryCommandInvocation.Failure(failure) }
                let bytes = try controller.graphExportData(format: format)
                try await publishCommandOutput(bytes, file: file, permission: permission, owner: owner)
                if !retired, !confirmingQuit, root?.path == repository.root.path { output = "Saved revision graph: " + file.path }
            } catch { if !retired, !confirmingQuit, !owner.cancellation.isCancelled { self.error = "Could not save " + file.path + ": " + error.localizedDescription } }
            controller.close()
            // Real worker/sheet retirement, rather than visual closure, releases
            // the originating permissions and the global Quit accounting.
            while controller.hasPendingWork { try? await Task.sleep(nanoseconds: 10_000_000) }
            finishCommandOutput(id)
            withExtendedLifetime((access, permission, controller)) {}
        }
    }
    private func showCommandContainingReferences(repository: GitRepository, access: RepositoryAccessLease?, revision: String) {
        let id = UUID(), preferences = fileComparisonPreferences
        let controller = CommitContainingReferencesWindowController(repository: repository, access: access, revision: revision, preferences: preferences)
        let owner = RepositoryWindowOwner(window: controller.window)
        controller.onClosed = { [weak self] in self?.commandReferenceWindows.removeValue(forKey: id) }
        controller.onLog = { [weak self] name, select, range in self?.showLog(repository: repository, access: access, paths: [], endRevision: name, selectedRevision: select ? name : nil, revisionRange: range) }
        controller.onBrowse = { [weak self] name in self?.showRepositoryBrowser(repository: repository, access: access, revision: name) }
        controller.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: from, to: to) }
        controller.onNavigate = { [weak self] name, select in self?.showLog(repository: repository, access: access, paths: [], endRevision: name, selectedRevision: select ? name : nil) }
        controller.onUnified = { [weak self] bytes, alternate in
            guard let self else { return }
            try await self.presentCommandUnifiedDiff(bytes, title: "References commit is on", repository: repository, access: access, alternate: alternate, preferences: preferences, cancellation: owner.cancellation)
        }
        commandReferenceWindows[id] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.refresh()
    }
    private func writeCommandSelection(_ revision: LogEntry?, file: URL, permission: RepositoryAccessLease) {
        let id = UUID(), token = OperationCancellation()
        commandLineOutputOperations[id] = token; Self.activeCommandFileOperations += 1
        let owner = workspaceWindow
        let observer = owner.map { NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: $0, queue: .main) { _ in token.cancel() } }
        Task {
            defer { if let observer { NotificationCenter.default.removeObserver(observer) }; commandLineOutputOperations.removeValue(forKey: id); Self.activeCommandFileOperations -= 1; withExtendedLifetime(permission) {} }
            do {
                guard permission.contains(file), !GitRuntime.isAppStoreBuild || permission.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await Task.detached { try PrimaryCommandInvocation.writeSelectedRevision(revision?.hash, to: file, cancellation: token) }.value
            } catch { if !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func handleCommandLine(arguments: [String], currentDirectory: String) {
        guard !confirmingQuit else { return }
        if handleUnifiedDiffCommandLine(arguments: arguments, currentDirectory: currentDirectory) { return }
        if handleMergeToolCommandLine(arguments: arguments, currentDirectory: currentDirectory) { return }
        do {
            guard let invocation = try PrimaryCommandInvocation.parse(arguments: arguments, currentDirectory: currentDirectory) else { return }
            guard !busy, commandRepositoryBatchCancellation == nil else { error = "Wait for the current repository operation before opening a command."; return }
            let backend:GitLibGit2Configuration?=invocation.request.action == .cat ? (captureCommandMaterializationBackend?() ?? .load(from:fileComparisonPreferences)):nil
            try CommandGraphOutputContext.$current.withValue(nil) {
                try HistoricalMaterializationContext.$backend.withValue(backend) {
                    if invocation.pathFile != nil { try prepareCommandPathList(invocation) }
                    else { try launchCommandLine(invocation) }
                }
            }
        } catch { if !retired, !confirmingQuit, !(error is OperationCancellationFailure) { self.error = error.localizedDescription } }
    }
    private func launchCommandLine(_ invocation: PrimaryCommandInvocation, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard !retired, !confirmingQuit else { return }
        if invocation.request.action == .revisionGraph, invocation.outputFile != nil, CommandGraphOutputContext.current == nil {
            let (id, owner) = beginCommandOutput()
            let handoff = CommandGraphOutputHandoff(id: id, owner: owner, preferences: fileComparisonPreferences, window: workspaceWindow)
            commandGraphHandoffs[id] = handoff
            defer { if !handoff.handedOff { finishCommandOutput(id) } }
            try CommandGraphOutputContext.$current.withValue(handoff) { try launchCommandLine(invocation, cancellation: cancellation) }
            return
        }
        try CommandGraphOutputContext.current?.owner.cancellation.check()
        let permission: RepositoryAccessLease?
        if let file = invocation.messageFile {
            if let commandLineMessagePermission { permission = try commandLineMessagePermission(file) }
            else { permission = try comparisonPermission(for: file, messageFile: true) }
            guard permission != nil else { return }
        } else { permission = nil }
        try cancellation?.check()
        let outputAccess: RepositoryAccessLease?
        if let output = invocation.outputFile {
            if let commandLineOutputPermission { outputAccess = try commandLineOutputPermission(output) }
            else { outputAccess = try comparisonPermission(for: output.deletingLastPathComponent(), commandOutput: true) }
            guard let outputAccess else { return }
            guard outputAccess.contains(output), outputAccess.contains(output.deletingLastPathComponent()), !GitRuntime.isAppStoreBuild || outputAccess.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
        } else { outputAccess = nil }
        try cancellation?.check()
        try CommandGraphOutputContext.current?.owner.cancellation.check()
        guard !retired, !confirmingQuit else { return }
        if [.editConflict, .resolve].contains(invocation.request.action) { prepareResolutionCommand(invocation, cancellation: cancellation); return }
        if invocation.request.action == .diff, invocation.diffSubmodule || invocation.hasHistoricalDiffPair || invocation.hasDiffRevisionPair && invocation.request.paths.count == 1 {
            prepareCommandComparison(invocation, cancellation: cancellation); return
        }
        if invocation.request.action == .updateCheck { onUpdateCheck(invocation.updateVisible, invocation.forceUpdate); return }
        if invocation.request.action == .autotextTest { onAutotextTest(); return }
        if invocation.request.action == .introduction { onIntroduction(); return }
        if invocation.request.action == .about { onAbout(); return }
        if !invocation.request.action.isApplicationUtility {configureActionRouting()}
        if invocation.request.action == .help { onCommandHelp(); return }
        if invocation.request.action == .firstStartWizard { onFirstStart(invocation.wizardPage ?? 0); return }
        if invocation.request.action.isDropTransfer { prepareCommandTransfer(invocation, cancellation: cancellation); return }
        if invocation.request.action == .settings { prepareCommandSettings(invocation, cancellation: cancellation); return }
        if invocation.request.action == .sendMail {
            showFinderSendMail(files: invocation.mailFiles, commandCancellation: cancellation); return
        }
        if invocation.request.action == .importPatch {
            prepareCommandPatchImport(invocation, cancellation: cancellation); return
        }
        if invocation.request.action == .initialize {
            showCreateRepository(folder: invocation.request.paths.first, commandLaunch: true, cancellation: cancellation); return
        }
        if invocation.request.action == .clone {
            showClone(directory: invocation.request.paths.first, source: invocation.sourceURL, exactPath: invocation.exactClonePath); return
        }
        if [.fetch, .pull, .push].contains(invocation.request.action), invocation.transportPaths.count > 1 {
            launchCommandRepositoryBatch(invocation, cancellation: cancellation); return
        }
        let backend:GitLibGit2Configuration?=invocation.request.action == .cat ? (HistoricalMaterializationContext.backend ?? captureCommandMaterializationBackend?() ?? .load(from:fileComparisonPreferences)):nil
        HistoricalMaterializationContext.$backend.withValue(backend) {
            ComparisonToolInvocation.$alternate.withValue(invocation.request.alternateTool ?? false) {
                let graphHandoff = CommandGraphOutputContext.current
                graphHandoff?.handedOff = true
                handleFinderRequest(invocation.request, invocation: invocation, messageAccess: permission, outputAccess: outputAccess, commandCancellation: graphHandoff?.owner.cancellation ?? cancellation,
                    completion: graphHandoff.map { handoff in { [weak self] _ in if !handoff.started { self?.finishCommandOutput(handoff.id) } } })
            }
        }
    }
    private func persistResolutionCommandScopes(_ folders: [URL], root: URL) {
        guard !folders.isEmpty, let store = accessStore,
              let saved = store.repositories.first(where: { GitReferenceName.equal($0.lastKnownPath, root.standardizedFileURL.resolvingSymlinksInPath().path) }) else { return }
        do { for folder in folders { try store.addPermission(saved.id, url: folder) } }
        catch { self.error = "The operation can continue, but additional folder access could not be saved: " + error.localizedDescription }
    }
    private func showResolutionCommand(_ invocation: PrimaryCommandInvocation, repository: GitRepository, access: RepositoryAccessLease, owner: NSWindow?, preferences: UserDefaults) {
        let paths = invocation.request.relativePaths(root: repository.root)
        if invocation.request.action == .resolve {
            guard paths.count == invocation.request.paths.count else { error = "Resolve selections must stay inside one working tree."; return }
            let options = invocation.resolveOptions ?? ResolveCommandOptions()
            if options.noQuestion && options.silent { runSilentResolve(repository: repository, access: access, paths: paths, owner: owner, preferences: preferences) }
            else { showResolve(repository: repository, access: access, paths: paths, quick: nil, preferences: preferences, commandOptions: options) }
            return
        }
        guard paths.count == 1, let path = paths.first, !path.isEmpty, path != "." else { error = "Select one conflicted file or submodule."; return }
        showConflictEditor(repository: repository, access: access, path: path, owner: owner, preferences: preferences, alternateTool: invocation.request.alternateTool ?? false, commandLaunch: true)
    }
    private func runSilentResolve(repository: GitRepository, access: RepositoryAccessLease, paths: [String], owner: NSWindow?, preferences: UserDefaults) {
        let key = repository.root.path + "\0" + paths.joined(separator: "\0")
        guard !retired, !confirmingQuit, silentResolveSessions[key] == nil else { return }
        let session = FileListComparisonSession(window: owner, preferences: preferences), execute = executeSilentResolve
        silentResolveSessions[key] = session
        Task {
            defer { if silentResolveSessions[key] === session { silentResolveSessions.removeValue(forKey: key) }; withExtendedLifetime(access) {} }
            do {
                try await session.run(selectedCount: 0) { token in
                    if GitRuntime.isAppStoreBuild && (!access.hasSecurityScope || !access.contains(repository.root)) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let text: String
                    do {
                        if let execute { text = try await execute(repository, paths, token) }
                        else { text = try await repository.resolveCommandSilently(paths: paths, cancellation: token) }
                    } catch {
                        if !retired { refreshAfterConflictChange(repository.root) }
                        throw error
                    }
                    guard !retired else { return }
                    refreshAfterConflictChange(repository.root)
                    try token.check(); guard !confirmingQuit else { return }
                    if let root, GitReferenceName.equal(root.path, repository.root.path) { output = text; Task { await refresh() } }
                }
            } catch { if !retired, !confirmingQuit, !session.cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func prepareCommandComparison(_ invocation: PrimaryCommandInvocation, cancellation: OperationCancellation?) {
        guard let first = invocation.request.paths.first else { return }
        // path2 belongs to the destination side, rather than repository lookup.
        // An external destination falls back to the existing standalone pair.
        let selection = invocation.selecting([first])
        prepareResolutionCommand(selection, cancellation: cancellation, receive: { [weak self] repository, access, owner, preferences in
            self?.showCommandComparison(invocation, repository: repository, access: access, owner: owner, preferences: preferences)
        })
    }
    private func showCommandComparison(_ invocation: PrimaryCommandInvocation, repository: GitRepository, access: RepositoryAccessLease, owner: NSWindow?, preferences: UserDefaults) {
        let repository=repository.capturingDiffBackend(preferences:preferences)
        guard !retired, !confirmingQuit, let first = invocation.request.paths.first else { return }
        let primary = FinderRequest(action: .diff, paths: [first]).relativePaths(root: repository.root)
        guard primary.count == 1 else { error = "Choose comparison paths inside this repository."; return }
        let source = primary[0], alternate = invocation.request.alternateTool ?? false
        var firstDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: first.path, isDirectory: &firstDirectory)
        ComparisonToolInvocation.$alternate.withValue(alternate) {
            if invocation.hasHistoricalDiffPair, let second = invocation.diffSecondaryPath {
                let destination = FinderRequest(action: .diff, paths: [second]).relativePaths(root: repository.root)
                guard destination.count == 1 else { handleFilePair(paths: [first, second], line: invocation.line, preferences: preferences); return }
                var secondDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: second.path, isDirectory: &secondDirectory)
                if firstDirectory.boolValue || secondDirectory.boolValue {
                    showCommandSubmodule(invocation, repository: repository, access: access, path: destination[0], preferences: preferences)
                    return
                }
                guard let from = invocation.diffFromRevision, let to = invocation.diffToRevision else { return }
                prepareFileComparisons(repository: repository, access: access, selectedCount: 1, owner: owner, preferences: preferences, capturedOwner: true) { [self] token in
                    // DiffCommand passes path2 to CGitDiff directly; its unified
                    // switch does not select StartShowUnifiedDiff in this branch.
                    let snapshot = try await repository.preparedPathComparison(from: from, fromPath: source, to: to, toPath: destination[0], cancellation: token)
                    presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token, line: invocation.line, preferences: preferences)
                }
            } else if firstDirectory.boolValue && !invocation.diffSubmodule {
                // Ordinary directory Diff keeps ChangedDlg precedence, even
                // when a revision pair or unified was supplied.
                showStatus(repository: repository, access: access, paths: primary, preferences: preferences)
            } else if invocation.unified {
                prepareFileComparisons(repository: repository, access: access, selectedCount: 1, owner: owner, preferences: preferences, capturedOwner: true) { [self] token in
                    let bytes = try await repository.commandUnifiedDiff(from: invocation.diffFrom, to: invocation.diffTo, paths: primary, cancellation: token)
                    let title = (invocation.diffFromRevision?.label ?? "HEAD") + " → " + (invocation.diffToRevision?.label ?? "Working tree")
                    try await presentCommandUnifiedDiff(bytes, title: title, repository: repository, access: access, alternate: alternate, preferences: preferences, cancellation: token)
                }
            } else if invocation.diffSubmodule && firstDirectory.boolValue {
                showCommandSubmodule(invocation, repository: repository, access: access, path: source, preferences: preferences)
            } else if let from = invocation.diffFromRevision, let to = invocation.diffToRevision {
                prepareFileComparisons(repository: repository, access: access, selectedCount: 1, owner: owner, preferences: preferences, capturedOwner: true) { [self] token in
                    let snapshot = try await repository.preparedPathComparison(from: from, fromPath: source, to: to, toPath: source, cancellation: token)
                    presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token, line: invocation.line, preferences: preferences)
                }
            } else {
                // The switch bypasses ChangedDlg; it does not force an
                // ordinary file to become a gitlink comparison.
                prepareFileComparisons(repository: repository, access: access, selectedCount: 1, owner: owner, preferences: preferences, capturedOwner: true) { [self] token in
                    let snapshot = try await repository.workingFileComparison(paths: primary, cancellation: token)
                    presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token, line: invocation.line, preferences: preferences)
                }
            }
        }
    }
    private func showCommandSubmodule(_ invocation: PrimaryCommandInvocation, repository: GitRepository, access: RepositoryAccessLease, path: String, preferences: UserDefaults) {
        let from = invocation.diffFromRevision ?? .revision("HEAD"), to = invocation.diffToRevision ?? .workingTree
        let working = from == .workingTree || to == .workingTree
        let base = from == .workingTree ? to : from
        // CGitDiff normalizes either working sentinel to the To side; two
        // working sides use the indexed gitlink as the old pointer.
        showSubmoduleDiff(repository: repository, access: access, path: path,
            from: working && base == .workingTree ? "Working tree" : base.label,
            to: working ? nil : to.label, fromIndex: from == .workingTree && to == .workingTree,
            preferences: preferences)
    }
    private func prepareResolutionCommand(_ invocation: PrimaryCommandInvocation, cancellation: OperationCancellation?, receive: ((GitRepository, RepositoryAccessLease, NSWindow?, UserDefaults) -> Void)? = nil) {
        guard !retired, !confirmingQuit, resolutionCommandPreparation == nil, let selected = invocation.request.paths.first else { return }
        let owner = RepositoryWindowOwner(window: workspaceWindow), window = workspaceWindow, preferences = fileComparisonPreferences
        resolutionCommandPreparation = owner; busy = true
        Task {
            var transferred = false
            defer { if resolutionCommandPreparation === owner { resolutionCommandPreparation = nil }; resolutionCommandFolderChoice = nil; if !transferred { busy = false } }
            do {
                try owner.cancellation.check(); try cancellation?.check()
                var permission: RepositoryAccessLease?
                if let activeAccess, invocation.request.paths.allSatisfy({activeAccess.contains($0)}), !requiresRepositoryScope || activeAccess.hasSecurityScope { permission = activeAccess }
                else if let commandLineRepositoryPermission { permission = try commandLineRepositoryPermission(invocation.request.paths) }
                else {
                    if let store = accessStore {
                        for saved in store.repositories {
                            if let lease = try? store.acquire(saved.id, requireSecurityScope: requiresRepositoryScope, updatingRecord: false, recordingOpen: false), invocation.request.paths.allSatisfy({lease.contains($0)}) { permission = lease; break }
                        }
                    }
                    if permission == nil, !requiresRepositoryScope {
                        let directory = (try? selected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                        var folder = directory ? selected : selected.deletingLastPathComponent()
                        while !invocation.request.paths.allSatisfy({RepositoryAccessLease.pathIsContained($0, by: folder)}) {
                            let parent = folder.deletingLastPathComponent(); if parent == folder { break }; folder = parent
                        }
                        permission = RepositoryAccessLease(url: folder)
                    } else if permission == nil {
                        permission = await withCheckedContinuation { continuation in
                            let choice = RepositoryCreationFolderChoice(window: window, owner: owner)
                            choice.panel.canChooseFiles = false; choice.panel.canChooseDirectories = true; choice.panel.showsHiddenFiles = true
                            choice.panel.prompt = "Authorize repository"; choice.panel.message = "Choose the working tree containing the selected paths."; choice.panel.directoryURL = selected.deletingLastPathComponent()
                            resolutionCommandFolderChoice = choice
                            choice.onFinished = { folder in continuation.resume(returning: folder.map { RepositoryAccessLease(url: $0) }) }
                            choice.begin(present: nil, selected: { $0.url })
                        }
                    }
                }
                try owner.cancellation.check(); try cancellation?.check(); guard !retired, !confirmingQuit, let permission else { return }
                guard invocation.request.paths.allSatisfy({permission.contains($0)}), !requiresRepositoryScope || permission.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                let directory = (try? selected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                var location = directory ? selected : selected.deletingLastPathComponent()
                if invocation.hasDiffRevisionPair {
                    while location.path != "/", (try? location.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                        let parent = location.deletingLastPathComponent()
                        guard !requiresRepositoryScope || permission.contains(parent) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(parent.path) }
                        location = parent
                    }
                }
                guard !requiresRepositoryScope || permission.contains(location) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(location.path) }
                let prepared = try await prepareRepositoryMetadataAccess(at: location, primary: permission, cancellation: owner.cancellation)
                var access = permission.retainingRelatedScopes(prepared.scopes)
                let candidate = try makeRepository(location)
                let resolved = try await candidate.discoverSelectionRoot(for: invocation.request.action, selected: selected, cancellation: owner.cancellation)
                if !requiresRepositoryScope, !access.contains(resolved) { access = RepositoryAccessLease(url: resolved).retainingRelatedScopes([access]) }
                guard !requiresRepositoryScope || access.contains(resolved) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(resolved.path) }
                let repository = try makeRepository(resolved)
                let repositoryIsBare = try await repository.isBare(cancellation: owner.cancellation)
                let historicalDiff = invocation.hasDiffRevisionPair && invocation.diffFromRevision != .workingTree && invocation.diffToRevision != .workingTree
                guard !repositoryIsBare || historicalDiff else { throw PrimaryCommandInvocation.Failure("This operation requires a working tree.") }
                if invocation.request.action == .resolve {
                    let paths = invocation.request.relativePaths(root: resolved)
                    guard paths.count == invocation.request.paths.count else { throw ResolveFailure.outsideWorkingTree }
                    _ = try await repository.resolveCommandPaths(paths, cancellation: owner.cancellation)
                }
                try owner.cancellation.check(); try cancellation?.check(); guard !retired, !confirmingQuit else { return }
                if let root, GitReferenceName.equal(root.path, resolved.path) {
                    activeAccess = access; persistResolutionCommandScopes(prepared.newFolders, root: root)
                    if let receive { busy = false; transferred = true; receive(repository, access, window, preferences) }
                    else { showResolutionCommand(invocation, repository: repository, access: access, owner: window, preferences: preferences) }; return
                }
                guard canChangeSettingsContext() else { return }
                busy = false; transferred = true
                // Adopt the validated root without dispatching an uncaptured
                // editor action. The original selected item stays in invocation.
                let rootRequest = invocation.selecting([resolved]).request
                openSession(access, selected: rootRequest, commandRootOnly: true, handoffOwner: owner, onOpened: { [weak self] in
                    guard let self, !self.retired, !self.confirmingQuit, !owner.cancellation.isCancelled, cancellation?.isCancelled != true,
                          let repository = self.repository, let access = self.activeAccess else { return }
                    self.persistResolutionCommandScopes(prepared.newFolders, root: repository.root)
                    if let receive { receive(repository, access, window, preferences) }
                    else { self.showResolutionCommand(invocation, repository: repository, access: access, owner: window, preferences: preferences) }
                })
            } catch { if !retired, !owner.cancellation.isCancelled, cancellation?.isCancelled != true { self.error = error.localizedDescription } }
        }
    }
    private func showCommandTransfer(_ invocation: PrimaryCommandInvocation, repository: GitRepository, access: RepositoryAccessLease, preferences: UserDefaults) {
        guard let target = invocation.transferTarget, !invocation.dropFiles.isEmpty else { return }
        if invocation.request.action == .dropMove {
            showMove(repository: repository, access: access, paths: [], clipboard: invocation.dropFiles, destination: target, renameFirst: invocation.renameTransfer, stopOnError: false, automaticallyStart: true, preferences: preferences)
        } else { showCopy(repository: repository, access: access, sources: invocation.dropFiles, folder: target, automaticallyStart: true, preferences: preferences) }
    }
    private func prepareCommandTransfer(_ invocation: PrimaryCommandInvocation, cancellation: OperationCancellation?) {
        guard !retired, !confirmingQuit, transferPreparation == nil, let target = invocation.transferTarget, !invocation.dropFiles.isEmpty else { return }
        let owner = RepositoryWindowOwner(window: workspaceWindow), window = workspaceWindow
        let preferences = fileComparisonPreferences
        transferPreparation = owner; busy = true
        Task {
            var transferred = false
            defer { if transferPreparation === owner { transferPreparation = nil }; transferFolderChoice = nil; if !transferred { busy = false } }
            do {
                try owner.cancellation.check(); try cancellation?.check()
                let permission: RepositoryAccessLease?
                if let activeAccess, activeAccess.contains(target), !requiresRepositoryScope || activeAccess.hasSecurityScope { permission = activeAccess }
                else if let commandLineRepositoryPermission { permission = try commandLineRepositoryPermission([target]) }
                else if !requiresRepositoryScope { permission = RepositoryAccessLease(url: target) }
                else {
                    permission = await withCheckedContinuation { continuation in
                        let choice = RepositoryCreationFolderChoice(window: window, owner: owner)
                        choice.panel.canChooseFiles = false; choice.panel.canChooseDirectories = true; choice.panel.showsHiddenFiles = true
                        choice.panel.prompt = "Authorize repository"; choice.panel.message = "Choose the working tree containing the drop destination."; choice.panel.directoryURL = target
                        transferFolderChoice = choice
                        choice.onFinished = { folder in continuation.resume(returning: folder.map { RepositoryAccessLease(url: $0) }) }
                        choice.begin(present: nil, selected: { $0.url })
                    }
                }
                try owner.cancellation.check(); try cancellation?.check(); guard !retired, !confirmingQuit, let permission else { return }
                guard permission.contains(target), !requiresRepositoryScope || permission.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                let prepared = try await prepareRepositoryMetadataAccess(at: target, primary: permission, cancellation: owner.cancellation)
                let access = permission.retainingRelatedScopes(prepared.scopes), candidate = try makeRepository(target)
                let discovered = try await candidate.discoverRoot(cancellation: owner.cancellation)
                guard !requiresRepositoryScope || access.contains(discovered) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(discovered.path) }
                let repository = try makeRepository(discovered)
                _ = try await repository.fileMoveDestination(target, cancellation: owner.cancellation)
                if invocation.request.action == .dropMove { _ = try await repository.clipboardMovePaths(invocation.dropFiles, cancellation: owner.cancellation) }
                try owner.cancellation.check(); try cancellation?.check(); guard !retired, !confirmingQuit else { return }
                if root?.path == discovered.path { showCommandTransfer(invocation, repository: repository, access: access, preferences: preferences); return }
                guard canChangeSettingsContext() else { return }
                busy = false; transferred = true
                let destination = invocation.selecting([target])
                openSession(access, selected: destination.request, action: destination.request.action, handoffOwner: owner, onOpened: { [weak self] in
                    guard let self, !self.retired, !self.confirmingQuit, !owner.cancellation.isCancelled,
                          let repository = self.repository, let access = self.activeAccess else { return }
                    self.showCommandTransfer(invocation, repository: repository, access: access, preferences: preferences)
                })
            } catch { if !retired, !owner.cancellation.isCancelled, cancellation?.isCancelled != true { self.error = error.localizedDescription } }
        }
    }
    private func prepareCommandSettings(_ invocation: PrimaryCommandInvocation, cancellation: OperationCancellation?) {
        guard !retired, !confirmingQuit, settingsPreparation == nil, let selected = invocation.request.paths.first else { return }
        let owner = RepositoryWindowOwner(window: workspaceWindow), window = workspaceWindow
        // The captured window's token is the authority; Git reads use it too.
        settingsPreparation = owner; busy = true
        Task {
            var transferred = false
            defer { if settingsPreparation === owner { settingsPreparation = nil }; settingsFolderChoice = nil; if !transferred { busy = false } }
            do {
                try owner.cancellation.check(); try cancellation?.check()
                let permission: RepositoryAccessLease?
                if let activeAccess, activeAccess.contains(selected), !requiresRepositoryScope || activeAccess.hasSecurityScope { permission = activeAccess }
                else if let commandLineRepositoryPermission { permission = try commandLineRepositoryPermission([selected]) }
                else if !requiresRepositoryScope {
                    let directory = (try? selected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    permission = RepositoryAccessLease(url: directory ? selected : selected.deletingLastPathComponent())
                } else {
                    permission = await withCheckedContinuation { continuation in
                        let choice = RepositoryCreationFolderChoice(window: window, owner: owner)
                        choice.panel.canChooseFiles = false; choice.panel.canChooseDirectories = true; choice.panel.showsHiddenFiles = true
                        choice.panel.prompt = "Authorize repository"; choice.panel.message = "Choose the folder containing this Settings path."; choice.panel.directoryURL = selected.deletingLastPathComponent()
                        settingsFolderChoice = choice
                        choice.onFinished = { folder in continuation.resume(returning: folder.map { RepositoryAccessLease(url: $0) }) }
                        choice.begin(present: nil, selected: { $0.url })
                    }
                }
                try owner.cancellation.check(); try cancellation?.check(); guard !retired, let permission else { return }
                guard permission.contains(selected), !requiresRepositoryScope || permission.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                let directory = (try? selected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let location = directory ? selected : selected.deletingLastPathComponent()
                guard permission.contains(location) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(location.path) }
                let scopeRequired = requiresRepositoryScope, token = owner.cancellation
                let hint = try await Task.detached { try RepositoryMetadataAccess.settingsRepository(at: location, permissions: [permission], requireSecurityScope: scopeRequired, cancellation: token) }.value
                try owner.cancellation.check(); try cancellation?.check(); guard !retired, !confirmingQuit else { return }
                guard let hint else {
                    guard canChangeSettingsContext() else { return }; onSettingsPage(true, invocation.settingsPage); return
                }
                let prepared = try await prepareRepositoryMetadataAccess(at: hint, primary: permission, cancellation: owner.cancellation)
                let access = permission.retainingRelatedScopes(prepared.scopes)
                let repository = try makeRepository(hint)
                let discovered = try await repository.discoverRoot(cancellation: owner.cancellation)
                try owner.cancellation.check(); try cancellation?.check(); guard !retired, !confirmingQuit else { return }
                guard !requiresRepositoryScope || access.contains(discovered) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(discovered.path) }
                if root?.path == discovered.path { onSettingsPage(false, invocation.settingsPage); return }
                guard canChangeSettingsContext() else { return }
                // Reuse the normal captured adoption/rollback transaction. It
                // rechecks the repository instead of trusting this preflight.
                busy = false; transferred = true
                openSession(access, selected: invocation.request, action: .settings, invocation: invocation, handoffOwner: owner)
                withExtendedLifetime(access) {}
            } catch { if !retired, !owner.cancellation.isCancelled, cancellation?.isCancelled != true { self.error = error.localizedDescription } }
        }
    }
    private func commandImportIsLive(_ owner: RepositoryWindowOwner, cancellation: OperationCancellation?) -> Bool {
        !retired && !confirmingQuit && commandImportOwner === owner && !owner.cancellation.isCancelled && cancellation?.isCancelled != true
    }
    private func chooseCommandImportGrant(file: URL?, owner: RepositoryWindowOwner, window: NSWindow?) async -> RepositoryAccessLease? {
        guard commandImportIsLive(owner, cancellation: nil), window?.attachedSheet == nil else { return nil }
        return await withCheckedContinuation { continuation in
            let choice = RepositoryCreationFolderChoice(window: window, owner: owner)
            choice.panel.canChooseFiles = file != nil; choice.panel.canChooseDirectories = true; choice.panel.showsHiddenFiles = true
            choice.panel.prompt = file == nil ? "Choose repository" : "Authorize patch file"
            choice.panel.message = file.map { "Choose this patch file or its containing folder to allow TurtleGit to import it: " + $0.path } ?? "Choose the repository into which the selected patches will be imported."
            choice.panel.directoryURL = file?.deletingLastPathComponent() ?? root
            commandImportFolderChoice = choice
            choice.onFinished = { [weak self, weak choice] selected in
                guard let self, let choice, self.commandImportFolderChoice === choice else { continuation.resume(returning: nil); return }
                Task { @MainActor [self,choice] in
                    while choice.panel.sheetParent != nil || choice.panel.attachedSheet != nil || window?.attachedSheet === choice.panel {try? await Task.sleep(nanoseconds:5_000_000)}
                    if self.commandImportFolderChoice === choice {self.commandImportFolderChoice=nil}
                    guard self.commandImportIsLive(owner,cancellation:nil),let selected else{continuation.resume(returning:nil);return}
                    continuation.resume(returning:RepositoryAccessLease(url:selected,provider:self.repositoryBookmarkProvider))
                }
            }
            choice.begin(present: presentCommandImportFolderPanel, selected: selectedCommandImportFolderURL)
        }
    }
    private func prepareCommandPatchImport(_ invocation: PrimaryCommandInvocation, cancellation: OperationCancellation?) {
        preparePatchImport(request:invocation.request,initialTarget:invocation.importTarget,cancellation:cancellation)
    }
    private func preparePatchImport(request:FinderRequest,initialTarget:URL?=nil,cancellation:OperationCancellation?=nil,serviceCommand:FinderServiceCommand?=nil,preferences:UserDefaults?=nil) {
        guard commandImportOwner == nil, !retired, !confirmingQuit else { return }
        let owner = RepositoryWindowOwner(window: workspaceWindow), window = workspaceWindow
        let defaults=preferences ?? fileComparisonPreferences
        commandImportOwner = owner; busy = true
        if serviceCommand != nil {finderServiceImportOwner=owner}
        Task {
            var transferred = false
            defer { if !transferred, commandImportOwner === owner { commandImportOwner = nil; busy = false };if !transferred,finderServiceImportOwner === owner{finderServiceImportOwner=nil} }
            do {
                var grants: [RepositoryAccessLease] = [], files: [URL] = []
                for file in request.paths {
                    guard commandImportIsLive(owner, cancellation: cancellation) else { return }
                    let lease: RepositoryAccessLease?
                    if serviceCommand != nil {lease=try await finderFileAccess(file,owner:owner,window:window,leases:grants)}
                    else if let retained = grants.first(where: { $0.contains(file) }) { lease = retained }
                    else if let activeAccess, activeAccess.contains(file), !requiresRepositoryScope || activeAccess.hasSecurityScope { lease = activeAccess }
                    else if let commandLinePatchPermission { lease = try commandLinePatchPermission(file) }
                    else if !requiresRepositoryScope { lease = RepositoryAccessLease(url: file, provider: repositoryBookmarkProvider) }
                    else { lease = await chooseCommandImportGrant(file: file, owner: owner, window: window) }
                    guard commandImportIsLive(owner, cancellation: cancellation), let lease else { return }
                    guard lease.contains(file), !requiresRepositoryScope || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                    grants.append(lease)
                    let isDirectory = await Task.detached { (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.value
                    if !isDirectory { files.append(file) }
                }
                guard commandImportIsLive(owner, cancellation: cancellation) else { return }
                if let serviceCommand,!files.isEmpty {
                    guard serviceCommand.isEligible(paths:request.paths,snapshot:FinderSnapshot(roots:[],states:[:])) else{throw FinderServiceCommand.Failure("Select patch files or one repository folder to apply patches.")}
                }
                var target = initialTarget
                // ImportPatchCommand skips directories in a selected patch
                // batch. They must not silently become the destination repo.
                let source=serviceCommand != nil && !files.isEmpty ? files.first:request.paths.first
                if target == nil, let first = source {
                    var location = first
                    if (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { location.deleteLastPathComponent() }
                    // A file-only grant cannot authorize probing its parent Git
                    // metadata. In that case the owned repository chooser runs.
                    if !requiresRepositoryScope || grants.contains(where: { $0.contains(location) }) {
                        target = try? await makeRepository(location).discoverRoot(cancellation: owner.cancellation)
                    }
                }
                guard commandImportIsLive(owner, cancellation: cancellation) else { return }
                if let target, target.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) {
                    throw PrimaryCommandInvocation.Failure("Choose a working folder outside Git metadata.")
                }
                let repositoryGrant: RepositoryAccessLease?
                if let target,let retained=grants.first(where:{$0.contains(target) && (!requiresRepositoryScope || $0.hasSecurityScope)}) {repositoryGrant=retained}
                else if let target, let activeAccess, activeAccess.contains(target), !requiresRepositoryScope || activeAccess.hasSecurityScope { repositoryGrant = activeAccess }
                else if let target, let commandLineRepositoryPermission { repositoryGrant = try commandLineRepositoryPermission([target]) }
                else if let target, !requiresRepositoryScope { repositoryGrant = RepositoryAccessLease(url: target, provider: repositoryBookmarkProvider) }
                else { repositoryGrant = await chooseCommandImportGrant(file: nil, owner: owner, window: window) }
                guard commandImportIsLive(owner, cancellation: cancellation), let repositoryGrant else { return }
                let requested = target ?? repositoryGrant.url
                guard repositoryGrant.contains(requested), !requiresRepositoryScope || repositoryGrant.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                let selected = FinderRequest(action: .importPatch, paths: [requested])
                transferred = true; busy = false
                openSession(repositoryGrant, selected: selected, onFinished: { [weak self] _ in
                    if self?.commandImportOwner === owner { self?.commandImportOwner = nil }
                    if self?.finderServiceImportOwner === owner {self?.finderServiceImportOwner=nil}
                }, handoffOwner: owner,serviceCommand:serviceCommand,servicePreferences:defaults,onOpened: { [weak self] in
                    guard let self, !self.retired, !owner.cancellation.isCancelled, !self.confirmingQuit, cancellation?.isCancelled != true, let repository = self.repository, let access = self.activeAccess else { return }
                    if self.bare { self.activate(.importPatch); return }
                    let context=serviceCommand.map{_ in FinderServiceDispatchIdentity(action:.importPatch,root:repository.root,preferences:defaults)}
                    FinderServicePresentationContext.$current.withValue(context) {
                        self.showImportPatchFiles(repository: repository, access: access, files: files, grants: grants, commandLaunch: serviceCommand == nil,preferences:defaults)
                    }
                })
            } catch { if commandImportIsLive(owner, cancellation: cancellation) { self.error = error.localizedDescription } }
        }
    }
    private func activateCommandLine(_ invocation: PrimaryCommandInvocation, message: String?, selectedRevision: String?, repository: GitRepository, access: RepositoryAccessLease, outputAccess: RepositoryAccessLease?) {
        let paths = invocation.request.relativePaths(root: repository.root)
        if bare && invocation.request.action.requiresWorkingTree && invocation.request.action != .pull { activate(invocation.request.action, paths: paths); return }
        switch invocation.request.action {
        case .cat:
            guard let file = invocation.outputFile, let permission = outputAccess, let revision = invocation.catRevision, let path = paths.first else { return }
            writeCommandHistoricalFile(repository: repository, access: access, revision: revision, path: path, file: file, permission: permission)
        case .showCompare:
            let preferences=fileComparisonPreferences,repository=repository.capturingDiffBackend(preferences:fileComparisonPreferences)
            let from = invocation.diffFrom.map(ComparisonRevision.revision) ?? .workingTree
            let to = invocation.diffTo.map(ComparisonRevision.revision) ?? .workingTree
            let scope = paths.filter { $0 != "." }
            if invocation.unified {
                prepareFileComparisons(repository: repository, access: access, selectedCount: paths.count, owner: workspaceWindow) { [self] token in
                    let snapshot = try await repository.revisionFileComparison(from: from, to: to, paths: scope, cancellation: token)
                    let bytes = try await repository.revisionComparisonPatchData(snapshot, cancellation: token)
                    try await presentCommandUnifiedDiff(bytes, title: from.label + " → " + to.label, repository: repository, access: access, alternate: invocation.request.alternateTool ?? false, preferences: preferences, cancellation: token)
                }
            } else {
                var directory: ObjCBool = false
                let selected = invocation.request.paths[0]
                if paths == ["."] || (FileManager.default.fileExists(atPath: selected.path, isDirectory: &directory) && directory.boolValue) {
                    showRevisionComparison(repository: repository, access: access, from: from, to: to, paths: scope)
                } else { showHistoricalFiles(repository: repository, access: access, from: from, to: to, paths: scope, owner: workspaceWindow) }
            }
        case .commitIsOnRefs: showCommandContainingReferences(repository: repository, access: access, revision: invocation.selectedRevision ?? "")
        case .revisionGraph:
            if let file = invocation.outputFile, let permission = outputAccess, let format = invocation.graphOutputFormat {
                writeCommandGraph(repository: repository, access: access, file: file, permission: permission, format: format)
            } else { showRevisionGraph(repository: repository, access: access) }
        case .commit: showCommitDialog(repository: repository, access: access, paths: paths, invocation: invocation, commandMessage: message)
        case .log: showLog(repository: repository, access: access, paths: paths, selectedRevision: selectedRevision, invocation: invocation, outputAccess: outputAccess)
        case .blame:
            guard paths.count == 1, paths[0] != "." else { error = "Select one versioned file to blame."; return }
            showBlame(repository: repository, access: access, path: paths[0], revision: invocation.blameRevision ?? "HEAD", line: invocation.line, commandLaunch: true)
        case .previousDiff:
            guard paths.count == 1 else { error = "Select one file or directory to compare."; return }
            showPreviousDiff(repository: repository, access: access, path: paths[0], owner: workspaceWindow, unified: invocation.unified)
        case .daemon: showDaemon(repository: repository, access: access)
        case .settings: onSettingsPage(false, invocation.settingsPage)
        case .requestPull:
            showRequestPull(repository: repository, access: access, end: invocation.request.requestPullEnd, repositoryURL: invocation.request.requestPullURL, commandLaunch: true)
        case .worktreeCreate:
            do {
                let directory = try invocation.worktreeDropTarget.map { try WorktreeCreationOptions.dropDestination(repository: repository.root, target: $0) }
                showWorktreeCreate(repository: repository, access: access, directory: directory, commandLaunch: true)
            } catch { self.error = error.localizedDescription }
        case .worktreeList: showWorktreeList(repository: repository, access: access)
        case .lfsLocks: showLFSLocks(repository: repository, access: access)
        case .lfsLock, .lfsUnlock:
            showFinderLFSOperation(repository: repository, access: access, paths: paths, locked: invocation.request.action == .lfsLock, force: invocation.forceLFSUnlock, commandLaunch: true)
        case .add: showAdd(repository: repository, access: access, paths: paths, commandLaunch: true)
        case .clean: showClean(repository: repository, access: access, paths: paths, commandLaunch: true)
        case .submoduleAdd:
            var folder = invocation.request.paths[0], directory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) || !directory.boolValue { folder.deleteLastPathComponent() }
            let path = FinderRequest(action: .submoduleAdd, paths: [folder]).relativePaths(root: repository.root).first ?? ""
            showSubmoduleAdd(repository: repository, access: access, path: path, commandLaunch: true)
        case .submoduleUpdate, .submoduleSync:
            let directories = invocation.request.paths.filter { url in
                var directory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
            }
            let scope = FinderRequest(action: invocation.request.action, paths: directories).relativePaths(root: repository.root)
            if invocation.request.action == .submoduleUpdate {
                showSubmoduleUpdate(repository: repository, access: access, scope: scope, selected: invocation.selectedSubmodule.map { [$0] } ?? [], commandLaunch: true)
            } else { showSubmoduleSync(repository: repository, access: access, scope: paths, commandLaunch: true) }
        case .synchronize: showSynchronization(sequence: invocation.synchronizationSequence ?? 0)
        case .svnFetch, .svnRebase, .svnDCommit, .svnIgnore:
            if let operation = invocation.request.action.svnOperation { showSVN(operation, repository: repository, access: access) }
        case .fetch: showFetch(repository: repository, access: access, remote: invocation.remote)
        case .pull: showFetch(repository: repository, access: access, isPull: true)
        case .push: showPush(repository: repository, access: access, source: invocation.pushBranch)
        case .branch, .tag: showReference(repository: repository, access: access, isTag: invocation.request.action == .tag, revision: invocation.selectedRevision, name: invocation.creationName)
        case .switchBranch: showSwitch(repository: repository, access: access, revision: invocation.selectedRevision)
        case .referenceBrowser: showReferenceBrowser(repository: repository, access: access)
        case .repositoryBrowser: showRepositoryBrowser(repository: repository, access: access, revision: invocation.selectedRevision ?? "HEAD")
        case .reflog: showReferenceLog(repository: repository, access: access, reference: invocation.reflogReference ?? "HEAD")
        case .rebase: showRebase(repository: repository, access: access, upstream: invocation.upstream, force: invocation.forceRebase, commandLaunch: true)
        case .merge: showMerge(repository: repository, access: access, commandLaunch: true)
        case .mergeAbort: showMergeAbort(repository: repository, access: access, commandLaunch: true)
        case .stash: showStash(repository: repository, access: access, message: invocation.message, commandLaunch: true)
        case .stashApply, .stashPop: showStashRestore(repository: repository, access: access, pop: invocation.request.action == .stashPop)
        case .stashList: showReferenceLog(repository: repository, access: access, reference: "refs/stash")
        case .bisect: showBisect(repository: repository, access: access, command: invocation.bisectCommand)
        case .formatPatch: showFormatPatch(repository: repository, access: access, preset: invocation.formatPatchPreset, commandLaunch: true)
        case .export: showExport(repository: repository, access: access, revision: invocation.selectedRevision ?? "HEAD", paths: paths, commandLaunch: true)
        case .diff:
            var directory: ObjCBool = false
            if let first = invocation.request.paths.first, FileManager.default.fileExists(atPath: first.path, isDirectory: &directory), directory.boolValue {
                activate(.diff, paths: paths)
            } else if invocation.unified {
                showCommandUnifiedDiff(invocation, repository: repository, access: access, paths: paths)
            } else if let from = invocation.diffFromRevision, let to = invocation.diffToRevision {
                showHistoricalFiles(repository: repository, access: access, from: from, to: to, paths: paths.contains(".") ? [] : paths, owner: workspaceWindow, line: invocation.line)
            } else { showWorkingFiles(repository: repository, access: access, paths: paths, owner: workspaceWindow, line: invocation.line) }
        default: activate(invocation.request.action, paths: paths)
        }
    }
    private var commandRepositoryBatchCancellation: OperationCancellation?
    private var commandTransportOwner:RepositoryWindowOwner?
    private var commandTransportFolderChoice:RepositoryCreationFolderChoice?
    private var commandTransportChain:RepositoryTransportBatchChain?
    var presentCommandTransportFolderPanel:((NSOpenPanel,NSWindow?,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    var selectedCommandTransportFolderURL:(NSOpenPanel)->URL?={$0.url}
    private func cancelCommandTransportBatch(){commandRepositoryBatchCancellation?.cancel();commandTransportOwner?.cancellation.cancel();commandTransportFolderChoice?.cancel();commandTransportChain?.cancel()}
    private func commandTransportAccess(_ paths:[URL],owner:RepositoryWindowOwner) async -> RepositoryAccessLease? {
        guard !owner.cancellation.isCancelled,!retired,!confirmingQuit,workspaceWindow?.attachedSheet==nil else{return nil}
        let choice=RepositoryCreationFolderChoice(window:workspaceWindow,owner:owner),panel=choice.panel
        commandTransportFolderChoice=choice
        panel.title="Allow repository folder access";panel.prompt="Allow Access"
        panel.message="Choose a folder containing the selected repository roots to allow this command batch."
        panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false;panel.showsHiddenFiles=true
        panel.directoryURL=paths.first?.deletingLastPathComponent();panel.alphaValue=workspaceWindow?.alphaValue ?? 1;panel.appearance=workspaceWindow?.appearance
        let folder:URL?=await withCheckedContinuation { continuation in
            choice.onFinished={ selected in continuation.resume(returning:selected) }
            choice.begin(present:presentCommandTransportFolderPanel,selected:selectedCommandTransportFolderURL)
        }
        while panel.sheetParent != nil || panel.attachedSheet != nil {try? await Task.sleep(nanoseconds:5_000_000)}
        if commandTransportFolderChoice === choice {commandTransportFolderChoice=nil}
        guard !retired,!confirmingQuit,!owner.cancellation.isCancelled,let folder else{return nil}
        let lease=RepositoryAccessLease(url:folder,provider:repositoryBookmarkProvider)
        guard paths.allSatisfy({lease.contains($0)}),!requiresRepositoryScope || lease.hasSecurityScope else {
            error="The selected folder does not authorize every requested repository.";return nil
        }
        return lease
    }
    private func launchCommandRepositoryBatch(_ invocation: PrimaryCommandInvocation, cancellation: OperationCancellation?) {
        let owner=RepositoryWindowOwner(window:workspaceWindow),token=cancellation ?? owner.cancellation
        commandRepositoryBatchCancellation=token;commandTransportOwner=owner
        Self.activeCommandFileOperations += 1
        let batchGeneration=adoptionGeneration
        Task { [self,owner] in
            let cancellationMonitor=Task { @MainActor [weak self] in
                while !Task.isCancelled,!token.isCancelled,!owner.cancellation.isCancelled {do{try await Task.sleep(nanoseconds:20_000_000)}catch{return}}
                guard !Task.isCancelled else{return}
                token.cancel();owner.cancellation.cancel();self?.commandTransportFolderChoice?.cancel();self?.commandTransportChain?.cancel()
            }
            defer{cancellationMonitor.cancel()}
            var expectedGeneration=batchGeneration,failures:[String]=[]
            var leases:[RepositoryAccessLease]=[]
            defer {
                commandTransportChain=nil
                if commandTransportOwner === owner {commandTransportOwner=nil}
                if commandRepositoryBatchCancellation === token {commandRepositoryBatchCancellation=nil}
                Self.activeCommandFileOperations -= 1
                if !retired,!token.isCancelled,!owner.cancellation.isCancelled,!failures.isEmpty {error=failures.joined(separator:"\n")}
                withExtendedLifetime((leases,owner)){}
            }
            @MainActor func allowed()->Bool {!retired && !confirmingQuit && !token.isCancelled && !owner.cancellation.isCancelled && adoptionGeneration==expectedGeneration}
            if let activeAccess,!requiresRepositoryScope || activeAccess.hasSecurityScope {leases.append(activeAccess)}
            if let store=accessStore {
                for saved in store.repositories {
                    if let lease=try? store.acquire(saved.id,requireSecurityScope:requiresRepositoryScope),invocation.transportPaths.contains(where:{lease.contains($0)}) {leases.append(lease)}
                }
            }
            // Preserve the explicit CLI permission seam per selected root. The
            // real application obtains missing collective authority in one
            // cancellable owned common-folder sheet, never runModal().
            if commandLineRepositoryPermission == nil,!invocation.transportPaths.allSatisfy({path in leases.contains{$0.contains(path)}}) {
                guard let lease=await commandTransportAccess(invocation.transportPaths,owner:owner) else {token.cancel();return}
                leases.append(lease)
            }
            owner.onCancelled={ [weak self] in token.cancel();self?.commandTransportChain?.cancel() }
            for path in invocation.transportPaths {
                while busy,allowed(){try? await Task.sleep(nanoseconds:10_000_000)}
                guard allowed() else{return}
                var access=leases.first{$0.contains(path) && (!requiresRepositoryScope || $0.hasSecurityScope)}
                if access==nil,let permission=commandLineRepositoryPermission {
                    do {
                        access=try permission([path])
                        guard allowed() else{return}
                        if let access {
                            guard access.contains(path),!requiresRepositoryScope || access.hasSecurityScope else {throw RepositoryAccessFailure.securityScopeUnavailable}
                            leases.append(access)
                        }
                    } catch {failures.append(path.path+": "+error.localizedDescription);continue}
                }
                guard let access else{failures.append(path.path+": "+RepositoryAccessFailure.securityScopeUnavailable.localizedDescription);continue}
                let nextGeneration=expectedGeneration+1
                let chain=RepositoryTransportBatchChain(root:path,command:true,allowed:{ [weak self] in self.map{!$0.retired && !$0.confirmingQuit && !token.isCancelled && !owner.cancellation.isCancelled && $0.adoptionGeneration==nextGeneration} ?? false})
                commandTransportChain=chain
                defer{chain.releaseCompleted()}
                let next=invocation.selecting([path])
                let opened:Bool=await withCheckedContinuation { continuation in
                    TransportBatchPresentationContext.$chain.withValue(chain) {
                        openSession(access,selected:next.request,action:next.request.action,invocation:next,commandRootOnly:true,onFinished:{continuation.resume(returning:$0)},handoffOwner:owner)
                    }
                }
                if adoptionGeneration != nextGeneration {
                    token.cancel();chain.cancel()
                    while chain.hasPendingWork {try? await Task.sleep(nanoseconds:10_000_000)}
                    return
                }
                expectedGeneration=nextGeneration
                if !opened || chain.controller == nil {
                    if let failure=error {failures.append(path.path+": "+failure)}
                    if commandTransportChain === chain {commandTransportChain=nil}
                    continue
                }
                while chain.hasPendingWork {
                    if !allowed(){token.cancel();chain.cancel()}
                    try? await Task.sleep(nanoseconds:10_000_000)
                }
                if commandTransportChain === chain {commandTransportChain=nil}
                guard allowed() else{return}
            }
        }
    }
    private var commandUnifiedWindows: [UUID: PatchWindowController] = [:]
    var commandUnifiedPresentation: ((Data) -> Void)?
    private func showCommandUnifiedDiff(_ invocation: PrimaryCommandInvocation, repository: GitRepository, access: RepositoryAccessLease, paths: [String]) {
        prepareFileComparisons(repository: repository, access: access, selectedCount: paths.count, owner: workspaceWindow) { [self] token in
            let bytes = try await repository.commandUnifiedDiff(from: invocation.diffFrom, to: invocation.diffTo, paths: paths, cancellation: token)
            let title = (invocation.diffFrom ?? "HEAD") + " → " + (invocation.diffTo ?? "Working tree")
            try await presentCommandUnifiedDiff(bytes, title: title, repository: repository, access: access, alternate: invocation.request.alternateTool ?? false, preferences: fileComparisonPreferences, cancellation: token)
        }
    }
    private func presentCommandUnifiedDiff(_ bytes: Data, title: String, repository: GitRepository, access: RepositoryAccessLease?, alternate: Bool, preferences: UserDefaults, cancellation: OperationCancellation) async throws {
        try cancellation.check(); guard !confirmingQuit, !retired else { return }
        if let commandUnifiedPresentation { commandUnifiedPresentation(bytes); return }
        if try await UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: preferences, title: title, permissions: access.map { [$0] } ?? [], cancellation: cancellation) { return }
        try cancellation.check(); guard !confirmingQuit, !retired else { return }
        let id = UUID()
        let controller = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: nil, title: title, preferences: preferences, onClosed: { [weak self] in self?.commandUnifiedWindows.removeValue(forKey: id) })
        commandUnifiedWindows[id] = controller
    }
    private func presentInaccessibleRepository(repository: GitRepository, access: RepositoryAccessLease, diagnosis: GitRepositoryDiagnosis? = nil) {
        guard !retired, !confirmingQuit else { return }
        let key = Data(repository.root.path.utf8)
        if let existing = inaccessibleWindows[key], !existing.model.retired {
            if let inaccessiblePresentation { inaccessiblePresentation(existing) }
            else { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil) }
            if existing.model.available { existing.model.refresh() }; return
        }
        let controller = InaccessibleRepositoryWindowController(repository: repository, access: access, diagnosis: diagnosis)
        if let read = inaccessibleReadDiagnosis { controller.model.readDiagnosis = { try await read(repository, $0) } }
        configureInaccessibleWindow?(controller)
        controller.model.onRetry = { [weak self, weak controller] in
            guard let self, let controller, !self.retired, !self.busy, !self.confirmingQuit,
                  self.inaccessibleWindows[key] === controller, controller.model.canRetry else { return }
            // Source ends after trust; reopening is an explicit native action.
            controller.close(); self.openSession(access, requestedLocation: repository.root)
        }
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller, self.inaccessibleWindows[key] === controller else { return }
            self.inaccessibleWindows.removeValue(forKey: key)
        }
        inaccessibleWindows[key] = controller
        if let inaccessiblePresentation { inaccessiblePresentation(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        if diagnosis == nil { controller.model.refresh() }
    }
    /// Failed roots must not pass repository discovery just to show diagnostics.
    private func openInaccessibleRepository(_ requested: URL, invocation: PrimaryCommandInvocation?, completion: ((Bool) -> Void)?) {
        guard !retired, !busy, !confirmingQuit else { completion?(false); return }
        guard requested.isFileURL, requested.path.hasPrefix("/"), !requested.path.utf8.contains(0) else {
            error = "Select one inaccessible repository folder."; completion?(false); return
        }
        let id = UUID(), token = OperationCancellation(), originalWindow = workspaceWindow
        inaccessiblePreparations[id] = token; Self.activeInaccessiblePreparations += 1
        let observer = originalWindow.map { NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: $0, queue: .main) { _ in token.cancel() } }
        Task { [self] in
            defer {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                inaccessiblePreparations.removeValue(forKey: id); inaccessibleFolderPrompts.removeValue(forKey: id)
                Self.activeInaccessiblePreparations -= 1
            }
            do {
                let lease: RepositoryAccessLease?
                if let inaccessibleFolderPermission { lease = try await inaccessibleFolderPermission(requested, token) }
                else if let activeAccess, activeAccess.contains(requested), !requiresRepositoryScope || activeAccess.hasSecurityScope { lease = activeAccess }
                else if invocation != nil, let commandLineRepositoryPermission { lease = try commandLineRepositoryPermission([requested]) }
                else if let stored = accessStore?.repositories.first(where: { RepositoryAccessLease.pathIsContained(requested, by: URL(fileURLWithPath: $0.lastKnownPath)) }), let accessStore {
                    lease = try accessStore.acquire(stored.id, requireSecurityScope: requiresRepositoryScope, recordingOpen: false)
                } else if !requiresRepositoryScope { lease = RepositoryAccessLease(url: requested, provider: repositoryBookmarkProvider) }
                else {
                    let prompt = RepositoryMetadataPermissionPrompt(); inaccessibleFolderPrompts[id] = prompt
                    let selected = await prompt.chooseFolder(requested, explanation: "Allow TurtleGit to read this folder to diagnose Git access. This does not mark the repository as trusted.", owner: originalWindow, cancellation: token)
                    lease = selected.map { RepositoryAccessLease(url: $0, provider: repositoryBookmarkProvider) }
                }
                try token.check()
                guard !retired, !confirmingQuit, inaccessiblePreparations[id] === token, let lease else { completion?(false); return }
                guard lease.contains(requested), !requiresRepositoryScope || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                // Sandbox denial can look like ENOENT: inspect the requested
                // folder only after its retained authorization has been acquired.
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: requested.path, isDirectory: &directory), directory.boolValue else {
                    throw PrimaryCommandInvocation.Failure("Select one inaccessible repository folder.")
                }
                let repository = try makeRepository(requested)
                presentInaccessibleRepository(repository: repository, access: lease); completion?(true)
            } catch {
                if !retired, !token.isCancelled { self.error = error.localizedDescription }; completion?(false)
            }
        }
    }
    private func handleFinderRequest(_ request:FinderRequest, invocation: PrimaryCommandInvocation? = nil, messageAccess: RepositoryAccessLease? = nil, outputAccess: RepositoryAccessLease? = nil, commandCancellation: OperationCancellation? = nil, commandRootOnly: Bool = false, completion: ((Bool) -> Void)? = nil) {
        var handedOff = false
        defer { if !handedOff { completion?(false) } }
        guard commandCancellation?.isCancelled != true else { return }
        let action = request.action
        if action == .registerRepository {
            handedOff=handleFinderService(request);if handedOff {completion?(true)};return
        }
        if action == .inaccessible {
            guard request.paths.count == 1 else { error = "Select one inaccessible repository folder."; return }
            handedOff = true
            openInaccessibleRepository(request.paths[0], invocation: invocation, completion: completion)
            return
        }
        if action == .settings {
            let knownRoot = request.paths.first.flatMap { selected in
                FinderSnapshot.readLive()?.roots.sorted { $0.count > $1.count }.first { selected.path == $0 || selected.path.hasPrefix($0 + "/") }
                    ?? root.flatMap { selected.path == $0.path || selected.path.hasPrefix($0.path + "/") ? $0.path : nil }
            }
            if knownRoot == nil { onSettings(true); return }
            if knownRoot == root?.path { onSettings(false); return }
            guard canChangeSettingsContext() else { return }
        } else if action.isApplicationUtility { activate(action); return }
        guard !busy else { return }
        if action == .reviewPatch {
            if let receipt = request.clipboardPatch { showFinderClipboardPatch(request, receipt: receipt) }
            else { showReviewPatch(files: request.paths) }; return
        }
        if action == .transferFiles, request.isTransferSourceSelection { handedOff = true; prepareFinderSourceTransfer(request, completion: completion); return }
        if action == .worktreeCreate,invocation == nil {handedOff=true;prepareFinderWorktreeCreation(request,completion:completion);return}
        if action == .sendMail { showFinderSendMail(files: request.paths); return }
        if action == .clearComparisonMark { clearComparisonMark(); return }
        if action == .diffLater {
            guard request.paths.count == 1 else { error = "Select one file to mark or compare."; return }
            launchFinderFileWorkflow(request); return
        }
        if action == .clone { showClone(directory: request.paths.first); return }
        if action == .initialize { showCreateRepository(folder: request.paths.first); return }
        if action == .diff && request.paths.count == 2 { launchFinderFileWorkflow(request,line:invocation?.line); return }
        let candidate = request.paths[0]
        // The link's parent contains the Git entry; its target is not read by
        // Blame. Keep the original request URLs for relative path dispatch.
        var permissionTargets = action == .blame ? request.paths.map { $0.standardizedFileURL.deletingLastPathComponent() } : request.paths
        if let discovery = invocation?.submoduleDiscoveryURL { permissionTargets.append(discovery) }
        if action == .rename || action == .remove || action == .submoduleSync || action == .logSubmodule || action == .properties,
           let parent = FinderSnapshot.readLive()?.repositories[candidate.standardizedFileURL.path]?.submoduleParentRoot {
            let parentURL = URL(fileURLWithPath: parent, isDirectory: true)
            if parentURL.path != candidate.path && candidate.standardizedFileURL.path.hasPrefix(parentURL.path.hasSuffix("/") ? parentURL.path : parentURL.path + "/") {
                permissionTargets.append(parentURL)
            }
        }
        // A URL from Finder or another app is a request, not a sandbox permission grant.
        if let activeAccess, permissionTargets.allSatisfy({ activeAccess.contains($0) }) {
            handedOff = true
            openSession(activeAccess, selected: request, action: action, invocation: invocation, messageAccess: messageAccess, outputAccess: outputAccess, commandRootOnly: commandRootOnly, onFinished: completion)
            return
        }
        if let store = accessStore {
            for saved in store.repositories {
                guard let lease = try? store.acquire(saved.id, requireSecurityScope: GitRuntime.isAppStoreBuild),
                      permissionTargets.allSatisfy({ lease.contains($0) }) else { continue }
                recentRepositories = store.repositories
                handedOff = true
                openSession(lease, selected: request, action: action, invocation: invocation, messageAccess: messageAccess, outputAccess: outputAccess, commandRootOnly: commandRootOnly, onFinished: completion)
                return
            }
        }
        if invocation != nil, let commandLineRepositoryPermission {
            do {
                guard let lease = try commandLineRepositoryPermission(permissionTargets), commandCancellation?.isCancelled != true else { return }
                guard permissionTargets.allSatisfy({ lease.contains($0) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                handedOff = true
                openSession(lease, selected: request, action: action, invocation: invocation, messageAccess: messageAccess, outputAccess: outputAccess, commandRootOnly: commandRootOnly, onFinished: completion)
            } catch { self.error = error.localizedDescription }
            return
        }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Authorize repository"
        panel.message = "Choose the repository root containing the requested selection to allow TurtleGit to work with it."
        panel.directoryURL = permissionTargets.count > request.paths.count ? permissionTargets.last : (candidate.hasDirectoryPath ? candidate : candidate.deletingLastPathComponent())
        guard panel.runModal() == .OK, let url = panel.url, commandCancellation?.isCancelled != true else { return }
        let lease = RepositoryAccessLease(url: url)
        guard permissionTargets.allSatisfy({ lease.contains($0) }) else {
            error = "The selected folder does not contain every requested item."; return
        }
        handedOff = true
        openSession(lease, selected: request, action: action, invocation: invocation, messageAccess: messageAccess, outputAccess: outputAccess, commandRootOnly: commandRootOnly, onFinished: completion)
    }
}

private enum FinderSelectionFailure: LocalizedError {
    case multipleRepositories
    var errorDescription: String? { "Select files from one repository at a time. The Finder selection spans different repositories." }
}

/// One captured initiating window and token for every conflict-editor route.
/// The preparation sheet is dismissed before handing control to an editor/tool.
@MainActor final class ConflictEditorLaunch: NSObject, NSWindowDelegate {
    let session: FileListComparisonSession
    private weak var owner: NSWindow?
    private var panel: NSPanel?
    private weak var cancelButton: NSButton?
    init(owner: NSWindow?, preferences: UserDefaults, alternateTool: Bool) { self.owner = owner; session = FileListComparisonSession(window: owner, preferences: preferences, alternateTool: alternateTool); super.init() }
    func showProgress(path: String) {
        guard panel == nil, !session.cancellation.isCancelled else { return }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 110))
        let progress = NSProgressIndicator(); progress.style = .spinning; progress.controlSize = .small; progress.isIndeterminate = true; progress.startAnimation(nil)
        progress.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([progress.widthAnchor.constraint(equalToConstant: 16), progress.heightAnchor.constraint(equalToConstant: 16)])
        let title = NSTextField(labelWithString: "Preparing conflict editor…"), file = NSTextField(labelWithString: path)
        file.lineBreakMode = .byTruncatingMiddle; file.maximumNumberOfLines = 1; file.toolTip = path
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancelButton = cancel; cancel.keyEquivalent = "\u{1b}"
        let heading = NSStackView(views: [progress, title, cancel]); heading.orientation = .horizontal; heading.spacing = 12
        let stack = NSStackView(views: [heading, file]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        let panel = NSPanel(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Conflict – TurtleGit"; panel.contentView = view; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.alphaValue=owner?.alphaValue ?? 1;panel.appearance=owner?.appearance;self.panel = panel
        if let owner, owner.isVisible, owner.attachedSheet == nil { owner.beginSheet(panel) }
        else { panel.center(); panel.orderFront(nil) }
    }
    @objc func cancel() { session.cancel(); cancelButton?.isEnabled = false; cancelButton?.title = "Cancelling…" }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    func dismissProgress() {
        guard let panel else { return }; self.panel = nil; cancelButton = nil; panel.delegate = nil
        if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }; panel.orderOut(nil); panel.close()
    }
}

/// The metadata picker belongs to the initiating workspace and cancellation token.
@MainActor private final class RepositoryMetadataPermissionPrompt {
    private var panel:NSOpenPanel?
    private var response:((URL?)->Void)?
    private var observer:NSObjectProtocol?
    private var monitor:Task<Void,Never>?
    private var token:OperationCancellation?
    func choose(_ requirement:RepositoryMetadataAccessRequirement,owner:NSWindow?,cancellation:OperationCancellation) async -> URL? {
        await chooseFolder(requirement.folder, explanation: requirement.explanation, owner: owner, cancellation: cancellation)
    }
    func chooseFolder(_ folder:URL,explanation:String,owner:NSWindow?,cancellation:OperationCancellation) async -> URL? {
        guard !cancellation.isCancelled,owner?.attachedSheet==nil else { return nil }
        token=cancellation
        let picker=NSOpenPanel();panel=picker
        picker.title="Allow repository folder access";picker.prompt="Allow Access"
        picker.message=explanation+"\n\nSelect this folder, or a parent folder: "+folder.path
        picker.canChooseDirectories=true;picker.canChooseFiles=false;picker.allowsMultipleSelection=false
        picker.directoryURL=folder;picker.appearance=owner?.appearance;picker.alphaValue=owner?.alphaValue ?? 1
        if let owner { observer=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:owner,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } } }
        monitor=Task { [weak self] in
            while !cancellation.isCancelled,!Task.isCancelled { do { try await Task.sleep(nanoseconds:20_000_000) } catch { return } }
            if cancellation.isCancelled { self?.cancel() }
        }
        return await withCheckedContinuation { continuation in
            response={ continuation.resume(returning:$0) }
            let completed:(NSApplication.ModalResponse)->Void={ [weak self,weak picker] value in
                guard let self else { return };self.finish(value == .OK && !cancellation.isCancelled ? picker?.url : nil)
            }
            if let owner { picker.beginSheetModal(for:owner,completionHandler:completed) }
            else { NSApp.activate(ignoringOtherApps:true);picker.begin(completionHandler:completed) }
        }
    }
    private func finish(_ url:URL?) {
        guard let response else { return };self.response=nil
        monitor?.cancel();monitor=nil
        if let observer { NotificationCenter.default.removeObserver(observer);self.observer=nil }
        panel=nil;response(url)
    }
    func cancel() {
        token?.cancel()
        if let panel { panel.sheetParent?.endSheet(panel,returnCode:.cancel);panel.orderOut(nil);panel.close() }
        finish(nil)
    }
    deinit { monitor?.cancel();if let observer { NotificationCenter.default.removeObserver(observer) } }
}
