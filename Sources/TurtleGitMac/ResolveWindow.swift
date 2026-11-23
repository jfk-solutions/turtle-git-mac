import AppKit
import Darwin
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

@MainActor final class ResolveWindowController: NSWindowController, NSWindowDelegate {
    var commandProgressScope: CommandProgressScope? { model.commandProgressScope }
    var commandKeyWindow: () -> NSWindow? = { NSApp.keyWindow }
    static private(set) var activeReleases=0
    let model: ResolveWindowModel
    let progressFiles:FileOperationProgressFiles
    var externalAvailability:()->Bool {get{model.externalAvailability}set{model.externalAvailability=newValue}}
    var onProgressLog:(String)->Void = {_ in}
    private var finishing=false
    private var presentationParent:NSWindow?
    private var commitHandoff:(()->Void)?
    var onClosed: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onCommit: () -> Void = {}
    private(set) var retired = false
    var configureComparison: (FileComparisonWindowModel) -> Void = { _ in }
    private(set) var baseComparison: FileComparisonWindowController?
    private(set) var fileUnifiedWindows:[UUID:PatchWindowController] = [:]
    private(set) var applicationPanel:NSOpenPanel?
    private(set) var fileRevertWindow:RevertProgressWindowController?
    var configureFileRevert:(RevertProgressWindowModel)->Void = {_ in}
    private var question: (UUID, NSAlert, (NSApplication.ModalResponse?) -> Void)?
    var presentQuestion: (NSWindow, NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Bool = { owner, alert, reply in
        guard owner.attachedSheet == nil else { return false }; alert.beginSheetModal(for: owner, completionHandler: reply); return true
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], quick: ResolveChoice? = nil, preferences: UserDefaults = .standard, commandOptions: ResolveCommandOptions? = nil) {
        model = ResolveWindowModel(repository: repository, access: access, paths: paths, quick: quick, preferences: preferences, commandOptions: commandOptions)
        progressFiles=FileOperationProgressFiles(repository:repository,access:access)
        let size = quick == nil ? NSSize(width: 780, height: 450) : NSSize(width: 480, height: 110)
        let window = ResolveCommandWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Resolve", preferences: preferences)
        window.contentMinSize = quick == nil ? NSSize(width: 660, height: 340) : size
        window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        model.primaryWindow=window
        window.contentViewController = NSHostingController(rootView: ResolveDialog(model: model, commit: { [weak self] in self?.commit() }).defaultAppStorage(preferences))
        window.setContentSize(size); window.center()
        model.close = { [weak self] in self?.requestClose() }
        model.confirm = { [weak self] choice, entries in self?.confirm(choice, entries: entries) }
        model.onChanged = { [weak self] output in guard let self, !self.retired else { return }; self.onChanged(output) }
        model.onProgress = { [weak self] in
            guard let self, !self.retired, let window = self.window else { return }
            window.contentMinSize = NSSize(width: 660, height: 340)
            if window.frame.width < 660 || window.contentLayoutRect.height < 340 { window.setContentSize(NSSize(width: 780, height: 450)) }
        }
        model.onComparison = { [weak self] prepared in
            guard let self, !self.retired, self.baseComparison == nil else { return }
            let child = FileComparisonWindowController(repository: repository, access: access, conflict: prepared, preferences: preferences)
            self.configureComparison(child.model); self.baseComparison = child; self.model.hasChild = true
            child.onClosed = { [weak self] in
                guard let self else { return }; self.baseComparison = nil; self.model.hasChild = false
                if !self.retired { self.model.load() }
            }
            child.showWindow(nil); child.window?.makeKeyAndOrderFront(nil)
        }
        model.confirmCancellation = { [weak self] reply in
            Task { let answer = await self?.ask(title: "The process is still running.", message: "Are you sure to abort?", buttons: ["Yes", "No"]); reply(answer == .alertFirstButtonReturn) }
        }
        model.confirmSubmoduleDeletion = { [weak self] request in
            await self?.ask(title: "Delete submodule folder?", message: request.gitError + "\n\nMove “\(request.path)” to Trash to resolve its deletion?", buttons: ["Delete", "Abort"]) == .alertFirstButtonReturn
        }
        model.confirmFileMutation = { [weak self] title,message in
            await self?.ask(title:title,message:message,buttons:["No","Yes"]) == .alertSecondButtonReturn
        }
        model.cancelMutationChild = { [weak self] in self?.fileRevertWindow?.model.cancel() }
        model.retireMutationChild = { [weak self] in self?.fileRevertWindow?.close() }
        model.presentFileRevert = { [weak self] rows,validate in
            guard let self,!self.retired,self.fileRevertWindow == nil,let window=self.window,window.attachedSheet == nil else {return nil}
            return await withCheckedContinuation {continuation in
                let child = CommandProgressContext.perform(self.commandProgressScope) { RevertProgressWindowController(repository:repository,access:access,entries:rows,amend:false,againstHead:true,autoCloseSuccess:true,preferences:preferences,policy:self.model.pendingFileRevertPolicy) }
                child.model.externalAvailability={ [weak self] in self?.retired == false && self?.model.confirmingQuit == false }
                child.onProgressLog={ [weak self] path in guard let self,!self.retired,!self.model.confirmingQuit else{return};self.onProgressLog(path) }
                let policy=child.model.policy
                var first = true,output = ""
                child.model.execute = {selected,token,progress,emit in
                    try await validate(token,first);first = false
                    return try await repository.revertWorkingFiles(selected,policy:policy,cancellation:token,progress:progress,onOutput:emit)
                }
                child.model.onFinished = {text,_ in output = text}
                child.model.onHandleSubmodules = { [weak model=self.model] revision,paths in model?.onFileSubmoduleRevert?(revision,paths) }
                child.onClosed = { [weak self,weak child] in
                    if let sheet=child?.window {sheet.sheetParent?.endSheet(sheet);sheet.orderOut(nil)}
                    if self?.fileRevertWindow === child {self?.fileRevertWindow = nil;self?.model.hasChild = false}
                    continuation.resume(returning:output)
                }
                self.fileRevertWindow = child;self.model.hasChild = true;self.configureFileRevert(child.model)
                if let sheet=child.window {window.beginSheet(sheet);child.model.start()} else {child.close()}
            }
        }
        model.chooseFileApplication = { [weak self,weak window] in
            guard let self,!self.retired,let window,window.attachedSheet == nil else {return nil}
            let panel = NSOpenPanel();self.applicationPanel = panel
            panel.title = "Open With";panel.prompt = "Open";panel.allowedContentTypes = [.applicationBundle]
            panel.canChooseDirectories = false;panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath:"/Applications",isDirectory:true)
            defer {if self.applicationPanel === panel {self.applicationPanel = nil}}
            let answer = await withCheckedContinuation {reply in panel.beginSheetModal(for:window) {reply.resume(returning:$0)}}
            return answer == .OK ? panel.url:nil
        }
        model.cancelFileChoice = { [weak self] in self?.applicationPanel?.cancel(nil) }
        model.onFileUnified = { [weak self] bytes,alternate,token in
            guard let self,!self.retired,!token.isCancelled else {return}
            if try await UnifiedDiffApplication.openExternal(bytes,alternate:alternate,preferences:preferences,title:"Conflict changes",permissions:access.map{[$0]} ?? []) {return}
            guard !self.retired,!token.isCancelled else {return}
            let id = UUID()
            self.fileUnifiedWindows[id] = UnifiedDiffApplication.presentBuiltin(bytes,repository:repository,access:access,existing:nil,title:"Conflict changes",onClosed:{ [weak self] in self?.fileUnifiedWindows.removeValue(forKey:id) })
        }
        progressFiles.window=window;progressFiles.available={ [weak model] in model?.progressOwnerAvailable==true }
        progressFiles.onBusy={ [weak model] in model?.progressFileActionBusy=$0 }
        progressFiles.onLog={ [weak self] in self?.onProgressLog($0) }
        progressFiles.onError={ [weak model] in model?.error=$0 }
        model.onProgressFileAction={ [weak self] action,path in self?.progressFiles.perform(action,path:path) }
        DialogGeometry.attach(window, identifier: quick == nil ? "ResolveDialog" : "QuickResolveDialog", legacyName: "ResolveDialog")
    }
    private func confirm(_ choice: ResolveChoice, entries: [ConflictEntry]) {
        let generation = model.generation
        Task {
            let message = choice == .current ? "The current working contents will be staged." : "This replaces the selected working contents with index stage \(choice.rawValue). A missing stage resolves the path as deleted."
            let answer = await ask(title: "Are you sure you want to mark the conflicted file(s) as resolved?", message: message, buttons: ["Yes", "No"])
            guard !retired, model.generation == generation else { return }
            if answer == .alertFirstButtonReturn { model.apply(entries, using: choice) } else { model.rejectConfirmation() }
        }
    }
    private func ask(title: String, message: String, buttons: [String]) async -> NSApplication.ModalResponse? {
        guard !retired, question == nil, let window, window.attachedSheet == nil else { return nil }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = message;alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
        buttons.forEach { alert.addButton(withTitle: $0) }
        let id = UUID(); model.hasQuestion = true
        return await withCheckedContinuation { continuation in
            question = (id, alert, { continuation.resume(returning: $0) })
            if !presentQuestion(window, alert, { [weak self] answer in self?.finishQuestion(id, answer: answer) }) { finishQuestion(id, answer: nil) }
        }
    }
    private func finishQuestion(_ id: UUID, answer: NSApplication.ModalResponse?) {
        guard let pending = question, pending.0 == id else { return }; question = nil
        Task { [self] in
            await FileOperationWindowDrain.detach(pending.1.window,parent:window)
            model.hasQuestion=false;pending.2(answer)
        }
    }
    func commit() {
        CommandProgressContext.perform(commandProgressScope) { commitInCommandProgressScope() }
    }
    private func commitInCommandProgressScope() {
        guard !retired,!finishing,model.progressActionsAvailable,model.success,!model.cancelled,window?.attachedSheet==nil else{return}
        finishing=true;model.handoffPending=true;commitHandoff=CommandProgressContext.capture(commandProgressScope,onCommit)
        model.saveActionLog();window?.orderOut(nil);close()
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        if model.busy{model.cancel();return false}
        return !model.confirmingQuit && !model.handoffPending && !model.hasQuestion && !model.hasChild && !model.progressFileActionBusy && !model.confirmingCancellation && sender.attachedSheet==nil
    }
    private func requestClose() {
        guard !retired,let window,windowShouldClose(window) else{return}
        // A sheet has no ordinary enabled titlebar Close button. Use the same
        // delegate policy directly instead of AppKit's button activation path.
        close()
    }
    override func close(){presentationParent=window?.sheetParent ?? presentationParent;super.close();retireClosedWindow()}
    func windowWillClose(_ notification:Notification){presentationParent=window?.sheetParent ?? presentationParent;retireClosedWindow()}
    private func retireClosedWindow(){
        guard !retired else{return};retired=true
        let callback=commitHandoff;commitHandoff=nil
        let sheets=[window?.attachedSheet,applicationPanel,question?.1.window].compactMap{$0}
        model.invalidate();progressFiles.retire();baseComparison?.close();baseComparison=nil
        applicationPanel?.cancel(nil);applicationPanel=nil
        Array(fileUnifiedWindows.values).forEach{$0.close()};fileUnifiedWindows=[:]
        if let pending=question{finishQuestion(pending.0,answer:nil)}
        Self.activeReleases += 1
        Task { [self] in
            defer{Self.activeReleases -= 1;model.handoffPending=false}
            for sheet in sheets{await FileOperationWindowDrain.detach(sheet,parent:window)}
            if let window{await FileOperationWindowDrain.detach(window,parent:presentationParent)}
            presentationParent=nil
            while model.busy || model.primaryActivationPending || model.confirmingCancellation || model.reportResetActive || progressFiles.busy{try? await Task.sleep(nanoseconds:5_000_000)}
            window?.contentViewController=nil
            // AppKit can reorder a dismissed sheet while the final worker or
            // child links drain. Release ownership only after hiding it again.
            window?.orderOut(nil)
            onClosed()
            if finishing,!model.confirmingQuit,model.externalAvailability(){callback?()}
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct ResolveConflictRow: Identifiable {
    let entry: ConflictEntry
    var id: String { GitPathRowIdentity.encode(entry.path) }
}

@MainActor final class ResolveWindowModel: ObservableObject {
    let commandProgressScope = CommandProgressContext.current
    let progressPresentation: GitCommandPresentation
    static private(set) var activeOperations = 0
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    var repositoryAccess: RepositoryAccessLease? { access }
    let preferences: UserDefaults
    let progress:FileOperationProgressState
    var externalAvailability:()->Bool = {true}
    @Published var confirmingQuit=false
    @Published var handoffPending=false
    @Published var progressFileActionBusy=false
    @Published private(set) var completionRange:NSRange?
    private var progressStarted:Date?
    var onProgressFileAction:(FileOperationProgressAction,String)->Void = {_,_ in}
    var progressOwnerAvailable:Bool {active && showingProgress && !busy && !confirmingQuit && !handoffPending && !hasQuestion && !hasChild && !confirmingCancellation && externalAvailability()}
    var progressActionsAvailable:Bool {progressOwnerAvailable && !progressFileActionBusy}
    var progressKeyboardAvailable:Bool {active && !confirmingQuit && !handoffPending && externalAvailability()}
    var actionLogOutput:String {progress.output+"\n"+output}
    let quick: ResolveChoice?
    let commandOptions: ResolveCommandOptions?
    private var commandStarted = false
    private(set) var silentAttempt = false
    @Published private(set) var paths: [String]
    private(set) var active = true
    private(set) var generation = UUID()
    private var cancellation: OperationCancellation?
    private var refreshCancellation: OperationCancellation?
    private var loaded = false, reloadQueued = false, initialLoadStarted = false
    private var fileMenuEpoch = UUID()
    private var usedFileMenus = Set<UUID>()
    private var droppedProviders: [NSItemProvider] = []
    private var dropTask: Task<Void,Never>?
    @Published private(set) var readingDrops = false
    var readDroppedURL: (NSItemProvider) async throws -> URL = CommitFileURLReader.read
    var readDroppedConflicts: (([String], OperationCancellation) async throws -> ([ConflictEntry], Bool))?
    @Published var entries: [ConflictEntry] = []
    let reportRefresh=FileListRefreshCoordinator()
    private(set) var reportResetActive=false
    static let reportColumnsKey = "ResolveDlg.FileColumns"
    static var defaultReportColumns:StatusListColumnSettings {StatusListColumnSettings(visible:[.path,.fileExtension])}
    @Published private(set) var reportColumns:StatusListColumnSettings
    @Published private(set) var reportSort:StatusListColumn = .path
    @Published private(set) var reportAscending=true
    @Published private(set) var reportHasLFS=false
    @Published private(set) var reportMetadata:GitPathMap<StatusListMetadata> = [:]
    @Published private(set) var reportStatistics:GitPathMap<CommitFile> = [:]
    @Published private(set) var reportLFSOwners:GitPathMap<String> = [:]
    @Published var checked = GitPathSet()
    private var selectedPaths = GitPathSet()
    @Published var nativeSelection = Set<String>() {
        didSet { selectedPaths = GitPathRowIdentity.paths(nativeSelection) }
    }
    var selection: GitPathSet {
        get { selectedPaths }
        set { let ids = Set(newValue.map(GitPathRowIdentity.encode)); if nativeSelection != ids { nativeSelection = ids } }
    }
    @Published var focusedFilePath:String?
    @Published private(set) var fileMutationTitle = ""
    private(set) var fileMutationActive = false
    private(set) var deletionResult:WorkingFileDeleteResult?
    var confirmFileMutation:(String,String) async -> Bool = {_,_ in false}
    private(set) var pendingFileRevertPolicy:WorkingFileRevertPolicy?
    var presentFileRevert:([StatusEntry],@escaping (OperationCancellation,Bool) async throws -> Void) async -> String? = {_,_ in nil}
    var cancelMutationChild:()->Void = {}
    var retireMutationChild:()->Void = {}
    var onFileSubmoduleRevert:((String,[String])->Void)?
    @Published var rebase = false
    @Published var busy = false
    @Published var error: String?
    @Published var patch: String?
    @Published private(set) var showingProgress = false
    @Published private(set) var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var resolvedCount = 0
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published var hasQuestion = false
    @Published var hasChild = false
    private var autoClosePolicy: GitProgressAutoClose?
    private var pendingResolution: (UUID, [ConflictEntry], ResolveChoice)?
    var closeAfterResolution = true
    var close: () -> Void = {}
    var confirm: (ResolveChoice, [ConflictEntry]) -> Void = { _, _ in }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var confirmSubmoduleDeletion: @Sendable (SubmoduleDeletionRequest) async -> Bool = { request in await ConflictPrompts.deleteSubmodule(request) }
    var onChanged: (String) -> Void = { _ in }
    var onFinished: (Int) -> Void = { _ in }
    var onProgress: () -> Void = {}
    var onComparison: (ConflictBaseComparison) -> Void = { _ in }
    var onEdit: (String) -> Void = { _ in }
    var onSubmoduleReset: (GitRepository, String, @escaping () -> Void) -> Void = { _, _, _ in }
    var readConflicts: ((OperationCancellation) async throws -> ([ConflictEntry], Bool))?
    var executeResolution: (([ConflictEntry], ResolveChoice, OperationCancellation, @escaping @Sendable (GitOutputChunk) -> Void, @escaping @Sendable (ConflictResolutionProgress) -> Void) async throws -> String)?
    var onFileLog: ((String)->Void)?
    var onFileBlame: ((String,String)->Void)?
    var onFilePair: (([String])->Void)?
    var onFileSubmoduleLog: ((GitRepository)->Void)?
    var onFileUnified: ((Data,Bool,OperationCancellation) async throws -> Void)?
    var chooseFileApplication: () async -> URL? = {nil}
    var cancelFileChoice: () -> Void = {}
    var writeFileClipboard: (String)->Void = {text in NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}
    var revealFiles: ([URL])->Void = {NSWorkspace.shared.activateFileViewerSelecting($0)}
    var openFile: (URL,URL?) async throws -> Void = {url,application in
        if let application {
            try await withCheckedThrowingContinuation { (reply:CheckedContinuation<Void,Error>) in
                NSWorkspace.shared.open([url],withApplicationAt:application,configuration:NSWorkspace.OpenConfiguration()) {_,error in if let error {reply.resume(throwing:error)} else {reply.resume()}}
            }
        } else if !NSWorkspace.shared.open(url) {throw StatusFileActionFailure(message:"Could not open "+url.lastPathComponent+".")}
    }
    lazy var openFileEditor: (URL) async throws -> Void = { [weak self] url in
        guard let self else {throw OperationCancellationFailure.cancelled}
        try await withCheckedThrowingContinuation { (reply:CheckedContinuation<Void,Error>) in
            AlternativeEditor.open(url,preferences:self.preferences,permissions:self.access.map{[$0]} ?? []) {error in
                if let error {reply.resume(throwing:StatusFileActionFailure(message:error))} else {reply.resume()}
            }
        }
    }
    lazy var submoduleFileLog = SubmoduleWorkingLogSession(repository:repository,access:access,preferences:preferences)
    var readFileMenuConflicts: (([String],OperationCancellation) async throws -> [ConflictEntry])?
    var canInteract: Bool { active && !confirmingQuit && !handoffPending && externalAvailability() && !busy && !showingProgress && !hasQuestion && !hasChild }
    var canCancel: Bool { active && busy && !cancelling && !confirmingCancellation && !hasQuestion && !hasChild }
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], quick: ResolveChoice?, preferences: UserDefaults = .standard, commandOptions: ResolveCommandOptions? = nil) {
        reportColumns = preferences.integer(forKey:Self.reportColumnsKey+".Version") == 1 ? StatusListColumnSettings.load(from:preferences,key:Self.reportColumnsKey):Self.defaultReportColumns
        self.repository = repository; self.access = access; self.paths = paths; self.quick = quick; self.commandOptions = commandOptions; self.preferences = preferences; self.progress=FileOperationProgressState(preferences:preferences); progressPresentation = GitCommandPresentation(defaults: preferences)
    }
    func invalidate() {
        reportRefresh.retire();progress.retire();invalidateFileMenus();cancelFileChoice();submoduleFileLog.retire();retireMutationChild()
        droppedProviders = [];dropTask?.cancel()
        if busy { cancelled = true } else {saveActionLog()}; active = false; generation = UUID(); cancellation?.cancel(); refreshCancellation?.cancel(); pendingResolution = nil; reloadQueued = false; patch = nil
    }
    private func begin() -> OperationCancellation {
        let token = OperationCancellation(); cancellation = token; generation = UUID(); busy = true; error = nil
        Self.activeOperations += 1; return token
    }
    private func live(_ token: OperationCancellation) -> Bool { active && cancellation === token }
    private func finish(_ token: OperationCancellation) {
        Self.activeOperations -= 1
        if cancellation === token {
            cancellation = nil; busy = false; cancelling = false
            if showingProgress,!hasChild,let started=progressStarted {
                progress.finish(success:success,cancelled:cancelled,started:started)
                let completion=SubmoduleProgressCompletion(success:success,cancelled:cancelled,exitCode:nil,elapsed:Date().timeIntervalSince(started),preferences:preferences,showTimings:true)
                currentWork=completion.currentWork;percentage=100;completionRange=completion.append(to:&output);progressStarted=nil
                saveActionLog()
            }
            if active, silentAttempt, success, !cancelled { close(); return }
            finishAutomaticClose()
            if canReceiveFileDrop,!droppedProviders.isEmpty { startFileDrop(); return }
            if active, reloadQueued, !showingProgress, !hasChild, !hasQuestion { reloadQueued = false; load() }
        }
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func refresh(_ token: OperationCancellation) async throws {
        try checkAccess()
        let next: ([ConflictEntry], Bool)
        if let readConflicts { next = try await readConflicts(token) }
        else { next = try await (repository.conflicts(paths: paths, cancellation: token), repository.conflictIsRebase(cancellation: token)) }
        try token.check(); guard live(token) else { return }
        if quick == nil {
            let columns=Set(visibleReportColumns)
            let metadata=try await repository.statusListMetadata(paths:next.0.map(\.path),columns:columns,cancellation:token)
            let hasLFS=try await repository.hasLFS(cancellation:token)
            let statistics:[CommitFile]
            if !columns.isDisjoint(with:[.added,.removed]) {statistics=try await repository.workingTreeFiles(cancellation:token)} else {statistics=[]}
            let locks:[LFSLock]
            if hasLFS,reportColumns.visible.contains(.lfsOwner) {locks=try await repository.lfsLocks(cancellation:token)} else {locks=[]}
            try token.check();guard live(token) else{return}
            reportMetadata=metadata;reportHasLFS=hasLFS
            reportStatistics=GitPathMap(statistics.map{($0.path,$0)},uniquingKeysWith:{_,last in last})
            reportLFSOwners=GitPathMap(locks.map{($0.path,$0.owner)},uniquingKeysWith:{first,_ in first})
        }
        publishConflicts(next.0,rebase:next.1)
    }
    /// A managed presenter can start preparation before SwiftUI appears. That
    /// view attachment must not enqueue another read which replaces the quick
    /// Resolve confirmation's generation. Explicit later refreshes still load.
    func loadInitial() {
        guard active,!initialLoadStarted else{return}
        load()
    }
    func load() {
        guard active else { return }
        initialLoadStarted=true
        if commandOptions?.noQuestion == true { startUnreviewedProgress(); return }
        if busy || hasQuestion || hasChild || showingProgress { reloadQueued = true; return }
        invalidateFileMenus()
        let position=reportRefresh.begin(preferences:preferences,selectedIDs:selection)
        if !position.remember {selection=[];focusedFilePath=nil}
        let token = begin()
        Task {
            defer {reportRefresh.finish(position);finish(token);withExtendedLifetime(access) {}}
            do {
                try await refresh(token)
                await reportRefresh.restore(position,ids:sortedReportEntries.map(\.path))
                guard live(token), !token.isCancelled else { return }
                if let quick { guard !entries.isEmpty else { throw ResolveFailure.stale }; busy = false; request(quick, ids: GitPathSet(entries.map(\.path))) }
            } catch { if live(token), !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func startUnreviewedProgress() {
        CommandProgressContext.perform(commandProgressScope) { startUnreviewedProgressInCommandProgressScope() }
    }
    private func startUnreviewedProgressInCommandProgressScope() {
        guard active,!confirmingQuit,!handoffPending,externalAvailability(), !commandStarted, !busy, !hasQuestion, !hasChild else { return }
        commandStarted = true; closeAfterResolution = true
        let token = begin(); showingProgress = true; output = ""; success = false;cancelled=false;progressStarted=Date();progress.begin("Resolve");completionRange=nil
        autoClosePolicy = GitProgressAutoClose(preferences: preferences); onProgress()
        LocalGitCommandProgress.begin()
        Task {
            defer { LocalGitCommandProgress.end(); finish(token); withExtendedLifetime(access) {} }
            do {
                try checkAccess()
                // Source noquestion bypasses CResolveDlg's status population;
                // bare argv paths have no UNMERGED action bit and are skipped.
                let selected = try await repository.resolveCommandPaths(paths, cancellation: token)
                for path in selected { try token.check(); output += "Skipped: " + path + "\n";progress.append("Skipped",path,kind:.skipped);await Task.yield() }
                try token.check(); guard live(token) else { return }
                success = true; onFinished(0)
            } catch { if live(token) { cancelled = token.isCancelled; output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences);progress.append(cancelled ? "User cancelled":"Error",error.localizedDescription,kind:.error) } }
        }
    }
    func setFileChecked(_ path: String, value: Bool) {
        guard canInteract, entries.contains(where: { GitReferenceName.equal($0.path, path) }) else { return }
        let targets = selection.contains(path) ? selection.intersection(entries.map(\.path)) : GitPathSet([path])
        if value { checked.formUnion(targets) } else { checked.subtract(targets) }
    }
    func resolveChecked() { guard canInteract else { return }; closeAfterResolution = true; apply(sortedReportEntries.filter { checked.contains($0.path) }, using: .current) }
    func request(_ choice: ResolveChoice, ids values: some Sequence<String>) {
        let ids = GitPathSet(values)
        let selected = sortedReportEntries.filter { ids.contains($0.path) }
        guard canInteract, !selected.isEmpty else { return }
        closeAfterResolution = false; pendingResolution = (generation, selected, choice); confirm(choice, selected)
    }
    func rejectConfirmation() { pendingResolution = nil; if quick != nil { close() } else if reloadQueued { reloadQueued = false; load() } }
    func apply(_ selected: [ConflictEntry], using choice: ResolveChoice) {
        CommandProgressContext.perform(commandProgressScope) { applyInCommandProgressScope(selected, using: choice) }
    }
    private func applyInCommandProgressScope(_ selected: [ConflictEntry], using choice: ResolveChoice) {
        guard active,!confirmingQuit,!handoffPending,externalAvailability(), !busy, !hasQuestion, !hasChild else { return }
        if let pendingResolution {
            guard pendingResolution.0 == generation, pendingResolution.1 == selected, pendingResolution.2 == choice else { return }
        }
        pendingResolution = nil
        do { guard !selected.isEmpty else { throw ResolveFailure.selection }; try checkAccess() }
        catch { self.error = error.localizedDescription; return }
        invalidateFileMenus()
        ProgressActionLog.nextAttempt(self, savePrevious: showingProgress)
        silentAttempt = commandOptions?.silent == true && closeAfterResolution
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        let token = begin(); showingProgress = !silentAttempt; output = ""; success = false; cancelled = false; resolvedCount = 0; patch = nil
        autoClosePolicy = silentAttempt ? nil : GitProgressAutoClose(preferences: preferences)
        if showingProgress {progressStarted=Date();progress.begin("Resolve");completionRange=nil;onProgress()}; LocalGitCommandProgress.begin()
        Task {
            defer { LocalGitCommandProgress.end(); finish(token); withExtendedLifetime(access) {} }
            do {
                let (events,continuation)=AsyncStream<ConflictResolutionProgress>.makeStream()
                let operation=Task { [self] in
                    defer{continuation.finish()}
                    return try await LocalGitCommandProgress.stream(preferences:preferences,update:{ [weak self] state in guard let self,self.live(token) else{return};self.output=state.output},resultText:{$0}){ [self] emit in
                        if let executeResolution{return try await executeResolution(selected,choice,token,emit,{continuation.yield($0)})}
                        return try await repository.resolveConflicts(selected,using:choice,confirmSubmoduleDeletion:confirmSubmoduleDeletion,cancellation:token,onOutput:emit,onProgress:{continuation.yield($0)})
                    }
                }
                for await event in events {
                    guard live(token) else{continue};resolvedCount=max(resolvedCount,event.completed)
                    if busy{currentWork=event.path;percentage=event.total>0 ? event.completed*100/event.total:nil}
                    if event.finished,showingProgress{progress.append(event.skipped ? "Skip":"Resolved",event.path,kind:.file)}
                }
                let text=try await operation.value
                guard live(token) else { return }
                resolvedCount = selected.count
                // A cancellation arriving after Git settled must still refresh the
                // actual index, while suppressing success/Commit post actions.
                if token.isCancelled { cancelled = true } else { success = true }
                onChanged(text); if success { onFinished(selected.count) }
            } catch ResolveFailure.submoduleCheckout(let path) {
                guard live(token), !token.isCancelled else { return }
                do {
                    guard let entry = selected.first(where: { GitReferenceName.equal($0.path,path) }) else { throw ResolveFailure.stale }
                    let (root, revision) = try await repository.submoduleResetTarget(entry, using: choice, cancellation: token)
                    guard live(token), !token.isCancelled else { return }
                    // The retry retains the original stages and is fenced to this
                    // owner; closing/reloading cannot revive an old reset callback.
                    let ownerGeneration = generation; hasChild = true
                    onSubmoduleReset(GitRepository(root: root, executable: repository.executable), revision) { [weak self] in
                        guard let self, self.active, self.generation == ownerGeneration, self.hasChild, !self.busy else { return }
                        self.hasChild = false; self.apply(selected, using: choice)
                    }
                } catch { if live(token) { output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences) } }
            } catch {
                guard live(token) else { return }
                cancelled = token.isCancelled || error is OperationCancellationFailure || error is GitCommandCancellationFailure || (error as? ResolveFailure).map { if case .cancelled = $0 { return true }; return false } == true
                output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences)
                if showingProgress{progress.append(cancelled ? "User cancelled":"Error",error.localizedDescription,kind:.error)}
                if cancelled { output = LocalGitCommandProgress.bounded(output + "\nResolution aborted. Earlier resolved items remain resolved.", preferences: preferences) }
                onChanged(output)
            }
            // Use a fresh read token after cancellation; retain ownership/count
            // until the refreshed conflict list has settled, including failures.
            guard live(token), !hasChild else { return }
            let refreshToken = OperationCancellation(); refreshCancellation = refreshToken
            defer { if refreshCancellation === refreshToken { refreshCancellation = nil } }
            do {
                let next = try await repository.conflicts(paths: paths, cancellation: refreshToken)
                guard live(token) else { return }
                let available = GitPathSet(next.map(\.path)); entries = next; checked.formIntersection(available); selection.formIntersection(available); reloadQueued = false
            } catch { if live(token) { output = LocalGitCommandProgress.bounded(output + "\nRefresh failed: " + error.localizedDescription, preferences: preferences) } }
            if live(token), token.isCancelled { cancelled = true; success = false }
            if live(token), silentAttempt, !success, !cancelled { error = output }
        }
    }
    func cancel() {
        if active,fileMutationActive,hasChild {cancelMutationChild();return}
        guard canCancel, let token = cancellation else { return }
        reportRefresh.cancel();droppedProviders = [];cancelFileChoice();submoduleFileLog.cancel()
        if !showingProgress || !preferences.bool(forKey: "ConfirmKillProcess") { cancelling = true; token.cancel();dropTask?.cancel(); refreshCancellation?.cancel(); return }
        confirmingCancellation = true; var answered = false
        confirmCancellation { [weak self] accepted in
            guard !answered, let self else { return }; answered = true; self.confirmingCancellation = false
            guard self.active else{return}
            if accepted, self.busy, self.cancellation === token { self.cancelling = true; token.cancel(); self.refreshCancellation?.cancel() }
            self.finishAutomaticClose()
        }
    }
    private func finishAutomaticClose() {
        guard active,!confirmingQuit,!handoffPending,externalAvailability(),showingProgress, !busy, !hasQuestion, !hasChild, !progressFileActionBusy,!confirmingCancellation, success, !cancelled,
              autoClosePolicy?.shouldClose(success: true, postActionCount: 1) == true else { return }
        closeProgress()
    }
    func closeProgress(commit: Bool = false) {
        CommandProgressContext.perform(commandProgressScope) { closeProgressInCommandProgressScope(commit: commit) }
    }
    private func closeProgressInCommandProgressScope(commit: Bool = false) {
        guard active,!confirmingQuit,!handoffPending,externalAvailability(), !busy, !confirmingCancellation, !hasQuestion, !hasChild,!progressFileActionBusy else { return }
        saveActionLog()
        if commit || quick != nil || commandOptions?.noQuestion == true || (success && closeAfterResolution) { close() }
        else { showingProgress = false; load() }
    }
    func dismissSubmoduleReset() { guard active, hasChild, !busy else { return }; hasChild = false; showingProgress = false; load() }
    var primaryActionRevision:UUID {fileMenuEpoch}
    var onPrimaryFileActivation:ConflictListPrimaryActivationSession.Launch?
    /// Shared working-list StartDiff; distinct from the stage-1 ancestor viewer.
    var onWorkingFileComparison:StatusListPrimaryActivationSession.Launch?
    var onWorkingFileUnifiedComparison:StatusListPrimaryActivationSession.Launch?
    var readWorkingComparisonStatus:(([String],OperationCancellation) async throws -> [StatusEntry])?
    var confirmPrimaryFileActivation:((Int) async -> Bool)?
    weak var primaryWindow:NSWindow?
    @Published private(set) var primaryActivationPending=false
    func activatePrimaryFile(_ receipt:StatusListPrimaryActionReceipt) {
        guard receipt.revision==primaryActionRevision,canInteract else{return}
        if onPrimaryFileActivation != nil {activatePrimaryFiles(receipt.paths,alternate:receipt.alternate);return}
        let snapshot=fileMenu([receipt.path],markedPath:receipt.path)
        guard snapshot.entries.count==1 else{return}
        ComparisonToolInvocation.$alternate.withValue(receipt.alternate) {
            withFileMenu(snapshot) {editOrCompare([receipt.path])}
        }
    }
    func activatePrimaryFiles(_ paths:[String],alternate:Bool,expectedEntries:[ConflictEntry]?=nil) {
        guard canInteract,!paths.isEmpty,let parent=primaryWindow,parent.attachedSheet==nil,NSApp.modalWindow==nil else{return}
        let ids=GitPathSet(paths),ordered=sortedReportEntries.filter{ids.contains($0.path)}
        guard ids.count==paths.count,ordered.count==paths.count else{return}
        if let expectedEntries {
            let accepted=expectedEntries.filter{ids.contains($0.path)}
            guard accepted==ordered else{return}
        }
        guard let launch=onPrimaryFileActivation else {
            if ordered.count==1,let entry=ordered.first {ComparisonToolInvocation.$alternate.withValue(alternate){onEdit(entry.path)}}
            return
        }
        let intent=StatusListPrimaryActivationSession.Intent(repository:repository,preferences:preferences,window:parent,amendToParent:false,alternateTool:alternate)
        let acceptedRebase=rebase,selection=self.selection
        let token=begin(),epoch=fileMenuEpoch,ownerGeneration=generation
        let records=entries.enumerated().compactMap{ids.contains($0.element.path) ? ($0.offset,$0.element):nil}
        primaryActivationPending=true
        Task { @MainActor [self] in
            defer {primaryActivationPending=false;finish(token);withExtendedLifetime(access){}}
            let current:()->Bool = {[weak self,weak parent] in
                guard let self,let parent,self.primaryWindow === parent,self.active,!self.confirmingQuit,!self.handoffPending,
                      self.live(token),!token.isCancelled,self.generation==ownerGeneration,self.fileMenuEpoch==epoch,
                      self.selection==selection,self.rebase==acceptedRebase,!self.hasQuestion,!self.hasChild,
                      !self.showingProgress,self.externalAvailability() else{return false}
                return records.count==ordered.count && records.allSatisfy{self.entries.indices.contains($0.0) && self.entries[$0.0]==$0.1}
            }
            do {
                try checkAccess()
                try await ConflictListPrimaryActivationSession.run(entries:ordered,intent:intent,isRebase:acceptedRebase,cancellation:token,ownerIsCurrent:current,confirmation:confirmPrimaryFileActivation,launch:launch)
            } catch {if current() {self.error=error.localizedDescription}}
        }
    }
    private func validateWorkingComparison(_ plan:StatusListPrimaryActivation,cancellation token:OperationCancellation)async throws {
        try token.check();guard plan.ownerIsCurrent(),let expected=plan.expectedConflicts else{throw ResolveFailure.stale}
        let fresh=try await plan.repository.conflicts(paths:expected.map(\.path),cancellation:token)
        let lookup=GitPathMap(uniqueKeysWithValues:fresh.map{($0.path,$0)})
        guard fresh.count==expected.count,expected.allSatisfy({lookup[$0.path]==$0}),
              try await plan.repository.conflictIsRebase(cancellation:token)==plan.isRebase else{throw ResolveFailure.stale}
        try token.check();guard plan.ownerIsCurrent() else{throw ResolveFailure.stale}
    }
    private func activateWorkingComparison(_ paths:[String],alternate:Bool,expectedEntries:[ConflictEntry]?=nil,unified:Bool=false) {
        guard canInteract,!primaryActivationPending,!paths.isEmpty,let parent=primaryWindow,
              parent.attachedSheet==nil,NSApp.modalWindow==nil else{return}
        let launch:StatusListPrimaryActivationSession.Launch
        if let configured=unified ? onWorkingFileUnifiedComparison:onWorkingFileComparison {launch=configured}
        else if unified,let present=onFileUnified {
            launch={plan,token in
                var bytes=Data()
                for action in plan.actions {
                    try await self.validateWorkingComparison(plan,cancellation:token)
                    let base:String
                    switch plan.base {
                    case .revision(let oid):base=oid
                    case .emptyTree,.workingTree:throw RevisionComparisonFailure.range
                    }
                    let part=try await plan.repository.unifiedDiffData(arguments:["diff","--stat","-p","--no-ext-diff","--no-textconv","--no-color","--end-of-options",base,"--",action.file.entry.path],cancellation:token,backend:plan.repository.libgit2Configuration)
                    try await self.validateWorkingComparison(plan,cancellation:token);bytes.append(part)
                }
                try await self.validateWorkingComparison(plan,cancellation:token)
                try await present(bytes,plan.alternateTool,token)
            }
        } else{return}
        let ids=GitPathSet(paths),ordered=sortedReportEntries.filter{ids.contains($0.path)}
        guard ids.count==paths.count,ordered.count==paths.count,expectedEntries.map({$0==ordered}) ?? true else{return}
        let intent=StatusListPrimaryActivationSession.Intent(repository:repository,preferences:preferences,window:parent,amendToParent:false,alternateTool:alternate)
        let acceptedRebase=rebase,acceptedSelection=selection,sort=reportSort,ascending=reportAscending
        let records=entries.enumerated().compactMap{ids.contains($0.element.path) ? ($0.offset,$0.element):nil}
        let token=begin(),epoch=fileMenuEpoch,ownerGeneration=generation
        primaryActivationPending=true
        let current:()->Bool = {[weak self,weak parent] in
            guard let self,let parent,self.primaryWindow === parent,self.active,!self.confirmingQuit,!self.handoffPending,
                  self.live(token),!token.isCancelled,self.generation==ownerGeneration,self.fileMenuEpoch==epoch,
                  self.selection==acceptedSelection,self.rebase==acceptedRebase,self.reportSort==sort,self.reportAscending==ascending,
                  !self.hasQuestion,!self.hasChild,!self.showingProgress,self.externalAvailability(),intent.settingsCurrent else{return false}
            return records.count==ordered.count && records.allSatisfy{self.entries.indices.contains($0.0) && self.entries[$0.0]==$0.1}
        }
        Task { @MainActor [self] in
            let watcher=Task { @MainActor in
                while !Task.isCancelled {
                    if !current(){token.cancel();return}
                    do {try await Task.sleep(nanoseconds:10_000_000)} catch{return}
                }
            }
            defer{watcher.cancel();primaryActivationPending=false;finish(token);withExtendedLifetime(access){}}
            do {
                try checkAccess();try token.check()
                let paths=ordered.map(\.path)
                @MainActor func stages()async throws->[ConflictEntry] {
                    if let readFileMenuConflicts {return try await readFileMenuConflicts(paths,token)}
                    return try await intent.repository.conflicts(paths:paths,cancellation:token)
                }
                func exact(_ fresh:[ConflictEntry])->Bool {
                    let lookup=GitPathMap(uniqueKeysWithValues:fresh.map{($0.path,$0)})
                    return fresh.count==ordered.count && ordered.allSatisfy{lookup[$0.path]==$0}
                }
                guard exact(try await stages()),current() else{throw ResolveFailure.stale}
                let raw:[StatusEntry]
                if let readWorkingComparisonStatus {raw=try await readWorkingComparisonStatus(paths,token)}
                else {
                    let result=try await intent.repository.run(["status","--porcelain=v1","-z","--untracked-files=no",intent.repository.diffDetection.statusArgument,"--"]+paths,environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:token)
                    raw=StatusEntry.parse(result.stdout)
                }
                try token.check()
                guard current(),exact(try await stages()),try await intent.repository.conflictIsRebase(cancellation:token)==acceptedRebase else{throw ResolveFailure.stale}
                let lookup=GitPathMap(uniqueKeysWithValues:raw.map{($0.path,$0)})
                let rows=ordered.compactMap {entry->StatusListPrimaryFile? in
                    guard let status=lookup[entry.path],status.state == .conflicted else{return nil}
                    return StatusListPrimaryFile(entry:status,isDirectory:entry.isSubmodule,isSubmodule:entry.isSubmodule)
                }
                guard rows.count==ordered.count,current() else{throw ResolveFailure.stale}
                let confirmation:((Int) async -> Bool)?=unified ? {_ in true}:confirmPrimaryFileActivation
                try await StatusListPrimaryActivationSession.run(rows:rows,intent:intent,cancellation:token,ownerIsCurrent:current,
                    confirmation:confirmation,expectedConflicts:ordered,expectedRebase:acceptedRebase,mode:.compareWithBase,launch:launch)
            } catch {if current(){self.error=error.localizedDescription}}
        }
    }
    func editOrCompare(_ values: some Sequence<String>) {
        let ids = GitPathSet(values)
        guard canInteract else { return }
        if ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) { onEdit(entry.path) }
        else { compare(ids) }
    }
    func compare(_ values: some Sequence<String>) {
        if onWorkingFileComparison != nil {
            activateWorkingComparison(Array(values),alternate:ComparisonToolInvocation.capture)
        } else {viewConflictBase(values)}
    }
    /// Preserve explicit access to the ancestor/stage-1 document. A shared
    /// status-list "Compare with base" command instead means HEAD → working.
    func viewConflictBase(_ values: some Sequence<String>) {
        let ids = GitPathSet(values)
        guard canInteract, !ids.isEmpty else { return }
        let selected = entries.filter { ids.contains($0.path) }; guard !selected.isEmpty else { return }
        let token = begin()
        Task {
            defer { finish(token); withExtendedLifetime(access) {} }
            do {
                let fresh = try await repository.conflicts(paths: selected.map(\.path), cancellation: token)
                guard fresh == selected else { throw ResolveFailure.stale }
                if selected.count == 1, !selected[0].isSubmodule, selected[0].stages.contains(where: { $0.number == 1 }) {
                    let prepared = try await repository.conflictBaseComparison(selected[0], cancellation: token)
                    guard live(token), !token.isCancelled else { return }; onComparison(prepared); return
                }
                let text = try await repository.run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--base", "--"] + selected.map(\.path), cancellation: token).text
                guard try await repository.conflicts(paths: selected.map(\.path), cancellation: token) == selected else { throw ResolveFailure.stale }
                guard live(token), !token.isCancelled else { return }; patch = text
            } catch { if live(token), !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct ResolveDialog: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: ResolveWindowModel
    let commit: () -> Void
    var body: some View {
        Group {
            if model.showingProgress {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.busy ? "Resolving selected conflicts…" : model.success ? "Resolved \(model.resolvedCount) files." : model.cancelled ? "Resolution aborted. Earlier resolved items remain resolved." : "Resolution failed.").font(.headline)
                    FileOperationProgressTable(state:model.progress,icon:.resolveBackdrop,available:model.progressActionsAvailable,repository:model.repository.root,keyboardAvailable:model.progressKeyboardAvailable,actionAvailability:{model.progressActionsAvailable},keyboardAvailability:{model.progressKeyboardAvailable},perform:model.onProgressFileAction)
                    if !model.output.isEmpty{SubmoduleProgressOutputView(text:model.output,completed:!model.busy,success:model.success,preferences:model.preferences).frame(height:90)}
                    Text("Reminder: Commit your change after resolve").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if model.busy { LocalGitProgressIndicator(percentage: model.percentage, animate: model.progressPresentation.animateActivity); Text(model.cancelling ? "Cancelling…" : model.currentWork).font(.caption) }
                        Spacer()
                        if model.busy { Button("Cancel") { model.cancel() }.disabled(!model.canCancel) }
                        else if model.hasChild { Button("Back") { model.dismissSubmoduleReset() } }
                        else {
                            if model.success { Button { commit() } label: { CommandLabel(title: "Commit…", icon: .commit) }.disabled(!model.progressActionsAvailable) }
                            Button(model.quick == nil && model.commandOptions?.noQuestion != true && (!model.success || !model.closeAfterResolution) ? "Back" : "Close") { model.closeProgress() }.keyboardShortcut(.defaultAction).disabled(model.hasQuestion || model.confirmingCancellation || model.progressFileActionBusy || model.confirmingQuit || model.handoffPending)
                        }
                    }
                }.padding(16)
            } else if model.quick != nil {
                HStack(spacing: 16) { GitCommandActivity(animate: model.progressPresentation.animateActivity); Text(model.busy ? "Resolving selected conflicts…" : "Review the selected resolution.") }.padding(20)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ResolveConflictReport(model:model)
                    HStack {
                        SelectionAllCheckbox(checked: model.checked.count, total: model.entries.count, checkedCount: { model.checked.count }) { model.checked = $0 ? GitPathSet(model.entries.map(\.path)) : [] }.fixedSize().disabled(!model.canInteract)
                        Spacer()
                        Text("Reminder: Commit your change after resolve").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity);if model.readingDrops {Text("Reading dropped files…").font(.caption)} else if !model.fileMutationTitle.isEmpty {Text(model.fileMutationTitle).font(.caption)} }
                        Spacer()
                        Button("OK") { model.resolveChecked() }.disabled(model.checked.isEmpty || !model.canInteract).keyboardShortcut(.defaultAction)
                        Button(model.busy ? "Cancel read" : "Cancel") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction)
                        Button { TurtleGitHelp.show(.resolve) } label: { CommandLabel(title: "Help", icon: .help) }
                    }
                }.padding(12)
                .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil) { model.receiveFileDrop($0) }
            }
        }.onAppear { model.loadInitial() }
        .alert("Could not resolve conflicts", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil; if model.quick != nil || model.silentAttempt { model.close() } }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(get: { model.patch != nil }, set: { if !$0 { model.patch = nil } })) {
            VStack { Text("Compare with base").font(.headline); OutputView(text: model.patch ?? "").frame(minWidth: 850, minHeight: 520); Button("Close") { model.patch = nil }.keyboardShortcut(.cancelAction) }.padding(12)
        }
    }
}
struct ResolveSelectionMenu: View {
    let paths: [String]
    var rebase = false
    var canEdit = false
    let action: (RepositoryAction, [String]) -> Void
    var body: some View {
        if canEdit { Button { action(.editConflict, paths) } label: { CommandLabel(title: "Edit conflict…", icon: .editConflict) } }
        Button { action(.resolveCurrent, paths) } label: { CommandLabel(title: "Resolved", icon: .resolve) }.disabled(paths.isEmpty)
        Button { action(.resolveTheirs, paths) } label: { CommandLabel(title: rebase ? "Resolve using commit being replayed" : "Resolve conflict using ‘theirs’", icon: .resolve) }.disabled(paths.isEmpty)
        Button { action(.resolveMine, paths) } label: { CommandLabel(title: rebase ? "Resolve using branch being rebased onto" : "Resolve conflict using ‘mine’", icon: .resolve) }.disabled(paths.isEmpty)
    }
}

