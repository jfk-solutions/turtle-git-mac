import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

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
            guard let self else { return }
            self.finish(response == .OK && !self.owner.cancellation.isCancelled ? selected(self.panel) : nil)
        }
        if let present { present(panel, window, reply) }
        else if let window { panel.beginSheetModal(for: window, completionHandler: reply) }
        else { panel.begin(completionHandler: reply) }
    }
    private func finish(_ selected: URL?) {
        guard !completed else { return }; completed = true
        if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: selected == nil ? .cancel : .OK) }
        panel.orderOut(nil); panel.close()
        let reply = onFinished; onFinished = { _ in }; reply(selected)
    }
    func cancel() { owner.cancellation.cancel(); finish(nil) }
}

@MainActor final class RepositoryModel: ObservableObject {
    private let autotextTester = AutotextTesterOwner()
    func showAutotextTester() {
        guard !busy, !confirmingQuit else { return }
        autotextTester.show()
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
    @Published var confirmingQuit = false { didSet { if confirmingQuit != oldValue { retireWorkspaceMenus() };repositoryAccessWindow?.model.objectWillChange.send();if !confirmingQuit { eventRefresh?.kick(); scheduleCompletedRepositoryHandoff() } } }
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
    private var logWindows: [String: LogWindowController] = [:]
    private struct ConfiguredLog { weak var model:LogWindowModel? }
    private var configuredLogModels:[ObjectIdentifier:ConfiguredLog]=[:]
    var logWindowFactory:((GitRepository,RepositoryAccessLease?)->LogWindowController)?
    private var revisionGraphWindows: [String: RevisionGraphWindowController] = [:]
    private var referenceBrowserWindows: [String: ReferenceBrowserWindowController] = [:]
    private var browserWindows: [String: RepositoryBrowserWindowController] = [:]
    private var worktreeListWindows: [String: WorktreeListWindowController] = [:]
    var worktreeCreateWindowFactory: ((GitRepository, RepositoryAccessLease?, UserDefaults, URL?) -> WorktreeCreateWindowController)?
    var worktreeListWindowFactory: ((GitRepository, RepositoryAccessLease?, UserDefaults) -> WorktreeListWindowController)?
    private var worktreeCreateWindows: [String: WorktreeCreateWindowController] = [:]
    var requestPullPresentation: ((RequestPullWindowController) -> Void)?
    var makeRequestPull: (GitRepository, RepositoryAccessLease?, String?, String?) -> RequestPullWindowController = { repository, access, end, url in
        RequestPullWindowController(repository: repository, access: access, end: end, repositoryURL: url)
    }
    private var requestPullWindows: [String: RequestPullWindowController] = [:]
    private var importPatchWindows: [String: ImportPatchWindowController] = [:]
    private var formatPatchWindows: [String: FormatPatchWindowController] = [:]
    private(set) var blameWindows = GitPathMap<BlameWindowController>()
    var blameRecentDocuments:BlameRecentDocuments?
    private var rebaseWindows: [String: RebaseWindowController] = [:]
    private var fetchWindows: [String: FetchWindowController] = [:]
    private var pushWindows: [String: PushWindowController] = [:]
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
    var daemonPresentation: ((GitDaemonWindowController) -> Void)?
    private var lfsLocksWindows: [String: LFSLocksWindowController] = [:]
    private var lfsFileOperations: [UUID: LFSFileOperationController] = [:]
    private var reviewPatchWorkflows: [UUID: ReviewPatchWorkflow] = [:]
    private(set) var patchDocumentWindows: [UUID: PatchWindowController] = [:]
    private var patchDocumentOpeningPaths: [UUID: Data] = [:]
    var patchDocumentPresentation: ((PatchWindowController) -> Void)?
    var configurePatchDocument: (PatchWindowController) -> Void = { _ in }
    var reviewPatchPreferences: UserDefaults = .standard
    var finderPatchHandoff: FinderPatchHandoff? = .current
    private var finderPatchReceipts: [String] = []
    var reviewPatchPreparation: ((ReviewPatchWorkflow) -> Void)?
    var reviewPatchPresentation: ((WorkingTreePatchWindowController) -> Void)?
    private var finderMailWorkflows: [UUID: SendMailWorkflow] = [:]
    var finderMailPresentation: ((NSWindowController) -> Void)?
    private var addProgressWindows: [UUID: AddProgressWindowController] = [:]
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
    var presentCreationFolderPanel: ((NSOpenPanel, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    var selectedCreationFolderURL: (NSOpenPanel) -> URL? = { $0.url }
    private var creationFolderChoice: RepositoryCreationFolderChoice?
    var finderTransferPresentation: ((FinderRequest, GitRepository, RepositoryAccessLease) -> Void)?
    private var copyWindows: [UUID: FileCopyWindowController] = [:]
    private(set) var moveWindows: [String: FileMoveWindowController] = [:]
    private var renameWindows: [String: RenameWindowController] = [:]
    private(set) var imageConflictWindows = GitPathMap<ImageConflictWindowController>()
    private(set) var textConflictWindows = GitPathMap<TextConflictWindowController>()
    private(set) var submoduleDiffWindows = GitPathMap<SubmoduleDiffWindowController>()
    private var revisionComparisonWindows: [String: RevisionComparisonWindowController] = [:]
    private var imageLoader: ImageLoadWindowController?
    private(set) var fileComparisonWindows = GitPathMap<FileComparisonWindowController>()
    private var submoduleSyncWindows: [UUID: SubmoduleSyncWindowController] = [:]
    private var submoduleAddWindows: [String: SubmoduleAddWindowController] = [:]
    private var submoduleAddProgressWindows: [UUID: SubmoduleAddProgressWindowController] = [:]
    private var submoduleUpdateProgressWindows: [UUID: SubmoduleUpdateProgressWindowController] = [:]
    private var submoduleUpdateWindows: [String: SubmoduleUpdateWindowController] = [:]
    private var submoduleConflictWindows: [String: SubmoduleConflictWindowController] = [:]
    private var deleteConflictWindows: [String: DeleteConflictWindowController] = [:]
    private var resetWindows: [String: ResetWindowController] = [:]
    private var resolveWindows: [String: ResolveWindowController] = [:]
    private var ignoreWindows: [String: IgnoreWindowController] = [:]
    var ignoreWindowFactory: ((GitRepository, RepositoryAccessLease?, [String], Bool, Bool) throws -> IgnoreWindowController)?
    private var removeWindows: [String: RemoveWindowController] = [:]
    var removeWindowFactory: ((GitRepository, RepositoryAccessLease?, RemovalRequest) -> RemoveWindowController)?
    private var adoptionGeneration = 0
    private var retired = false
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
    var hasPendingRepositoryWork: Bool { hasPendingRepositoryHandoff || !addPreparations.isEmpty || !lfsPreparations.isEmpty || creationFolderChoice != nil || commandImportOwner != nil || !commandOutputOwners.isEmpty }
    private var lfsPreparations: [UUID: RepositoryWindowOwner] = [:]
    var lfsSelectionPreflight: ((GitRepository, [String], Bool, OperationCancellation) async throws -> [String])?
    var lfsLocksWindowFactory: ((GitRepository, RepositoryAccessLease?, UserDefaults) -> LFSLocksWindowController)?
    var lfsFileOperationFactory: ((GitRepository, RepositoryAccessLease?, UserDefaults) -> LFSFileOperationController)?
    private var addPreparations: [UUID: RepositoryWindowOwner] = [:]
    private var commandOutputOwners: [UUID: RepositoryWindowOwner] = [:]
    private var commandGraphWindows: [UUID: RevisionGraphWindowController] = [:]
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
    var notifyFinder:()->Void = { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification),object:nil) }
    private(set) var finderWatches:FinderWatchManager?
    private let monitoringEnabled:Bool
    private var fileMonitor:RepositoryFileEventMonitor?
    private var eventRefresh:RepositoryEventRefresh?
    private var watchIdentity=UUID()
    private var watchPaths:[URL]=[]
    func stopMonitoringForTermination() { retired = true; completedRepositoryHandoff = nil; creationFolderChoice?.cancel(); commandImportOwner?.cancellation.cancel(); commandImportFolderChoice?.cancel(); for owner in addPreparations.values { owner.cancellation.cancel() }; for owner in lfsPreparations.values { owner.cancellation.cancel() }; commandLineInputCancellation?.cancel(); commandRepositoryBatchCancellation?.cancel(); for token in commandLineOutputOperations.values { token.cancel() };for owner in commandOutputOwners.values { owner.cancellation.cancel(); owner.onCancelled() };for controller in Array(commandReferenceWindows.values) { controller.close() }; repositoryAccessWindow?.model.retire();repositoryAccessWindow?.close();adoptionCancellation?.cancel();repositoryPermissionPrompt?.cancel();cancelConflictEditorPreparations(); stopFileMonitoring() }
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

    init(startMonitoring: Bool = true,initializePreferences:Bool = true,repositoryFactory:((URL) throws -> GitRepository)? = nil,snapshotWriter:(@Sendable (FinderSnapshot) throws -> Bool)? = nil,snapshotStore:FinderSnapshotStore? = nil,finderWatches:FinderWatchManager? = nil,savedAccessStore:RepositoryAccessStore? = nil,comparisonMarks:WorkingComparisonMarkStore? = nil) {
        comparisonMarkStore=comparisonMarks ?? WorkingComparisonMarkStore(storageURL:WorkingComparisonMarkStore.defaultStorageURL)
        self.accessStore=savedAccessStore;recentRepositories=savedAccessStore?.repositories ?? []
        self.finderWatches=finderWatches
        self.repositoryFactory=repositoryFactory;self.snapshotWriter=snapshotWriter
        self.snapshotStore=snapshotStore ?? FinderIntegration.snapshotURL.map { FinderSnapshotStore(url:$0) }
        if self.snapshotStore != nil { finderStatus = "Finder cache ready" }
        monitoringEnabled=startMonitoring
        guard startMonitoring && initializePreferences else { return }
        do { if self.finderWatches==nil { self.finderWatches=try FinderWatchManager.production() };self.finderWatches?.restore() }
        catch { finderStatus="Watched repositories unavailable: "+error.localizedDescription }
        do { _ = try FinderMenuSettings.from().write() }
        catch { finderStatus = "Finder menu preferences unavailable: " + error.localizedDescription }
        do { _ = try FinderCacheTrayPreferences.from().write() }
        catch { finderStatus = "Finder cache menu preferences unavailable: " + error.localizedDescription }
        do { _ = try FinderOverlaySettings.effective().write() }
        catch { finderStatus = "Finder overlay preferences unavailable: " + error.localizedDescription }
        do { workingComparisonMark = try comparisonMarkStore.snapshot() } catch { self.error = error.localizedDescription }
        do {
            let store = try savedAccessStore ?? RepositoryAccessStore(storageURL: RepositoryAccessStore.defaultStorageURL)
            accessStore = store; recentRepositories = store.repositories
        } catch { self.error = "Saved repository permissions could not be loaded: " + error.localizedDescription }
        Task {
            if let snapshot = await Task.detached(operation: { FinderSnapshot.read() }).value, root == nil {
                cacheStates = snapshot.states; monitoredRoots = snapshot.roots; cacheRepositories = snapshot.repositories
                cacheOverlayEntries = snapshot.overlayEntries
                cacheIndexFlags = snapshot.indexFlags
            }
        }

    }
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
                selected=await prompt.choose(requirement,owner:workspaceWindow,cancellation:cancellation)
            }
            try cancellation.check()
            guard let selected else { cancellation.cancel();throw OperationCancellationFailure.cancelled }
            let scope=RepositoryAccessLease(url:selected,provider:repositoryBookmarkProvider)
            guard scope.hasSecurityScope,scope.contains(requirement.folder) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(requirement.folder.path) }
            scopes.append(scope);newFolders.append(selected)
        }
        throw RepositoryMetadataAccessFailure.tooManyDependencies
    }
    private func openSession(_ lease: RepositoryAccessLease, selected: FinderRequest? = nil, action: RepositoryAction? = nil, actionPaths: [String]? = nil, invocation: PrimaryCommandInvocation? = nil, messageAccess: RepositoryAccessLease? = nil, outputAccess: RepositoryAccessLease? = nil, commandRootOnly: Bool = false, onFinished: ((Bool) -> Void)? = nil, handoffOwner: RepositoryWindowOwner? = nil, onOpened: (() -> Void)? = nil) {
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
        let owner=workspaceWindow
        let ownerObserver=owner.map { NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:$0,queue:.main) { _ in cancellation.cancel() } }
        Task {
            var opened = false, holdsBusy = true
            defer { onFinished?(opened) }
            defer { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) };if adoptionCancellation === cancellation { adoptionCancellation=nil;if holdsBusy { busy=false } };withExtendedLifetime(lease) {} }
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
                let first = selected?.paths.first ?? lease.url
                let submoduleLocation = invocation?.submoduleDiscoveryURL
                var location = submoduleLocation ?? first
                var directory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) || !directory.boolValue {
                    location.deleteLastPathComponent()
                }
                let historicalSelection = invocation.map { [.cat, .showCompare].contains($0.request.action) } ?? false
                if historicalSelection {
                    while location.path != "/" {
                        var existingDirectory: ObjCBool = false
                        if FileManager.default.fileExists(atPath: location.path, isDirectory: &existingDirectory), existingDirectory.boolValue { break }
                        let parent = location.deletingLastPathComponent()
                        guard lease.contains(parent) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(parent.path) }
                        location = parent
                    }
                }
                let prepared=try await prepareRepositoryMetadataAccess(at:location,primary:lease,cancellation:cancellation)
                try cancellation.check();guard adoption==adoptionGeneration else { return }
                let sessionAccess=lease.retainingRelatedScopes(prepared.scopes)
                let candidate = try makeRepository(location)
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
                if (requiresRepositoryScope && !lease.hasSecurityScope) || ((requiresRepositoryScope || submoduleLocation != nil) && !lease.contains(resolved)) {
                    throw RepositoryAccessFailure.repositoryRootOutsidePermission(resolved.path)
                }
                if let selected {
                    for item in selected.paths {
                        guard lease.contains(item), item.path == resolved.path || item.path.hasPrefix(resolved.path + "/") else {
                            throw FinderSelectionFailure.multipleRepositories
                        }
                        if submoduleLocation != nil || historicalSelection { continue }
                        var location = item
                        var directory: ObjCBool = false
                        if !FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) || !directory.boolValue { location.deleteLastPathComponent() }
                        let itemRoot = try await makeRepository(location).discoverSelectionRoot(for: action ?? .status, selected: item,cancellation:cancellation)
                        guard itemRoot.standardizedFileURL == resolved.standardizedFileURL else { throw FinderSelectionFailure.multipleRepositories }
                    }
                }
                try cancellation.check();guard adoption == adoptionGeneration else { return }
                repository = try makeRepository(resolved); activeAccess = sessionAccess; root = resolved
                if invocation?.request.action == .log, let revision = invocation?.selectedRevision {
                    commandSelectedRevision = try await repository!.rebaseCommit(revision, cancellation: cancellation).hash
                    try cancellation.check(); guard adoption == adoptionGeneration else { return }
                }
                restoreCloneKeyAccess(root: resolved)
                selection = []; entries = []; branch = ""; mergeActive = false
                section = .status
                output = "Repository: \(resolved.path)"
                try await reload(cancellation:cancellation)
                try cancellation.check();guard adoption == adoptionGeneration else { return }
                if bare { section = .log }
                if let selected { selection = selected.selectedStatusPaths(root: resolved, entries: entries) }
                rememberAccess(sessionAccess, repositoryRoot: resolved)
                if let store=accessStore,let saved=store.repositories.first(where:{$0.lastKnownPath==resolved.standardizedFileURL.resolvingSymlinksInPath().path}) {
                    do { for folder in prepared.newFolders { try store.addPermission(saved.id,url:folder) };recentRepositories=store.repositories }
                    catch { self.error="The repository is open, but additional folder access could not be saved: "+error.localizedDescription }
                }
                holdsBusy = false; busy = false
                if let invocation {
                    activateCommandLine(invocation, message: commandMessage, selectedRevision: commandSelectedRevision, repository: repository!, access: sessionAccess, outputAccess: outputAccess)
                } else if let action {
                    let paths = actionPaths ?? selected?.relativePaths(root: resolved) ?? []
                    if action.isFileTransfer, let request = selected, let repository, let destination = request.paths.first {
                        if let finderTransferPresentation { finderTransferPresentation(request, repository, sessionAccess) }
                        else if action == .pasteCopy { showCopy(repository: repository, access: sessionAccess, sources: request.sources, paste: true, folder: destination) }
                        else { showMove(repository: repository, access: sessionAccess, paths: [], clipboard: request.sources, destination: destination) }
                    } else if action == .requestPull, let repository {
                        showRequestPull(repository: repository, access: sessionAccess, end: selected?.requestPullEnd, repositoryURL: selected?.requestPullURL)
                    } else { activate(action, paths: paths) }
                }
                opened = true; onOpened?()
            } catch {
                guard adoption == adoptionGeneration else { return }
                restoreState()
                if !cancellation.isCancelled { self.error=error.localizedDescription }
                if !retired,monitoringEnabled,let repository,let directories=try? await repository.finderWatchDirectories() { monitorFiles(directories) }
                holdsBusy = false; busy=false
            }
        }
    }
    func refresh(refreshStatus: Bool = true) async {
        guard !busy, !confirmingQuit else { return }
        busy = true; defer { busy = false }
        do { try await reload() } catch { self.error = error.localizedDescription }
        if refreshStatus, let root { statusWindows[root.path]?.model.requestReload() }
    }
    private func reload(cancellation:OperationCancellation? = nil) async throws {
        guard let repository, let root else { return }
        let token=cancellation ?? OperationCancellation()
        let store=snapshotStore
        var ticket:FinderPublicationTicket?,publicationError:String?
        if snapshotWriter==nil,let store {
            do { ticket=try await Task.detached { try store.begin(root:root,cancellation:token) }.value }
            catch { publicationError=error.localizedDescription }
        }
        let collected=try await repository.collectFinderRepository(authorizedRoot:activeAccess?.url ?? root,cancellation:token,watchReady:{ [weak self] directories in if !token.isCancelled { await self?.monitorFiles(directories) } })
        try token.check()
        bare=collected.bare;entries=collected.entries;conflictRebase=collected.conflictIsRebase;submodules=collected.submodules
        selection = (pendingWorkspaceSelection ?? selection).intersection(visibleEntries.map(\.path));pendingWorkspaceSelection=nil
        branch=collected.branch;hasGitSVN=collected.metadata.hasGitSVN;mergeActive=collected.metadata.mergeActive
        var cached=FinderSnapshot(roots:monitoredRoots,states:cacheStates,repositories:cacheRepositories,overlayEntries:cacheOverlayEntries,indexFlags:cacheIndexFlags)
        cached.replaceSubtree(root:root,snapshots:collected.snapshots)
        monitoredRoots = cached.roots; cacheStates = cached.states; cacheRepositories = cached.repositories
        cacheOverlayEntries = cached.overlayEntries
        cacheIndexFlags = cached.indexFlags
        do {
            if let publicationError { finderStatus="Finder cache unavailable: "+publicationError;return }
            let written:Bool
            if let writer=snapshotWriter { written=try await Task.detached { try writer(cached) }.value }
            else if let store,let ticket {
                let update=try await Task.detached { try store.publish(ticket,snapshots:collected.snapshots,cancellation:token) }.value
                cached=update.snapshot
                monitoredRoots=cached.roots;cacheStates=cached.states;cacheRepositories=cached.repositories
                cacheOverlayEntries=cached.overlayEntries;cacheIndexFlags=cached.indexFlags
                guard update.published else { finderStatus="Finder cache update superseded";return }
                written=true
            } else { written=false }
            finderStatus = written ? (collected.failures.isEmpty ? "Finder cache updated" : "Finder cache updated; \(collected.failures.count) submodule scan(s) failed: " + collected.failures.sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value }.joined(separator: "; ")) : "Finder cache unavailable: App Group access required"
            if written { notifyFinder() }
        } catch { finderStatus = "Finder cache unavailable: " + error.localizedDescription }
    }
    func perform(_ operation: @escaping (GitRepository) async throws -> String) {
        guard let repository, !busy, !confirmingQuit else { return }
        busy = true
        let access = activeAccess
        Task {
            defer { busy = false; withExtendedLifetime(access) {} }
            do { output = try await operation(repository); try await reload() }
            catch { self.error = error.localizedDescription; try? await reload() }
            if let root { statusWindows[root.path]?.model.requestReload() }
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
        case .clone: showClone()
        case .initialize: showCreateRepository()
        case .rename:
            guard let repository else { return }
            let selected = paths.isEmpty ? selectedPaths : paths
            guard selected.count == 1, selected[0] != "." else { error = RenameFailure.source.localizedDescription; return }
            showRename(repository: repository, access: activeAccess, source: selected[0])
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
    private func showClone(directory: URL? = nil, source: String? = nil, exactPath: Bool = false) {
        let id = UUID(), controller = cloneWindowFactory?(directory ?? root, activeAccess) ?? CloneWindowController(directory: directory ?? root, access: activeAccess,preferences:fileComparisonPreferences,clipboardText:source == nil ? creationClipboardText():nil)
        controller.onClosed = { [weak self] in self?.cloneWindows.removeValue(forKey: id) }
        controller.model.onLog = { [weak self] repository, access in self?.showLog(repository: repository, access: access, paths: []) }
        let handoffOwner = RepositoryWindowOwner(window: workspaceWindow)
        controller.model.onCloned = { [weak self] repo, access, keyAccess, _, result in
            guard let self, !self.retired, !handoffOwner.cancellation.isCancelled else { return }
            if let keyAccess {
                self.cloneKeyAccess[repo.root.path] = keyAccess
                do { UserDefaults.standard.set(try SystemRepositoryBookmarkProvider().create(for: keyAccess.url), forKey: "Clone.KeyBookmark." + repo.root.path) }
                catch { self.error = "The clone completed, but its SSH-key permission could not be saved.\n" + error.localizedDescription }
            }
            self.adoptRepository(repo, access: access, output: result, owner: handoffOwner)
        }
        cloneWindows[id] = controller
        controller.model.configureLaunch(source: source, exactPath: exactPath)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
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
            commandRepositoryBatchCancellation?.cancel()
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
        guard !retired, !owner.cancellation.isCancelled, lease.contains(folder), !requiresRepositoryScope || lease.hasSecurityScope else { return }
        let key = GitPathRowIdentity.encode(folder.path)
        let controller = createWindows[key] ?? createWindowFactory?(folder, lease) ?? CreateRepositoryWindowController(folder: folder, access: lease)
        let fresh = createWindows[key] == nil
        controller.onClosed = { [weak self] in self?.createWindows.removeValue(forKey: key) }
        if fresh {
            controller.model.onInitialized = { [weak self] repo, access, _, output in self?.adoptRepository(repo, access: access, output: output, owner: owner) }
        }
        createWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        if fresh { controller.model.prepare() }
    }
    private func showRename(repository: GitRepository, access: RepositoryAccessLease?, source: String) {
        let root = repository.root, key = GitPathRowIdentity.encode(root.path + "\0" + source)
        let controller = renameWindows[key] ?? RenameWindowController(repository: repository, access: access, source: source, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.renameWindows.removeValue(forKey: key) }
        controller.model.onRenamed = { [weak self] old, new, output in
            guard let self else { return }
            self.revertWindows[root.path]?.model.didRename(old,to:new); self.statusWindows[root.path]?.model.didRename(old, to: new)
            self.commitWindows[root.path]?.model.didRename(old, to: new)
            if self.root == root {
                self.didMoveWorkspacePath(old,to:new)
                self.output = output.isEmpty ? "Renamed \(old) to \(new)." : output
            }
        }
        controller.model.onChanged = { [weak self] in
            self?.revertWindows[root.path]?.model.requestReload(); self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
            if self?.root == root { Task { await self?.refresh() } }
        }
        renameWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func showMove(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], clipboard: [URL]? = nil, destination: URL? = nil, renameFirst: Bool = false, stopOnError: Bool = true) {
        let root = repository.root, key = GitPathRowIdentity.encode(root.path + "\0" + (clipboard == nil ? paths.joined(separator: "\0") : UUID().uuidString))
        let controller = moveWindows[key] ?? FileMoveWindowController(repository: repository, access: access, paths: paths)
        controller.onClosed = { [weak self] in self?.moveWindows.removeValue(forKey: key) }
        controller.model.onMoved = { [weak self] old, new, text in
            guard let self else { return }; self.revertWindows[root.path]?.model.didRename(old,to:new); self.statusWindows[root.path]?.model.didRename(old, to: new); self.commitWindows[root.path]?.model.didRename(old, to: new)
            if self.root == root { self.didMoveWorkspacePath(old,to:new); self.output = text.isEmpty ? "Moved \(old) to \(new)." : text }
        }
        controller.model.onChanged = { [weak self] in
            self?.revertWindows[root.path]?.model.requestReload(); self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
            if self?.root == root { Task { await self?.refresh() } }
        }
        moveWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        if let clipboard { controller.model.renameFirst = renameFirst; controller.model.loadClipboard(clipboard, destination: destination, stopOnError: stopOnError) }
    }
    func showCopy(repository: GitRepository, access: RepositoryAccessLease?, sources: [URL], paste: Bool = false, folder: URL? = nil) {
        let id = UUID(), root = repository.root
        let controller = FileCopyWindowController(repository: repository, access: access, sources: sources, folder: folder, paste: paste)
        controller.onClosed = { [weak self] in self?.copyWindows.removeValue(forKey: id) }
        controller.model.onChanged = { [weak self] in
            self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.refreshRepositoryLogs(root)
            if self?.root == root { Task { await self?.refresh() } }
        }
        copyWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private var dropTransfers: [UUID: FileDropTransferWindowController] = [:]
    var canReceiveTransferDrop: Bool { repository != nil && !bare && !busy && !confirmingQuit && workspaceWindow?.attachedSheet == nil }
    var configureDropTransfer: (FileDropTransferWindowController) -> Void = { _ in }
    @discardableResult func receiveTransferDrop(_ providers: [NSItemProvider], repository captured: GitRepository? = nil, access capturedAccess: RepositoryAccessLease? = nil, owner capturedOwner: NSWindow? = nil) -> Bool {
        guard !confirmingQuit, captured != nil || canReceiveTransferDrop, !providers.isEmpty, providers.count <= 256, providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }), let repository = captured ?? repository, let owner = capturedOwner ?? workspaceWindow, owner.attachedSheet == nil else { return false }
        let id = UUID(), access = captured == nil ? activeAccess : capturedAccess, controller = FileDropTransferWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.dropTransfers.removeValue(forKey: id) }
        controller.onAccepted = { [weak self] choice, urls, folder in
            guard let self, !self.confirmingQuit else { return }
            if choice == .copyAdd { self.showCopy(repository: repository, access: access, sources: urls, folder: folder) }
            else { self.showMove(repository: repository, access: access, paths: [], clipboard: urls, destination: folder, renameFirst: choice == .moveRename, stopOnError: false) }
        }
        configureDropTransfer(controller); dropTransfers[id] = controller
        guard controller.present(owner: owner) else { controller.close(); dropTransfers.removeValue(forKey: id); return false }
        controller.model.load(providers); return true
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
    lazy var openExternalConflict: (GitRepository, RepositoryAccessLease?, String, Bool, NSWindow?, ConflictEntry, OperationCancellation, @escaping () -> Void, MergeToolPreferences) async throws -> Bool = { [weak self] repository, access, path, alternate, owner, entry, token, prepared, tools in
        try await MergeToolApplication.open(repository: repository, access: access, path: path, alternate: alternate, owner: owner, cancellation: token, onPrepared: prepared, preferences: tools, expectedEntry: entry, identityOptions: ConflictIdentityOptions(defaults: self?.fileComparisonPreferences ?? .standard))
    }
    private var conflictEditorPreparations: [String: ConflictEditorLaunch] = [:]
    @Published private(set) var conflictEditorPreparationCount = 0
    func cancelConflictEditorPreparations() { for request in conflictEditorPreparations.values { request.cancel() } }
    func cancelConflictEditorPreparation(repository: GitRepository, path: String) { conflictEditorPreparations[repository.root.path + "\0" + path]?.cancel() }
    private func validateConflictEditorEntry(_ entry: ConflictEntry, repository: GitRepository, token: OperationCancellation) async throws {
        try token.check()
        guard !confirmingQuit, try await repository.conflictEditorEntry(path: entry.path, cancellation: token) == entry else { throw ResolveFailure.stale }
        try token.check()
    }
    func showConflictEditor(repository: GitRepository, access: RepositoryAccessLease?, path: String, owner: NSWindow? = nil) {
        guard !confirmingQuit else { return }
        let key = repository.root.path + "\0" + path
        guard conflictEditorPreparations[key] == nil else { return }
        let alternate = ComparisonToolInvocation.capture, owner = owner ?? NSApp.keyWindow ?? workspaceWindow
        let tools = MergeToolPreferences.load(from: fileComparisonPreferences)
        let request = ConflictEditorLaunch(owner: owner, preferences: fileComparisonPreferences)
        conflictEditorPreparations[key] = request; conflictEditorPreparationCount = conflictEditorPreparations.count
        request.showProgress(path: path)
        Task {
            defer {
                request.dismissProgress(); if conflictEditorPreparations[key] === request { conflictEditorPreparations.removeValue(forKey: key); conflictEditorPreparationCount = conflictEditorPreparations.count }
                withExtendedLifetime(access) {}
            }
            do {
                try await request.session.run(selectedCount: 0) { [self] token in
                    try token.check(); guard !confirmingQuit else { return }
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let entry: ConflictEntry
                    if let readConflictEditorEntry { entry = try await readConflictEditorEntry(repository, path, token) }
                    else { entry = try await repository.conflictEditorEntry(path: path, cancellation: token) }
                    guard GitReferenceName.equal(entry.path,path) else { throw ResolveFailure.stale }; try token.check()
                if entry.isDeleteModify {
                    try await validateConflictEditorEntry(entry, repository: repository, token: token)
                    request.dismissProgress(); if let conflictEditorPresentation { conflictEditorPresentation(.deleteModify, repository, path, nil) }
                    else { showDeleteConflict(repository: repository, access: access, path: path) }; return
                }
                if !entry.isSubmodule {
                    if try await openExternalConflict(repository, access, path, alternate, owner, entry, token, { request.dismissProgress() }, tools) {
                        try token.check(); guard !confirmingQuit else { return }
                        let root = repository.root
                        refreshAfterConflictChange(root)
                        if self.root == root { await refresh() }; return
                    }
                    let root = repository.root, key = root.path + "\0" + path
                    if let document = try await repository.imageConflictDocument(path: path, identityOptions: ConflictIdentityOptions(defaults: fileComparisonPreferences), cancellation: token) {
                        guard document.entry == entry else { throw ResolveFailure.stale }
                        try await validateConflictEditorEntry(entry, repository: repository, token: token)
                        request.dismissProgress()
                        if let conflictEditorPresentation { conflictEditorPresentation(.image, repository, path, document); return }
                        let controller = imageConflictWindows[key] ?? ImageConflictWindowController(repository: repository, access: access, document: document, preferences: fileComparisonPreferences)
                        controller.onClosed = { [weak self] in self?.imageConflictWindows.removeValue(forKey: key) }
                        controller.model.onChanged = { [weak self] output in
                            self?.refreshAfterConflictChange(root)
                            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
                        }
                        imageConflictWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return
                    }
                    try await validateConflictEditorEntry(entry, repository: repository, token: token)
                    request.dismissProgress()
                    if let conflictEditorPresentation { conflictEditorPresentation(.text, repository, path, nil); return }
                    let controller = (textConflictWindows[key]?.window != nil ? textConflictWindows[key] : nil) ?? TextConflictWindowController(repository: repository, access: access, path: path)
                    controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.textConflictWindows[key] === controller else { return }; self.textConflictWindows.removeValue(forKey: key) }
                    controller.model.onChanged = { [weak self] output in
                        self?.refreshAfterConflictChange(root)
                        if let self, self.root == root { self.output = output; Task { await self.refresh() } }
                    }
                    textConflictWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return
                }
                let root = repository.root, key = root.path + "\0" + path
                try await validateConflictEditorEntry(entry, repository: repository, token: token)
                request.dismissProgress()
                if let conflictEditorPresentation { conflictEditorPresentation(.submodule, repository, path, nil); return }
                let controller = submoduleConflictWindows[key] ?? SubmoduleConflictWindowController(repository: repository, access: access, path: path)
                controller.onClosed = { [weak self] in self?.submoduleConflictWindows.removeValue(forKey: key) }
                controller.model.onChanged = { [weak self] output in
                    self?.refreshAfterConflictChange(root)
                    if let self, self.root == root { self.output = output; Task { await self.refresh() } }
                }
                controller.model.onLog = { [weak self] child, revision in self?.showLog(repository: child, access: access, paths: [], endRevision: revision) }
                controller.model.onReset = { [weak self, weak controller] child, revision, done in self?.showReset(repository: child, access: access, revision: revision, completion: done, dismissed: { [weak controller] in controller?.model.dismissReset() }) }
                submoduleConflictWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
                }
            } catch { if !request.session.cancellation.isCancelled, !confirmingQuit { self.error = error.localizedDescription } }
        }
    }
    private func showDeleteConflict(repository: GitRepository, access: RepositoryAccessLease?, path: String) {
        let root = repository.root, key = root.path + "\0" + path
        let controller = deleteConflictWindows[key] ?? DeleteConflictWindowController(repository: repository, access: access, path: path)
        controller.onClosed = { [weak self] in self?.deleteConflictWindows.removeValue(forKey: key) }
        controller.model.onChanged = { [weak self] output in
            self?.refreshAfterConflictChange(root)
            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
        }
        controller.model.onLog = { [weak self] revision in self?.showLog(repository: repository, access: access, paths: [path], endRevision: revision) }
        deleteConflictWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func configureResetInteractions(_ controller: ResetWindowController, repository: GitRepository, access: RepositoryAccessLease?, completion: (() -> Void)? = nil) {
        let root = repository.root
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
        controller.configureCommitPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.configureModifiedComparison = { [weak self] model in
            self?.configureRevisionComparisonInteractions(model, repository: repository, access: access)
        }
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload(); self?.statusWindows[root.path]?.model.requestReload()
            self?.refreshRepositoryLogs(root); self?.commitWindows[root.path]?.model.reload()
            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
        }
        controller.model.onReset = { _ in completion?() }
        controller.model.onPostAction = { [weak self] action in
            switch action {
            case .submoduleUpdate: self?.showSubmoduleUpdate(repository: repository, access: access, scope: [])
            case .clean: self?.showClean(repository: repository, access: access, paths: [])
            case .bisectGood: self?.showBisect(repository: repository, access: access, operation: .good)
            case .bisectBad: self?.showBisect(repository: repository, access: access, operation: .bad)
            case .bisectSkip: self?.showBisect(repository: repository, access: access, operation: .skip)
            case .bisectReset: self?.showBisect(repository: repository, access: access, operation: .reset)
            case .retry: break
            }
        }
    }
    private func showReset(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, mode: ResetMode? = nil, completion: (() -> Void)? = nil, dismissed: (() -> Void)? = nil) {
        let root = repository.root, key = root.path + "\0" + (revision.map { $0 + "\0" + UUID().uuidString } ?? "")
        if revision == nil, let existing = resetWindows[key] {
            if let completion { let previous = existing.model.onReset; existing.model.onReset = { output in previous(output); completion() } }
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return
        }
        let controller = ResetWindowController(repository: repository, access: access, revision: revision)
        if let mode { controller.model.mode = mode }
        controller.onClosed = { [weak self] in self?.resetWindows.removeValue(forKey: key); dismissed?() }
        configureResetInteractions(controller, repository: repository, access: access, completion: completion)
        resetWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func refreshAfterConflictChange(_ root:URL) {
        ConflictListRefreshPolicy.perform(preferences:fileComparisonPreferences) {
            revertWindows[root.path]?.model.requestReload(); statusWindows[root.path]?.model.requestReload();commitWindows[root.path]?.model.reload()
            for resolve in resolveWindows.values where resolve.model.repository.root == root {resolve.model.load()}
            synchronizationWindows[root.path]?.model.refreshConflictFiles()
        }
        rebaseWindows[root.path]?.model.refreshState();refreshRepositoryLogs(root)
    }
    private func showResolve(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], quick: ResolveChoice?) {
        let root = repository.root, key = root.path + "\0" + String(quick?.rawValue ?? -1) + "\0" + paths.joined(separator: "\0")
        let controller = resolveWindows[key] ?? ResolveWindowController(repository: repository, access: access, paths: paths, quick: quick, preferences:fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.resolveWindows.removeValue(forKey: key) }
        controller.onChanged = { [weak self] output in
            self?.refreshAfterConflictChange(root)
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onEdit = { [weak self, weak controller] path in self?.showConflictEditor(repository: repository, access: access, path: path, owner: controller?.window) }
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
        controller.onCommit = { [weak self] in
            guard let self else { return }
            if self.root == root { self.activate(.commit) }
            else if let access { self.openSession(access, action: .commit) }
        }
        resolveWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
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
                self?.revertWindows[root.path]?.model.requestReload(); self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
                guard let self, self.root == root else { return }
                self.output = output; Task { await self.refresh() }
            }
            ignoreWindows[key] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } catch { self.error = error.localizedDescription }
    }
    private func showRemove(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], keepLocal: Bool) {
        do {
            let request = try RemovalRequest(paths: paths, keepLocal: keepLocal)
            let root = repository.root, key = root.path + "\0" + String(keepLocal) + "\0" + request.paths.joined(separator: "\0")
            let controller = removeWindows[key] ?? removeWindowFactory?(repository, access, request) ?? RemoveWindowController(repository: repository, access: access, request: request, preferences: fileComparisonPreferences)
            controller.onClosed = { [weak self] in self?.removeWindows.removeValue(forKey: key) }
            controller.onChanged = { [weak self] output in
                self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
                guard let self, self.root == root else { return }
                self.output = output; Task { await self.refresh() }
            }
            removeWindows[key] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.start()
        } catch { self.error = error.localizedDescription }
    }
    private func showCommitDialog(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], invocation: PrimaryCommandInvocation? = nil, commandMessage: String? = nil) {
        let root = repository.root
        if invocation != nil, let existing = commitWindows[root.path] {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "A Commit dialog is already open. Close it before opening a command-line Commit with new presets."
            return
        }
        let controller = commitWindows[root.path] ?? commitWindowFactory?(repository,access) ?? CommitWindowController(repository: repository, access: access)
        controller.onPullAfterLFSLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.onClosed = { [weak self] in self?.commitWindows.removeValue(forKey: root.path) }
        controller.model.onCommitted = { [weak self] output in
            self?.statusWindows[root.path]?.model.requestReload(); self?.refreshRepositoryLogs(root)
            guard let self, self.root == root else { return }
            self.output = output
            Task { await self.refresh() }
        }
        let access = controller.model.access
        controller.model.onPush = { [weak self] in self?.showPush(repository: repository, access: access) }
        controller.model.onPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true, followUp: PullFollowUp(showPush: true)) }
        controller.model.onCreateTag = { [weak self] in self?.showReference(repository: repository, access: access, isTag: true) }
        controller.model.onSVNDCommit = { [weak self] in self?.showSVN(.dcommit, repository: repository, access: access) }
        configureCommitInteractions(controller.model, repository: repository, access: access)
        commitWindows[root.path] = controller
        if let invocation { controller.model.applyCommandLine(invocation, message: commandMessage) }
        controller.model.reload(paths: invocation?.wholeProject == true ? [] : paths)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showAdd(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], commandLaunch: Bool = false) {
        let id = UUID(), owner = RepositoryWindowOwner(window: workspaceWindow)
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
                if files { showAddProgress(repository: repository, access: access, paths: paths); return }
                let key = repository.root.path
                if commandLaunch, let existing = addWindows[key] {
                    existing.window?.makeKeyAndOrderFront(nil)
                    error = "An Add dialog is already open. Close it before opening another command-line Add."
                    return
                }
                let controller = addWindows[key] ?? AddWindowController(repository: repository, access: access, defaults: fileComparisonPreferences)
                guard !controller.model.busy else { controller.window?.makeKeyAndOrderFront(nil); return }
                controller.onClosed = { [weak self] in self?.addWindows.removeValue(forKey: key) }
                controller.model.onAccepted = { [weak self] paths in self?.showAddProgress(repository: repository, access: access, paths: paths) }
                controller.onPullAfterLFSLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
                controller.model.onLFSChanged = { [weak self] in
                    self?.statusWindows[key]?.model.requestReload(); self?.commitWindows[key]?.model.reload()
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
                    self?.statusWindows[key]?.model.requestReload(); self?.commitWindows[key]?.model.reload()
                    if let self, self.root == repository.root { self.output = output; Task { await self.refresh() } }
                }
                controller.model.onRevert = { [weak self] entries, done in
                    guard let self else { done(false); return {} }
                    let progress = self.showRevertProgress(repository: repository, access: access, entries: entries, autoCloseSuccess: true, completion: done)
                    return { [weak progress] in progress?.model.cancel() }
                }
                controller.model.onRestoreChanged = { [weak model = controller.model] in model?.onIgnoreChanged("Working copies restored.") }
                controller.model.onDeleteChanged = controller.model.onIgnoreChanged
                addWindows[key] = controller; controller.model.setScope(paths); controller.model.reload()
                controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
            } catch { if !retired, !owner.cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func showSVN(_ operation: GitSVNOperation) {
        guard !busy, !confirmingQuit, !bare, let repository else { return }
        showSVN(operation, repository: repository, access: activeAccess)
    }
    func showSVN(_ operation: GitSVNOperation, repository: GitRepository, access: RepositoryAccessLease?) {
        guard !confirmingQuit else { return }
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
        let controller = svnWindowFactory?(repository,access,operation) ?? SVNWindowController(repository: repository, access: access, operation: operation, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller, self.svnWindows[key] === controller else { return }
            self.svnWindows.removeValue(forKey: key)
        }
        controller.model.onChanged = { [weak self] in
            self?.refreshRepositoryLogs(repository.root)
            if self?.root == repository.root { Task { await self?.refresh() } }
        }
        controller.model.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: .revision(from), to: .revision(to)) }
        controller.model.onLog = { [weak self] result in self?.showLog(repository: repository, access: access, paths: [], revisionRange: HistoryRevisionRange(from: result.oldHash, to: result.newHash)) }
        controller.model.onRepositoryLog = { [weak self] in self?.showLog(repository: repository, access: access, paths: []) }
        controller.model.openRebase = { [weak self, weak controller] reference in
            guard let self, let window = controller?.window, window.attachedSheet == nil, self.rebaseWindows[key] == nil else { return false }
            return await withCheckedContinuation { continuation in
                self.showRebase(repository: repository, access: access, upstream: String(reference.dropFirst("refs/".count)), owner: window, onResult: { continuation.resume(returning: $0) }, onRequestedLog: { [weak controller] in controller?.model.pendingRebaseLog = true })
            }
        }
        svnWindows[key] = controller
        if let svnPresentation { svnPresentation(controller) } else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        controller.model.load()
    }
    func showDaemon() {
        guard !busy, !confirmingQuit, let repository else { return }
        let key = repository.root.path
        if let existing = daemonWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = GitDaemonWindowController(repository: repository, access: activeAccess)
        controller.onClosed = { [weak self] in self?.daemonWindows.removeValue(forKey: key) }
        daemonWindows[key] = controller
        if let daemonPresentation { daemonPresentation(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        controller.model.begin()
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
        controller.onClosed = { [weak self] in self?.lfsLocksWindows.removeValue(forKey: key) }
        lfsLocksWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        Task { await controller.model.refresh() }
    }
    private func showFinderLFSOperation(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], locked: Bool, force: Bool = false, commandLaunch: Bool = false) {
        guard !retired, !busy, !confirmingQuit, workspaceWindow?.attachedSheet == nil else { return }
        let id = UUID(), window = workspaceWindow, owner = RepositoryWindowOwner(window: workspaceWindow)
        let preflight = lfsSelectionPreflight
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
                let controller = lfsFileOperationFactory?(repository, access, fileComparisonPreferences) ?? LFSFileOperationController(repository: repository, access: access, defaults: fileComparisonPreferences)
                controller.model.onProgressLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path]) }
                controller.model.onPullAfterLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
                controller.onClosed = { [weak self] in
                    guard let self else { return }; self.lfsFileOperations.removeValue(forKey: id)
                    self.statusWindows[repository.root.path]?.model.requestReload(); self.commitWindows[repository.root.path]?.model.reload()
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
        let known = FinderSnapshot.read()?.roots.first { selected.path == $0 || selected.path.hasPrefix($0 + "/") }
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
    private func presentReview(_ workflow: ReviewPatchWorkflow) {
        let id = UUID(); reviewPatchWorkflows[id] = workflow
        workflow.presentation = { [weak self] controller in
            let root = controller.model.repository.root
            let refresh: () -> Void = { [weak self] in
                self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.refreshRepositoryLogs(root)
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
        workflow.start()
    }
    func showReviewPatch(files: [URL]) {
        guard !busy, !confirmingQuit else { return }
        guard files.count <= 1 else { error = "Select one patch file to review."; return }
        let first = files.first
        let knownRoot = first.flatMap { first in
            FinderSnapshot.read()?.roots.sorted { $0.count > $1.count }.first { first.path == $0 || first.path.hasPrefix($0 + "/") }
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

    private func showFinderSendMail(files: [URL]) {
        guard !busy, !confirmingQuit, !files.isEmpty else { return }
        let first = files[0]
        let knownRoot = FinderSnapshot.read()?.roots.sorted { $0.count > $1.count }.first { first.path == $0 || first.path.hasPrefix($0 + "/") }
            ?? root.flatMap { first.path == $0.path || first.path.hasPrefix($0.path + "/") ? $0.path : nil }
        let rootURL = knownRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let targets = files + (rootURL.map { [$0] } ?? [])
        var grants: [RepositoryAccessLease] = []
        if let activeAccess { grants.append(activeAccess) }
        if GitRuntime.isAppStoreBuild {
            if let store = accessStore {
                for saved in store.repositories {
                    if let lease = try? store.acquire(saved.id, requireSecurityScope: true), targets.contains(where: { lease.contains($0) }) { grants.append(lease) }
                }
            }
            if !targets.allSatisfy({ target in grants.contains { $0.hasSecurityScope && $0.contains(target) } }) {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
                panel.prompt = "Authorize mail files"; panel.directoryURL = rootURL ?? first.deletingLastPathComponent()
                panel.message = "Select these files or their containing folders. For a known repository, include its root folder to use the local sender identity."
                guard panel.runModal() == .OK else { return }
                grants += panel.urls.map { RepositoryAccessLease(url: $0) }
                guard targets.allSatisfy({ target in grants.contains { $0.hasSecurityScope && $0.contains(target) } }) else {
                    error = "The selected permissions do not cover every mail file and its sender repository."; return
                }
            }
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                for file in files {
                    guard (try file.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw MailPatchFailure.file }
                }
                var senderRoot = rootURL
                // Desktop permits direct discovery. Sandboxed discovery is only
                // attempted when the containing folder is already authorized.
                if !GitRuntime.isAppStoreBuild || grants.contains(where: { $0.hasSecurityScope && $0.contains(first.deletingLastPathComponent()) }) {
                    let candidate = try makeRepository(first.deletingLastPathComponent())
                    senderRoot = try? await candidate.discoverRoot()
                    if let senderRoot, GitRuntime.isAppStoreBuild, !grants.contains(where: { $0.hasSecurityScope && $0.contains(senderRoot) }) {
                        throw RepositoryAccessFailure.repositoryRootOutsidePermission(senderRoot.path)
                    }
                }
                let context = senderRoot == nil ? try ApplicationMailContext() : nil
                guard let directory = senderRoot ?? context?.root else { throw MailPatchFailure.file }
                let repository = try makeRepository(directory)
                let access = grants.first { $0.contains(repository.root) && (!GitRuntime.isAppStoreBuild || $0.hasSecurityScope) }
                guard !confirmingQuit else { return }
                let id = UUID()
                let workflow = SendMailWorkflow(files: files, repository: repository, access: access, fileAccess: grants, preferences: .standard, presentation: finderMailPresentation, applicationContext: context) { [weak self] result in
                    self?.finderMailWorkflows.removeValue(forKey: id)
                    if let result { self?.error = result }
                }
                finderMailWorkflows[id] = workflow; workflow.start()
            } catch { self.error = error.localizedDescription }
        }
    }

    func showSynchronization(sequence: Int? = nil) {
        guard !busy, !confirmingQuit, !bare, let repository else { return }
        let key = repository.root.path, access = activeAccess
        if let existing = synchronizationWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = SynchronizationWindowController(repository: repository, access: access, preferences: fileComparisonPreferences, sequence: sequence)
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
        controller.model.onTagLog = { [weak self] revision in self?.showLog(repository: repository, access: access, paths: [], endRevision: revision, selectedRevision: revision) }
        controller.model.onTagsChanged = { [weak self] in
            guard let self else { return }
            self.refreshRepositoryLogs(repository.root)
            if self.root?.path == repository.root.path { Task { await self.refresh() } }
        }
        controller.model.onReferenceLog = { [weak self] reference in self?.showReferenceLog(repository: repository, access: access, reference: reference) }
        controller.model.onReferenceCompare = { [weak self] old, new in self?.showRevisionComparison(repository: repository, access: access, from: .revision(old), to: .revision(new)) }
        controller.model.onHistoryCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: from, to: to) }
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
            await withCheckedContinuation { continuation in
                self.showRebase(repository: repository, access: access, upstream: target, autoStart: autoStart, preserveMerges: preserve,
                    afterFetch: true, owner: owner, onDismissed: { continuation.resume() })
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
                    self?.refreshRepositoryLogs(repository.root); self?.statusWindows[key]?.model.requestReload(); self?.commitWindows[key]?.model.reload()
                    if self?.root == repository.root { self?.output = output; Task { await self?.refresh() } }
                }
            case let child as HistoryNotesWindowController:
                child.model.onChanged = { [weak self] _ in self?.refreshRepositoryLogs(repository.root) }
            case let child as HistoryRevertWindowController:
                child.model.onChanged = { [weak self] output in
                    self?.refreshRepositoryLogs(repository.root); self?.statusWindows[key]?.model.requestReload(); self?.commitWindows[key]?.model.reload()
                    if self?.root == repository.root { self?.output = output; Task { await self?.refresh() } }
                }
                child.model.onCommit = { [weak self] in self?.showCommitDialog(repository: repository, access: access, paths: []) }
            case let child as SwitchProgressWindowController:
                child.model.onFinished = { [weak self] output, _ in
                    self?.refreshRepositoryLogs(repository.root); self?.statusWindows[key]?.model.requestReload(); self?.commitWindows[key]?.model.reload()
                    if self?.root == repository.root { self?.output = output; Task { await self?.refresh() } }
                }
                child.model.onPostAction = { [weak self] action, branch in self?.performSwitchPostAction(action, previousBranch: branch, repository: repository, access: access) }
            default: break
            }
        }
        controller.model.onHistoryBisect = { [weak self, weak controller] request in
            self?.showBisect(repository: repository, access: access, good: request.good, bad: request.bad, operation: request.operation, revisions: request.revisions, requireStart: request.operation == nil, onChanged: { [weak controller] in controller?.model.refresh() })
        }
        controller.model.onHistoryPush = { [weak self] revision, preserveAllBranches in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: preserveAllBranches) }
        controller.model.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.model.onHistoryReferenceChanged = { [weak self] output in
            self?.refreshRepositoryLogs(repository.root); self?.statusWindows[key]?.model.requestReload(); self?.commitWindows[key]?.model.reload()
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
        synchronizationWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }

    private func showAddProgress(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], mode: WorkingFileAddMode = .normal) {
        let id = UUID(), controller = AddProgressWindowController(repository: repository, access: access, paths: paths, mode: mode, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.addProgressWindows.removeValue(forKey: id) }
        controller.model.onFinished = { [weak self] text, _ in
            self?.refreshRepositoryLogs(repository.root)
            self?.statusWindows[repository.root.path]?.model.requestReload()
            self?.commitWindows[repository.root.path]?.model.reload()
            if self?.root?.path == repository.root.path { self?.output = text; Task { await self?.refresh() } }
        }
        controller.model.onCommit = { [weak self] in self?.openSession(access ?? RepositoryAccessLease(url: repository.root), selected: FinderRequest(action: .commit, paths: [repository.root]), action: .commit) }
        addProgressWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
    }
    private func showClean(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], commandLaunch: Bool = false) {
        if commandLaunch, let existing = cleanWindows[repository.root.path] {
            existing.window?.makeKeyAndOrderFront(nil)
            error = "A Cleanup dialog is already open. Close it before opening another command-line Cleanup."; return
        }
        let root = repository.root
        let controller = cleanWindows[root.path] ?? cleanWindowFactory?(repository) ?? CleanWindowController(repository: repository, defaults: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.cleanWindows.removeValue(forKey: root.path) }
        controller.model.setScope(paths)
        controller.model.onAccepted = { [weak self] request in
            guard let self else { return }
            let id = UUID(), progress = CleanProgressWindowController(repository: repository, access: access, request: request, preferences: fileComparisonPreferences)
            progress.onClosed = { [weak self] in self?.cleanProgressWindows.removeValue(forKey: id) }
            progress.model.onFinished = { [weak self] output, changed in
                guard let self else { return }
                if changed {
                    self.statusWindows[root.path]?.model.requestReload()
                    self.commitWindows[root.path]?.model.reload()
                    self.refreshRepositoryLogs(root)
                    if self.root == root { Task { await self.refresh() } }
                }
                if self.root == root { self.output = output }
            }
            self.cleanProgressWindows[id] = progress
            progress.showWindow(nil); progress.window?.makeKeyAndOrderFront(nil); progress.model.start()
        }
        cleanWindows[root.path] = controller
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
            self?.refreshRepositoryLogs(root);self?.statusWindows[root.path]?.model.requestReload();self?.commitWindows[root.path]?.model.reload()
        }

        revertWindows[root.path] = controller
        controller.model.setScope(paths)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    var submoduleDiffPresentation:((SubmoduleDiffWindowController)->Void)?
    private func showSubmoduleDiff(repository: GitRepository, access: RepositoryAccessLease?, path: String, from: String = "HEAD", to: String? = nil, fromPath: String? = nil, fromIndex: Bool = false) {
        let key = repository.root.path + "\0" + path + "\0" + from + "\0" + (to ?? "Working tree") + "\0" + (fromPath ?? path) + "\0" + String(fromIndex)
        let controller = submoduleDiffWindows[key] ?? SubmoduleDiffWindowController(repository: repository, access: access, path: path, from: from, to: to, fromPath:fromPath,fromIndex:fromIndex,preferences:fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.submoduleDiffWindows.removeValue(forKey: key) }
        controller.model.onLog = { [weak self] child, hash in self?.showLog(repository: child, access: access, paths: [], endRevision: hash, selectedRevision: hash) }
        controller.model.onStatus = { [weak self] child in self?.showStatus(repository: child, access: access) }
        controller.model.onCompare = { [weak self] child, old, new in self?.showRevisionComparison(repository: child, access: access, from: old, to: new) }
        controller.model.onConflict = { [weak self, weak controller] in
            controller?.window?.close()
            self?.showConflictEditor(repository: repository, access: access, path: path)
        }
        controller.onUpdated = { [weak self] output in
            self?.refreshRepositoryLogs(repository.root)
            self?.statusWindows[repository.root.path]?.model.requestReload()
            self?.commitWindows[repository.root.path]?.model.reload()
            self?.rebaseWindows[repository.root.path]?.model.refreshState()
            if let self, self.root == repository.root { self.output = output; Task { await self.refresh() } }
        }
        controller.onBisect = { [weak self] in self?.showBisect(repository: repository, access: access, operation: $0) }
        submoduleDiffWindows[key] = controller
        if let submoduleDiffPresentation {submoduleDiffPresentation(controller)} else {controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)}
        controller.model.load()
    }
    private func showRevisionComparison(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision, paths: [String] = []) {
        let baseKey = repository.root.path + "\0" + from.label + "\0" + to.label + "\0scope\0" + paths.joined(separator: "\0")
        let reusable = revisionComparisonWindows.first { _, controller in
            controller.model.repository.root == repository.root && controller.model.repository.executable == repository.executable &&
            controller.model.alternateTool == ComparisonToolInvocation.alternate && controller.window?.attachedSheet == nil && controller.model.canReuseForComparison(from: from, to: to, paths: paths)
        }
        let key = reusable?.key ?? (revisionComparisonWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? RevisionComparisonWindowController(repository: repository, access: access, from: from, to: to, paths: paths, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.revisionComparisonWindows.removeValue(forKey: key) }
        configureRevisionComparisonInteractions(controller.model, repository: repository, access: access)
        revisionComparisonWindows[key] = controller
        controller.model.load()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showRevisionGraph(repository: GitRepository, access: RepositoryAccessLease?) {
        let key = repository.root.path + "\0" + repository.executable.path
        if let existing = revisionGraphWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = revisionGraphWindowFactory?(repository, access, fileComparisonPreferences, true) ?? RevisionGraphWindowController(repository: repository, access: access, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.revisionGraphWindows.removeValue(forKey: key) }
        controller.model.onLog = { [weak self] hash in self?.showLog(repository: repository, access: access, paths: [], endRevision: hash, selectedRevision: hash) }
        controller.model.onBrowse = { [weak self] hash in self?.showRepositoryBrowser(repository: repository, access: access, revision: hash) }
        controller.model.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: from, to: to) }
        controller.model.onCheckout = { [weak self] hash in self?.showSwitch(repository: repository, access: access, revision: hash) }
        controller.model.onLogRange = { [weak self] range in self?.showLog(repository: repository, access: access, paths: [], revisionRange: range) }
        controller.model.onSwitchBranch = { [weak self, weak controller] reference in
            guard let parent = controller?.window, parent.attachedSheet == nil else { return }
            self?.showSwitchProgress(repository: repository, access: access, reference: reference, parent: parent, completion: { [weak controller] in controller?.model.load() })
        }
        revisionGraphWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func configureSelectableLog(_ log: LogWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        configureLogMenus(log, repository: repository, access: access)
        configureLogBisect(log, repository: repository, access: access, refreshPicker: true)
        log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        log.onHistoryPush = { [weak self] revision, all in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: all) }
        log.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        log.onCreateReference = { [weak self] tag, revision in self?.showReference(repository: repository, access: access, isTag: tag, revision: revision) }
        log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
        log.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision) }
        configureLogIntegration(log,repository:repository,access:access)
        log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
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
        log.onSubmoduleFileLog={ [weak self] checkout,hash in self?.showLog(repository:GitRepository(root:checkout,executable:repository.executable),access:access,paths:[],endRevision:hash,selectedRevision:hash) }
        log.onBlame={ [weak self] path,hash in self?.showBlame(repository:repository,access:access,path:path,revision:hash) }
        log.onRevisionChanged={ [weak self] output in
            guard let self else {return}
            self.refreshRepositoryLogs(repository.root)
            self.statusWindows[repository.root.path]?.model.requestReload();self.commitWindows[repository.root.path]?.model.reload();self.rebaseWindows[repository.root.path]?.model.refreshState()
            if self.root==repository.root {self.output=output;Task{await self.refresh()}}
        }
    }
    private func configureRevisionComparisonInteractions(_ model: RevisionComparisonWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        model.configureReferencePicker = { [weak self] picker in self?.configureReferenceBrowser(picker, repository: repository, access: access) }
        model.configureLogPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        model.onBlame={ [weak self] path,revision in self?.showBlame(repository:repository,access:access,path:path,revision:revision) }
        model.onSubmoduleLog={ [weak self] checkout,revision in self?.showLog(repository:GitRepository(root:checkout,executable:repository.executable),access:access,paths:[],endRevision:revision,selectedRevision:revision) }
        model.onFilesChanged={ [weak self] in
            self?.refreshRepositoryLogs(repository.root);self?.statusWindows[repository.root.path]?.model.requestReload();self?.commitWindows[repository.root.path]?.model.reload()
            if self?.root==repository.root {Task{await self?.refresh()}}
        }
        model.onLogRange = { [weak self] range in self?.showLog(repository:repository,access:access,paths:[],revisionRange:range) }
        model.onLog = { [weak self] hash in self?.showLog(repository: repository, access: access, paths: [], endRevision: hash) }
        model.onFileLog = { [weak self] path, hash in self?.showLog(repository: repository, access: access, paths: [path], endRevision: hash) }
        model.onSubmoduleCompare = { [weak self] path, oldPath, old, new in
            let from = old == .emptyTree ? "" : old == .workingTree ? "Working tree" : old.label
            let to = new == .emptyTree ? "" : new == .workingTree ? nil : new.label
            self?.showSubmoduleDiff(repository: repository, access: access, path: path, from: from, to: to,fromPath:oldPath)
        }
    }
    var fileComparisonPreferences: UserDefaults = .standard
    var fileComparisonQuestion: ((Int) async -> Bool)?
    var fileComparisonPresentation: ((RevisionComparisonSnapshot, CommitFile) -> Void)?
    var commitChangeSetPresentation: ((CommitChangeSetComparison) -> Void)?
    private func showCommitChangeSets(repository:GitRepository,access:RepositoryAccessLease?,comparison:CommitChangeSetComparison) {
        guard !confirmingQuit else { return }
        if let commitChangeSetPresentation { commitChangeSetPresentation(comparison);return }
        let key=repository.root.path+"\0changesets\0"+comparison.snapshot.from.label+"\0"+comparison.snapshot.to.label+"\0"+ComparisonToolInvocation.cacheKey
        let controller=fileComparisonWindows[key] ?? FileComparisonWindowController(repository:repository,access:access,changeSets:comparison)
        controller.model.comparisonDefaults=fileComparisonPreferences
        controller.onClosed={ [weak self,weak controller] in
            guard let self,let controller,self.fileComparisonWindows[key] === controller else { return }
            self.fileComparisonWindows.removeValue(forKey:key)
        }
        fileComparisonWindows[key]=controller;controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
    }
    private var fileComparisonSessions: [UUID: FileListComparisonSession] = [:]
    private func prepareFileComparisons(repository: GitRepository, access: RepositoryAccessLease?, selectedCount: Int, owner: NSWindow?, operation: @escaping (OperationCancellation) async throws -> Void) {
        guard !busy, !confirmingQuit else { return }
        let id = UUID(), session = FileListComparisonSession(window: owner ?? NSApp.keyWindow ?? workspaceWindow, preferences: fileComparisonPreferences)
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
    func showFileComparisons(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, owner: NSWindow? = nil) {
        prepareFileComparisons(repository: repository, access: access, selectedCount: snapshot.files.count, owner: owner) { [self] token in
            presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token)
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
    func showPreparedFileComparison(repository: GitRepository, access: RepositoryAccessLease?, marked: PreparedFileComparisonMark, current: PreparedFileComparisonMark, owner: NSWindow? = nil) {
        prepareFileComparisons(repository: repository, access: access, selectedCount: 2, owner: owner) { [self] token in
            if current.isDirectory || marked.isDirectory {
                guard current.isDirectory,marked.workingAccess == nil else {throw SubmoduleComparisonFailure.unsupported}
                try token.check()
                showSubmoduleDiff(repository:repository,access:access,path:current.path,
                    from:marked.revision.isEmpty ? "Working tree":marked.revision,
                    to:current.revision.isEmpty ? nil:current.revision,
                    fromPath:marked.path,fromIndex:marked.revision.isEmpty && current.revision.isEmpty)
                return
            }
            if let workingAccess = marked.workingAccess {
                if GitRuntime.isAppStoreBuild && (!workingAccess.permission.hasSecurityScope || !workingAccess.permission.contains(workingAccess.file)) { throw RepositoryAccessFailure.securityScopeUnavailable }
                guard !token.isCancelled, !confirmingQuit else { return }
                let key = "historical-working:" + UUID().uuidString
                let controller: FileComparisonWindowController
                if current.revision.isEmpty {
                    let file = repository.root.appendingPathComponent(current.path)
                    if GitRuntime.isAppStoreBuild && access?.contains(file) != true { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let comparison = try WorkingFileComparison(base: workingAccess.file, destination: file)
                    _ = try comparison.read()
                    controller = FileComparisonWindowController(comparison: comparison, permissions: [workingAccess.permission] + [access].compactMap { $0 })
                } else {
                    let comparison = try await repository.historicalWorkingFileComparison(revision: current.revision, path: current.path, workingFile: workingAccess.file, cancellation: token)
                    controller = FileComparisonWindowController(repository: repository, access: access, comparison: comparison, permission: workingAccess.permission)
                }
                guard !token.isCancelled, !confirmingQuit else { return }
                controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.fileComparisonWindows[key] === controller else { return }; self.fileComparisonWindows.removeValue(forKey: key) }
                fileComparisonWindows[key] = controller
                controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
                _ = try comparisonMarkStore.consume(workingAccess.mark.id)
                try publishComparisonMark()
            } else {
                let snapshot = try await repository.preparedPathComparison(from: marked.revision.isEmpty ? .workingTree : .revision(marked.revision), fromPath: marked.path, to: current.revision.isEmpty ? .workingTree : .revision(current.revision), toPath: current.path, cancellation: token)
                presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token)
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
    func showHistoricalFiles(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision, paths: [String], owner: NSWindow? = nil, line: Int? = nil) {
        prepareFileComparisons(repository: repository, access: access, selectedCount: paths.count, owner: owner) { [self] token in
            let snapshot = try await repository.revisionFileComparison(from: from, to: to, paths: paths, cancellation: token)
            if snapshot.files.isEmpty { output = "No files exist at the selected comparison paths."; return }
            presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token, line: line)
        }
    }
    private func presentFileComparisons(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, cancellation: OperationCancellation, line: Int? = nil) {
        for file in snapshot.files {
            guard !confirmingQuit, !cancellation.isCancelled else { return }
            if let fileComparisonPresentation { fileComparisonPresentation(snapshot, file); continue }
            if file.isSubmodule {
                showSubmoduleDiff(repository: repository, access: access, path: file.path, from: snapshot.from == .emptyTree ? "" : snapshot.from.label, to: snapshot.to == .workingTree ? nil : snapshot.to == .emptyTree ? "" : snapshot.to.label,fromPath:file.oldPath)
                continue
            }
            let key = repository.root.path + "\0" + file.path + "\0" + (file.oldPath ?? file.path) + "\0" + snapshot.from.label + "\0" + snapshot.to.label + "\0" + ComparisonToolInvocation.cacheKey + (line.map { "\0line\0" + String($0) + "\0" + UUID().uuidString } ?? "")
            let controller = (fileComparisonWindows[key]?.window != nil ? fileComparisonWindows[key] : nil) ?? FileComparisonWindowController(repository: repository, access: access, snapshot: snapshot, path: file.path, preferences: fileComparisonPreferences, line: line)
            controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.fileComparisonWindows[key] === controller else { return }; self.fileComparisonWindows.removeValue(forKey: key) }
            fileComparisonWindows[key] = controller
            controller.model.comparisonDefaults = fileComparisonPreferences
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
    }
    private func showSubmoduleSync(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], commandLaunch: Bool = false) {
        if let existing = submoduleSyncWindows.values.first(where: { $0.model.repository.root == repository.root && $0.model.activeOperation }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            if commandLaunch { error = "A Submodule Sync operation is already running. Wait for it before opening another command." }; return
        }
        let id = UUID(), controller = SubmoduleSyncWindowController(repository: repository, access: access, scope: scope, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.submoduleSyncWindows.removeValue(forKey: id) }
        controller.model.onSynced = { [weak self] _ in
            self?.refreshRepositoryLogs(repository.root)
            if let self, self.root == repository.root { Task { await self.refresh() } }
        }
        submoduleSyncWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
    }
    private func showSubmoduleAdd(repository: GitRepository, access: RepositoryAccessLease?, path: String, commandLaunch: Bool = false) {
        let key = repository.root.path
        if commandLaunch, let existing = submoduleAddWindows[key] {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "A Submodule Add dialog is already open. Close it before opening another command-line Submodule Add."; return
        }
        if commandLaunch, let existing = submoduleAddProgressWindows.values.first(where: { $0.model.repository.root == repository.root && $0.model.activeOperation }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "A Submodule Add operation is already running. Wait for it before opening another command."; return
        }
        let controller = submoduleAddWindows[key] ?? SubmoduleAddWindowController(repository: repository, access: access, path: path, preferences: fileComparisonPreferences, clipboardText:creationClipboardText())
        controller.onClosed = { [weak self] in self?.submoduleAddWindows.removeValue(forKey: key) }
        controller.model.onSubmit = { [weak self] progress in self?.showSubmoduleAddProgress(model: progress) }
        submoduleAddWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showSubmoduleAddProgress(model: SubmoduleAddProgressWindowModel) {
        let root = model.repository.root, key = root.path, id = UUID()
        let controller = SubmoduleAddProgressWindowController(model: model)
        controller.onClosed = { [weak self] in self?.submoduleAddProgressWindows.removeValue(forKey: id) }
        model.onAdded = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            self?.statusWindows[key]?.model.requestReload(); self?.commitWindows[key]?.model.reload()
            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
        }
        submoduleAddProgressWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); model.start()
    }
    private func showSubmoduleUpdate(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], selected: [String] = [], commandLaunch: Bool = false, completion: (() -> Void)? = nil) {
        let root = repository.root, key = root.path + "\0" + scope.joined(separator: "\0") + "\0" + selected.joined(separator: "\0")
        if commandLaunch, let existing = submoduleUpdateWindows.values.first(where: { $0.model.repository.root == root }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "A Submodule Update dialog is already open. Close it before opening another command-line Submodule Update."; return
        }
        if commandLaunch, let existing = submoduleUpdateProgressWindows.values.first(where: { $0.model.repository.root == root && $0.model.activeOperation }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "A Submodule Update operation is already running. Wait for it before opening another command."; return
        }
        let controller = submoduleUpdateWindows[key] ?? SubmoduleUpdateWindowController(repository: repository, access: access, scope: scope, selected: selected, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.submoduleUpdateWindows.removeValue(forKey: key) }
        controller.model.onSubmit = { [weak self] paths, options in
            self?.showSubmoduleUpdateProgress(repository: repository, access: access, paths: paths, options: options, completion: completion)
        }
        submoduleUpdateWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showSubmoduleUpdateProgress(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], options: SubmoduleUpdateOptions, completion: (() -> Void)? = nil) {
        let root = repository.root, id = UUID()
        let controller = SubmoduleUpdateProgressWindowController(repository: repository, access: access, paths: paths, options: options, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.submoduleUpdateProgressWindows.removeValue(forKey: id) }
        controller.model.onUpdated = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
            if let self, self.root == root { self.output = output; Task { await self.refresh() } }
            completion?()
        }
        controller.model.onBisect = { [weak self] operation in self?.showBisect(repository: repository, access: access, operation: operation) }
        submoduleUpdateProgressWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
    }
    @discardableResult private func showRevertProgress(repository: GitRepository, access: RepositoryAccessLease?, entries: [StatusEntry], amend: Bool = false, againstHead: Bool = false, autoCloseSuccess: Bool = false, completion: @escaping (Bool) -> Void = { _ in }) -> RevertProgressWindowController {
        let root = repository.root, id = UUID()
        let controller = RevertProgressWindowController(repository: repository, access: access, entries: entries, amend: amend, againstHead: againstHead, autoCloseSuccess: autoCloseSuccess)
        controller.onClosed = { [weak self] in self?.revertProgressWindows.removeValue(forKey: id) }
        controller.model.onFinished = { [weak self] output, succeeded in
            completion(succeeded)
            self?.refreshRepositoryLogs(root)
            self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
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
    private func showStatus(repository: GitRepository, access: RepositoryAccessLease?, paths: [String] = []) {
        let root = repository.root
        section = .status
        let controller = statusWindows[root.path] ?? StatusWindowController(repository: repository, access: access, defaults: fileComparisonPreferences)
        controller.onPullAfterLFSLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.onClosed = { [weak self] in self?.statusWindows.removeValue(forKey: root.path) }
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
            case .stash: self.showStash(repository: repository, access: access); return
            case .stashPop: self.showStashRestore(repository: repository, access: access, pop: true, showChanges: 2); return
            case .stashApply: self.showStashRestore(repository: repository, access: access, pop: false, showChanges: 0); return
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
        controller.model.onAddFiles = { [weak self] paths, mode in self?.showAddProgress(repository:repository, access:access, paths:paths, mode:mode) }
        controller.model.onSubmoduleLog = { [weak self] child in self?.showLog(repository: child, access: access, paths: []) }
        controller.model.onBlame = { [weak self] path in self?.showBlame(repository: repository, access: access, path: path, revision: "HEAD") }
        controller.model.onCompareTwoFiles = { [weak self, weak controller] paths in guard let controller else { return }; self?.showWorkingFilePair(repository: repository, access: access, paths: paths, owner: controller.window) }
        controller.model.onChanged = { [weak self] in Task { await self?.refresh() } }
        statusWindows[root.path] = controller
        controller.model.setScope(paths)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showReferenceLog(repository: GitRepository, access: RepositoryAccessLease?, reference: String) {
        let root = repository.root
        let controller = referenceLogWindows[root.path] ?? ReferenceLogWindowController(repository: repository, access: access, reference: reference, preferences:fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.referenceLogWindows.removeValue(forKey: root.path) }
        controller.model.onLog = { [weak self] hash in self?.showLog(repository: repository, access: access, paths: [], endRevision: hash, selectedRevision: hash) }
        controller.model.onLogRange = { [weak self] range in self?.showLog(repository: repository, access: access, paths: [], revisionRange: range) }
        controller.model.onBrowseRepository = { [weak self] hash in self?.showRepositoryBrowser(repository: repository, access: access, revision: hash) }
        controller.model.onCreateReference = { [weak self] isTag, hash in self?.showReference(repository: repository, access: access, isTag: isTag, revision: hash) }
        controller.model.onExport = { [weak self] hash in self?.showExport(repository: repository, access: access, revision: hash) }
        controller.model.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: from, to: to) }
        controller.model.onCheckout = { [weak self] hash in self?.showSwitch(repository: repository, access: access, revision: hash) }
        controller.model.onReset = { [weak self] hash in self?.showReset(repository: repository, access: access, revision: hash) }
        controller.model.onSwitchBranch = { [weak self, weak controller] reference in
            guard let parent = controller?.window, parent.attachedSheet == nil else { return }
            self?.showSwitchProgress(repository: repository, access: access, reference: reference, parent: parent)
        }
        controller.model.onTransport = { [weak self] request in
            switch request.command {
            case .push: self?.showPush(repository: repository, access: access, source: request.source, preserveAllBranches: true)
            case .pull: self?.showFetch(repository: repository, access: access, isPull: true)
            case .svnDCommit: self?.showSVN(.dcommit, repository: repository, access: access)
            }
        }
        controller.model.onBisect = { [weak self] request in self?.showBisect(repository: repository, access: access, good: request.good, bad: request.bad, operation: request.operation, revisions: request.revisions, requireStart: request.operation == nil) }
        controller.model.onCombineRevisions = { [weak self, weak controller] entries, offset, head in guard let controller else { return }; self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: controller.window) }
        controller.model.onFormatPatch = { [weak self] preset in self?.showFormatPatch(repository: repository, access: access, preset: preset) }
        controller.model.onMergeRevision = { [weak self] hash in self?.showMerge(repository: repository, access: access, revision: hash) }
        controller.model.onRebaseRevision = { [weak self] upstream in self?.showRebase(repository: repository, access: access, upstream: upstream) }
        controller.model.onCherryPick = { [weak self] commits in self?.showRebase(repository: repository, access: access, cherryPick: commits) }
        controller.model.onRevertRevisions = { [weak self, weak controller] entries, mainline in guard let controller else { return }; self?.showHistoryRevert(repository: repository, access: access, entries: entries, mainline: mainline, owner: controller.window) }
        controller.model.onApply = { [weak self] hash in self?.showStashRestore(repository: repository, access: access, pop: false, reference: hash) }
        controller.model.onChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        referenceLogWindows[root.path] = controller
        controller.model.reference = reference; controller.model.reload()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showStashRestore(repository: GitRepository, access: RepositoryAccessLease?, pop: Bool, reference: String? = nil, showChanges: Int = 1) {
        let root = repository.root, key = repository.root.path + (pop ? ":pop" : ":apply:" + (reference ?? "latest")) + ":show:" + String(showChanges)
        if let existing = stashRestoreWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        guard !stashMutationIsBusy(repository.root) else { error = "Wait for the current stash operation to finish."; return }
        let controller = stashRestoreWindowFactory?(repository, access, pop, reference, showChanges) ?? StashRestoreWindowController(repository: repository, access: access, pop: pop, reference: reference, showChanges: showChanges, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self, weak controller] in if self?.stashRestoreWindows[key] === controller { self?.stashRestoreWindows.removeValue(forKey: key) } }
        controller.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.requestReload(); self?.refreshRepositoryLogs(root)
            self?.commitWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.onViewChanges = { [weak self] in self?.showStatus(repository: repository, access: access) }
        stashRestoreWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.start()
    }
    private func showWorktreeList(repository: GitRepository, access: RepositoryAccessLease?) {
        let key = repository.root.path
        let controller = worktreeListWindows[key] ?? worktreeListWindowFactory?(repository, access, fileComparisonPreferences) ?? WorktreeListWindowController(repository: repository, access: access, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.worktreeListWindows.removeValue(forKey: key) }
        controller.onSubmodules = { [weak self] path, lease in
            self?.showSubmoduleUpdate(repository: GitRepository(root: path, executable: repository.executable), access: lease, scope: [])
        }
        worktreeListWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showWorktreeCreate(repository: GitRepository, access: RepositoryAccessLease?, directory: URL? = nil, commandLaunch: Bool = false) {
        let key = repository.root.path
        if commandLaunch, let existing = worktreeCreateWindows[key] ?? worktreeListWindows[key]?.createWindow {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = worktreeCreateWindows[key] ?? worktreeCreateWindowFactory?(repository, access, fileComparisonPreferences, directory) ?? WorktreeCreateWindowController(repository: repository, access: access, preferences: fileComparisonPreferences, initialDirectory: directory)
        controller.onClosed = { [weak self] in self?.worktreeCreateWindows.removeValue(forKey: key) }
        controller.model.onCreated = { [weak self] output in
            self?.worktreeListWindows[key]?.model.requestReload()
            if self?.root?.path == key { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onSubmodules = { [weak self] path, lease in
            self?.showSubmoduleUpdate(repository: GitRepository(root: path, executable: repository.executable), access: lease, scope: [])
        }
        controller.configureCommitPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
        worktreeCreateWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showRequestPull(repository: GitRepository, access: RepositoryAccessLease?, end: String? = nil, repositoryURL: String? = nil) {
        let key = repository.root.path + ":requestPull:" + UUID().uuidString
        let controller = makeRequestPull(repository, access, end, repositoryURL)
        controller.configureLogPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.onClosed = { [weak self] in self?.requestPullWindows.removeValue(forKey: key) }
        requestPullWindows[key] = controller
        if let requestPullPresentation { requestPullPresentation(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
    }
    private func showImportPatch(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        let files = paths.map { repository.root.appendingPathComponent($0) }.filter { ["patch", "diff"].contains($0.pathExtension.lowercased()) }
        showImportPatchFiles(repository: repository, access: access, files: files)
    }
    private func showImportPatchFiles(repository: GitRepository, access: RepositoryAccessLease?, files: [URL], grants: [RepositoryAccessLease] = [], commandLaunch: Bool = false) {
        let key = repository.root.path
        if commandLaunch, let existing = importPatchWindows[key], existing.activeOperation {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "Wait for the current patch operation to finish."; return
        }
        let controller = importPatchWindows[key] ?? ImportPatchWindowController(repository: repository, access: access, preferences: fileComparisonPreferences)
        controller.model.onMutationStopped = { [weak self] in
            self?.statusWindows[key]?.model.requestReload(); self?.commitWindows[key]?.model.reload()
            if self?.root?.path == key { Task { await self?.refresh() } }
        }
        controller.onClosed = { [weak self] in self?.importPatchWindows.removeValue(forKey: key) }
        controller.model.onChanged = { [weak self] output in
            self?.statusWindows[key]?.model.requestReload()
            if self?.root?.path == key { self?.output = output; Task { await self?.refresh() } }
        }
        var existingPaths = GitPathSet(controller.model.items.map { FileTransferPaths.lexicalPath($0.file.path) })
        let accepted = commandLaunch ? files.filter { existingPaths.insert(FileTransferPaths.lexicalPath($0.path)).inserted } : files
        controller.model.add(accepted, retaining: grants)
        importPatchWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showFormatPatch(repository: GitRepository, access: RepositoryAccessLease?, preset: FormatPatchPreset? = nil, sendMail: Bool = false, commandLaunch: Bool = false) {
        let rootKey = repository.root.path
        let suffix: String
        switch preset?.selection {
        case .since(let revision): suffix = "\0since\0" + revision
        case .range(let from, let to): suffix = "\0range\0" + from + "\0" + to
        case .number(let count): suffix = "\0number\0" + String(count)
        case nil: suffix = ""
        }
        let key = rootKey + (commandLaunch ? "\0command-format-patch" : suffix)
        let existing = formatPatchWindows[key]
        let controller = existing ?? FormatPatchWindowController(repository: repository, access: access, preset: preset, sendMail: sendMail, preferences: fileComparisonPreferences)
        if sendMail && controller.model.optionsAvailable { controller.model.sendMail = true }
        controller.configureReferencePicker = { [weak self] picker in self?.configureReferenceBrowser(picker, repository: repository, access: access) }
        controller.configureLogPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.onClosed = { [weak self] in self?.formatPatchWindows.removeValue(forKey: key) }
        controller.model.onOutputChanged = { [weak self] output in
            self?.statusWindows[rootKey]?.model.requestReload()
            if self?.root?.path == rootKey { self?.output = output; Task { await self?.refresh() } }
        }
        formatPatchWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func configureBrowserRevisionPicker(_ controller:RepositoryBrowserWindowController,repository:GitRepository,access:RepositoryAccessLease?) {
        controller.configureLogPicker={ [weak self] log in self?.configureSelectableLog(log,repository:repository,access:access) }
    }
    private func showRepositoryBrowser(repository: GitRepository, access: RepositoryAccessLease?, revision: String = "HEAD") {
        let baseKey = repository.root.path + "\0" + revision
        let reusable = browserWindows.first { _, controller in
            controller.model.repository.root == repository.root && controller.model.repository.executable == repository.executable &&
            controller.window?.attachedSheet == nil && controller.model.canReuseForRevision(revision)
        }
        let key = reusable?.key ?? (browserWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? RepositoryBrowserWindowController(repository: repository, access: access, revision: revision, preferences:fileComparisonPreferences)
        configureBrowserRevisionPicker(controller,repository:repository,access:access)
        controller.onClosed = { [weak self] in self?.browserWindows.removeValue(forKey: key) }
        controller.model.onLog = { [weak self] path, hash in self?.showLog(repository: repository, access: access, paths: path.isEmpty ? [] : [path], endRevision: hash) }
        controller.model.onBlame = { [weak self] path, hash in self?.showBlame(repository: repository, access: access, path: path, revision: hash) }
        controller.model.onCompare = { [weak self, weak controller] path, hash in guard let controller else { return }; self?.showHistoricalFiles(repository: repository, access: access, from: .revision(hash), to: .workingTree, paths: [path], owner: controller.window) }
        controller.model.onChanged = { [weak self] in
            guard let self else { return }
            self.statusWindows[repository.root.path]?.model.requestReload()
            self.commitWindows[repository.root.path]?.model.reload()
            if self.root == repository.root { Task { await self.refresh() } }
        }
        controller.model.importWorkingComparisonMark(try? comparisonMarkStore.acquire(requireSecurityScope: GitRuntime.isAppStoreBuild))
        controller.model.onPreparedFileCompare = { [weak self, weak controller] marked, current in guard let controller else { return }; self?.showPreparedFileComparison(repository: repository, access: access, marked: marked, current: current, owner: controller.window) }
        controller.model.onSubmoduleUpdate = { [weak self] path in
            self?.showSubmoduleUpdate(repository:repository,access:access,scope:[],selected:[path])
        }
        controller.model.onSubmodule = { [weak self,weak model=controller.model] module,entry,showLog in
            guard let model, model.active else { return }
            guard let checkout=module.checkout, module.from.available else {
                if showLog { model.error="Cannot show submodule history at " + entry.objectID + ". The child repository is not initialized or the revision is unavailable." }
                else { model.offerSubmoduleUpdate(entry) }
                return
            }
            let child=GitRepository(root:checkout,executable:repository.executable)
            if showLog { self?.showLog(repository:child,access:access,paths:[],endRevision:entry.objectID) }
            else { self?.showRepositoryBrowser(repository:child,access:access,revision:entry.objectID) }
        }
        browserWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func configureBlameRoutes(_ controller:BlameWindowController) {
        let repository=controller.model.repository,access=controller.model.repositoryAccess
        controller.model.onHistoryExport={ [weak self] hash in self?.showExport(repository:repository,access:access,revision:hash) }
        controller.model.onHistoryReference={ [weak self] tag,hash in self?.showReference(repository:repository,access:access,isTag:tag,revision:hash) }
        controller.model.onHistorySwitch={ [weak self] hash in self?.showSwitch(repository:repository,access:access,revision:hash) }
        controller.model.onHistoryBrowse={ [weak self] hash in self?.showRepositoryBrowser(repository:repository,access:access,revision:hash) }
        controller.configureContainingReferences={ [weak self] child in
            child.onLog={ [weak self] name,select,range in self?.showLog(repository:repository,access:access,paths:[],endRevision:name,selectedRevision:select ? name : nil,revisionRange:range) }
            child.onBrowse={ [weak self] name in self?.showRepositoryBrowser(repository:repository,access:access,revision:name) }
            child.onCompare={ [weak self] from,to in self?.showRevisionComparison(repository:repository,access:access,from:from,to:to) }
        }
        controller.model.onLog={ [weak self] origin,hash in self?.showLog(repository:repository,access:access,paths:[origin],endRevision:hash) }
        controller.model.onChanges={ [weak self, weak controller] snapshot in guard let controller else { return }; self?.showFileComparisons(repository:repository,access:access,snapshot:snapshot,owner:controller.window) }
        controller.model.onPrevious={ [weak self] origin,hash,number,inherited in self?.showBlame(repository:repository,access:access,path:origin,revision:hash,line:number,options:inherited) }
    }
    private func showBlame(repository:GitRepository,access:RepositoryAccessLease?,path:String,revision:String,line:Int? = nil,options:GitBlameOptions? = nil,commandLaunch:Bool = false) {
        let key=GitPathRowIdentity.encode(repository.root.path+"\0"+path+"\0"+revision)+(commandLaunch ? UUID().uuidString:"")
        var recentFailure:String?
        if blameRecentDocuments==nil { do { blameRecentDocuments=try BlameRecentDocuments.production() } catch { recentFailure="Recent files could not be loaded: "+error.localizedDescription } }
        let controller=blameWindows[key] ?? BlameWindowController(repository:repository,access:access,path:path,revision:revision,options:options ?? GitBlamePreferences.load(from:fileComparisonPreferences),preferences:fileComparisonPreferences,recentDocuments:blameRecentDocuments)
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
        blameWindows[key]=controller;controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
    }
    private func refreshRepositoryLogs(_ root: URL) {
        configuredLogModels=configuredLogModels.filter { $0.value.model?.isInvalidated == false }
        var refreshed=Set<ObjectIdentifier>()
        for model in logWindows.values.map(\.model)+configuredLogModels.values.compactMap(\.model) where model.repository.root == root && !model.isInvalidated {
            if refreshed.insert(ObjectIdentifier(model)).inserted { model.requestRepositoryRefresh() }
        }
        for graph in revisionGraphWindows.values where graph.model.repository.root == root && !graph.model.closed { graph.requestRepositoryRefresh() }
    }
    private func showHistoryRevert(repository: GitRepository, access: RepositoryAccessLease?, entries: [LogEntry], mainline: Int?, owner: NSWindow?) {
        guard owner?.attachedSheet == nil else { return }
        let id = UUID(), root = repository.root
        let child = HistoryRevertWindowController(repository: repository, access: access, entries: entries, mainline: mainline, preferences: .standard)
        child.model.onChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root); self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        child.model.onCommit = { [weak self] in self?.showCommitDialog(repository: repository, access: access, paths: []) }
        child.onClosed = { [weak self, weak owner, weak child] in
            if let window = child?.window, window.sheetParent === owner { owner?.endSheet(window) }
            self?.historyRevertWindows.removeValue(forKey: id)
        }
        historyRevertWindows[id] = child
        if let owner, let window = child.window { window.alphaValue = owner.alphaValue; window.appearance = owner.appearance; owner.beginSheet(window) }
        else { child.showWindow(nil) }
        child.model.start()
    }
    private func showHistoryCombine(repository: GitRepository, access: RepositoryAccessLease?, entries: [LogEntry], offset: Int, head: String, owner: NSWindow?) {
        guard owner?.attachedSheet == nil else { return }
        let id = UUID(), root = repository.root
        let child = HistoryCombineWindowController(repository: repository, access: access, entries: entries, firstOffset: offset, expectedHead: head, preferences: .standard)
        child.configureCommit = { [weak self] commit in self?.configureCommitInteractions(commit.model, repository: repository, access: access) }
        child.model.onChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root); self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload()
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
            self?.statusWindows[changed.root.path]?.model.requestReload(); self?.commitWindows[changed.root.path]?.model.reload()
            if self?.root == changed.root { Task { await self?.refresh() } }
        }
        gitPropertyWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showLog(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], endRevision: String? = nil, selectedRevision: String? = nil, revisionRange: HistoryRevisionRange? = nil, invocation: PrimaryCommandInvocation? = nil, outputAccess: RepositoryAccessLease? = nil) {
        let root = repository.root
        var baseKey = root.path
        if let revisionRange { baseKey += "\0range\0" + revisionRange.expression }
        else if let endRevision { baseKey += "\0" + endRevision }
        if !paths.isEmpty { baseKey += "\0paths\0" + paths.sorted().joined(separator: "\0") }
        if invocation != nil { baseKey += "\0command\0" + UUID().uuidString }
        let reusable: (key: String, value: LogWindowController)?
        if let revisionRange, invocation == nil {
            reusable = logWindows.first { _, controller in
                controller.model.repository.root == root && controller.model.repository.executable == repository.executable &&
                controller.window?.attachedSheet == nil && controller.model.canReuseForRange(revisionRange,paths:paths)
            }
        } else { reusable = logWindows[baseKey].map { (key: baseKey, value: $0) } }
        let key = reusable?.key ?? (logWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller: LogWindowController
        if let output = invocation?.outputFile, let outputAccess {
            let completion: (LogEntry?) -> Void = { [weak self] revision in self?.writeCommandSelection(revision, file: output, permission: outputAccess) }
            controller = commandLineSelectionWindowFactory?(repository, access, completion) ?? LogWindowController(repository: repository, access: access, onChoose: completion, labelDefaults: fileComparisonPreferences, loadsImmediately: false)
        } else { controller = reusable?.value ?? logWindowFactory?(repository,access) ?? LogWindowController(repository: repository, access: access, loadsImmediately: invocation == nil) }
        controller.onClosed = { [weak self] in self?.logWindows.removeValue(forKey: key) }
        controller.model.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        controller.model.onHistoryPush = { [weak self] revision, preserveAllBranches in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: preserveAllBranches) }
        controller.model.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.model.onCombineRevisions = { [weak self, weak controller] entries, offset, head in guard let controller else { return }; self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: controller.window) }
        configureLogRevert(controller.model,repository:repository,access:access)
        controller.model.onFormatPatch = { [weak self] preset in self?.showFormatPatch(repository: repository, access: access, preset: preset) }
        controller.model.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
        controller.model.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
        configureLogMenus(controller.model, repository: repository, access: access)
        controller.model.onCherryPick = { [weak self] commits in self?.showRebase(repository: repository, access: access, cherryPick: commits) }
        controller.model.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision, paths: paths) }
        configureLogIntegration(controller.model,repository:repository,access:access)
        configureLogBisect(controller.model, repository: repository, access: access)
        controller.model.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
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
            self?.showAddProgress(repository: repository, access: access, paths: paths, mode: mode)
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
        controller.model.onSubmoduleFileLog = { [weak self] checkout, hash in
            let child = GitRepository(root: checkout, executable: repository.executable)
            self?.showLog(repository: child, access: access, paths: [], endRevision: hash)
        }
        controller.model.onBlame = { [weak self] path, hash in self?.showBlame(repository: repository, access: access, path: path, revision: hash) }
        controller.model.onRevisionChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
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
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }

    private func configureLogMenus(_ model: LogWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        model.onFollowedFileComparison = { [weak self] snapshot, token in
            self?.presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token)
        }
        configuredLogModels=configuredLogModels.filter { $0.value.model?.isInvalidated == false }
        configuredLogModels[ObjectIdentifier(model)]=ConfiguredLog(model:model)
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
            self?.showRevisionComparison(repository:repository,access:access,from:from,to:to,paths:model.showWholeProject ? [] : model.historyPaths)
        }
        model.onShowHistory={ [weak self] hash in self?.showLog(repository:repository,access:access,paths:[],endRevision:hash,selectedRevision:hash) }
        model.onShowHistoryRange={ [weak self,weak model] range in
            guard let model else { return }
            self?.showLog(repository:repository,access:access,paths:model.historyPaths,revisionRange:range)
        }
        model.onCommitChangeSets={ [weak self] comparison in self?.showCommitChangeSets(repository:repository,access:access,comparison:comparison) }
        model.onHistorySVNDCommit={ [weak self] in self?.showSVN(.dcommit,repository:repository,access:access) }
        model.configureStartReferenceBrowser = { [weak self] picker in self?.configureReferenceBrowser(picker, repository: repository, access: access) }
        model.onSwitchBranch = { [weak self, weak model] reference in
            guard let parent = model?.window, parent.attachedSheet == nil else { return }
            self?.showSwitchProgress(repository: repository, access: access, reference: reference, parent: parent)
        }
    }
    private func configureLogBisect(_ model: LogWindowModel, repository: GitRepository, access: RepositoryAccessLease?, refreshPicker: Bool = false) {
        model.onBisect = { [weak self, weak model] request in
            self?.showBisect(repository: repository, access: access, good: request.good, bad: request.bad, operation: request.operation, revisions: request.revisions, requireStart: request.operation == nil, sourceLog: refreshPicker ? model : nil)
        }
    }
    private func showBisect(repository: GitRepository, access: RepositoryAccessLease?, good: String? = nil, bad: String? = nil, operation: BisectOperation? = nil, revisions: [String] = [], requireStart: Bool = false, sourceLog: LogWindowModel? = nil, onChanged: (() -> Void)? = nil, command: BisectCommandRequest? = nil) {
        let root = repository.root
        let controller: BisectWindowController
        if let existing = bisectWindows[root.path] {
            if command != nil && existing.activeOperation {
                existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
                error = "Wait for the current bisect operation to finish."; return
            }
            controller = existing
            if !existing.activeOperation { existing.model.load(good: good, bad: bad, operation: operation, revisions: revisions, requireStart: requireStart, command: command, preserveStartDraft: command != nil && existing.model.hasStartReview && !existing.model.showingProgress) }
        } else { controller = BisectWindowController(repository: repository, access: access, good: good, bad: bad, operation: operation, revisions: revisions, requireStart: requireStart, command: command, preferences: fileComparisonPreferences) }
        if let sourceLog { controller.model.observeLog(sourceLog) }
        controller.onClosed = { [weak self] in self?.bisectWindows.removeValue(forKey: root.path) }
        controller.model.onChanged = { [weak self] output in
            onChanged?()
            guard let self else { return }
            self.refreshRepositoryLogs(root)
            self.commitWindows[root.path]?.model.reload(); self.statusWindows[root.path]?.model.requestReload()
            if self.root == root { self.output = output; Task { await self.refresh() } }
        }
        controller.model.onSubmoduleUpdate = { [weak self] in self?.showSubmoduleUpdate(repository: repository, access: access, scope: []) }
        bisectWindows[root.path] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func configureExportInteractions(_ controller: ExportWindowController, repository: GitRepository, access: RepositoryAccessLease?) {
        controller.configureCommitPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.configureReferencePicker = { [weak self] picker in self?.configureReferenceBrowser(picker, repository: repository, access: access) }
    }
    private func showExport(repository: GitRepository, access: RepositoryAccessLease?, revision: String, paths: [String] = [], commandLaunch: Bool = false) {
        let commandKey = repository.root.path + "\0command-export"
        if commandLaunch, let existing = exportWindows[commandKey] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let root = repository.root
        let directory = ExportWindowModel.directoryScope(root: root, paths: paths)
        let baseKey = root.path + "\0" + revision + "\0" + directory
        let reusable = exportWindows.first { key, controller in
            !commandLaunch && key != commandKey &&
            controller.model.repository.root == repository.root && controller.model.repository.executable == repository.executable &&
            controller.window?.attachedSheet == nil && controller.model.canReuseForRevision(revision, directory: directory)
        }
        let key = commandLaunch ? commandKey : reusable?.key ?? (exportWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? ExportWindowController(repository: repository, access: access, revision: revision, directory: directory, preferences: fileComparisonPreferences)
        configureExportInteractions(controller, repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.exportWindows.removeValue(forKey: key) }
        exportWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showMergeAbort(repository: GitRepository, access: RepositoryAccessLease?, commandLaunch: Bool = false) {
        if commandLaunch, let existing = mergeAbortWindows.values.first(where: { $0.model.repository.root == repository.root }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return
        }
        let id = UUID(), root = repository.root
        let controller = mergeAbortWindowFactory?(repository,access) ?? MergeAbortWindowController(repository: repository, access: access, preferences: fileComparisonPreferences)
        controller.configureModifiedComparison={ [weak self] model in self?.configureRevisionComparisonInteractions(model,repository:repository,access:access) }
        controller.onClosed = { [weak self] in self?.mergeAbortWindows.removeValue(forKey: id) }
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.statusWindows[root.path]?.model.requestReload()
            self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPostAction = { [weak self] action in
            if let operation = action.bisectOperation { self?.showBisect(repository: repository, access: access, operation: operation) }
            else if action == .submoduleUpdate { self?.showSubmoduleUpdate(repository: repository, access: access, scope: []) }
            else if action == .clean { self?.showClean(repository: repository, access: access, paths: []) }
        }
        mergeAbortWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func configureMergeInteractions(_ controller: MergeWindowController, repository: GitRepository, access: RepositoryAccessLease?, showStashPop: Bool = false) {
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
        let root = repository.root
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.requestReload(); self?.refreshRepositoryLogs(root)
            self?.commitWindows[root.path]?.model.reload()
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.configureLogPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.model.showStashPop = showStashPop
        controller.model.onAbortRequested = { [weak self] in self?.showMergeAbort(repository: repository, access: access) }
        controller.model.onPostAction = { [weak self] action, request in
            switch action {
            case .resolve: self?.showResolve(repository: repository, access: access, paths: [], quick: nil)
            case .commit: self?.showCommitDialog(repository: repository, access: access, paths: [])
            case .stash:
                var followUp = StashSaveFollowUp(); followUp.mergeRevision = request.revision
                self?.showStash(repository: repository, access: access, followUp: followUp)
            case .stashPop: self?.showStashRestore(repository: repository, access: access, pop: true)
            case .push: self?.showPush(repository: repository, access: access)
            case .mergeUnrelated, .removeBranch: break
            }
        }
    }
    func configureLogRevert(_ log:LogWindowModel,repository:GitRepository,access:RepositoryAccessLease?) {
        log.onPreparedRevert={ [weak self,weak log] selection in
            self?.showHistoryRevert(repository:repository,access:access,entries:selection.rows,mainline:selection.mainline,owner:log?.window)
        }
    }
    func configureLogIntegration(_ log:LogWindowModel,repository:GitRepository,access:RepositoryAccessLease?) {
        log.onMergeRevision = { [weak self] revision in self?.showMerge(repository:repository,access:access,revision:revision) }
        log.onPreparedRebase = { [weak self] prepared in
            self?.showRebase(repository:repository,access:access,upstream:prepared.canonicalRevision,fromLog:true)
        }
    }
    private func showMerge(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, showStashPop: Bool = false, commandLaunch: Bool = false) {
        let key = repository.root.path + "\0" + (commandLaunch ? "command-merge" : UUID().uuidString)
        if let existing = mergeWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = MergeWindowController(repository: repository, access: access, preferences: fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.mergeWindows.removeValue(forKey: key) }
        configureMergeInteractions(controller, repository: repository, access: access, showStashPop: showStashPop)
        mergeWindows[key] = controller; controller.model.load(revision: revision)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func stashMutationIsBusy(_ root: URL) -> Bool {
        stashWindows.values.contains { $0.model.repository.root == root && $0.model.busy }
            || stashRestoreWindows.values.contains { $0.repository.root == root && $0.model.busy }
    }
    private func showStash(repository: GitRepository, access: RepositoryAccessLease?, followUp: StashSaveFollowUp = StashSaveFollowUp(), message: String? = nil, commandLaunch: Bool = false) {
        let root = repository.root, key = repository.root.path + "\0" + (commandLaunch ? "command-stash" : UUID().uuidString)
        if let existing = stashWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        guard !stashMutationIsBusy(root) else { error = "Wait for the current stash operation to finish."; return }
        let controller = StashWindowController(repository: repository, access: access, preferences: fileComparisonPreferences)
        if let message { controller.model.options.message = message }
        controller.model.canStart = { [weak self] in self.map { !$0.stashMutationIsBusy(root) } ?? false }
        controller.onClosed = { [weak self] in self?.stashWindows.removeValue(forKey: key) }
        let changed: (String) -> Void = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.requestReload(); self?.refreshRepositoryLogs(root)
            self?.commitWindows[root.path]?.model.reload()
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onSaved = { result in changed(result.output) }
        controller.model.onFailed = changed
        controller.model.followUp = followUp
        controller.model.onPostAction = { [weak self] action, request in
            switch action {
            case .pull: self?.showFetch(repository: repository, access: access, isPull: true, followUp: PullFollowUp(stashSave: request))
            case .merge: if let revision = request.mergeRevision { self?.showMerge(repository: repository, access: access, revision: revision, showStashPop: true) }
            case .pop, .apply: self?.showStashRestore(repository: repository, access: access, pop: action == .pop)
            }
        }
        stashWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func configureCommitInteractions(_ model: CommitWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        model.onCommitSubmodule = { [weak self] checkout in
            guard !GitRuntime.isAppStoreBuild || access?.hasSecurityScope == true && access?.contains(checkout) == true else { self?.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
            self?.showCommitDialog(repository: GitRepository(root: checkout, executable: repository.executable), access: access, paths: [])
        }
        model.onCompare = { [weak self, weak model] paths, amendToParent in
            guard let model, model.messageFocusAvailable else { return }
            self?.showWorkingFiles(repository: repository, access: access, paths: paths, amendToParent: amendToParent, owner: model.comparisonWindow)
        }
        model.onCompareTwoFiles = { [weak self, weak model] paths in
            guard let model, model.messageFocusAvailable else { return }
            self?.showWorkingFilePair(repository: repository, access: access, paths: paths, owner: model.comparisonWindow)
        }
        model.onSubmoduleLog = { [weak self] child in self?.showLog(repository: child, access: access, paths: []) }
        model.onFileLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path]) }
        model.onFileBlame = { [weak self] path in self?.showBlame(repository: repository, access: access, path: path, revision: "HEAD") }
        model.onResolve = { [weak self, weak model] action, paths in
            if action == .editConflict, let path = paths.first { self?.showConflictEditor(repository: repository, access: access, path: path, owner: model?.comparisonWindow) }
            else { self?.showResolve(repository: repository, access: access, paths: paths, quick: action.resolveChoice) }
        }
        model.onIgnore = { [weak self] action, paths in self?.showIgnore(repository: repository, access: access, paths: paths, action: action) }
        model.onRevert = { [weak self, weak model] entries, amend, againstHead, done in
            guard let self else { done(false); return }
            self.showRevertProgress(repository: repository, access: access, entries: entries, amend: amend, againstHead: againstHead, autoCloseSuccess: !entries.contains(where: { model?.submodules.contains($0.path) == true }), completion: done)
        }
        model.onCopyAdd = { [weak self] paths in self?.showCopy(repository: repository, access: access, sources: paths.map { repository.root.appendingPathComponent($0) }) }
        model.onPasteFiles = { [weak self] copy, urls in self?.showFileTransfer(copy: copy, repository: repository, access: access, urls: urls) }
        model.onMove = { [weak self] paths in self?.showMove(repository: repository, access: access, paths: paths) }
        model.onRename = { [weak self] path in self?.showRename(repository: repository, access: access, source: path) }
        model.configureLogPicker = { [weak self] log in
            log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
            log.onHistoryPush = { [weak self] revision, preserveAllBranches in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: preserveAllBranches) }
            log.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
            log.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
            log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
            self?.configureLogMenus(log, repository: repository, access: access)
            log.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision) }
            self?.configureLogIntegration(log,repository:repository,access:access)
            log.onCombineRevisions = { [weak self, weak log] entries, offset, head in self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: log?.window) }
            self?.configureLogRevert(log,repository:repository,access:access)
            self?.configureLogBisect(log, repository: repository, access: access, refreshPicker: true)
            log.onCherryPick = { [weak self] commits in self?.showRebase(repository: repository, access: access, cherryPick: commits) }
        log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
        }
    }
    private func showRebase(repository: GitRepository, access: RepositoryAccessLease?, upstream: String? = nil, autoStart: Bool = false, preserveMerges: Bool = false, cherryPick: [String]? = nil, afterFetch: Bool = false, fromLog: Bool = false, owner: NSWindow? = nil, force: Bool? = nil, commandLaunch: Bool = false, onDismissed: (() -> Void)? = nil, onResult: ((Bool) -> Void)? = nil, onRequestedLog: (() -> Void)? = nil) {
        let root = repository.root
        let existing = rebaseWindows[root.path]
        if commandLaunch, let existing {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            error = "Close the existing Rebase dialog before launching another Rebase command."
            return
        }
        if let existing, existing.window?.sheetParent != nil { existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = existing ?? RebaseWindowController(repository: repository, access: access, preferences:fileComparisonPreferences)
        controller.configureReferencePicker = { [weak self] picker in self?.configureReferenceBrowser(picker, repository: repository, access: access) }
        var dismissed = false
        controller.onClosed = { [weak self, weak controller] in
            guard !dismissed else { return }; dismissed = true
            if let window = controller?.window { window.sheetParent?.endSheet(window) }
            let completed = controller?.model.completedSuccessfully == true
            self?.rebaseWindows.removeValue(forKey: root.path); onResult?(completed); onDismissed?()
        }
        controller.model.onChanged = { [weak self] in
            self?.refreshRepositoryLogs(root); self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
            if self?.root == root { Task { await self?.refresh() } }
        }
        controller.model.onShowStatus = { [weak self] in
            guard let self else { return }
            if self.root == root { self.activate(.status) }
            else if let access { self.openSession(access, action: .status) }
        }
        controller.model.onConflictAction = { [weak self, weak controller] action, paths in
            if action == .editConflict, let path = paths.first { self?.showConflictEditor(repository: repository, access: access, path: path, owner: controller?.window) }
            else { self?.showResolve(repository: repository, access: access, paths: paths, quick: action.resolveChoice) }
        }
        controller.model.onConflictRevertSubmodules={ [weak self] revision,paths in
            for path in paths {self?.showSubmoduleDiff(repository:repository,access:access,path:path,from:revision)}
        }
        controller.model.importConflictComparisonMark(try? comparisonMarkStore.acquire(requireSecurityScope:GitRuntime.isAppStoreBuild))
        controller.model.onConflictPreparedComparison={ [weak self,weak controller] marked,current in
            guard let controller else {return};self?.showPreparedFileComparison(repository:repository,access:access,marked:marked,current:current,owner:controller.window)
        }
        controller.model.onConflictSubmoduleLog={ [weak self] child in self?.showLog(repository:child,access:access,paths:[]) }
        controller.model.onConflictFileLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path]) }
        controller.model.onConflictFileBlame = { [weak self] path, revision in self?.showBlame(repository: repository, access: access, path: path, revision: revision) }
        controller.model.onConflictWorkingComparison = { [weak self, weak controller] paths,amendToParent in
            guard let self, let controller else { return }
            self.prepareFileComparisons(repository: repository, access: access, selectedCount: paths.count, owner: controller.window) { [weak self] token in
                let snapshot = try await repository.workingFileComparison(paths: paths,amendToParent:amendToParent, cancellation: token)
                self?.presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token)
            }
        }
        controller.model.onConflictWorkingPair = { [weak self, weak controller] paths in guard let controller else { return }; self?.showWorkingFilePair(repository: repository, access: access, paths: paths, owner: controller.window) }
        controller.model.completionAfterFetch = afterFetch
        controller.model.completionFromLog = fromLog
        controller.model.completionAutoStart = autoStart
        controller.model.onCompletedLog = onRequestedLog ?? { [weak self] in self?.showLog(repository: repository, access: access, paths: []) }
        controller.model.onCompletedPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        controller.model.onCompletedMail = { [weak self] preset in self?.showFormatPatch(repository: repository, access: access, preset: preset, sendMail: true) }
        controller.model.configureCommitSelection = { [weak self] commit in self?.configureCommitInteractions(commit, repository: repository, access: access) }
        let revisionFiles=controller.model.revisionFiles
        revisionFiles.onFileLog={ [weak self] path,revision in self?.showLog(repository:repository,access:access,paths:[path],endRevision:revision) }
        revisionFiles.onBlame={ [weak self] path,revision in self?.showBlame(repository:repository,access:access,path:path,revision:revision) }
        revisionFiles.onSubmoduleLog={ [weak self] child,revision in self?.showLog(repository:GitRepository(root:child,executable:repository.executable),access:access,paths:[],endRevision:revision) }
        revisionFiles.onSubmoduleCompare={ [weak self] path,oldPath,from,to in
            self?.showSubmoduleDiff(repository:repository,access:access,path:path,from:from == .emptyTree ? "" : from.label,to:to == .workingTree ? nil : to == .emptyTree ? "":to.label,fromPath:oldPath)
        }
        let revisionLog = controller.model.revisionMenuLog
        revisionLog.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: from, to: to) }
        revisionLog.onBrowseRepository = { [weak self] hash in self?.showRepositoryBrowser(repository: repository, access: access, revision: hash) }
        revisionLog.onCreateReference = { [weak self] tag, hash in self?.showReference(repository: repository, access: access, isTag: tag, revision: hash) }
        revisionLog.onPush = { [weak self] hash in self?.showPush(repository: repository, access: access, source: hash) }
        revisionLog.onHistoryPush = { [weak self] revision, preserveAllBranches in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: preserveAllBranches) }
        revisionLog.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        revisionLog.onFormatPatch = { [weak self] preset in self?.showFormatPatch(repository: repository, access: access, preset: preset) }
        revisionLog.onRevisionChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output }
        }
        controller.model.onShowRevisionLog = { [weak self] hash in self?.showLog(repository: repository, access: access, paths: [], endRevision: hash) }
        controller.model.configureLogPicker = { [weak self] log in
            log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
            log.onHistoryPush = { [weak self] revision, preserveAllBranches in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: preserveAllBranches) }
            log.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
            log.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
            log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
            self?.configureLogMenus(log, repository: repository, access: access)
            log.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision) }
            self?.configureLogIntegration(log,repository:repository,access:access)
            log.onCombineRevisions = { [weak self, weak log] entries, offset, head in self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: log?.window) }
            self?.configureLogRevert(log,repository:repository,access:access)
            self?.configureLogBisect(log, repository: repository, access: access, refreshPicker: true)
            log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
        }
        rebaseWindows[root.path] = controller
        if existing == nil || controller.model.finished || upstream != nil || cherryPick != nil { controller.model.load(upstream: upstream, autoStart: autoStart, preserveMerges: preserveMerges, cherryPick: cherryPick, force: force) }
        if let owner, let child = controller.window { owner.beginSheet(child) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
    }
    private func configureFetchInteractions(_ controller: FetchWindowController, repository: GitRepository, access: RepositoryAccessLease?, followUp: PullFollowUp = PullFollowUp()) {
        let root = repository.root
        controller.model.onShowStatus = { [weak self] in
            guard let self else { return }
            if self.root == root { self.activate(.status) }
            else if let access { self.openSession(access, action: .status) }
        }
        controller.model.onFetched = { [weak self, weak controller] output in
            guard controller?.model.progress == nil, controller?.model.fetchProgress == nil else { return }
            self?.refreshRepositoryLogs(root)
            self?.statusWindows[root.path]?.model.requestReload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.followUp = followUp
        controller.model.onChanged = { [weak self] output in
            self?.refreshRepositoryLogs(root); self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.referenceLogWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPullPostAction = { [weak self] action, result in
            switch action {
            case .resolve: self?.showResolve(repository: repository, access: access, paths: [], quick: nil)
            case .commit: self?.showCommitDialog(repository: repository, access: access, paths: [])
            case .pull: self?.showFetch(repository: repository, access: access, isPull: true)
            case .stash:
                var request = StashSaveFollowUp(); request.showPull = true
                self?.showStash(repository: repository, access: access, followUp: request)
            case .reset: self?.showReset(repository: repository, access: access, revision: result.resetRevision.isEmpty ? "HEAD" : result.resetRevision, mode: .hard)
            case .stashPop: self?.showStashRestore(repository: repository, access: access, pop: true)
            case .diff: self?.showRevisionComparison(repository: repository, access: access, from: .revision(result.oldHead), to: .revision(result.newHead))
            case .log: self?.showLog(repository: repository, access: access, paths: [], revisionRange: HistoryRevisionRange(from: result.oldHead, to: result.newHead))
            case .push: self?.showPush(repository: repository, access: access)
            case .submoduleUpdate: self?.showSubmoduleUpdate(repository: repository, access: access, scope: [])
            case .mergeUnrelated: break
            }
        }
        controller.model.onFetchPostAction = { [weak self] action, revision in
            switch action {
            case .log: self?.showLog(repository: repository, access: access, paths: [])
            case .reset: self?.showReset(repository: repository, access: access, revision: revision.isEmpty ? "HEAD" : revision, mode: .hard)
            case .fetch: self?.showFetch(repository: repository, access: access)
            case .rebase: self?.showRebase(repository: repository, access: access, afterFetch: true)
            case .switchBranch: self?.showSwitch(repository: repository, access: access)
            case .resolve: self?.showCommitDialog(repository: repository, access: access, paths: [])
            case .retry: break
            }
        }
        controller.model.onRebase = { [weak self] upstream, autoStart, preserveMerges in
            self?.showRebase(repository: repository, access: access, upstream: upstream, autoStart: autoStart, preserveMerges: preserveMerges, afterFetch: true)
        }
    }
    var transportClipboardText: () -> String? = { NSPasteboard.general.string(forType: .string) ?? NSPasteboard.general.string(forType: .fileURL) }
    private func showFetch(repository: GitRepository, access: RepositoryAccessLease?, isPull: Bool = false, followUp: PullFollowUp = PullFollowUp(), remote: String? = nil, allRemotes: Bool? = nil) {
        let key = repository.root.path + (isPull ? ":pull:" : ":fetch:") + UUID().uuidString
        let controller = FetchWindowController(repository: repository, access: access, isPull: isPull, preferences:fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.fetchWindows.removeValue(forKey: key) }
        configureFetchInteractions(controller, repository: repository, access: access, followUp: followUp)
        controller.model.clipboardText = transportClipboardText
        fetchWindows[key] = controller; controller.model.load(remote: remote, allRemotes: allRemotes)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showPush(repository: GitRepository, access: RepositoryAccessLease?, source: String? = nil, preserveAllBranches: Bool = false) {
        let root = repository.root, key = repository.root.path + ":push:" + UUID().uuidString
        let controller = PushWindowController(repository: repository, access: access, preferences:fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.pushWindows.removeValue(forKey: key) }
        configurePushInteractions(controller, repository: repository, access: access)
        controller.model.clipboardText = transportClipboardText
        pushWindows[key] = controller; controller.model.load(source: source, preserveAllBranches: preserveAllBranches)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func configurePushInteractions(_ controller: PushWindowController, repository: GitRepository, access: RepositoryAccessLease?) {
        controller.configureReferencePicker = { [weak self] picker in self?.configureReferenceBrowser(picker, repository: repository, access: access) }
        controller.configureLogPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        let root = repository.root
        controller.model.onTransportResult = { [weak self] output, _ in
            self?.refreshRepositoryLogs(root); self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.referenceLogWindows[root.path]?.model.reload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPostAction = { [weak self] action, options, superproject in
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
    private func configureReferenceInteractions(_ controller: BranchTagWindowController, repository: GitRepository, access: RepositoryAccessLease?) {
        let root = repository.root
        controller.model.onCreated = { [weak self] output in
            self?.refreshRepositoryLogs(root)
            self?.statusWindows[root.path]?.model.requestReload()
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onSwitch = { [weak self, weak controller] reference, done in
            guard let self, let parent = controller?.window, parent.attachedSheet == nil else { done(); return }
            let progress = self.showSwitchProgress(repository: repository, access: access, reference: reference, parent: parent, preferences: controller?.model.presentationPreferences ?? .standard, completion: done)
            controller?.model.cancelSwitchPresentation = { [weak progress] in progress?.close() }
        }
        controller.model.onPushTag = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        controller.configureCommitPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
    }
    private func showReference(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool, revision: String? = nil, name: String? = nil) {
        let key = repository.root.path + (isTag ? ":tag:" : ":branch:") + UUID().uuidString
        let controller = referenceWindows[key] ?? BranchTagWindowController(repository: repository, access: access, isTag: isTag, preferences:fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.referenceWindows.removeValue(forKey: key) }
        configureReferenceInteractions(controller, repository: repository, access: access)
        referenceWindows[key] = controller; controller.model.load(revision: revision, name: name)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    @discardableResult private func showSwitchProgress(repository: GitRepository, access: RepositoryAccessLease?, reference: String, parent: NSWindow, preferences: UserDefaults = .standard, completion: (() -> Void)? = nil) -> SwitchProgressWindowController {
        let id = UUID(), root = repository.root
        let controller = SwitchProgressWindowController(model: SwitchProgressWindowModel(repository: repository, access: access, reference: reference, preferences: preferences))
        controller.onClosed = { [weak self] in self?.switchProgressWindows.removeValue(forKey: id) }
        controller.model.onFinished = { [weak self] output, _ in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.commitWindows[root.path]?.model.reload(); self?.statusWindows[root.path]?.model.requestReload()
            self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPostAction = { [weak self] action, branch in self?.performSwitchPostAction(action, previousBranch: branch, repository: repository, access: access) }
        switchProgressWindows[id] = controller
        if let window = controller.window { parent.beginSheet(window) { _ in completion?() } }
        controller.model.start(); return controller
    }
    private func performSwitchPostAction(_ action: SwitchPostAction, previousBranch: String, repository: GitRepository, access: RepositoryAccessLease?) {
        switch action {
        case .submoduleUpdate: showSubmoduleUpdate(repository: repository, access: access, scope: [])
        case .mergePreviousBranch: showMerge(repository: repository, access: access, revision: "refs/heads/" + previousBranch)
        case .pull: showFetch(repository: repository, access: access, isPull: true)
        case .commit, .resolve: showCommitDialog(repository: repository, access: access, paths: [])
        case .stash:
            var followUp = StashSaveFollowUp(); followUp.showPull = true
            showStash(repository: repository, access: access, followUp: followUp)
        case .retry, .switchWithMerge: break
        }
    }
    private func showReferenceBrowser(repository: GitRepository, access: RepositoryAccessLease?) {
        let key = repository.root.path
        if let existing = referenceBrowserWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = ReferenceBrowserWindowController(repository: repository, access: access, initial: "HEAD", preferences:fileComparisonPreferences, picking: false) { _ in }
        controller.model.onReferencesChanged = { [weak self] in self?.refreshRepositoryLogs(repository.root); if self?.root == repository.root { Task { await self?.refresh() } } }
        configureReferenceBrowser(controller.model, repository: repository, access: access)
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller, self.referenceBrowserWindows[key] === controller else { return }
            self.referenceBrowserWindows.removeValue(forKey: key)
        }
        referenceBrowserWindows[key] = controller
        controller.model.load(); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func configureReferenceBrowser(_ model: ReferenceBrowserWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        model.configureComparison = { [weak self] comparison in self?.configureRevisionComparisonInteractions(comparison, repository: repository, access: access) }
        model.onLogRange = { [weak self] range in self?.showLog(repository: repository, access: access, paths: [], revisionRange: range) }
        model.onLog = { [weak self] name in self?.showLog(repository: repository, access: access, paths: [], endRevision: name) }
        model.onBrowse = { [weak self] name in self?.showRepositoryBrowser(repository: repository, access: access, revision: name) }
        model.onCompare = { [weak self] name in self?.showRevisionComparison(repository: repository, access: access, from: .revision(name), to: .workingTree) }
        model.configureFetch = { [weak self] controller in self?.configureFetchInteractions(controller, repository: repository, access: access) }
        model.configureBranch = { [weak self] controller in self?.configureReferenceInteractions(controller, repository: repository, access: access) }
        model.configureMerge = { [weak self] controller in self?.configureMergeInteractions(controller, repository: repository, access: access) }
        model.configureSwitch = { [weak self] controller in self?.configureSwitchInteractions(controller, repository: repository, access: access) }
    }
    private func configureSwitchInteractions(_ controller: SwitchWindowController, repository: GitRepository, access: RepositoryAccessLease?) {
        let root = repository.root
        controller.model.onSwitched = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload()
            self?.commitWindows[root.path]?.model.reload()
            self?.statusWindows[root.path]?.model.requestReload()
            self?.refreshRepositoryLogs(root)
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onChanged = { [weak self] output in
            self?.referenceLogWindows[root.path]?.model.reload(); self?.commitWindows[root.path]?.model.reload(); self?.statusWindows[root.path]?.model.requestReload(); self?.refreshRepositoryLogs(root)
            if self?.root == root { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onPostAction = { [weak self] action, branch in self?.performSwitchPostAction(action, previousBranch: branch, repository: repository, access: access) }
        controller.configureCommitPicker = { [weak self] log in self?.configureSelectableLog(log, repository: repository, access: access) }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
    }
    private func showSwitch(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil) {
        let root = repository.root
        let key = root.path + ":switch:" + UUID().uuidString
        let controller = switchWindows[key] ?? SwitchWindowController(repository: repository, access: access, revision: revision, preferences:fileComparisonPreferences)
        controller.onClosed = { [weak self] in self?.switchWindows.removeValue(forKey: key) }
        configureSwitchInteractions(controller, repository: repository, access: access)
        switchWindows[key] = controller; controller.model.load(revision: revision)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func execute(_ action: RepositoryAction, value: String) {
        dialog = nil
        if action == .clone { showClone(source: value); return }
        if action == .initialize { showCreateRepository(); return }
        guard let args = action.arguments(value: value) else { return }
        guard !bare || !action.requiresWorkingTree else { error = "This operation requires a working tree."; return }
        perform { try await $0.run(args).text }
    }
    private func publishComparisonMark() throws {
        workingComparisonMark = try comparisonMarkStore.snapshot()
        if workingComparisonMark != nil {
            let access = try? comparisonMarkStore.acquire(requireSecurityScope: GitRuntime.isAppStoreBuild)
            if let access { workingComparisonMark = access.mark }
            for controller in logWindows.values { controller.model.importWorkingComparisonMark(access) }
            for controller in rebaseWindows.values {controller.model.importConflictComparisonMark(access)}
            for controller in revertWindows.values {controller.model.importWorkingComparisonMark(access)}
        }
        if try WorkingComparisonMarkSnapshot.publish(workingComparisonMark) {
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification), object: nil)
        }
    }
    private func clearComparisonMark() {
        guard !busy, !confirmingQuit else { return }
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
        guard !busy, !confirmingQuit else { return }
        let alternateTool = ComparisonToolInvocation.capture
        do {
            guard let permission = try permission ?? comparisonPermission(for: file) else { return }
            if try comparisonMarkStore.snapshot() == nil {
                _ = try comparisonMarkStore.remember(file: file, permission: permission, requireSecurityScope: GitRuntime.isAppStoreBuild)
                try publishComparisonMark(); output = "Marked for comparison: " + file.path
            } else {
                let marked = try comparisonMarkStore.acquire(requireSecurityScope: GitRuntime.isAppStoreBuild)
                let comparison = try WorkingFileComparison(base: marked.file, destination: file)
                guard !GitRuntime.isAppStoreBuild || permission.hasSecurityScope && permission.contains(file) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                _ = try comparison.read()
                let key = "working-mark:" + UUID().uuidString
                let controller = FileComparisonWindowController(comparison: comparison, permissions: [marked.permission, permission],preferences:fileComparisonPreferences)
                controller.model.captureToolChoice(alternateTool)
                controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.fileComparisonWindows[key] === controller else { return }; self.fileComparisonWindows.removeValue(forKey: key) }
                fileComparisonWindows[key] = controller
                controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
                _ = try comparisonMarkStore.consume(marked.mark.id)
                try publishComparisonMark()
            }
        } catch { self.error = error.localizedDescription }
    }
    private func handleFilePair(paths: [URL], line: Int? = nil) {
        let alternateTool = ComparisonToolInvocation.capture
        do {
            guard let prepared = try WorkingFilePairAccess.prepare(paths: paths, requireSecurityScope: GitRuntime.isAppStoreBuild,
                acquire: { try comparisonPermission(for: $0) }) else { return }
            let key = "working-pair:" + UUID().uuidString
            let controller = FileComparisonWindowController(comparison: prepared.comparison, permissions: prepared.permissions,preferences:fileComparisonPreferences, line: line)
            controller.model.captureToolChoice(alternateTool)
            controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.fileComparisonWindows[key] === controller else { return }; self.fileComparisonWindows.removeValue(forKey: key) }
            fileComparisonWindows[key] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } catch { self.error = error.localizedDescription }
    }
    func handle(_ url: URL) {
        if url.isFileURL { openPatchDocument(url); return }
        guard !confirmingQuit, let request = FinderRequest(url: url) else { return }
        let choice=request.alternateTool ?? ComparisonToolInvocation.capture
        ComparisonToolInvocation.$alternate.withValue(choice) {handleFinderRequest(request)}
    }
    func openPatchDocument(_ url: URL) {
        guard !confirmingQuit else { return }
        guard url.isFileURL, ["patch", "diff"].contains(url.pathExtension.lowercased()) else {
            error = "Choose a .patch or .diff document to open in Unified Diff."; return
        }
        let file = url.standardizedFileURL, key = Data(file.path.utf8)
        if let entry = patchDocumentWindows.first(where: { id, controller in
            if let current = controller.documentSession.fileURL { return Data(current.standardizedFileURL.path.utf8) == key }
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
        do {
            let id = UUID()
            let context = GitRepository(root: file.deletingLastPathComponent(), executable: try GitRuntime.executable())
            let controller = PatchWindowController(repository: context, access: nil, preferences: reviewPatchPreferences)
            controller.presentDocument(Data(), title: file.lastPathComponent + " – Unified Diff – TurtleGit", comparison: file.lastPathComponent,
                information: "Opening patch document…")
            configurePatchDocument(controller)
            controller.onClosed = { [weak self, weak controller] in
                guard let self, let controller, self.patchDocumentWindows[id] === controller else { return }
                self.patchDocumentWindows.removeValue(forKey: id); self.patchDocumentOpeningPaths.removeValue(forKey: id)
            }
            patchDocumentWindows[id] = controller; patchDocumentOpeningPaths[id] = key
            if let patchDocumentPresentation { patchDocumentPresentation(controller) }
            else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
            controller.documentSession.openFile(file)
        } catch { self.error = error.localizedDescription }
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
        commandOutputOwners.removeValue(forKey: id); commandLineOutputOperations.removeValue(forKey: id); commandGraphWindows.removeValue(forKey: id)
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
        Task {
            defer { finishCommandOutput(id); withExtendedLifetime((access, permission)) {} }
            do {
                let bytes = try await repository.commandHistoricalFile(revision: revision, path: path, cancellation: owner.cancellation)
                try await publishCommandOutput(bytes, file: file, permission: permission, owner: owner)
                if root?.path == repository.root.path { output = "Saved historical file: " + file.path }
            } catch { if !retired, !owner.cancellation.isCancelled { self.error = "Could not save " + file.path + ": " + error.localizedDescription } }
        }
    }
    private func writeCommandGraph(repository: GitRepository, access: RepositoryAccessLease, file: URL, permission: RepositoryAccessLease, format: RevisionGraphFormat) {
        let (id, owner) = beginCommandOutput()
        let controller = revisionGraphWindowFactory?(repository, access, fileComparisonPreferences, false) ?? RevisionGraphWindowController(repository: repository, access: access, preferences: fileComparisonPreferences, automaticallyLoad: false)
        commandGraphWindows[id] = controller
        owner.onCancelled = { [weak controller] in controller?.model.cancel() }
        controller.onClosed = { owner.cancellation.cancel() }
        controller.model.load()
        Task {
            defer { controller.close(); finishCommandOutput(id); withExtendedLifetime((access, permission)) {} }
            await controller.model.waitForCompletion()
            do {
                try owner.cancellation.check()
                guard !controller.model.closed else { throw OperationCancellationFailure.cancelled }
                if let failure = controller.model.error { throw PrimaryCommandInvocation.Failure(failure) }
                let bytes = try controller.graphExportData(format: format)
                try await publishCommandOutput(bytes, file: file, permission: permission, owner: owner)
                if root?.path == repository.root.path { output = "Saved revision graph: " + file.path }
            } catch { if !retired, !owner.cancellation.isCancelled { self.error = "Could not save " + file.path + ": " + error.localizedDescription } }
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
        do {
            guard let invocation = try PrimaryCommandInvocation.parse(arguments: arguments, currentDirectory: currentDirectory) else { return }
            guard !busy, commandRepositoryBatchCancellation == nil else { error = "Wait for the current repository operation before opening a command."; return }
            if invocation.pathFile != nil { try prepareCommandPathList(invocation) }
            else { try launchCommandLine(invocation) }
        } catch { self.error = error.localizedDescription }
    }
    private func launchCommandLine(_ invocation: PrimaryCommandInvocation, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard !confirmingQuit else { return }
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
        if invocation.request.action == .importPatch {
            prepareCommandPatchImport(invocation, cancellation: cancellation); return
        }
        if invocation.request.action == .initialize {
            showCreateRepository(folder: invocation.request.paths.first, commandLaunch: true, cancellation: cancellation); return
        }
        if invocation.request.action == .clone {
            showClone(directory: invocation.request.paths.first, source: invocation.sourceURL, exactPath: invocation.exactClonePath); return
        }
        if [.fetch, .pull, .push].contains(invocation.request.action), invocation.request.paths.count > 1 {
            launchCommandRepositoryBatch(invocation, cancellation: cancellation); return
        }
        ComparisonToolInvocation.$alternate.withValue(invocation.request.alternateTool ?? false) {
            handleFinderRequest(invocation.request, invocation: invocation, messageAccess: permission, outputAccess: outputAccess, commandCancellation: cancellation)
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
                self.commandImportFolderChoice = nil
                guard self.commandImportIsLive(owner, cancellation: nil), let selected else { continuation.resume(returning: nil); return }
                continuation.resume(returning: RepositoryAccessLease(url: selected, provider: self.repositoryBookmarkProvider))
            }
            choice.begin(present: presentCommandImportFolderPanel, selected: selectedCommandImportFolderURL)
        }
    }
    private func prepareCommandPatchImport(_ invocation: PrimaryCommandInvocation, cancellation: OperationCancellation?) {
        guard commandImportOwner == nil, !retired, !confirmingQuit else { return }
        let owner = RepositoryWindowOwner(window: workspaceWindow), window = workspaceWindow
        commandImportOwner = owner; busy = true
        Task {
            var transferred = false
            defer { if !transferred, commandImportOwner === owner { commandImportOwner = nil; busy = false } }
            do {
                var grants: [RepositoryAccessLease] = [], files: [URL] = []
                for file in invocation.request.paths {
                    guard commandImportIsLive(owner, cancellation: cancellation) else { return }
                    let lease: RepositoryAccessLease?
                    if let retained = grants.first(where: { $0.contains(file) }) { lease = retained }
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
                var target = invocation.importTarget
                if target == nil, let first = invocation.request.paths.first {
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
                if let target, let activeAccess, activeAccess.contains(target), !requiresRepositoryScope || activeAccess.hasSecurityScope { repositoryGrant = activeAccess }
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
                }, handoffOwner: owner, onOpened: { [weak self] in
                    guard let self, !self.retired, !owner.cancellation.isCancelled, !self.confirmingQuit, cancellation?.isCancelled != true, let repository = self.repository, let access = self.activeAccess else { return }
                    if self.bare { self.activate(.importPatch); return }
                    self.showImportPatchFiles(repository: repository, access: access, files: files, grants: grants, commandLaunch: true)
                })
            } catch { if commandImportIsLive(owner, cancellation: cancellation) { self.error = error.localizedDescription } }
        }
    }
    private func activateCommandLine(_ invocation: PrimaryCommandInvocation, message: String?, selectedRevision: String?, repository: GitRepository, access: RepositoryAccessLease, outputAccess: RepositoryAccessLease?) {
        let paths = invocation.request.relativePaths(root: repository.root)
        if bare && invocation.request.action.requiresWorkingTree { activate(invocation.request.action, paths: paths); return }
        switch invocation.request.action {
        case .cat:
            guard let file = invocation.outputFile, let permission = outputAccess, let revision = invocation.catRevision, let path = paths.first else { return }
            writeCommandHistoricalFile(repository: repository, access: access, revision: revision, path: path, file: file, permission: permission)
        case .showCompare:
            let from = invocation.diffFrom.map(ComparisonRevision.revision) ?? .workingTree
            let to = invocation.diffTo.map(ComparisonRevision.revision) ?? .workingTree
            let scope = paths.filter { $0 != "." }
            if invocation.unified {
                prepareFileComparisons(repository: repository, access: access, selectedCount: paths.count, owner: workspaceWindow) { [self] token in
                    let snapshot = try await repository.revisionFileComparison(from: from, to: to, paths: scope, cancellation: token)
                    let bytes = try await repository.revisionComparisonPatchData(snapshot, cancellation: token)
                    try await presentCommandUnifiedDiff(bytes, title: from.label + " → " + to.label, repository: repository, access: access, alternate: invocation.request.alternateTool ?? false, preferences: fileComparisonPreferences, cancellation: token)
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
            } else if let from = invocation.diffFrom, let to = invocation.diffTo {
                showHistoricalFiles(repository: repository, access: access, from: .revision(from), to: .revision(to), paths: paths.contains(".") ? [] : paths, owner: workspaceWindow, line: invocation.line)
            } else { showWorkingFiles(repository: repository, access: access, paths: paths, owner: workspaceWindow, line: invocation.line) }
        default: activate(invocation.request.action, paths: paths)
        }
    }
    private var commandRepositoryBatchCancellation: OperationCancellation?
    private func launchCommandRepositoryBatch(_ invocation: PrimaryCommandInvocation, cancellation: OperationCancellation?) {
        let token = cancellation ?? OperationCancellation()
        commandRepositoryBatchCancellation = token
        let owner = workspaceWindow
        let observer = owner.map { NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: $0, queue: .main) { _ in token.cancel() } }
        Self.activeCommandFileOperations += 1
        let batchGeneration = adoptionGeneration
        Task {
            var expectedGeneration = batchGeneration
            defer {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                if commandRepositoryBatchCancellation === token { commandRepositoryBatchCancellation = nil }
                Self.activeCommandFileOperations -= 1
            }
            for path in invocation.request.paths {
                guard !token.isCancelled, !confirmingQuit, adoptionGeneration == expectedGeneration else { return }
                let next = invocation.selecting([path])
                let nextGeneration = expectedGeneration + 1
                let opened = await withCheckedContinuation { continuation in
                    handleFinderRequest(next.request, invocation: next, commandCancellation: token, commandRootOnly: true, completion: { continuation.resume(returning: $0) })
                }
                guard opened, adoptionGeneration == nextGeneration else { return }
                expectedGeneration = nextGeneration
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
    private func handleFinderRequest(_ request:FinderRequest, invocation: PrimaryCommandInvocation? = nil, messageAccess: RepositoryAccessLease? = nil, outputAccess: RepositoryAccessLease? = nil, commandCancellation: OperationCancellation? = nil, commandRootOnly: Bool = false, completion: ((Bool) -> Void)? = nil) {
        var handedOff = false
        defer { if !handedOff { completion?(false) } }
        guard commandCancellation?.isCancelled != true else { return }
        let action = request.action
        if action == .settings {
            let knownRoot = request.paths.first.flatMap { selected in
                FinderSnapshot.read()?.roots.sorted { $0.count > $1.count }.first { selected.path == $0 || selected.path.hasPrefix($0 + "/") }
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
        if action == .sendMail { showFinderSendMail(files: request.paths); return }
        if action == .clearComparisonMark { clearComparisonMark(); return }
        if action == .diffLater {
            guard request.paths.count == 1 else { error = "Select one file to mark or compare."; return }
            handleComparisonMark(file: request.paths[0]); return
        }
        if action == .clone { showClone(directory: request.paths.first); return }
        if action == .initialize { showCreateRepository(folder: request.paths.first); return }
        if action == .diff && request.paths.count == 2 { handleFilePair(paths: request.paths, line: invocation?.line); return }
        let candidate = request.paths[0]
        var permissionTargets = request.paths
        if let discovery = invocation?.submoduleDiscoveryURL { permissionTargets.append(discovery) }
        if action == .rename || action == .remove || action == .submoduleSync || action == .logSubmodule || action == .properties,
           let parent = FinderSnapshot.read()?.repositories[candidate.standardizedFileURL.path]?.submoduleParentRoot {
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
    init(owner: NSWindow?, preferences: UserDefaults) { self.owner = owner; session = FileListComparisonSession(window: owner, preferences: preferences); super.init() }
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
        panel.title = "Conflict – TurtleGit"; panel.contentView = view; panel.isReleasedWhenClosed = false; panel.delegate = self; self.panel = panel
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
        guard !cancellation.isCancelled,owner?.attachedSheet==nil else { return nil }
        token=cancellation
        let picker=NSOpenPanel();panel=picker
        picker.title="Allow repository folder access";picker.prompt="Allow Access"
        picker.message=requirement.explanation+"\n\nSelect this folder, or a parent folder: "+requirement.folder.path
        picker.canChooseDirectories=true;picker.canChooseFiles=false;picker.allowsMultipleSelection=false
        picker.directoryURL=requirement.folder;picker.appearance=owner?.appearance
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
            else { picker.begin(completionHandler:completed) }
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
