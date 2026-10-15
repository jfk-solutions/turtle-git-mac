import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

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
                controller.model.singleFileMode = single
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
    weak var workspaceWindow: NSWindow?
    var onSettings: (Bool) -> Void = { _ in }
    var canChangeSettingsContext: () -> Bool = { true }
    var onHelp: () -> Void = {}
    var onAbout: () -> Void = {}
    @Published var root: URL?
    @Published var branch = ""
    @Published var hasGitSVN = false
    @Published var bare = false
    @Published var conflictRebase = false
    @Published var mergeActive = false
    @Published var submodules = Set<String>()
    @Published var entries: [StatusEntry] = []
    @Published var selection = Set<String>()
    @Published var output = "Open a repository to get started."
    @Published var busy = false { didSet { repositoryAccessWindow?.model.objectWillChange.send();if !busy { eventRefresh?.kick() } } }
    @Published var confirmingQuit = false { didSet { repositoryAccessWindow?.model.objectWillChange.send();if !confirmingQuit { eventRefresh?.kick() } } }
    @Published var error: String?
    @Published var section = RepositoryAction.status
    @Published var dialog: RepositoryAction?
    @Published var message = ""
    @Published var stagedDiff = false
    @Published var showIgnored = false
    @Published var finderStatus = "Finder cache not configured"
    @Published var workingComparisonMark: WorkingComparisonMarkSnapshot?
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
    private var combineWindows: [UUID: HistoryCombineWindowController] = [:]
    private var historyRevertWindows: [UUID: HistoryRevertWindowController] = [:]
    private var logWindows: [String: LogWindowController] = [:]
    var logWindowFactory:((GitRepository,RepositoryAccessLease?)->LogWindowController)?
    private var revisionGraphWindows: [String: RevisionGraphWindowController] = [:]
    private var referenceBrowserWindows: [String: ReferenceBrowserWindowController] = [:]
    private var browserWindows: [String: RepositoryBrowserWindowController] = [:]
    private var worktreeListWindows: [String: WorktreeListWindowController] = [:]
    private var worktreeCreateWindows: [String: WorktreeCreateWindowController] = [:]
    private var requestPullWindows: [String: RequestPullWindowController] = [:]
    private var importPatchWindows: [String: ImportPatchWindowController] = [:]
    private var formatPatchWindows: [String: FormatPatchWindowController] = [:]
    private var blameWindows: [String: BlameWindowController] = [:]
    private var blameRecentDocuments:BlameRecentDocuments?
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
    var reviewPatchPreferences: UserDefaults = .standard
    var reviewPatchPreparation: ((ReviewPatchWorkflow) -> Void)?
    var reviewPatchPresentation: ((WorkingTreePatchWindowController) -> Void)?
    private var finderMailWorkflows: [UUID: SendMailWorkflow] = [:]
    var finderMailPresentation: ((NSWindowController) -> Void)?
    private var addProgressWindows: [UUID: AddProgressWindowController] = [:]
    private var cleanWindows: [String: CleanWindowController] = [:]
    private var cleanProgressWindows: [UUID: CleanProgressWindowController] = [:]
    private var revertWindows: [String: RevertWindowController] = [:]
    private var statusWindows: [String: StatusWindowController] = [:]
    private var bisectWindows: [String: BisectWindowController] = [:]
    private var exportWindows: [String: ExportWindowController] = [:]
    private var mergeAbortWindows: [UUID: MergeAbortWindowController] = [:]
    private var mergeWindows: [String: MergeWindowController] = [:]
    private var referenceLogWindows: [String: ReferenceLogWindowController] = [:]
    private var stashRestoreWindows: [String: StashRestoreWindowController] = [:]
    private var stashWindows: [String: StashWindowController] = [:]
    private var cloneWindows: [UUID: CloneWindowController] = [:]
    private var createWindows: [String: CreateRepositoryWindowController] = [:]
    var finderTransferPresentation: ((FinderRequest, GitRepository, RepositoryAccessLease) -> Void)?
    private var copyWindows: [UUID: FileCopyWindowController] = [:]
    private var moveWindows: [String: FileMoveWindowController] = [:]
    private var renameWindows: [String: RenameWindowController] = [:]
    private var imageConflictWindows: [String: ImageConflictWindowController] = [:]
    private var textConflictWindows: [String: TextConflictWindowController] = [:]
    private var submoduleDiffWindows: [String: SubmoduleDiffWindowController] = [:]
    private var revisionComparisonWindows: [String: RevisionComparisonWindowController] = [:]
    private var imageLoader: ImageLoadWindowController?
    private var fileComparisonWindows: [String: FileComparisonWindowController] = [:]
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
    private var removeWindows: [String: RemoveWindowController] = [:]
    private var adoptionGeneration = 0
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
    func stopMonitoringForTermination() { repositoryAccessWindow?.model.retire();repositoryAccessWindow?.close();adoptionCancellation?.cancel();repositoryPermissionPrompt?.cancel();cancelConflictEditorPreparations(); stopFileMonitoring() }
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
    private var cacheStates: [String: FileState] = [:]
    private var cacheOverlayEntries: [String: FileState]?
    private var cacheIndexFlags: [String: FinderIndexFlags]?
    private var cacheRepositories: [String: FinderRepositoryMetadata] = [:]
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
        monitoringEnabled=startMonitoring
        guard startMonitoring && initializePreferences else { return }
        do { if self.finderWatches==nil { self.finderWatches=try FinderWatchManager.production() };self.finderWatches?.restore() }
        catch { finderStatus="Watched repositories unavailable: "+error.localizedDescription }
        do { _ = try FinderMenuSettings.from().write() }
        catch { finderStatus = "Finder menu preferences unavailable: " + error.localizedDescription }
        do { _ = try FinderOverlaySettings.from().write() }
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
            let folders=([primary]+scopes).filter(\.hasSecurityScope).map(\.url)
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
    private func openSession(_ lease: RepositoryAccessLease, selected: FinderRequest? = nil, action: RepositoryAction? = nil, actionPaths: [String]? = nil, onOpened: (() -> Void)? = nil) {
        guard !busy, !confirmingQuit else { return }
        let restoreState:()->Void = { [repository,activeAccess,root,entries,selection,branch,bare,hasGitSVN,mergeActive,conflictRebase,submodules,section,output] in
            self.repository=repository;self.activeAccess=activeAccess;self.root=root;self.entries=entries;self.selection=selection
            self.branch=branch;self.bare=bare;self.hasGitSVN=hasGitSVN;self.mergeActive=mergeActive;self.conflictRebase=conflictRebase;self.submodules=submodules;self.section=section;self.output=output
        }
        stopFileMonitoring()
        adoptionGeneration += 1
        let adoption = adoptionGeneration
        busy = true
        let cancellation=OperationCancellation();adoptionCancellation=cancellation
        let owner=workspaceWindow
        let ownerObserver=owner.map { NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:$0,queue:.main) { _ in cancellation.cancel() } }
        Task {
            defer { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) };if adoptionCancellation === cancellation { adoptionCancellation=nil };withExtendedLifetime(lease) {} }
            do {
                let first = selected?.paths.first ?? lease.url
                var location = first
                var directory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) || !directory.boolValue {
                    location.deleteLastPathComponent()
                }
                let prepared=try await prepareRepositoryMetadataAccess(at:location,primary:lease,cancellation:cancellation)
                try cancellation.check();guard adoption==adoptionGeneration else { return }
                let sessionAccess=lease.retainingRelatedScopes(prepared.scopes)
                let candidate = try makeRepository(location)
                let resolved = try await candidate.discoverSelectionRoot(for: action ?? .status, selected: first,cancellation:cancellation)
                if requiresRepositoryScope && (!lease.hasSecurityScope || !lease.contains(resolved)) {
                    throw RepositoryAccessFailure.repositoryRootOutsidePermission(resolved.path)
                }
                if let selected {
                    for item in selected.paths {
                        guard lease.contains(item), item.path == resolved.path || item.path.hasPrefix(resolved.path + "/") else {
                            throw FinderSelectionFailure.multipleRepositories
                        }
                        var location = item
                        var directory: ObjCBool = false
                        if !FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) || !directory.boolValue { location.deleteLastPathComponent() }
                        let itemRoot = try await makeRepository(location).discoverSelectionRoot(for: action ?? .status, selected: item,cancellation:cancellation)
                        guard itemRoot.standardizedFileURL == resolved.standardizedFileURL else { throw FinderSelectionFailure.multipleRepositories }
                    }
                }
                try cancellation.check();guard adoption == adoptionGeneration else { return }
                repository = try makeRepository(resolved); activeAccess = sessionAccess; root = resolved
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
                busy = false
                if let action {
                    let paths = actionPaths ?? selected?.relativePaths(root: resolved) ?? []
                    if action.isFileTransfer, let request = selected, let repository, let destination = request.paths.first {
                        if let finderTransferPresentation { finderTransferPresentation(request, repository, sessionAccess) }
                        else if action == .pasteCopy { showCopy(repository: repository, access: sessionAccess, sources: request.sources, paste: true, folder: destination) }
                        else { showMove(repository: repository, access: sessionAccess, paths: [], clipboard: request.sources, destination: destination) }
                    } else { activate(action, paths: paths) }
                }
                onOpened?()
            } catch {
                guard adoption == adoptionGeneration else { return }
                restoreState()
                if !cancellation.isCancelled { self.error=error.localizedDescription }
                if monitoringEnabled,let repository,let directories=try? await repository.finderWatchDirectories() { monitorFiles(directories) }
                busy=false
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
        selection.formIntersection(Set(entries.map(\.id)))
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
        guard let repository, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { output = try await operation(repository); try await reload() }
            catch { self.error = error.localizedDescription; try? await reload() }
            if let root { statusWindows[root.path]?.model.requestReload() }
        }
    }
    func stage() { let paths = selectedPaths; perform { try await $0.stage(paths); return "Staged \(paths.count) file(s)." } }
    func unstage() { let paths = selectedPaths; perform { try await $0.unstage(paths); return "Unstaged \(paths.count) file(s)." } }
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
    func showCommit(_ hash: String) { perform { try await $0.run(["show", "--no-ext-diff", "--no-color", hash, "--"]).text } }
    func commit() {
        let text = message
        perform { repo in let result = try await repo.commit(message: text); await MainActor.run { self.message = "" }; return result }
    }
    func activate(_ action: RepositoryAction, paths: [String] = []) {
        guard !confirmingQuit else { return }
        guard !bare || !action.requiresWorkingTree else { error = "\(action.title) requires a working tree. This repository is bare."; return }
        switch action {
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
            if selected.count == 1, let root { handleComparisonMark(file: root.appendingPathComponent(selected[0])) }
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
    private func showClone(directory: URL? = nil, source: String? = nil) {
        let id = UUID(), controller = CloneWindowController(directory: directory ?? root, access: activeAccess)
        controller.onClosed = { [weak self] in self?.cloneWindows.removeValue(forKey: id) }
        controller.model.onLog = { [weak self] repository, access in self?.showLog(repository: repository, access: access, paths: []) }
        controller.model.onCloned = { [weak self] repo, access, keyAccess, bare, result in
            guard let self else { return }
            if let keyAccess {
                self.cloneKeyAccess[repo.root.path] = keyAccess
                do { UserDefaults.standard.set(try SystemRepositoryBookmarkProvider().create(for: keyAccess.url), forKey: "Clone.KeyBookmark." + repo.root.path) }
                catch { self.error = "The clone completed, but its SSH-key permission could not be saved.\n" + error.localizedDescription }
            }
            self.adoptRepository(repo, access: access, bare: bare, output: result)
        }
        cloneWindows[id] = controller
        if let source { controller.model.source = source }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func adoptRepository(_ repo: GitRepository, access: RepositoryAccessLease, bare: Bool, output: String) {
        rememberAccess(access, repositoryRoot: repo.root)
        adoptionGeneration += 1; let generation = adoptionGeneration
        Task {
            // Let an operation on the previous repository finish before switching
            // workspace state. An explicit Open/Close supersedes this handoff.
            while busy && generation == adoptionGeneration { try? await Task.sleep(nanoseconds: 50_000_000) }
            guard generation == adoptionGeneration else { return }
            repository = repo; activeAccess = access; root = repo.root; self.bare = bare
            entries = []; selection = []; branch = ""; mergeActive = false; section = bare ? .log : .status; self.output = output
            await refresh()
        }
    }
    private func showCreateRepository(folder preferred: URL? = nil) {
        let folder = preferred
        var lease: RepositoryAccessLease?
        if let folder, let activeAccess, activeAccess.contains(folder) { lease = activeAccess }
        else if let folder, !GitRuntime.isAppStoreBuild { lease = RepositoryAccessLease(url: folder) }
        if lease == nil {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.prompt = "Create repository here"; panel.directoryURL = folder ?? root?.deletingLastPathComponent()
            panel.message = "Choose the folder that will contain the new repository."
            panel.begin { [weak self] response in
                guard response == .OK, let selected = panel.url else { return }
                self?.presentCreateRepository(folder: selected, lease: RepositoryAccessLease(url: selected))
            }
            return
        }
        guard let folder, let lease else { return }
        presentCreateRepository(folder: folder, lease: lease)
    }
    private func presentCreateRepository(folder: URL, lease: RepositoryAccessLease) {
        guard lease.contains(folder), !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
        let controller = createWindows[folder.path] ?? CreateRepositoryWindowController(folder: folder, access: lease)
        let fresh = createWindows[folder.path] == nil
        controller.onClosed = { [weak self] in self?.createWindows.removeValue(forKey: folder.path) }
        controller.model.onInitialized = { [weak self] repo, access, bare, output in self?.adoptRepository(repo, access: access, bare: bare, output: output) }
        createWindows[folder.path] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        if fresh { controller.model.prepare() }
    }
    private func showRename(repository: GitRepository, access: RepositoryAccessLease?, source: String) {
        let root = repository.root, key = root.path + "/" + source
        let controller = renameWindows[key] ?? RenameWindowController(repository: repository, access: access, source: source)
        controller.onClosed = { [weak self] in self?.renameWindows.removeValue(forKey: key) }
        controller.model.onRenamed = { [weak self] old, new, output in
            guard let self else { return }
            self.statusWindows[root.path]?.model.didRename(old, to: new)
            self.commitWindows[root.path]?.model.didRename(old, to: new)
            if self.root == root {
                self.selection = Set(self.selection.map { $0 == old ? new : $0.hasPrefix(old + "/") ? new + $0.dropFirst(old.count) : $0 })
                self.output = output.isEmpty ? "Renamed \(old) to \(new)." : output
            }
        }
        controller.model.onChanged = { [weak self] in
            self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
            if self?.root == root { Task { await self?.refresh() } }
        }
        renameWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func showMove(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], clipboard: [URL]? = nil, destination: URL? = nil, renameFirst: Bool = false, stopOnError: Bool = true) {
        let root = repository.root, key = root.path + "\0" + (clipboard == nil ? paths.joined(separator: "\0") : UUID().uuidString)
        let controller = moveWindows[key] ?? FileMoveWindowController(repository: repository, access: access, paths: paths)
        controller.onClosed = { [weak self] in self?.moveWindows.removeValue(forKey: key) }
        controller.model.onMoved = { [weak self] old, new, text in
            guard let self else { return }; self.statusWindows[root.path]?.model.didRename(old, to: new); self.commitWindows[root.path]?.model.didRename(old, to: new)
            if self.root == root { self.selection = Set(self.selection.map { $0 == old ? new : $0.hasPrefix(old + "/") ? new + $0.dropFirst(old.count) : $0 }); self.output = text.isEmpty ? "Moved \(old) to \(new)." : text }
        }
        controller.model.onChanged = { [weak self] in
            self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
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
    var openExternalConflict: (GitRepository, RepositoryAccessLease?, String, Bool, NSWindow?, ConflictEntry, OperationCancellation, @escaping () -> Void) async throws -> Bool = { repository, access, path, alternate, owner, entry, token, prepared in
        try await MergeToolApplication.open(repository: repository, access: access, path: path, alternate: alternate, owner: owner, cancellation: token, onPrepared: prepared, expectedEntry: entry)
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
                    guard entry.path == path else { throw ResolveFailure.stale }; try token.check()
                if entry.isDeleteModify {
                    try await validateConflictEditorEntry(entry, repository: repository, token: token)
                    request.dismissProgress(); if let conflictEditorPresentation { conflictEditorPresentation(.deleteModify, repository, path, nil) }
                    else { showDeleteConflict(repository: repository, access: access, path: path) }; return
                }
                if !entry.isSubmodule {
                    if try await openExternalConflict(repository, access, path, alternate, owner, entry, token, { request.dismissProgress() }) {
                        try token.check(); guard !confirmingQuit else { return }
                        let root = repository.root
                        statusWindows[root.path]?.model.requestReload(); commitWindows[root.path]?.model.reload(); rebaseWindows[root.path]?.model.refreshState(); refreshRepositoryLogs(root)
                        for resolve in resolveWindows.values where resolve.model.repository.root == root { resolve.model.load() }
                        if self.root == root { await refresh() }; return
                    }
                    let root = repository.root, key = root.path + "\0" + path
                    if let document = try await repository.imageConflictDocument(path: path, cancellation: token) {
                        guard document.entry == entry else { throw ResolveFailure.stale }
                        try await validateConflictEditorEntry(entry, repository: repository, token: token)
                        request.dismissProgress()
                        if let conflictEditorPresentation { conflictEditorPresentation(.image, repository, path, document); return }
                        let controller = imageConflictWindows[key] ?? ImageConflictWindowController(repository: repository, access: access, document: document)
                        controller.onClosed = { [weak self] in self?.imageConflictWindows.removeValue(forKey: key) }
                        controller.model.onChanged = { [weak self] output in
                            self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
                            for resolve in self?.resolveWindows.values ?? Dictionary<String, ResolveWindowController>().values where resolve.model.repository.root == root { resolve.model.load() }
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
                        self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
                        for resolve in self?.resolveWindows.values ?? Dictionary<String, ResolveWindowController>().values where resolve.model.repository.root == root { resolve.model.load() }
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
                    self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
                    for resolve in self?.resolveWindows.values ?? Dictionary<String, ResolveWindowController>().values where resolve.model.repository.root == root { resolve.model.load() }
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
            self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
            for resolve in self?.resolveWindows.values ?? Dictionary<String, ResolveWindowController>().values where resolve.model.repository.root == root { resolve.model.load() }
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
    private func showResolve(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], quick: ResolveChoice?) {
        let root = repository.root, key = root.path + "\0" + String(quick?.rawValue ?? -1) + "\0" + paths.joined(separator: "\0")
        let controller = resolveWindows[key] ?? ResolveWindowController(repository: repository, access: access, paths: paths, quick: quick)
        controller.onClosed = { [weak self] in self?.resolveWindows.removeValue(forKey: key) }
        controller.onChanged = { [weak self] output in
            self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState(); self?.refreshRepositoryLogs(root)
            guard let self, self.root == root else { return }
            self.output = output; Task { await self.refresh() }
        }
        controller.model.onEdit = { [weak self, weak controller] path in self?.showConflictEditor(repository: repository, access: access, path: path, owner: controller?.window) }
        controller.model.onSubmoduleReset = { [weak self, weak controller] child, revision, done in
            self?.showReset(repository: child, access: access, revision: revision, completion: done, dismissed: { [weak controller] in controller?.model.dismissSubmoduleReset() })
        }
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
            let root = repository.root, key = root.path + "\0" + action.rawValue + "\0" + paths.joined(separator: "\0")
            let controller = try ignoreWindows[key] ?? IgnoreWindowController(repository: repository, access: access, paths: paths, mask: action.ignoresByExtension, delete: action.removesWhenIgnoring)
            controller.onClosed = { [weak self] in self?.ignoreWindows.removeValue(forKey: key) }
            controller.onChanged = { [weak self] output in
                self?.refreshRepositoryLogs(root)
                self?.statusWindows[root.path]?.model.requestReload(); self?.commitWindows[root.path]?.model.reload(); self?.rebaseWindows[root.path]?.model.refreshState()
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
            let controller = removeWindows[key] ?? RemoveWindowController(repository: repository, access: access, request: request)
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
    private func showCommitDialog(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        let root = repository.root
        let controller = commitWindows[root.path] ?? CommitWindowController(repository: repository, access: access)
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
        controller.model.reload(paths: paths)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showAdd(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        Task {
            do {
                if try await repository.addSelectionIsFiles(paths) { showAddProgress(repository: repository, access: access, paths: paths); return }
                let key = repository.root.path
                let controller = addWindows[key] ?? AddWindowController(repository: repository, access: access)
                guard !controller.model.busy else { controller.window?.makeKeyAndOrderFront(nil); return }
                controller.onClosed = { [weak self] in self?.addWindows.removeValue(forKey: key) }
                controller.model.onAccepted = { [weak self] paths in self?.showAddProgress(repository: repository, access: access, paths: paths) }
                controller.model.onPreview = { [weak self, weak controller] path in guard let controller else { return }; self?.showWorkingFiles(repository: repository, access: access, paths: [path], owner: controller.window) }
                controller.model.onCompare = { [weak self, weak controller] paths in guard let controller else { return }; self?.showWorkingFiles(repository: repository, access: access, paths: paths, owner: controller.window) }
                controller.model.onCompareTwo = { [weak self, weak controller] paths in guard let controller else { return }; self?.showWorkingFilePair(repository: repository, access: access, paths: paths, owner: controller.window) }
                controller.model.unifiedViewerBusy = { [weak self] in self?.addUnifiedWindows[key]?.model.busy == true || self?.addUnifiedWindows[key]?.window?.attachedSheet != nil }
                controller.model.onUnifiedPatch = { [weak self] bytes, alternate in
                    guard let self else { return }
                    if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate) {
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
            } catch { self.error = error.localizedDescription }
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
            if existing.model.busy || existing.model.phase == .options || existing.window?.attachedSheet != nil {
                if existing.model.operation != operation { error = "Finish " + existing.model.title + " before starting another SVN operation." }
                if let svnPresentation { svnPresentation(existing) } else { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil) }
                return
            }
            existing.window?.close()
        }
        if operation == .rebase, let existing = rebaseWindows[key] { existing.window?.makeKeyAndOrderFront(nil); error = "Close the existing Rebase dialog before starting SVN Rebase."; return }
        let controller = svnWindowFactory?(repository,access,operation) ?? SVNWindowController(repository: repository, access: access, operation: operation)
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
        let key = repository.root.path
        if let existing = lfsLocksWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let access = activeAccess
        let controller = LFSLocksWindowController(repository: repository, access: access)
        controller.onPullAfterLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.onClosed = { [weak self] in self?.lfsLocksWindows.removeValue(forKey: key) }
        lfsLocksWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        Task { await controller.model.refresh() }
    }
    private func showFinderLFSOperation(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], locked: Bool) {
        guard !busy, !confirmingQuit, workspaceWindow?.attachedSheet == nil else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let targets = try await repository.finderLFSPaths(paths)
                guard !confirmingQuit else { return }
                let id = UUID(), controller = LFSFileOperationController(repository: repository, access: access)
                controller.model.onPullAfterLock = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
                controller.onClosed = { [weak self] in
                    guard let self else { return }; self.lfsFileOperations.removeValue(forKey: id)
                    self.statusWindows[repository.root.path]?.model.requestReload(); self.commitWindows[repository.root.path]?.model.reload()
                    if self.root == repository.root { Task { await self.refresh() } }
                }
                lfsFileOperations[id] = controller
                if !controller.present(owner: workspaceWindow, paths: targets, locked: locked) { lfsFileOperations.removeValue(forKey: id) }
            } catch { self.error = error.localizedDescription }
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

    func showSynchronization() {
        guard !busy, !confirmingQuit, !bare, let repository else { return }
        let key = repository.root.path, access = activeAccess
        if let existing = synchronizationWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = SynchronizationWindowController(repository: repository, access: access)
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
        let id = UUID(), controller = AddProgressWindowController(repository: repository, access: access, paths: paths, mode: mode)
        controller.onClosed = { [weak self] in self?.addProgressWindows.removeValue(forKey: id) }
        controller.model.onFinished = { [weak self] text, _ in
            self?.refreshRepositoryLogs(repository.root)
            self?.output = text
            if self?.root?.path == repository.root.path { Task { await self?.refresh() } }
        }
        controller.model.onCommit = { [weak self] in self?.openSession(access ?? RepositoryAccessLease(url: repository.root), selected: FinderRequest(action: .commit, paths: [repository.root]), action: .commit) }
        addProgressWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
    }
    private func showClean(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        let root = repository.root
        let controller = cleanWindows[root.path] ?? CleanWindowController(repository: repository)
        controller.onClosed = { [weak self] in self?.cleanWindows.removeValue(forKey: root.path) }
        controller.model.setScope(paths)
        controller.model.onAccepted = { [weak self] request in
            guard let self else { return }
            let id = UUID(), progress = CleanProgressWindowController(repository: repository, access: access, request: request)
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
        let controller = revertWindows[root.path] ?? RevertWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.revertWindows.removeValue(forKey: root.path) }
        controller.model.onFileLog = { [weak self] path in self?.showLog(repository: repository, access: access, paths: [path]) }
        controller.model.onAccepted = { [weak self] entries in self?.showRevertProgress(repository: repository, access: access, entries: entries) }
        revertWindows[root.path] = controller
        controller.model.setScope(paths)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showSubmoduleDiff(repository: GitRepository, access: RepositoryAccessLease?, path: String, from: String = "HEAD", to: String? = nil) {
        let key = repository.root.path + "\0" + path + "\0" + from + "\0" + (to ?? "Working tree")
        let controller = submoduleDiffWindows[key] ?? SubmoduleDiffWindowController(repository: repository, access: access, path: path, from: from, to: to)
        controller.onClosed = { [weak self] in self?.submoduleDiffWindows.removeValue(forKey: key) }
        controller.model.onLog = { [weak self] child, hash in self?.showLog(repository: child, access: access, paths: [], endRevision: hash) }
        controller.model.onStatus = { [weak self] child in self?.showStatus(repository: child, access: access) }
        controller.model.onCompare = { [weak self] child, old, new in self?.showRevisionComparison(repository: child, access: access, from: old, to: new) }
        controller.model.onUpdate = { [weak self] done in self?.showSubmoduleUpdate(repository: repository, access: access, scope: [], selected: [path], completion: done) }
        submoduleDiffWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.load()
    }
    private func showRevisionComparison(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision, paths: [String] = []) {
        let baseKey = repository.root.path + "\0" + from.label + "\0" + to.label + "\0scope\0" + paths.joined(separator: "\0")
        let reusable = revisionComparisonWindows.first { _, controller in
            controller.model.repository.root == repository.root && controller.model.repository.executable == repository.executable &&
            controller.window?.attachedSheet == nil && controller.model.canReuseForComparison(from: from, to: to, paths: paths)
        }
        let key = reusable?.key ?? (revisionComparisonWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? RevisionComparisonWindowController(repository: repository, access: access, from: from, to: to, paths: paths)
        controller.onClosed = { [weak self] in self?.revisionComparisonWindows.removeValue(forKey: key) }
        configureRevisionComparisonInteractions(controller.model, repository: repository, access: access)
        revisionComparisonWindows[key] = controller
        controller.model.load()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showRevisionGraph(repository: GitRepository, access: RepositoryAccessLease?) {
        let key = repository.root.path + "\0" + repository.executable.path
        if let existing = revisionGraphWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = RevisionGraphWindowController(repository: repository, access: access)
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
    private func configureRevisionComparisonInteractions(_ model: RevisionComparisonWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        model.onLog = { [weak self] hash in self?.showLog(repository: repository, access: access, paths: [], endRevision: hash) }
        model.onFileLog = { [weak self] path, hash in self?.showLog(repository: repository, access: access, paths: [path], endRevision: hash) }
        model.onSubmoduleCompare = { [weak self] path, old, new in
            let from = old == .emptyTree ? "" : old == .workingTree ? "Working tree" : old.label
            let to = new == .emptyTree ? "" : new == .workingTree ? nil : new.label
            self?.showSubmoduleDiff(repository: repository, access: access, path: path, from: from, to: to)
        }
    }
    var fileComparisonPreferences: UserDefaults = .standard
    var fileComparisonQuestion: ((Int) async -> Bool)?
    var fileComparisonPresentation: ((RevisionComparisonSnapshot, CommitFile) -> Void)?
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
    func showWorkingFiles(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], amendToParent: Bool = false, owner: NSWindow? = nil) {
        let conflicts = paths.filter { path in entries.contains { $0.path == path && $0.state == .conflicted } }
        let ordinary = paths.filter { !conflicts.contains($0) }
        prepareFileComparisons(repository: repository, access: access, selectedCount: paths.count, owner: owner) { [self] token in
            for path in conflicts {
                guard !token.isCancelled, !confirmingQuit else { return }
                showConflictEditor(repository: repository, access: access, path: path, owner: owner)
            }
            guard !ordinary.isEmpty else { return }
            let snapshot = try await repository.workingFileComparison(paths: ordinary, amendToParent: amendToParent, cancellation: token)
            if snapshot.files.isEmpty { output = "No changes for the selected files."; return }
            presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token)
        }
    }
    func showPreviousDiff(repository: GitRepository, access: RepositoryAccessLease?, path: String, owner: NSWindow? = nil) {
        prepareFileComparisons(repository: repository, access: access, selectedCount: 1, owner: owner) { [self] token in
            let base = try await repository.previousDiffBase(path: path, cancellation: token)
            guard !confirmingQuit, !token.isCancelled else { return }
            if base.directory {
                showRevisionComparison(repository: repository, access: access, from: .revision(base.revision), to: .workingTree, paths: [path])
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
    func showHistoricalFiles(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision, paths: [String], owner: NSWindow? = nil) {
        prepareFileComparisons(repository: repository, access: access, selectedCount: paths.count, owner: owner) { [self] token in
            let snapshot = try await repository.revisionFileComparison(from: from, to: to, paths: paths, cancellation: token)
            if snapshot.files.isEmpty { output = "No files exist at the selected comparison paths."; return }
            presentFileComparisons(repository: repository, access: access, snapshot: snapshot, cancellation: token)
        }
    }
    private func presentFileComparisons(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, cancellation: OperationCancellation) {
        for file in snapshot.files {
            guard !confirmingQuit, !cancellation.isCancelled else { return }
            if let fileComparisonPresentation { fileComparisonPresentation(snapshot, file); continue }
            if file.isSubmodule {
                showSubmoduleDiff(repository: repository, access: access, path: file.path, from: snapshot.from == .emptyTree ? "" : snapshot.from.label, to: snapshot.to == .workingTree ? nil : snapshot.to == .emptyTree ? "" : snapshot.to.label)
                continue
            }
            let key = repository.root.path + "\0" + file.path + "\0" + (file.oldPath ?? file.path) + "\0" + snapshot.from.label + "\0" + snapshot.to.label + "\0" + ComparisonToolInvocation.cacheKey
            let controller = (fileComparisonWindows[key]?.window != nil ? fileComparisonWindows[key] : nil) ?? FileComparisonWindowController(repository: repository, access: access, snapshot: snapshot, path: file.path)
            controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.fileComparisonWindows[key] === controller else { return }; self.fileComparisonWindows.removeValue(forKey: key) }
            fileComparisonWindows[key] = controller
            controller.model.comparisonDefaults = fileComparisonPreferences
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
    }
    private func showSubmoduleSync(repository: GitRepository, access: RepositoryAccessLease?, scope: [String]) {
        guard !submoduleSyncWindows.values.contains(where: { $0.model.repository.root == repository.root && $0.model.activeOperation }) else { return }
        let id = UUID(), controller = SubmoduleSyncWindowController(repository: repository, access: access, scope: scope)
        controller.onClosed = { [weak self] in self?.submoduleSyncWindows.removeValue(forKey: id) }
        controller.model.onSynced = { [weak self] _ in
            self?.refreshRepositoryLogs(repository.root)
            if let self, self.root == repository.root { Task { await self.refresh() } }
        }
        submoduleSyncWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
    }
    private func showSubmoduleAdd(repository: GitRepository, access: RepositoryAccessLease?, path: String) {
        let key = repository.root.path
        let controller = submoduleAddWindows[key] ?? SubmoduleAddWindowController(repository: repository, access: access, path: path)
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
    private func showSubmoduleUpdate(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], selected: [String] = [], completion: (() -> Void)? = nil) {
        let root = repository.root, key = root.path + "\0" + scope.joined(separator: "\0") + "\0" + selected.joined(separator: "\0")
        let controller = submoduleUpdateWindows[key] ?? SubmoduleUpdateWindowController(repository: repository, access: access, scope: scope, selected: selected)
        controller.onClosed = { [weak self] in self?.submoduleUpdateWindows.removeValue(forKey: key) }
        controller.model.onSubmit = { [weak self] paths, options in
            self?.showSubmoduleUpdateProgress(repository: repository, access: access, paths: paths, options: options, completion: completion)
        }
        submoduleUpdateWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showSubmoduleUpdateProgress(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], options: SubmoduleUpdateOptions, completion: (() -> Void)? = nil) {
        let root = repository.root, id = UUID()
        let controller = SubmoduleUpdateProgressWindowController(repository: repository, access: access, paths: paths, options: options)
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
        let controller = statusWindows[root.path] ?? StatusWindowController(repository: repository, access: access)
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
        let controller = referenceLogWindows[root.path] ?? ReferenceLogWindowController(repository: repository, access: access, reference: reference)
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
        let controller = StashRestoreWindowController(repository: repository, access: access, pop: pop, reference: reference, showChanges: showChanges)
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
        let controller = worktreeListWindows[key] ?? WorktreeListWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.worktreeListWindows.removeValue(forKey: key) }
        controller.onSubmodules = { [weak self] path, lease in
            self?.showSubmoduleUpdate(repository: GitRepository(root: path, executable: repository.executable), access: lease, scope: [])
        }
        worktreeListWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showWorktreeCreate(repository: GitRepository, access: RepositoryAccessLease?) {
        let key = repository.root.path
        let controller = worktreeCreateWindows[key] ?? WorktreeCreateWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.worktreeCreateWindows.removeValue(forKey: key) }
        controller.model.onCreated = { [weak self] output in
            if self?.root?.path == key { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.onSubmodules = { [weak self] path, lease in
            self?.showSubmoduleUpdate(repository: GitRepository(root: path, executable: repository.executable), access: lease, scope: [])
        }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
        worktreeCreateWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showRequestPull(repository: GitRepository, access: RepositoryAccessLease?, end: String? = nil, repositoryURL: String? = nil) {
        let key = repository.root.path + ":requestPull:" + UUID().uuidString
        let controller = RequestPullWindowController(repository: repository, access: access, end: end, repositoryURL: repositoryURL)
        controller.onClosed = { [weak self] in self?.requestPullWindows.removeValue(forKey: key) }
        requestPullWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showImportPatch(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        let key = repository.root.path
        let controller = importPatchWindows[key] ?? ImportPatchWindowController(repository: repository, access: access)
        controller.model.onMutationStopped = { [weak self] in
            self?.statusWindows[key]?.model.requestReload(); self?.commitWindows[key]?.model.reload()
            if self?.root?.path == key { Task { await self?.refresh() } }
        }
        controller.onClosed = { [weak self] in self?.importPatchWindows.removeValue(forKey: key) }
        controller.model.onChanged = { [weak self] output in
            self?.statusWindows[key]?.model.requestReload()
            if self?.root?.path == key { self?.output = output; Task { await self?.refresh() } }
        }
        controller.model.add(paths.map { repository.root.appendingPathComponent($0) }.filter { ["patch", "diff"].contains($0.pathExtension.lowercased()) })
        importPatchWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showFormatPatch(repository: GitRepository, access: RepositoryAccessLease?, preset: FormatPatchPreset? = nil, sendMail: Bool = false) {
        let rootKey = repository.root.path
        let suffix: String
        switch preset?.selection {
        case .since(let revision): suffix = "\0since\0" + revision
        case .range(let from, let to): suffix = "\0range\0" + from + "\0" + to
        case .number(let count): suffix = "\0number\0" + String(count)
        case nil: suffix = ""
        }
        let key = rootKey + suffix
        let existing = formatPatchWindows[key]
        let controller = existing ?? FormatPatchWindowController(repository: repository, access: access, preset: preset, sendMail: sendMail)
        if existing != nil { controller.model.apply(preset) }
        if sendMail && !controller.model.busy && !controller.model.progress && !controller.model.composingMail { controller.model.sendMail = true }
        controller.onClosed = { [weak self] in self?.formatPatchWindows.removeValue(forKey: key) }
        controller.model.onOutputChanged = { [weak self] output in
            self?.statusWindows[rootKey]?.model.requestReload()
            if self?.root?.path == rootKey { self?.output = output; Task { await self?.refresh() } }
        }
        formatPatchWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showRepositoryBrowser(repository: GitRepository, access: RepositoryAccessLease?, revision: String = "HEAD") {
        let baseKey = repository.root.path + "\0" + revision
        let reusable = browserWindows.first { _, controller in
            controller.model.repository.root == repository.root && controller.model.repository.executable == repository.executable &&
            controller.window?.attachedSheet == nil && controller.model.canReuseForRevision(revision)
        }
        let key = reusable?.key ?? (browserWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? RepositoryBrowserWindowController(repository: repository, access: access, revision: revision)
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
    private func showBlame(repository:GitRepository,access:RepositoryAccessLease?,path:String,revision:String,line:Int? = nil,options:GitBlameOptions? = nil) {
        let key=repository.root.path+"\0"+path+"\0"+revision
        var recentFailure:String?
        if blameRecentDocuments==nil { do { blameRecentDocuments=try BlameRecentDocuments.production() } catch { recentFailure="Recent files could not be loaded: "+error.localizedDescription } }
        let controller=blameWindows[key] ?? BlameWindowController(repository:repository,access:access,path:path,revision:revision,options:options ?? GitBlamePreferences.load(),recentDocuments:blameRecentDocuments)
        controller.model.recentHistoryError=recentFailure
        configureBlameRoutes(controller)
        controller.onClosed={ [weak self,weak controller] in guard let self,let controller else { return };self.blameWindows=self.blameWindows.filter { $0.value !== controller } }
        controller.onDocumentChanged={ [weak self,weak controller] in
            guard let self,let controller else { return };self.configureBlameRoutes(controller)
            self.blameWindows=self.blameWindows.filter { $0.value !== controller }
            let newKey=controller.model.repository.root.path+"\0"+controller.model.path+"\0HEAD"
            // Another window may already display this file; retain both without
            // corrupting either owner's lifecycle or discarding its work.
            let available=self.blameWindows[newKey]==nil ? newKey : newKey+"\0"+UUID().uuidString
            self.blameWindows[available]=controller
        }
        if let options { controller.model.configure(options:options,line:line) } else if let line { controller.model.selectOriginalLine(line) }
        blameWindows[key]=controller;controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
    }
    private func refreshRepositoryLogs(_ root: URL) {
        for log in logWindows.values where log.model.repository.root == root && !log.model.isInvalidated { log.model.requestRepositoryRefresh() }
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
        var contexts = [GitPropertiesContext(repository:repository,paths:selection,access:access,submodule:false)]
        if selection == ["."], let parent = FinderSnapshot.read()?.repositories[repository.root.path]?.submoduleParentRoot {
            let root = URL(fileURLWithPath:parent,isDirectory:true)
            if access?.contains(root) == true, repository.root.path.hasPrefix(root.path + "/") {
                let path = String(repository.root.path.dropFirst(root.path.count + 1))
                contexts.insert(GitPropertiesContext(repository:GitRepository(root:root,executable:repository.executable),paths:[path],access:access,submodule:true),at:0)
            }
        }
        let controller = GitPropertiesWindowController(contexts:contexts)
        controller.onClosed = { [weak self,weak controller] in guard self?.gitPropertyWindows[key] === controller else { return }; self?.gitPropertyWindows.removeValue(forKey:key) }
        controller.model.onLog = { [weak self] context in self?.showLog(repository:context.repository,access:context.access,paths:context.paths == ["."] ? [] : context.paths) }
        controller.model.onChanged = { [weak self] changed in
            self?.statusWindows[changed.root.path]?.model.requestReload(); self?.commitWindows[changed.root.path]?.model.reload()
            if self?.root == changed.root { Task { await self?.refresh() } }
        }
        gitPropertyWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showLog(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], endRevision: String? = nil, selectedRevision: String? = nil, revisionRange: HistoryRevisionRange? = nil) {
        let root = repository.root
        var baseKey = root.path
        if let revisionRange { baseKey += "\0range\0" + revisionRange.expression }
        else if let endRevision { baseKey += "\0" + endRevision }
        if !paths.isEmpty { baseKey += "\0paths\0" + paths.sorted().joined(separator: "\0") }
        let reusable: (key: String, value: LogWindowController)?
        if let revisionRange {
            reusable = logWindows.first { _, controller in
                controller.model.repository.root == root && controller.model.repository.executable == repository.executable &&
                controller.window?.attachedSheet == nil && controller.model.canReuseForRange(revisionRange)
            }
        } else { reusable = logWindows[baseKey].map { (key: baseKey, value: $0) } }
        let key = reusable?.key ?? (logWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? logWindowFactory?(repository,access) ?? LogWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.logWindows.removeValue(forKey: key) }
        controller.model.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        controller.model.onHistoryPush = { [weak self] revision, preserveAllBranches in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: preserveAllBranches) }
        controller.model.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
        controller.model.onCombineRevisions = { [weak self, weak controller] entries, offset, head in guard let controller else { return }; self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: controller.window) }
        controller.model.onRevertRevisions = { [weak self, weak controller] entries, mainline in guard let controller else { return }; self?.showHistoryRevert(repository: repository, access: access, entries: entries, mainline: mainline, owner: controller.window) }
        controller.model.onFormatPatch = { [weak self] preset in self?.showFormatPatch(repository: repository, access: access, preset: preset) }
        controller.model.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
        controller.model.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
        configureLogMenus(controller.model, repository: repository, access: access)
        controller.model.onCherryPick = { [weak self] commits in self?.showRebase(repository: repository, access: access, cherryPick: commits) }
        controller.model.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision, paths: paths) }
        controller.model.onMergeRevision = { [weak self] revision in self?.showMerge(repository: repository, access: access, revision: revision) }
        controller.model.onRebaseRevision = { [weak self] revision in self?.showRebase(repository: repository, access: access, upstream: revision, fromLog: true) }
        configureLogBisect(controller.model, repository: repository, access: access)
        controller.model.onWorkingCommand = { [weak self] action in
            switch action {
            case .stash: self?.showStash(repository: repository, access: access)
            case .stashPop: self?.showStashRestore(repository: repository, access: access, pop: true)
            case .stashList: self?.showReferenceLog(repository: repository, access: access, reference: "refs/stash")
            case .pull, .fetch: self?.showFetch(repository: repository, access: access, isPull: action == .pull)
            case .submoduleUpdate: self?.showSubmoduleUpdate(repository: repository, access: access, scope: [])
            default: break
            }
        }
        controller.model.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
        controller.model.onContainingLog = { [weak self] name, select, range in
            self?.showLog(repository: repository, access: access, paths: [], endRevision: name, selectedRevision: select ? name : nil, revisionRange: range)
        }
        controller.model.onCompare = { [weak self] from, to in self?.showRevisionComparison(repository: repository, access: access, from: from, to: to) }
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
        controller.model.onCommit = { [weak self] in
            guard let self else { return }
            if self.root == root { self.activate(.commit) }
            else if let access { self.openSession(access, action: .commit) }
        }
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
        controller.model.setPathScope(paths)
        if let selectedRevision { ReferenceLogWindowModel.configureRevisionLog(controller.model, revision: selectedRevision) }
        if let revisionRange {
            ReferenceLogWindowModel.configureRangeLog(controller.model, range: revisionRange)
            controller.window?.title = location + " – Log Messages " + revisionRange.expression + " – TurtleGit"
        }
        controller.model.reload()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }

    private func configureLogMenus(_ model: LogWindowModel, repository: GitRepository, access: RepositoryAccessLease?) {
        model.onShowHistory={ [weak self] hash in self?.showLog(repository:repository,access:access,paths:[],endRevision:hash,selectedRevision:hash) }
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
    private func showBisect(repository: GitRepository, access: RepositoryAccessLease?, good: String? = nil, bad: String? = nil, operation: BisectOperation? = nil, revisions: [String] = [], requireStart: Bool = false, sourceLog: LogWindowModel? = nil, onChanged: (() -> Void)? = nil) {
        let root = repository.root
        let controller: BisectWindowController
        if let existing = bisectWindows[root.path] {
            controller = existing
            if !existing.activeOperation { existing.model.load(good: good, bad: bad, operation: operation, revisions: revisions, requireStart: requireStart) }
        } else { controller = BisectWindowController(repository: repository, access: access, good: good, bad: bad, operation: operation, revisions: revisions, requireStart: requireStart) }
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
    private func showExport(repository: GitRepository, access: RepositoryAccessLease?, revision: String, paths: [String] = []) {
        let root = repository.root
        let directory = ExportWindowModel.directoryScope(root: root, paths: paths)
        let baseKey = root.path + "\0" + revision + "\0" + directory
        let reusable = exportWindows.first { _, controller in
            controller.model.repository.root == repository.root && controller.model.repository.executable == repository.executable &&
            controller.window?.attachedSheet == nil && controller.model.canReuseForRevision(revision, directory: directory)
        }
        let key = reusable?.key ?? (exportWindows[baseKey] == nil ? baseKey : baseKey + "\0" + UUID().uuidString)
        let controller = reusable?.value ?? ExportWindowController(repository: repository, access: access, revision: revision, directory: directory)
        controller.onClosed = { [weak self] in self?.exportWindows.removeValue(forKey: key) }
        exportWindows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showMergeAbort(repository: GitRepository, access: RepositoryAccessLease?) {
        let id = UUID(), root = repository.root
        let controller = MergeAbortWindowController(repository: repository, access: access)
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
        controller.model.configureLogPicker = { [weak self] log in
            log.onPush = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
            log.onHistoryPush = { [weak self] revision, preserveAllBranches in self?.showPush(repository: repository, access: access, source: revision, preserveAllBranches: preserveAllBranches) }
            log.onHistoryPull = { [weak self] in self?.showFetch(repository: repository, access: access, isPull: true) }
            log.onCreateReference = { [weak self] isTag, revision in self?.showReference(repository: repository, access: access, isTag: isTag, revision: revision) }
            log.onCheckout = { [weak self] revision in self?.showSwitch(repository: repository, access: access, revision: revision) }
            self?.configureLogMenus(log, repository: repository, access: access)
            log.onExportRevision = { [weak self] revision in self?.showExport(repository: repository, access: access, revision: revision) }
            log.onMergeRevision = { [weak self] revision in self?.showMerge(repository: repository, access: access, revision: revision) }
            log.onRebaseRevision = { [weak self] revision in self?.showRebase(repository: repository, access: access, upstream: revision, fromLog: true) }
            log.onCombineRevisions = { [weak self, weak log] entries, offset, head in self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: log?.window) }
            log.onRevertRevisions = { [weak self, weak log] entries, mainline in self?.showHistoryRevert(repository: repository, access: access, entries: entries, mainline: mainline, owner: log?.window) }
            self?.configureLogBisect(log, repository: repository, access: access, refreshPicker: true)
                log.onCherryPick = { [weak self] commits in self?.showRebase(repository: repository, access: access, cherryPick: commits) }
            log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
        }
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
    private func showMerge(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, showStashPop: Bool = false) {
        let key = repository.root.path + "\0" + UUID().uuidString
        let controller = MergeWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.mergeWindows.removeValue(forKey: key) }
        configureMergeInteractions(controller, repository: repository, access: access, showStashPop: showStashPop)
        mergeWindows[key] = controller; controller.model.load(revision: revision)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showStash(repository: GitRepository, access: RepositoryAccessLease?, followUp: StashSaveFollowUp = StashSaveFollowUp()) {
        let root = repository.root, key = repository.root.path + "\0" + UUID().uuidString
        let controller = StashWindowController(repository: repository, access: access)
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
            log.onMergeRevision = { [weak self] revision in self?.showMerge(repository: repository, access: access, revision: revision) }
            log.onRebaseRevision = { [weak self] revision in self?.showRebase(repository: repository, access: access, upstream: revision, fromLog: true) }
            log.onCombineRevisions = { [weak self, weak log] entries, offset, head in self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: log?.window) }
            log.onRevertRevisions = { [weak self, weak log] entries, mainline in self?.showHistoryRevert(repository: repository, access: access, entries: entries, mainline: mainline, owner: log?.window) }
            self?.configureLogBisect(log, repository: repository, access: access, refreshPicker: true)
            log.onCherryPick = { [weak self] commits in self?.showRebase(repository: repository, access: access, cherryPick: commits) }
        log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
        }
    }
    private func showRebase(repository: GitRepository, access: RepositoryAccessLease?, upstream: String? = nil, autoStart: Bool = false, preserveMerges: Bool = false, cherryPick: [String]? = nil, afterFetch: Bool = false, fromLog: Bool = false, owner: NSWindow? = nil, onDismissed: (() -> Void)? = nil, onResult: ((Bool) -> Void)? = nil, onRequestedLog: (() -> Void)? = nil) {
        let root = repository.root
        let existing = rebaseWindows[root.path]
        if let existing, existing.window?.sheetParent != nil { existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = existing ?? RebaseWindowController(repository: repository, access: access)
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
            log.onMergeRevision = { [weak self] revision in self?.showMerge(repository: repository, access: access, revision: revision) }
            log.onRebaseRevision = { [weak self] revision in self?.showRebase(repository: repository, access: access, upstream: revision, fromLog: true) }
            log.onCombineRevisions = { [weak self, weak log] entries, offset, head in self?.showHistoryCombine(repository: repository, access: access, entries: entries, offset: offset, head: head, owner: log?.window) }
            log.onRevertRevisions = { [weak self, weak log] entries, mainline in self?.showHistoryRevert(repository: repository, access: access, entries: entries, mainline: mainline, owner: log?.window) }
            self?.configureLogBisect(log, repository: repository, access: access, refreshPicker: true)
            log.onReset = { [weak self] revision in self?.showReset(repository: repository, access: access, revision: revision) }
        }
        rebaseWindows[root.path] = controller
        if existing == nil || controller.model.finished || upstream != nil || cherryPick != nil { controller.model.load(upstream: upstream, autoStart: autoStart, preserveMerges: preserveMerges, cherryPick: cherryPick) }
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
    private func showFetch(repository: GitRepository, access: RepositoryAccessLease?, isPull: Bool = false, followUp: PullFollowUp = PullFollowUp(), remote: String? = nil, allRemotes: Bool? = nil) {
        let key = repository.root.path + (isPull ? ":pull:" : ":fetch:") + UUID().uuidString
        let controller = FetchWindowController(repository: repository, access: access, isPull: isPull)
        controller.onClosed = { [weak self] in self?.fetchWindows.removeValue(forKey: key) }
        configureFetchInteractions(controller, repository: repository, access: access, followUp: followUp)
        fetchWindows[key] = controller; controller.model.load(remote: remote, allRemotes: allRemotes)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showPush(repository: GitRepository, access: RepositoryAccessLease?, source: String? = nil, preserveAllBranches: Bool = false) {
        let root = repository.root, key = repository.root.path + ":push:" + UUID().uuidString
        let controller = PushWindowController(repository: repository, access: access)
        controller.onClosed = { [weak self] in self?.pushWindows.removeValue(forKey: key) }
        configurePushInteractions(controller, repository: repository, access: access)
        pushWindows[key] = controller; controller.model.load(source: source, preserveAllBranches: preserveAllBranches)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func configurePushInteractions(_ controller: PushWindowController, repository: GitRepository, access: RepositoryAccessLease?) {
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
            self.showSwitchProgress(repository: repository, access: access, reference: reference, parent: parent, completion: done)
        }
        controller.model.onPushTag = { [weak self] source in self?.showPush(repository: repository, access: access, source: source) }
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
    }
    private func showReference(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool, revision: String? = nil) {
        let key = repository.root.path + (isTag ? ":tag:" : ":branch:") + UUID().uuidString
        let controller = referenceWindows[key] ?? BranchTagWindowController(repository: repository, access: access, isTag: isTag)
        controller.onClosed = { [weak self] in self?.referenceWindows.removeValue(forKey: key) }
        configureReferenceInteractions(controller, repository: repository, access: access)
        referenceWindows[key] = controller; controller.model.load(revision: revision)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func showSwitchProgress(repository: GitRepository, access: RepositoryAccessLease?, reference: String, parent: NSWindow, completion: (() -> Void)? = nil) {
        let id = UUID(), root = repository.root
        let controller = SwitchProgressWindowController(repository: repository, access: access, reference: reference)
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
        controller.model.start()
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
        let controller = ReferenceBrowserWindowController(repository: repository, access: access, initial: "HEAD", picking: false) { _ in }
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
        controller.configureReferencePicker = { [weak self] model in
            self?.configureReferenceBrowser(model, repository: repository, access: access)
        }
    }
    private func showSwitch(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil) {
        let root = repository.root
        let key = root.path + ":switch:" + UUID().uuidString
        let controller = switchWindows[key] ?? SwitchWindowController(repository: repository, access: access, revision: revision)
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
    private func comparisonPermission(for file: URL) throws -> RepositoryAccessLease? {
        if let activeAccess, activeAccess.contains(file), !GitRuntime.isAppStoreBuild || activeAccess.hasSecurityScope { return activeAccess }
        if let accessStore {
            for saved in accessStore.repositories {
                if let lease = try? accessStore.acquire(saved.id, requireSecurityScope: GitRuntime.isAppStoreBuild), lease.contains(file) { return lease }
            }
        }
        if !GitRuntime.isAppStoreBuild { return RepositoryAccessLease(url: file) }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.directoryURL = file.deletingLastPathComponent(); panel.prompt = "Authorize comparison"
        panel.message = "Choose the requested file or its containing folder to allow TurtleGit to compare it."
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
    private func handleFilePair(paths: [URL]) {
        let alternateTool = ComparisonToolInvocation.capture
        do {
            guard let prepared = try WorkingFilePairAccess.prepare(paths: paths, requireSecurityScope: GitRuntime.isAppStoreBuild,
                acquire: { try comparisonPermission(for: $0) }) else { return }
            let key = "working-pair:" + UUID().uuidString
            let controller = FileComparisonWindowController(comparison: prepared.comparison, permissions: prepared.permissions,preferences:fileComparisonPreferences)
            controller.model.captureToolChoice(alternateTool)
            controller.onClosed = { [weak self, weak controller] in guard let self, let controller, self.fileComparisonWindows[key] === controller else { return }; self.fileComparisonWindows.removeValue(forKey: key) }
            fileComparisonWindows[key] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } catch { self.error = error.localizedDescription }
    }
    func handle(_ url: URL) {
        guard !confirmingQuit, let request = FinderRequest(url: url) else { return }
        let choice=request.alternateTool ?? ComparisonToolInvocation.capture
        ComparisonToolInvocation.$alternate.withValue(choice) {handleFinderRequest(request)}
    }
    private func handleFinderRequest(_ request:FinderRequest) {
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
        if action == .reviewPatch { showReviewPatch(files: request.paths); return }
        if action == .sendMail { showFinderSendMail(files: request.paths); return }
        if action == .clearComparisonMark { clearComparisonMark(); return }
        if action == .diffLater {
            guard request.paths.count == 1 else { error = "Select one file to mark or compare."; return }
            handleComparisonMark(file: request.paths[0]); return
        }
        if action == .clone { showClone(directory: request.paths.first); return }
        if action == .initialize { showCreateRepository(folder: request.paths.first); return }
        if action == .diff && request.paths.count == 2 { handleFilePair(paths: request.paths); return }
        let candidate = request.paths[0]
        var permissionTargets = request.paths
        if action == .rename || action == .remove || action == .submoduleSync || action == .logSubmodule || action == .properties,
           let parent = FinderSnapshot.read()?.repositories[candidate.standardizedFileURL.path]?.submoduleParentRoot {
            let parentURL = URL(fileURLWithPath: parent, isDirectory: true)
            if parentURL.path != candidate.path && candidate.standardizedFileURL.path.hasPrefix(parentURL.path.hasSuffix("/") ? parentURL.path : parentURL.path + "/") {
                permissionTargets.append(parentURL)
            }
        }
        // A URL from Finder or another app is a request, not a sandbox permission grant.
        if let activeAccess, permissionTargets.allSatisfy({ activeAccess.contains($0) }) {
            openSession(activeAccess, selected: request, action: action)
            return
        }
        if let store = accessStore {
            for saved in store.repositories {
                guard let lease = try? store.acquire(saved.id, requireSecurityScope: GitRuntime.isAppStoreBuild),
                      permissionTargets.allSatisfy({ lease.contains($0) }) else { continue }
                recentRepositories = store.repositories
                openSession(lease, selected: request, action: action)
                return
            }
        }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Authorize repository"
        panel.message = "Choose the repository root containing the Finder selection to allow TurtleGit to work with it."
        panel.directoryURL = permissionTargets.count > request.paths.count ? permissionTargets.last : (candidate.hasDirectoryPath ? candidate : candidate.deletingLastPathComponent())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lease = RepositoryAccessLease(url: url)
        guard permissionTargets.allSatisfy({ lease.contains($0) }) else {
            error = "The selected folder does not contain every requested Finder item."; return
        }
        openSession(lease, selected: request, action: action)
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