/// Only explicit conflict-list callbacks are optional. Actual resolution,
/// replay state, repository notifications and filesystem observers stay live.
enum ConflictListRefreshPolicy {
    static func perform(preferences:UserDefaults, _ refresh:()->Void) {
        if ((preferences.object(forKey:"RefreshFileListAfterResolvingConflict") as? NSNumber)?.uint32Value ?? 1) == 1 { refresh() }
    }
}

extension ResolveWindowModel {
    var canReceiveFileDrop:Bool { active && !confirmingQuit && !handoffPending && externalAvailability() && quick == nil && !showingProgress && !fileMutationActive && !hasQuestion && !hasChild && !cancelling && !confirmingCancellation }
    @discardableResult func receiveFileDrop(_ providers:[NSItemProvider])->Bool {
        guard canReceiveFileDrop,!providers.isEmpty,providers.allSatisfy({$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)}) else {return false}
        droppedProviders.append(contentsOf:providers)
        if !busy {startFileDrop()}
        return true
    }
    private func dropCheck(_ token:OperationCancellation)throws {
        try token.check();guard live(token),readingDrops,!Task.isCancelled else {throw OperationCancellationFailure.cancelled}
    }
    private func publishConflicts(_ next:[ConflictEntry],rebase:Bool,dropped:[WorkingFileDropItem] = []) {
        let prior = GitPathSet(entries.map(\.path)),available = GitPathSet(next.map(\.path))
        var checks = loaded ? checked.intersection(available).union(available.subtracting(prior)) : available
        for path in available where dropped.contains(where:{item in
            item.path == "." || path.utf8.elementsEqual(item.path.utf8) || item.directory && path.utf8.starts(with:(item.path+"/").utf8)
        }) {checks.insert(path)}
        entries = next;self.rebase = rebase;checked = checks;loaded = true;selection.formIntersection(available)
    }
    private func startFileDrop() {
        guard canReceiveFileDrop,!busy,!droppedProviders.isEmpty else {return}
        invalidateFileMenus()
        let token = begin();readingDrops = true
        dropTask = Task {
            defer {dropTask = nil;readingDrops = false;finish(token);withExtendedLifetime(access) {}}
            do {
                try checkAccess()
                var urls:[URL] = []
                while true {
                    let providers = droppedProviders;droppedProviders = []
                    for provider in providers {
                        try dropCheck(token);urls.append(try await readDroppedURL(provider));try dropCheck(token)
                    }
                    // ResolveDlg's REFRESHTIMER coalesces drops for 200 ms and
                    // waits for the current status reader before replacing rows.
                    try await Task.sleep(nanoseconds:200_000_000);try dropCheck(token)
                    if !droppedProviders.isEmpty {continue}
                    let items = try await repository.resolveWorkingFileDrops(urls,cancellation:token);try dropCheck(token)
                    if !droppedProviders.isEmpty {continue}
                    guard !items.isEmpty else {return}
                    var scope = paths
                    if items.contains(where:{$0.path == "."}) {scope = []}
                    else if !scope.isEmpty {
                        for item in items where !scope.contains(where:{item.path.utf8.elementsEqual($0.utf8) || item.path.utf8.starts(with:($0+"/").utf8)}) {scope.append(item.path)}
                    }
                    let next:([ConflictEntry],Bool)
                    if let readDroppedConflicts {next = try await readDroppedConflicts(scope,token)}
                    else {next = try await (repository.conflicts(paths:scope,cancellation:token),repository.conflictIsRebase(cancellation:token))}
                    try dropCheck(token)
                    if !droppedProviders.isEmpty {continue}
                    paths = scope;publishConflicts(next.0,rebase:next.1,dropped:items);reloadQueued = false
                    return
                }
            } catch {if active,!token.isCancelled,!Task.isCancelled {self.error = error.localizedDescription}}
        }
    }
}

