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
        window.contentViewController = NSHostingController(rootView: ResolveDialog(model: model, commit: { [weak self] in self?.commit() }).defaultAppStorage(preferences))
        window.setContentSize(size); window.center()
        model.close = { [weak self] in guard let self, !self.retired else { return }; self.window?.performClose(nil) }
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
            await FileOperationWindowDrain.detach(pending.1.window)
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
    override func close(){super.close();retireClosedWindow()}
    func windowWillClose(_ notification:Notification){retireClosedWindow()}
    private func retireClosedWindow(){
        guard !retired else{return};retired=true
        let callback=commitHandoff;commitHandoff=nil
        let sheets=[window?.attachedSheet,applicationPanel,question?.1.window].compactMap{$0}
        ResolveSelectionMarkProbe.retire(in:window?.contentView);model.invalidate();progressFiles.retire();baseComparison?.close();baseComparison=nil
        applicationPanel?.cancel(nil);applicationPanel=nil
        Array(fileUnifiedWindows.values).forEach{$0.close()};fileUnifiedWindows=[:]
        if let pending=question{finishQuestion(pending.0,answer:nil)}
        Self.activeReleases += 1
        Task { [self] in
            defer{Self.activeReleases -= 1;model.handoffPending=false}
            for sheet in sheets{await FileOperationWindowDrain.detach(sheet)}
            if let window{await FileOperationWindowDrain.detach(window)}
            while model.busy || model.confirmingCancellation || progressFiles.busy{try? await Task.sleep(nanoseconds:5_000_000)}
            window?.contentViewController=nil
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
    private var loaded = false, reloadQueued = false
    private var fileMenuEpoch = UUID()
    private var usedFileMenus = Set<UUID>()
    private var droppedProviders: [NSItemProvider] = []
    private var dropTask: Task<Void,Never>?
    @Published private(set) var readingDrops = false
    var readDroppedURL: (NSItemProvider) async throws -> URL = CommitFileURLReader.read
    var readDroppedConflicts: (([String], OperationCancellation) async throws -> ([ConflictEntry], Bool))?
    @Published var entries: [ConflictEntry] = []
    @Published var checked = GitPathSet()
    private var selectedPaths = GitPathSet()
    @Published var nativeSelection = Set<String>() {
        didSet { selectedPaths = GitPathRowIdentity.paths(nativeSelection) }
    }
    var selection: GitPathSet {
        get { selectedPaths }
        set { let ids = Set(newValue.map(GitPathRowIdentity.encode)); if nativeSelection != ids { nativeSelection = ids } }
    }
    var focusedFilePath:String?
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
        self.repository = repository; self.access = access; self.paths = paths; self.quick = quick; self.commandOptions = commandOptions; self.preferences = preferences; self.progress=FileOperationProgressState(preferences:preferences); progressPresentation = GitCommandPresentation(defaults: preferences)
    }
    func invalidate() {
        progress.retire();invalidateFileMenus();cancelFileChoice();submoduleFileLog.retire();retireMutationChild()
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
        publishConflicts(next.0,rebase:next.1)
    }
    func load() {
        guard active else { return }
        if commandOptions?.noQuestion == true { startUnreviewedProgress(); return }
        if busy || hasQuestion || hasChild || showingProgress { reloadQueued = true; return }
        invalidateFileMenus()
        let token = begin()
        Task {
            defer { finish(token); withExtendedLifetime(access) {} }
            do {
                try await refresh(token); guard live(token), !token.isCancelled else { return }
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
    func resolveChecked() { guard canInteract else { return }; closeAfterResolution = true; apply(entries.filter { checked.contains($0.path) }, using: .current) }
    func request(_ choice: ResolveChoice, ids values: some Sequence<String>) {
        let ids = GitPathSet(values)
        let selected = entries.filter { ids.contains($0.path) }
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
        droppedProviders = [];cancelFileChoice();submoduleFileLog.cancel()
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
    func editOrCompare(_ values: some Sequence<String>) {
        let ids = GitPathSet(values)
        guard canInteract else { return }
        if ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) { onEdit(entry.path) }
        else { compare(ids) }
    }
    func compare(_ values: some Sequence<String>) {
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
    @AppStorage("LogFontForFileListCtrl") private var reportUsesLogFont=false
    @AppStorage("LogFontName") private var reportFontName=MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var reportFontSize=MessageEditorFont.defaultSize
    var body: some View {
        let geometry=FileListUniformRowGeometry.resolve(useLogFont:reportUsesLogFont,name:reportFontName,size:reportFontSize)
        Group {
            if model.showingProgress {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.busy ? "Resolving selected conflicts…" : model.success ? "Resolved \(model.resolvedCount) files." : model.cancelled ? "Resolution aborted. Earlier resolved items remain resolved." : "Resolution failed.").font(.headline)
                    FileOperationProgressTable(state:model.progress,icon:.resolveBackdrop,available:model.progressActionsAvailable,repository:model.repository.root,keyboardAvailable:model.active && !model.confirmingQuit && !model.handoffPending && model.externalAvailability(),perform:model.onProgressFileAction)
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
                    Table(model.entries.map(ResolveConflictRow.init), selection: $model.nativeSelection) {
                        TableColumn("") { row in
                            let entry = row.entry
                            FileSelectionCheckbox(path: entry.path, verb: "Resolve", checked: model.checked.contains(entry.path), enabled: model.canInteract) { model.setFileChecked(entry.path, value: $0) }.frame(width: 20, height: 20).frame(height:geometry.contentHeight)
                        }.width(24)
                        TableColumn("Path") { row in let entry = row.entry; HStack { Image(nsImage: FileState.conflicted.icon.image() ?? NSImage()).resizable().frame(width:16,height:16); Text(entry.path).foregroundStyle(FileState.conflicted.textColor).background(NativeListSelectionLabelMarker()) }.frame(height:geometry.contentHeight).repositoryFileHelp(repository: model.repository.root, path: entry.path, preferences: model.preferences) }.width(min: 260, ideal: 440)
                        TableColumn("Extension") { row in let value=StatusListClipboard.fileExtension(row.entry.path,isDirectory:row.entry.isSubmodule);Text(value).help(value).frame(height:geometry.contentHeight) }.width(70)
                        TableColumn("Status") { _ in Text("Conflicted").help("Conflicted").foregroundStyle(FileState.conflicted.textColor).frame(height:geometry.contentHeight) }.width(95)
                    } .disabled(!model.canInteract).fileListFont().environment(\.defaultMinListRowHeight,geometry.rowHeight).lineLimit(1).truncationMode(.tail).background(ResolveSelectionMarkProbe(model:model))
                    .background(NativeListSelectionProbe(preferences:model.preferences,primaryTitle:"Path",labelText:{row in model.entries.indices.contains(row) ? model.entries[row].path:nil},font:geometry.font,leadingInset:24,uniformRowGeometry:geometry,rowIDs:{model.entries.map{Data($0.path.utf8)}}))
                    .contextMenu(forSelectionType: String.self) { ids in
                        let target = model.fileMenu(GitPathRowIdentity.paths(ids))
                        TurtleGitContextMenu {
                            ResolveSelectionMenu(paths:target.entries.map(\.path),rebase:model.rebase,canEdit:target.entries.count == 1) {action,paths in
                                model.withFileMenu(target) {
                                    if action == .editConflict {model.editOrCompare(GitPathSet(paths))} else {model.request(action.resolveChoice ?? .current,ids:GitPathSet(paths))}
                                }
                            }
                            Divider()
                            ForEach(target.commands,id:\.self) {command in
                                Button {model.fileCommand(command,menu:target)} label: {CommandLabel(title:command.title,icon:command.icon)}.disabled(!model.canFileCommand(command,menu:target))
                            }
                            Divider()
                            Menu {ForEach(ResolveClipboardChoice.allCases,id:\.self) {choice in
                                Button {model.copyFileMenu(target,copy:choice.copy)} label: {CommandLabel(title:choice.rawValue,icon:.copy)}
                            }} label: {CommandLabel(title:"Copy to clipboard",icon:.copy)}
                        }
                    } primaryAction: { ids in model.editOrCompare(GitPathRowIdentity.paths(ids)) }
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
        }.onAppear { model.load() }
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
    case full = "Full paths",relative = "Relative paths",names = "File/folder names",all = "Copy all information to clipboard"
    var copy:StatusListCopy {switch self {case .full:return .fullPaths;case .relative:return .relativePaths;case .names:return .names;case .all:return .all}}
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
        let selected = entries.filter{ids.contains($0.path)}
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
        withFileMenu(menu) {writeFileClipboard(StatusListClipboard.text(menu.entries,root:repository.root,copy:copy, label:FileListLabels.caption))}
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
        if command == .compareBase {ComparisonToolInvocation.$alternate.withValue(menu.alternate) {compare(GitPathSet(menu.paths))};return}
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
                    case .unified:
                        let bytes = try await repository.run(["diff","--no-ext-diff","--no-textconv","--no-color","--base","--"]+menu.paths,cancellation:token).stdout
                        try await validateFileMenu(menu,token:token);try await onFileUnified?(bytes,alternate,token)
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

/// Observe only this Resolve table's events; return every event unchanged.
private struct ResolveSelectionMarkProbe:NSViewRepresentable {
    let model:ResolveWindowModel
    func makeNSView(context:Context)->Probe {let view=Probe();view.model=model;return view}
    func updateNSView(_ view:Probe,context:Context) {view.model=model;if !model.active {view.stop()}}
    static func dismantleNSView(_ view:Probe,coordinator:()) {view.stop()}
    static func retire(in root:NSView?) {guard let root else {return};(root as? Probe)?.stop();root.subviews.forEach{retire(in:$0)}}
    final class Probe:NSView {
        weak var model:ResolveWindowModel?
        private var monitor:Any?
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow();stop();guard window != nil else {return}
            monitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.keyDown]) { [weak self] event in
                guard let self,let window=self.window,event.window === window,let model=self.model,model.canInteract else {return event}
                func tables(_ root:NSView)->[NSTableView] {(root as? NSTableView).map{[$0]} ?? root.subviews.flatMap(tables)}
                guard let root=window.contentView,let table=tables(root).first else {return event}
                if event.type == .keyDown {
                    guard [123,124,125,126,115,119].contains(event.keyCode) else {return event}
                    let generation=model.generation
                    DispatchQueue.main.async { [weak self,weak table,weak model] in
                        guard self?.window === window,let table,let model,model.canInteract,model.generation == generation,model.entries.indices.contains(table.selectedRow) else {return}
                        model.focusedFilePath=model.entries[table.selectedRow].path
                    }
                } else {
                    let point=table.convert(event.locationInWindow,from:nil),row=table.row(at:point)
                    if table.bounds.contains(point),model.entries.indices.contains(row) {model.focusedFilePath=model.entries[row].path}
                }
                return event
            }
        }
        func stop() {if let monitor {NSEvent.removeMonitor(monitor)};monitor=nil}
        deinit {if let monitor {NSEvent.removeMonitor(monitor)}}
    }
}