@MainActor private final class ResolveCommandWindow:NSWindow {
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        if let table=firstResponder as? AddNativeTable,table.performSelectedReturn(event) {return true}
        guard let owner = delegate as? ResolveWindowController else {return super.performKeyEquivalent(with:event)}
        if owner.performCommandKey(event) {return true};return super.performKeyEquivalent(with:event)
    }
    override func keyDown(with event:NSEvent) {
        if (delegate as? ResolveWindowController)?.performCommandKey(event) != true {super.keyDown(with:event)}
    }
}
extension ResolveWindowController {
    @discardableResult func performCommandKey(_ event:NSEvent)->Bool {
        guard !retired,let window,commandKeyWindow() === window,event.windowNumber == window.windowNumber else {return false}
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        let refresh = event.keyCode == 96 && flags.isEmpty
        let accept = [36,76].contains(event.keyCode) && (flags == .control || flags == .command)
        let view = window.firstResponder as? NSView
        let table = view as? NSTableView ?? view?.enclosingScrollView?.documentView as? NSTableView
        let copy = table != nil && (view as? NSTextView)?.isFieldEditor != true && event.charactersIgnoringModifiers?.lowercased() == "c" && (flags == .command || flags == [.command,.shift])
        guard refresh || accept || copy else {return false}
        guard model.canInteract,window.attachedSheet == nil else {return true}
        if copy {model.copyFileMenu(model.fileMenu(model.selection),copy:flags.contains(.shift) ? .pathsAndStatus:.relativePaths)}
        else if refresh {model.load()}
        else if !model.checked.isEmpty {model.resolveChecked()}
        return true
    }
}

enum ResolveFileCommand:String,CaseIterable {
    case compareBase,unified,compareTwo,revert,log,submoduleLog,blame,editor,open,openWith,reveal,delete
    var title:String {
        switch self {
        case .revert:return "Revert…";case .delete:return "Delete"
        case .compareBase:return "Compare with base";case .unified:return "Show changes as unified diff"
        case .compareTwo:return StatusFileCommand.compareTwo.rawValue;case .log:return StatusFileCommand.log.rawValue
        case .submoduleLog:return StatusFileCommand.submoduleLog.rawValue;case .blame:return StatusFileCommand.blame.rawValue
        case .editor:return StatusFileCommand.editor.rawValue;case .open:return StatusFileCommand.open.rawValue
        case .openWith:return StatusFileCommand.openWith.rawValue;case .reveal:return StatusFileCommand.reveal.rawValue
        }
    }
    var icon:MenuIcon {
        switch self {
        case .revert:return .revert;case .delete:return .remove
        case .compareBase,.compareTwo:return .compare;case .unified:return .unifiedDiff
        case .log,.submoduleLog:return .log;case .blame:return .blame;case .editor:return .editor
        case .open,.openWith:return .open;case .reveal:return .explore
        }
    }
}
enum ResolveClipboardChoice:String,CaseIterable {
    case full = "Full paths",relative = "Relative paths",names = "File/folder names",extensions = "Extensions",all = "Copy all information to clipboard"
    var copy:StatusListCopy {switch self {case .full:return .fullPaths;case .relative:return .relativePaths;case .names:return .names;case .extensions:return .column(.fileExtension);case .all:return .all}}
}
struct ResolveFileMenuSnapshot {
    let id = UUID()
    let epoch:UUID
    let entries:[ConflictEntry]
    let commands:[ResolveFileCommand]
    let alternate:Bool
    let mark:String
    let permanently:Bool
    var paths:[String] {entries.map(\.path)}
}
extension ResolveWindowModel {
    private func invalidateFileMenus() {fileMenuEpoch = UUID();usedFileMenus = []}
    func fileMenu(_ values:some Sequence<String>,markedPath:String? = nil,permanently:Bool? = nil)->ResolveFileMenuSnapshot {
        let ids = GitPathSet(values)
        let selected = sortedReportEntries.filter{ids.contains($0.path)}
        let ordinary = selected.allSatisfy{!$0.isSubmodule}
        func exists(_ entry:ConflictEntry)->Bool {
            let type = (try? FileManager.default.attributesOfItem(atPath:repository.root.appendingPathComponent(entry.path).path)[.type]) as? FileAttributeType
            return type == .typeRegular || type == .typeSymbolicLink
        }
        var commands:[ResolveFileCommand] = []
        if !selected.isEmpty,ordinary {commands += [.compareBase,.unified]}
        if selected.count == 2,ordinary,selected.allSatisfy(exists) {commands.append(.compareTwo)}
        if !selected.isEmpty {commands.append(.revert)}
        if selected.count == 1,let entry = selected.first {
            commands.append(.log)
            if entry.isSubmodule {commands.append(.submoduleLog)}
            else {
                if exists(entry),entry.stages.contains(where:{$0.number == 1}),entry.stages.contains(where:{$0.number == 2}) {commands.append(.blame)}
                if exists(entry) {commands += [.editor,.open,.openWith]}
            }
            commands.append(.reveal)
        }
        let mark = (markedPath ?? focusedFilePath).flatMap {value in selected.contains(where:{$0.path.utf8.elementsEqual(value.utf8)}) ? value:nil} ?? selected.first?.path ?? ""
        if !mark.isEmpty,let location = try? fileLocation(mark) {
            var info = stat()
            if lstat(location.path,&info) != 0,errno == ENOENT {commands.append(.delete)}
        }
        return ResolveFileMenuSnapshot(epoch:fileMenuEpoch,entries:selected,commands:commands,alternate:ComparisonToolInvocation.capture,mark:mark,permanently:permanently ?? NSEvent.modifierFlags.contains(.shift))
    }
    func captureComparisonOwner(paths:[String])->()->Bool {
        let requested=GitPathSet(paths),epoch=fileMenuEpoch,ownerGeneration=generation,selected=selection
        let records=entries.enumerated().compactMap {index,entry in requested.contains(entry.path) ? (index,entry):nil}
        let request=cancellation
        let complete = !requested.isEmpty && records.count==requested.count
        return { [weak self] in
            guard let self,complete,self.active,!self.confirmingQuit,!self.handoffPending,!self.hasQuestion,!self.hasChild,
                !self.showingProgress,!self.confirmingCancellation,self.fileMenuEpoch==epoch,self.generation==ownerGeneration,
                self.selection==selected,request?.isCancelled != true else{return false}
            guard !self.busy || request != nil && self.cancellation === request else{return false}
            return records.allSatisfy {index,entry in self.entries.indices.contains(index) && self.entries[index]==entry}
        }
    }
    private func acceptsFileMenu(_ menu:ResolveFileMenuSnapshot,during token:OperationCancellation? = nil)->Bool {
        active && (token.map{live($0) && !$0.isCancelled} ?? (canInteract && !usedFileMenus.contains(menu.id))) && menu.epoch == fileMenuEpoch && !menu.entries.isEmpty && menu.entries.allSatisfy{entries.contains($0)}
    }
    func canFileCommand(_ command:ResolveFileCommand,menu:ResolveFileMenuSnapshot)->Bool {
        guard acceptsFileMenu(menu),menu.commands.contains(command) else {return false}
        switch command {
        case .log:return onFileLog != nil;case .blame:return onFileBlame != nil
        case .submoduleLog:return onFileSubmoduleLog != nil;case .compareTwo:return onFilePair != nil
        case .unified:return onFileUnified != nil
        default:return true
        }
    }
    func withFileMenu(_ menu:ResolveFileMenuSnapshot, action:()->Void) {
        guard acceptsFileMenu(menu) else {return};usedFileMenus.insert(menu.id);action()
    }
    func copyFileMenu(_ menu:ResolveFileMenuSnapshot,copy:StatusListCopy) {
        let columns=visibleReportColumns
        let metadata=reportMetadata,statistics=reportStatistics,owners=reportLFSOwners
        withFileMenu(menu) {
            let selected:[StatusListColumn]
            switch copy {case .all:selected=columns;case .column(let column):selected=[column];case .pathsAndStatus:selected=[.path,.status];default:selected=[]}
            let heading=StatusListClipboard.heading(copy:copy,columns:selected,label:FileListLabels.caption)
            let text=heading+menu.entries.map {entry in
                switch copy {
                case .fullPaths:return repository.root.appendingPathComponent(entry.path).path
                case .relativePaths:return entry.path
                case .names:return (entry.path as NSString).lastPathComponent
                default:return selected.map{reportText(entry,column:$0,metadata:metadata,statistics:statistics,owners:owners)}.joined(separator:"\t")
                }
            }.joined(separator:"\n")+"\n"
            writeFileClipboard(text)
        }
    }
    private func validateFileMenu(_ menu:ResolveFileMenuSnapshot,token:OperationCancellation) async throws {
        try checkAccess();try token.check()
        guard acceptsFileMenu(menu,during:token) else {throw ResolveFailure.stale}
        let fresh:[ConflictEntry]
        if let readFileMenuConflicts {fresh = try await readFileMenuConflicts(menu.paths,token)}
        else {fresh = try await repository.conflicts(paths:menu.paths,cancellation:token)}
        try token.check()
        guard acceptsFileMenu(menu,during:token),fresh == menu.entries else {throw ResolveFailure.stale}
    }
    private func fileLocation(_ path:String)throws->URL {
        _ = try RemovalRequest(paths:[path],keepLocal:true)
        let value = repository.root.appendingPathComponent(path).standardizedFileURL
        guard RepositoryAccessLease.pathIsContained(value.deletingLastPathComponent(),by:repository.root) else {throw ResolveFailure.outsideWorkingTree}
        return value
    }
    func fileCommand(_ command:ResolveFileCommand,menu:ResolveFileMenuSnapshot) {
        guard canFileCommand(command,menu:menu) else {return}
        if command == .revert || command == .delete {mutateFileMenu(command,menu:menu);return}
        usedFileMenus.insert(menu.id)
        if command == .compareBase {
            if onWorkingFileComparison != nil {activateWorkingComparison(menu.paths,alternate:menu.alternate,expectedEntries:menu.entries)}
            else {ComparisonToolInvocation.$alternate.withValue(menu.alternate){viewConflictBase(menu.paths)}}
            return
        }
        if command == .unified {
            activateWorkingComparison(menu.paths,alternate:menu.alternate,expectedEntries:menu.entries,unified:true)
            return
        }
        let alternate = menu.alternate,token = begin()
        Task {
            defer {finish(token);withExtendedLifetime(access) {}}
            do {
                try await validateFileMenu(menu,token:token)
                try await ComparisonToolInvocation.$alternate.withValue(alternate) {
                    switch command {
                    case .compareBase,.revert,.delete:break
                    case .log:onFileLog?(menu.paths[0])
                    case .blame:
                        let hash = try await repository.run(["rev-parse","--verify","HEAD^{commit}"],cancellation:token).text.trimmingCharacters(in:.newlines)
                        try await validateFileMenu(menu,token:token);onFileBlame?(menu.paths[0],hash)
                    case .compareTwo:onFilePair?(menu.paths)
                    case .submoduleLog:
                        let child = try await submoduleFileLog.load(menu.paths[0],cancellation:token)
                        try await validateFileMenu(menu,token:token);onFileSubmoduleLog?(child)
                    case .reveal:
                        var value = try fileLocation(menu.paths[0])
                        while !FileManager.default.fileExists(atPath:value.path),value.path != repository.root.path {value.deleteLastPathComponent()}
                        revealFiles([value])
                    case .editor,.open,.openWith:
                        let application = command == .openWith ? await chooseFileApplication():nil
                        guard command != .openWith || application != nil else {return}
                        try await validateFileMenu(menu,token:token)
                        let value = try fileLocation(menu.paths[0]),type = try FileManager.default.attributesOfItem(atPath:value.path)[.type] as? FileAttributeType
                        guard type == .typeRegular || type == .typeSymbolicLink else {throw WorkingFileRestoreFailure.unsupported}
                        let grant = application.map{RepositoryAccessLease(url:$0)};defer {withExtendedLifetime(grant) {}}
                        if GitRuntime.isAppStoreBuild,application != nil,grant?.hasSecurityScope != true {throw RepositoryAccessFailure.securityScopeUnavailable}
                        if command == .editor {try await openFileEditor(value)} else {try await openFile(value,application)}
                    case .unified:break
                    }
                }
            } catch {if active,!token.isCancelled {self.error = error.localizedDescription}}
        }
    }
}

extension ResolveWindowModel {
    private func mutateFileMenu(_ command:ResolveFileCommand,menu:ResolveFileMenuSnapshot) {
        guard canFileCommand(command,menu:menu) else {return}
        usedFileMenus.insert(menu.id)
        let policy=WorkingFileRevertPolicy.load(from:preferences)
        pendingFileRevertPolicy=command == .revert ? policy:nil
        let token = begin();fileMutationActive = true;fileMutationTitle = command == .revert ? "Preparing Revert…":"Deleting selected paths…"
        Task {
            var refresh = false
            defer {pendingFileRevertPolicy=nil;fileMutationActive = false;fileMutationTitle = "";finish(token);withExtendedLifetime(access) {}}
            do {
                try await validateFileMenu(menu,token:token)
                let head = command == .revert ? try await repository.run(["rev-parse","--verify","HEAD^{commit}"],cancellation:token).stdout:Data()
                let rows = try await repository.conflictWorkingFileSelection(menu.entries,cancellation:token)
                try await validateFileMenu(menu,token:token)
                if command == .delete {
                    let message = "Delete \(menu.entries.count) selected path(s) and remove their index entries?"+(menu.permanently ? " This cannot be undone.":" Existing working files will move to Trash.")
                    guard await confirmFileMutation(menu.permanently ? "Permanently delete the selected paths?":"Move the selected paths to Trash?",message) else {return}
                    try await validateFileMenu(menu,token:token)
                    refresh = true
                    let result = try await repository.deleteConflictWorkingFiles(menu.entries,markedPath:menu.mark,permanently:menu.permanently,cancellation:token)
                    guard live(token),!token.isCancelled else {throw OperationCancellationFailure.cancelled}
                    deletionResult = result
                    onChanged("Deleted \(result.removedPaths.count) working file(s); removed \(result.removedIndexPaths.count) index entries.\n"+result.trashedFiles.map{"Moved to Trash: "+$0.path}.joined(separator:"\n"))
                } else {
                    let diff = try await repository.run(["diff","--no-ext-diff","--no-textconv","--name-status","-z","HEAD","--"]+menu.paths,cancellation:token).stdout
                    let modified = GitPathSet(CommitFile.parse(names:diff,statistics:Data()).filter{$0.action.hasPrefix("M")}.map(\.path))
                    if menu.entries.contains(where:{!$0.isSubmodule && modified.contains($0.path)}) {
                        guard await confirmFileMutation("Revert selected changes?","Revert \(menu.entries.count) selected conflicted file(s) to HEAD? "+WorkingFileRevertPresentation.confirmation(policy)) else {return}
                    }
                    try await validateFileMenu(menu,token:token)
                    guard try await repository.run(["rev-parse","--verify","HEAD^{commit}"],cancellation:token).stdout == head else {throw ResolveFailure.stale}
                    refresh = true
                    if let output = await presentFileRevert(rows,{ [self] child,first in
                        try child.check();guard live(token),!token.isCancelled else {throw OperationCancellationFailure.cancelled}
                        if first {try await validateFileMenu(menu,token:token)}
                        guard try await repository.run(["rev-parse","--verify","HEAD^{commit}"],cancellation:child).stdout == head else {throw ResolveFailure.stale}
                        try child.check()
                    }),active {onChanged(output)}
                }
            } catch {if active,!token.isCancelled {self.error = error.localizedDescription};if active,refresh {onChanged(error.localizedDescription)}}
            // Re-read actual stages after partial mutation/cancellation using its own
            // token, retaining operation ownership while the result settles.
            guard active,refresh else {return}
            let read = OperationCancellation();refreshCancellation = read
            defer {if refreshCancellation === read {refreshCancellation = nil}}
            do {
                let next = try await repository.conflicts(paths:paths,cancellation:read)
                guard active else {return};invalidateFileMenus();publishConflicts(next,rebase:rebase);reloadQueued = false
            } catch {if active {self.error = "Could not refresh conflicts after the operation. Press F5.\n"+error.localizedDescription}}
        }
    }
}

// ResolveDlg and ConflictSyncDlg share the report/menu entry contract while
// retaining their separate row models, action masks and operation ownership.
extension ResolveWindowModel {
    var availableReportColumns:Set<StatusListColumn> {Set(StatusListColumn.allCases.filter{$0 != .lfsOwner || reportHasLFS})}
    var visibleReportColumns:[StatusListColumn] {reportColumns.order.filter{reportColumns.visible.contains($0) && availableReportColumns.contains($0)}}
    var sortedReportEntries:[ConflictEntry] {
        entries.sorted {a,b in
            var result:ComparisonResult
            switch reportSort {
            case .fileSize:
                let x=reportMetadata[a.path]?.size ?? -1,y=reportMetadata[b.path]?.size ?? -1
                result=x<y ? .orderedAscending:x>y ? .orderedDescending:.orderedSame
            case .lastModified:result=(reportMetadata[a.path]?.modificationDate ?? .distantPast).compare(reportMetadata[b.path]?.modificationDate ?? .distantPast)
            case .added,.removed:
                let x=(reportSort == .added ? reportStatistics[a.path]?.added:reportStatistics[a.path]?.removed) ?? -1
                let y=(reportSort == .added ? reportStatistics[b.path]?.added:reportStatistics[b.path]?.removed) ?? -1
                result=x<y ? .orderedAscending:x>y ? .orderedDescending:.orderedSame
            default:result=reportText(a,column:reportSort).compare(reportText(b,column:reportSort),options:[.caseInsensitive,.numeric],locale:Locale(identifier:"en_US_POSIX"))
            }
            if result == .orderedSame {result=a.path.compare(b.path,options:[.caseInsensitive,.numeric],locale:Locale(identifier:"en_US_POSIX"))}
            if result == .orderedSame,!a.path.utf8.elementsEqual(b.path.utf8) {result=a.path.utf8.lexicographicallyPrecedes(b.path.utf8) ? .orderedAscending:.orderedDescending}
            return reportAscending ? result == .orderedAscending:result == .orderedDescending
        }
    }
    func reportText(_ entry:ConflictEntry,column:StatusListColumn)->String {reportText(entry,column:column,metadata:reportMetadata,statistics:reportStatistics,owners:reportLFSOwners)}
    private func reportText(_ entry:ConflictEntry,column:StatusListColumn,metadata:GitPathMap<StatusListMetadata>,statistics:GitPathMap<CommitFile>,owners:GitPathMap<String>)->String {
        switch column {
        case .path:return entry.path
        case .fileName:return (entry.path as NSString).lastPathComponent
        case .fileExtension:return StatusListClipboard.fileExtension(entry.path,isDirectory:entry.isSubmodule)
        case .status:return FileListLabels.caption("Conflicted")
        case .added:return statistics[entry.path]?.added.map(String.init) ?? "–"
        case .removed:return statistics[entry.path]?.removed.map(String.init) ?? "–"
        case .lastModified:return metadata[entry.path]?.dateText ?? "–"
        case .fileSize:return metadata[entry.path]?.sizeText ?? "–"
        case .lfsOwner:return owners[entry.path] ?? ""
        }
    }
    func sortReport(_ column:StatusListColumn,ascending:Bool) {
        guard canInteract,availableReportColumns.contains(column) else{return}
        invalidateFileMenus();reportSort=column;reportAscending=ascending
    }
    func saveReportLayout(_ order:[StatusListColumn],widths:[StatusListColumn:Double]) {
        guard canInteract else{return}
        let next=StatusListColumnSettings(visible:reportColumns.visible,order:order,widths:widths)
        guard next != reportColumns else{return};invalidateFileMenus();reportColumns=next;next.save(to:preferences,key:Self.reportColumnsKey)
    }
    func setReportColumn(_ column:StatusListColumn,visible:Bool) {
        guard canInteract,column != .path,availableReportColumns.contains(column) else{return}
        invalidateFileMenus()
        if visible {reportColumns.visible.insert(column)} else {reportColumns.visible.remove(column)}
        reportColumns.save(to:preferences,key:Self.reportColumnsKey)
        if visible,[StatusListColumn.added,.removed,.lastModified,.fileSize,.lfsOwner].contains(column) {load()}
    }
    func resetReportColumns(choose:@escaping () async->Bool) {
        guard canInteract else{return}
        let epoch=fileMenuEpoch
        hasQuestion=true;reportResetActive=true
        Task { [self] in
            let accepted=await choose()
            hasQuestion=false;reportResetActive=false
            guard accepted,canInteract,fileMenuEpoch==epoch else{return}
            invalidateFileMenus();reportColumns=Self.defaultReportColumns;reportColumns.save(to:preferences,key:Self.reportColumnsKey)
            reportSort = .path;reportAscending=true
        }
    }
    func reportMenu(_ paths:[String],mark:String?,column:StatusListColumn?)->NSMenu {
        let target=fileMenu(paths,markedPath:mark),menu=NSMenu()
        menu.autoenablesItems=false
        func item(_ title:String,_ icon:MenuIcon,enabled:Bool=true,_ action:@escaping()->Void) {menu.addItem(ConflictReportMenuItem(title,icon:icon,preferences:preferences,enabled:enabled,action:action))}
        if target.entries.count==1 {item("Edit conflict…",.editConflict){[weak self] in self?.withFileMenu(target){self?.editOrCompare(target.paths)}}}
        for (title,choice) in [("Resolved",ResolveChoice.current),(rebase ? "Resolve using commit being replayed":"Resolve conflict using ‘theirs’",.theirs),(rebase ? "Resolve using branch being rebased onto":"Resolve conflict using ‘mine’",.mine)] {
            item(title,.resolve,enabled:!target.entries.isEmpty){[weak self] in self?.withFileMenu(target){self?.request(choice,ids:target.paths)}}
        }
        menu.addItem(.separator())
        for command in target.commands {item(command.title,command.icon,enabled:canFileCommand(command,menu:target)){[weak self] in self?.fileCommand(command,menu:target)}}
        menu.addItem(.separator())
        let copy=NSMenu();copy.autoenablesItems=false
        for choice in ResolveClipboardChoice.allCases {copy.addItem(ConflictReportMenuItem(choice.rawValue,icon:.copy,preferences:preferences){[weak self] in self?.copyFileMenu(target,copy:choice.copy)})}
        if let column {
            copy.addItem(ConflictReportMenuItem(String(format:NSLocalizedString("Copy \"%@\" to clipboard",comment:""),FileListLabels.caption(column.rawValue)),localized:false,icon:.copy,preferences:preferences){[weak self] in self?.copyFileMenu(target,copy:.column(column))})
        }
        let parent=NSMenuItem(title:NSLocalizedString("Copy to clipboard",comment:""),action:nil,keyEquivalent:"");parent.image=MenuIcon.copy.contextImage(defaults:preferences);parent.submenu=copy;parent.isEnabled = !target.entries.isEmpty;menu.addItem(parent)
        return menu
    }
}

/// The callback retains an immutable row/column receipt; a menu item cannot
/// execute twice even if AppKit dispatches an accessibility and pointer action.
@MainActor final class ConflictReportMenuItem:NSMenuItem {
    private var callback:(()->Void)?
    var validate:()->Bool = {true}
    init(_ title:String,localized:Bool=true,icon:MenuIcon,preferences:UserDefaults,enabled:Bool=true,action:@escaping()->Void) {
        callback=action;super.init(title:localized ? NSLocalizedString(title,comment:""):title,action:nil,keyEquivalent:"")
        target=self;self.action=#selector(invoke);image=icon.contextImage(defaults:preferences);isEnabled=enabled
    }
    required init(coder:NSCoder){fatalError("init(coder:) is not supported")}
    @objc private func invoke(){guard isEnabled,validate(),let callback else{return};self.callback=nil;callback()}
}

struct ConflictReportRow {
    let path:String
    let text:[StatusListColumn:String]
    var checked:Bool?=nil
    var color:NSColor = .labelColor
    var tooltip:String?=nil
    var icon:MenuIcon = FileState.conflicted.icon
}

@MainActor final class ConflictReportNativeTable:AddNativeTable {
    var focusedRow:()->Int? = {nil}
    var focusMoved:(Int)->Void = {_ in}
    override func keyDown(with event:NSEvent) {
        let navigation=[125,126,115,119].contains(event.keyCode) && event.modifierFlags.intersection([.command,.control,.option]).isEmpty
        let anchor=focusedRow() ?? selectedRowIndexes.first ?? 0
        super.keyDown(with:event)
        guard navigation,numberOfRows>0 else{return}
        let target=event.keyCode==115 ? 0:event.keyCode==119 ? numberOfRows-1:min(numberOfRows-1,max(0,anchor+(event.keyCode==125 ? 1:-1)))
        if selectedRowIndexes.contains(target) {focusMoved(target)}
    }
}

/// Owned AppKit report avoids rebuilding headers as SwiftUI observes selection,
/// check state or text changes. The data model owns sorting and action validity.
@MainActor final class ConflictReportScrollView:NSScrollView {
    var didLayout:()->Void = {}
    override func layout() {super.layout();didLayout()}
}

struct ConflictReportTable:NSViewRepresentable {
    @AppStorage("LogFontForFileListCtrl") private var usesLogFont=false
    @AppStorage("LogFontName") private var fontName=MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize=MessageEditorFont.defaultSize
    @AppStorage("ShowListBackgroundImage") private var showsBackground=true
    @AppStorage("ShowAppContextMenuIcons") private var showsMenuIcons=true
    private var geometry:FileListUniformRowGeometry {FileListUniformRowGeometry.resolve(useLogFont:usesLogFont,name:fontName,size:fontSize)}
    let rows:[ConflictReportRow]
    let selection:GitPathSet
    let settings:StatusListColumnSettings
    let available:Set<StatusListColumn>
    let sort:StatusListColumn
    let ascending:Bool
    let enabled:Bool
    let preferences:UserDefaults
    var hasCheckboxes=false
    var checksEnabled=true
    var checkVerb="Resolve"
    var ownerRetired=false
    var focusedPath:String?
    let selectionChanged:(GitPathSet,String?)->Void
    let sortChanged:(StatusListColumn,Bool)->Void
    let layoutChanged:([StatusListColumn],[StatusListColumn:Double])->Void
    let columnChanged:(StatusListColumn,Bool)->Void
    let resetColumns:(@escaping () async->Bool)->Void
    let makeMenu:([String],String?,StatusListColumn?)->NSMenu
    let copySelection:([String],Bool)->Void
    let activate:(String,Bool)->Void
    var activateSelection:(([String],Bool)->Void)?=nil
    var checkChanged:((String,Bool)->Void)?=nil
    var captureDrag:(([String])->WorkingFileListDrag?)?=nil
    var configureRefresh:((any FileListRefreshClient)->Void)?=nil
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView {context.coordinator.make()}
    func updateNSView(_ view:NSScrollView,context:Context){context.coordinator.update(self)}
    static func dismantleNSView(_ view:NSScrollView,coordinator:Coordinator){coordinator.retire()}
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSMenuDelegate,FileListRefreshClient {
        var owner:ConflictReportTable
        let table:ConflictReportNativeTable
        private var updating=false,retired=false
        private var renderedRows:[ConflictReportRow]=[]
        private var renderedFont:NSFont?
        private var contextMark:String?,contextColumn:StatusListColumn?
        private var contextEpoch=UUID()
        private var storedPosition:(path:String?,offset:CGFloat,point:NSPoint,selection:GitPathSet)?
        private var restoreRequest:(ids:[Data],remember:Bool,reply:()->Void)?
        private var drag:WorkingFileListDrag?
        private var resetQuestion:(id:UUID,alert:NSAlert,parent:NSWindow,reply:(Bool)->Void)?
        private static var dragOwners:[ObjectIdentifier:Coordinator]=[:]
        private let fileMenu=NSMenu(),headerMenu=NSMenu()
        init(_ owner:ConflictReportTable){self.owner=owner;table=ConflictReportNativeTable(icon:.resolveBackdrop,defaults:owner.preferences)}
        func make()->NSScrollView {
            let scroll=ConflictReportScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.borderType = .bezelBorder
            scroll.didLayout={[weak self] in self?.finishPositionIfReady()}
            table.dataSource=self;table.delegate=self;table.allowsMultipleSelection=true;table.allowsColumnReordering=true;table.usesAlternatingRowBackgroundColors=true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.target=self;table.doubleAction=#selector(openSelected)
            fileMenu.delegate=self;fileMenu.autoenablesItems=false;headerMenu.delegate=self;headerMenu.autoenablesItems=false
            table.menu=fileMenu;table.headerView?.menu=headerMenu
            table.selectionMenuAvailable={[weak self] in self?.isAvailable == true}
            table.selectionMenuRow={[weak self] in guard let self,let mark=owner.focusedPath else{return nil};return renderedRows.firstIndex{GitReferenceName.equal($0.path,mark)}}
            table.contextSelection={[weak self] row,column in self?.prepareMenu(row,column:column)}
            table.focusedRow={[weak self] in guard let self,let path=owner.focusedPath else{return nil};return renderedRows.firstIndex{GitReferenceName.equal($0.path,path)}}
            table.focusMoved={[weak self] row in guard let self,isAvailable,renderedRows.indices.contains(row) else{return};owner.selectionChanged(GitPathSet(selectedPaths),renderedRows[row].path)}
            table.toggleChecks={[weak self] in self?.toggleChecks()}
            table.copySelection={[weak self] status in guard let self,isAvailable else{return};owner.copySelection(selectedPaths,status)}
            table.setDraggingSourceOperationMask([.copy,.move],forLocal:true);table.setDraggingSourceOperationMask([.copy,.move],forLocal:false)
            scroll.documentView=table;owner.configureRefresh?(self);update(owner);return scroll
        }
        private var isAvailable:Bool {!retired && owner.enabled && table.window?.attachedSheet == nil && NSApp.modalWindow == nil}
        private var selectedPaths:[String] {table.selectedRowIndexes.compactMap{renderedRows.indices.contains($0) ? renderedRows[$0].path:nil}}
        private func column(_ native:NSTableColumn)->StatusListColumn? {StatusListColumn(rawValue:native.identifier.rawValue)}
        func update(_ value:ConflictReportTable) {
            guard !retired else{return}
            if value.ownerRetired {retire();return}
            updating=true;defer{updating=false}
            let checksChanged=owner.enabled != value.enabled || owner.checksEnabled != value.checksEnabled || owner.checkVerb != value.checkVerb
            let contextChanged=owner.settings != value.settings || owner.available != value.available || owner.enabled != value.enabled || owner.sort != value.sort || owner.ascending != value.ascending || renderedRows.count != value.rows.count || zip(renderedRows,value.rows).contains{a,b in !a.path.utf8.elementsEqual(b.path.utf8) || a.text != b.text}
            owner=value;if contextChanged {contextEpoch=UUID()}
            table.activateSelectedReturn = value.activateSelection == nil ? nil : {[weak self] alternate in
                guard let self,self.isAvailable,self.table.numberOfRows==self.renderedRows.count else{return}
                self.owner.activateSelection?(self.selectedPaths,alternate)
            }
            let visible=value.settings.order.filter{value.settings.visible.contains($0) && value.available.contains($0)}
            let desired=(value.hasCheckboxes ? ["check"]:[])+value.settings.order.filter{value.available.contains($0)}.map(\.rawValue)
            for existing in table.tableColumns where !desired.contains(existing.identifier.rawValue) {table.removeTableColumn(existing)}
            for (index,id) in desired.enumerated() {
                let native=table.tableColumns.first{$0.identifier.rawValue==id} ?? {
                    let next=NSTableColumn(identifier:.init(id));next.minWidth=id=="check" ? 26:40;next.width=id=="check" ? 26:id==StatusListColumn.path.rawValue ? 420:110
                    if id=="check" {next.title="";next.maxWidth=26;next.resizingMask=[]} else {next.title=FileListLabels.caption(id);next.sortDescriptorPrototype=NSSortDescriptor(key:id,ascending:true)}
                    table.addTableColumn(next);return next
                }()
                if let column=column(native) {native.isHidden = !visible.contains(column);if let width=value.settings.widths[column] {native.width=width}}
                if let actual=table.tableColumns.firstIndex(of:native),actual != index {table.moveColumn(actual,toColumn:index)}
            }
            let descriptor=NSSortDescriptor(key:value.sort.rawValue,ascending:value.ascending)
            if table.sortDescriptors != [descriptor] {table.sortDescriptors=[descriptor]}
            let geometry=value.geometry
            let changed=renderedRows.count != value.rows.count || zip(renderedRows,value.rows).contains{a,b in !a.path.utf8.elementsEqual(b.path.utf8) || a.text != b.text || a.checked != b.checked || a.color != b.color || a.tooltip != b.tooltip || a.icon != b.icon} || table.rowHeight != geometry.rowHeight || renderedFont != geometry.font
            renderedRows=value.rows;renderedFont=geometry.font;table.rowHeight=geometry.rowHeight;table.isEnabled=value.enabled
            if changed {table.reloadData()}
            else if checksChanged,let checkColumn=table.tableColumns.firstIndex(where:{$0.identifier.rawValue=="check"}) {
                // Update existing controls without rebuilding the report header.
                // Newly materialized views read the same current owner below.
                table.enumerateAvailableRowViews {rowView,row in
                    guard self.renderedRows.indices.contains(row) else{return}
                    let button=rowView.view(atColumn:checkColumn) as? NSButton
                    button?.isEnabled=value.enabled && value.checksEnabled
                    button?.setAccessibilityLabel(NSLocalizedString(value.checkVerb,comment:"")+" "+self.renderedRows[row].path)
                }
            }
            let indexes=IndexSet(renderedRows.indices.filter{value.selection.contains(renderedRows[$0].path)})
            if table.selectedRowIndexes != indexes {table.selectRowIndexes(indexes,byExtendingSelection:false)}
            NativeListSelection.install(on:table,preferences:value.preferences,primaryColumn:table.tableColumns.first{column($0) == .path},labelText:{[weak self] row in self?.renderedRows.indices.contains(row)==true ? self?.renderedRows[row].path:nil},font:geometry.font,leadingInset:24)
            table.needsDisplay=true;finishPositionIfReady()
        }
        func numberOfRows(in tableView:NSTableView)->Int {renderedRows.count}
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            guard renderedRows.indices.contains(row),let tableColumn else{return nil};let value=renderedRows[row]
            if tableColumn.identifier.rawValue=="check" {
                let button=NSButton(checkboxWithTitle:"",target:self,action:#selector(checkClicked(_:)));button.tag=row;button.state=value.checked == true ? .on:.off;button.isEnabled=owner.enabled && owner.checksEnabled
                button.setAccessibilityLabel(NSLocalizedString(owner.checkVerb,comment:"")+" "+value.path);return button
            }
            guard let column=column(tableColumn) else{return nil}
            let field=NSTextField(labelWithString:singleLine(value.text[column] ?? ""));field.lineBreakMode = .byTruncatingTail;field.maximumNumberOfLines=1
            field.font=owner.geometry.font
            field.textColor=column == .path || column == .status ? value.color:.labelColor;field.toolTip=value.text[column]
            if [.added,.removed,.fileSize].contains(column) {field.alignment = .right}
            guard column == .path else{return field}
            let cell=NSTableCellView();let image=NSImageView(frame:NSRect(x:2,y:2,width:16,height:16));image.image=value.icon.image()
            field.frame=NSRect(x:23,y:2,width:max(0,tableColumn.width-26),height:table.rowHeight-4);field.autoresizingMask=[.width];cell.addSubview(image);cell.addSubview(field);cell.imageView=image;cell.textField=field;cell.toolTip=value.tooltip;return cell
        }
        private func singleLine(_ text:String)->String {
            var result=text.replacingOccurrences(of:"\r\n",with:"↵")
            for separator in ["\r","\n","\u{0085}","\u{2028}","\u{2029}","\u{000B}","\u{000C}"] {result=result.replacingOccurrences(of:separator,with:"↵")}
            return result.replacingOccurrences(of:"\t",with:"⇥")
        }
        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !updating,!retired else{return}
            let mark=renderedRows.indices.contains(table.clickedRow) && table.selectedRowIndexes.contains(table.clickedRow) ? renderedRows[table.clickedRow].path:selectedPaths.first
            owner.selectionChanged(GitPathSet(selectedPaths),mark)
        }
        func tableView(_ tableView:NSTableView,sortDescriptorsDidChange oldDescriptors:[NSSortDescriptor]) {
            guard !updating,isAvailable,let descriptor=table.sortDescriptors.first,let key=descriptor.key,let column=StatusListColumn(rawValue:key) else{return}
            owner.sortChanged(column,descriptor.ascending)
        }
        func tableView(_ tableView:NSTableView,shouldReorderColumn column:Int,toColumn newColumn:Int)->Bool {isAvailable && (!owner.hasCheckboxes || column>0 && newColumn>0)}
        func tableView(_ tableView:NSTableView,sizeToFitWidthOfColumn index:Int)->CGFloat {
            guard table.tableColumns.indices.contains(index),let definition=column(table.tableColumns[index]) else{return 26}
            let font=owner.geometry.font
            let width=renderedRows.map{(singleLine($0.text[definition] ?? "") as NSString).size(withAttributes:[.font:font]).width+(definition == .path ? 38:14)}.max() ?? 40
            return min(10000,max(table.tableColumns[index].minWidth,width))
        }
        func tableViewColumnDidMove(_ notification:Notification){saveLayout()}
        func tableViewColumnDidResize(_ notification:Notification){saveLayout()}
        private func saveLayout() {
            guard !updating,isAvailable else{return}
            owner.layoutChanged(table.tableColumns.compactMap(column),Dictionary(uniqueKeysWithValues:table.tableColumns.compactMap{native in column(native).map{($0,Double(native.width))}}))
        }
        @objc private func checkClicked(_ sender:NSButton) {
            guard isAvailable,owner.hasCheckboxes,owner.checksEnabled,renderedRows.indices.contains(sender.tag),let checked=renderedRows[sender.tag].checked else{return}
            owner.checkChanged?(renderedRows[sender.tag].path,!checked)
        }
        private func toggleChecks() {
            guard isAvailable,owner.hasCheckboxes,owner.checksEnabled,let mark=selectedPaths.first(where:{GitReferenceName.equal($0,owner.focusedPath)}) ?? selectedPaths.first,let row=renderedRows.first(where:{GitReferenceName.equal($0.path,mark)}),let checked=row.checked else{return}
            owner.checkChanged?(mark,!checked)
        }
        @objc private func openSelected() {
            guard isAvailable,renderedRows.indices.contains(table.clickedRow),table.clickedColumn >= (owner.hasCheckboxes ? 1:0) else{return}
            owner.activate(renderedRows[table.clickedRow].path,ComparisonToolInvocation.capture)
        }
        private func prepareMenu(_ row:Int,column index:Int) {
            guard isAvailable,renderedRows.indices.contains(row) else{contextMark=nil;contextColumn=nil;return}
            contextMark=renderedRows[row].path;contextColumn=table.tableColumns.indices.contains(index) ? column(table.tableColumns[index]):nil
            owner.selectionChanged(GitPathSet(selectedPaths),contextMark)
        }
        func menuNeedsUpdate(_ menu:NSMenu) {
            menu.removeAllItems();guard isAvailable else{return}
            if menu === headerMenu {
                menu.addItem(ConflictReportMenuItem("Reset columns",icon:.reset,preferences:owner.preferences){[weak self] in guard let self,isAvailable else{return};owner.resetColumns({[weak self] in await self?.confirmColumnReset() ?? false})})
                menu.addItem(.separator())
                for column in StatusListColumn.allCases where owner.available.contains(column) && column != .path {
                    let visible=owner.settings.visible.contains(column)
                    let item=ConflictReportMenuItem(column.rawValue,icon:.settingsDialogs,preferences:owner.preferences){[weak self] in guard let self,isAvailable else{return};owner.columnChanged(column,!visible)}
                    item.state=visible ? .on:.off;menu.addItem(item)
                }
            } else if !selectedPaths.isEmpty {
                let built=owner.makeMenu(selectedPaths,contextMark,contextColumn)
                for item in built.items {built.removeItem(item);menu.addItem(item)}
            }
            let epoch=contextEpoch
            func gate(_ value:NSMenu) {
                for item in value.items {
                    if let callback=item as? ConflictReportMenuItem {callback.validate={[weak self] in self?.isAvailable==true && self?.contextEpoch==epoch}}
                    if let submenu=item.submenu {gate(submenu)}
                }
            }
            gate(menu)
        }
        func storeListPosition(selectedIDs:GitPathSet?) {
            cancelListPosition()
            let point=table.visibleRect.origin,row=table.row(at:NSPoint(x:point.x+1,y:point.y+1))
            storedPosition=(renderedRows.indices.contains(row) ? renderedRows[row].path:nil,renderedRows.indices.contains(row) ? point.y-table.rect(ofRow:row).minY:0,point,selectedIDs ?? GitPathSet(selectedPaths))
        }
        func restoreListPosition(ids:[String],enabled:Bool,completion:@escaping()->Void) {
            guard !retired else{completion();return}
            if let prior=restoreRequest {restoreRequest=nil;prior.reply()}
            restoreRequest=(ids.map{Data($0.utf8)},enabled,completion)
            // The actor's published model reaches the representable on a later
            // main-loop turn. Completion waits for those exact native row IDs.
            DispatchQueue.main.async{[weak self] in self?.finishPositionIfReady()}
        }
        private func finishPositionIfReady() {
            guard let request=restoreRequest,request.ids == renderedRows.map({Data($0.path.utf8)}),
                  let scroll=table.enclosingScrollView,scroll.contentView.bounds.width>0,scroll.contentView.bounds.height>0 else{return}
            restoreRequest=nil
            let point:NSPoint
            if request.remember,let position=storedPosition {
                let row=position.path.flatMap{path in renderedRows.firstIndex{GitReferenceName.equal($0.path,path)}}
                point=NSPoint(x:position.point.x,y:row.map{table.rect(ofRow:$0).minY+position.offset} ?? position.point.y)
            } else {
                table.deselectAll(nil);owner.selectionChanged([],nil)
                point = .zero
            }
            // Empty-table construction and later column/viewport changes can
            // leave a saved offset outside the newly laid out document. Honor
            // the requested content position within AppKit's actual bounds.
            var bounds=scroll.contentView.bounds;bounds.origin=point
            scroll.contentView.scroll(to:scroll.contentView.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            request.reply()
        }
        func cancelListPosition(){storedPosition=nil;if let request=restoreRequest {restoreRequest=nil;request.reply()}}
        func tableView(_ tableView:NSTableView,writeRowsWith rowIndexes:IndexSet,to pasteboard:NSPasteboard)->Bool {
            guard isAvailable,let capture=owner.captureDrag else{return false}
            let paths=rowIndexes.compactMap{renderedRows.indices.contains($0) ? renderedRows[$0].path:nil}
            guard let captured=capture(paths),captured.write(to:pasteboard) else{return false};drag=captured;return true
        }
        func tableView(_ tableView:NSTableView,draggingSession session:NSDraggingSession,willBeginAt screenPoint:NSPoint,forRowIndexes rowIndexes:IndexSet) {if drag != nil {Self.dragOwners[ObjectIdentifier(session)]=self}}
        func tableView(_ tableView:NSTableView,draggingSession session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation) {drag=nil;Self.dragOwners.removeValue(forKey:ObjectIdentifier(session));if retired {table.delegate=nil;table.dataSource=nil}}
        private func confirmColumnReset() async->Bool {
            guard !retired,resetQuestion==nil,let window=table.window,window.attachedSheet==nil else{return false}
            let alert=NSAlert();alert.messageText=NSLocalizedString("Reset column order",comment:"");alert.informativeText=NSLocalizedString("Are you sure you want to reset the column order?",comment:"")
            alert.addButton(withTitle:NSLocalizedString("Yes",comment:""));alert.addButton(withTitle:NSLocalizedString("No",comment:""));alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
            let id=UUID()
            return await withCheckedContinuation{reply in
                resetQuestion=(id,alert,window,{reply.resume(returning:$0)})
                alert.beginSheetModal(for:window){[weak self] response in self?.finishColumnReset(id,accepted:response == .alertFirstButtonReturn)}
            }
        }
        private func finishColumnReset(_ id:UUID,accepted:Bool) {
            guard let request=resetQuestion,request.id==id else{return};resetQuestion=nil
            Task{[self] in await FileOperationWindowDrain.detach(request.alert.window,parent:request.parent);request.reply(accepted && !retired)}
        }
        func retireListPresentation(){retire()}
        func retire(){guard !retired else{return};retired=true;if let question=resetQuestion {finishColumnReset(question.id,accepted:false)};cancelListPosition();contextEpoch=UUID();table.activateSelectedReturn=nil;table.selectionMenuAvailable={false};table.contextSelection={_,_ in};table.focusedRow={nil};table.focusMoved={_ in};table.toggleChecks={};table.copySelection={_ in};table.menu=nil;table.headerView?.menu=nil;table.target=nil;if drag==nil {table.delegate=nil;table.dataSource=nil};NativeListSelection.remove(from:table)}
    }
}

private struct ResolveConflictReport:View {
    @ObservedObject var model:ResolveWindowModel
    var body:some View {
        let primaryRevision=model.primaryActionRevision,primaryEntries=model.sortedReportEntries
        ConflictReportTable(rows:model.sortedReportEntries.map{entry in ConflictReportRow(path:entry.path,text:Dictionary(uniqueKeysWithValues:StatusListColumn.allCases.map{($0,model.reportText(entry,column:$0))}),checked:model.checked.contains(entry.path),color:NSColor(FileState.conflicted.textColor),tooltip:RepositoryPresentationSettings(defaults:model.preferences).fileTooltip(repository:model.repository.root,path:entry.path))},selection:model.selection,settings:model.reportColumns,available:model.availableReportColumns,sort:model.reportSort,ascending:model.reportAscending,enabled:model.canInteract,preferences:model.preferences,hasCheckboxes:true,ownerRetired:!model.active,focusedPath:model.focusedFilePath,selectionChanged:{model.selection=$0;model.focusedFilePath=$1},sortChanged:model.sortReport,layoutChanged:model.saveReportLayout,columnChanged:model.setReportColumn,resetColumns:model.resetReportColumns,makeMenu:model.reportMenu,copySelection:{paths,status in model.copyFileMenu(model.fileMenu(paths),copy:status ? .pathsAndStatus:.relativePaths)},activate:{path,alternate in
            guard model.primaryActionRevision==primaryRevision,primaryEntries.filter({GitReferenceName.equal($0.path,path)})==model.sortedReportEntries.filter({GitReferenceName.equal($0.path,path)}) else{return}
            model.activatePrimaryFile(StatusListPrimaryActionReceipt(path:path,revision:primaryRevision,alternate:alternate))
        },activateSelection:{paths,alternate in
            guard model.primaryActionRevision==primaryRevision else{return}
            model.activatePrimaryFiles(paths,alternate:alternate,expectedEntries:primaryEntries)
        },checkChanged:model.setFileChecked,configureRefresh:{model.reportRefresh.attach($0)})
    }
}
