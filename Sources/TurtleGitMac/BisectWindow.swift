// Native adaptation of TortoiseGit BisectStartDlg.cpp and AppUtils.cpp.
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor final class BisectWindowController: NSWindowController, NSWindowDelegate {
    let model: BisectWindowModel
    var onClosed: () -> Void = {}
    private var picker: LogWindowController?
    private var stashReply: ((Bool) -> Void)?
    private var retired = false
    private var pickerRequest: UUID?
    private var pendingSubmodule: (() -> Void)?
    private var parent:NSWindow?
    private var release:BisectOwnerRelease?
    private var pickerDrain:Task<Void,Never>?
    private var pickerSession:PickerSession?
    private var question:QuestionSession?
    private var retiringSheets:[NSWindow]=[]
    var questionWindow:NSWindow? {question?.alert.window}
    var presentQuestion:((BisectQuestion,NSAlert,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    var canReuse:Bool {!retired && !model.retired}
    private var underlyingWork:Bool {
        model.hasPendingWork || pickerSession != nil || picker != nil || pickerDrain != nil || question != nil ||
        window?.attachedSheet != nil || window?.sheetParent != nil ||
        retiringSheets.contains {$0.sheetParent != nil || $0.attachedSheet != nil}
    }
    var hasPendingWork:Bool {release != nil || underlyingWork}
    private final class PickerSession {
        let id=UUID(),context:BisectWindowModel.FormContext,draft:UUID,good:Bool,original:String
        var answered=false,closed=false
        var entry:LogEntry?
        init(context:BisectWindowModel.FormContext,draft:UUID,good:Bool,original:String) {self.context=context;self.draft=draft;self.good=good;self.original=original}
    }
    private final class QuestionSession {
        let alert:NSAlert
        var answered=false
        var reply:((NSApplication.ModalResponse)->Void)?
        var release:BisectOwnerRelease?
        init(_ alert:NSAlert) {self.alert=alert}
    }
    static var activeChildReleases:Int {BisectOwnerRelease.activeCount}
    var makePicker: (GitRepository, RepositoryAccessLease?, String?, UserDefaults, @escaping (LogEntry?) -> Void) -> LogWindowController = { repository, access, revision, preferences, choose in
        let child=LogWindowController(repository:repository,access:access,onChoose:choose,labelDefaults:preferences,initialRevision:revision,loadsImmediately:false)
        if let revision {child.model.selected=[revision]}
        child.model.reload()
        return child
    }
    var presentPicker: (NSWindow, NSWindow) -> Bool = { parent, child in child.alphaValue=parent.alphaValue;child.appearance=parent.appearance;parent.beginSheet(child); return true }
    var activeOperation: Bool { model.hasPendingWork || model.busy || model.hasPicker || model.confirmingCancellation || question != nil || window?.attachedSheet != nil }
    init(repository: GitRepository, access: RepositoryAccessLease?, good: String? = nil, bad: String? = nil, operation: BisectOperation? = nil, revisions: [String] = [], requireStart: Bool = false, command: BisectCommandRequest? = nil, preferences: UserDefaults = .standard) {
        model = BisectWindowModel(repository: repository, access: access, preferences: preferences)
        let window = ReferenceFormNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 180), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Bisect start", preferences: preferences)
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 620, height: 180)
        window.referenceMinimumContentSize=NSSize(width:620,height:180)
        let host=NSHostingController(rootView:BisectDialog(model:model).defaultAppStorage(preferences))
        host.sizingOptions=[];window.contentViewController=host
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window,weak model] in guard model?.confirmingQuit == false else{return};window?.performClose(nil) }
        model.presentationAvailable = { [weak self,weak window] in self?.retired==false && window != nil && window?.attachedSheet == nil }
        model.quitStateChanged={ [weak self] value in self?.picker?.model.confirmingQuit=value }
        model.closeForSubmoduleHandoff = { [weak self] action in
            guard let self,!self.retired,self.pendingSubmodule == nil,!self.model.activeReview else{return}
            self.pendingSubmodule=action;self.parent=self.window?.sheetParent;self.window?.close()
        }
        model.onProgress = { [weak window] in
            guard let window else { return }; RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Bisect", preferences: preferences)
            window.referenceMinimumContentSize=NSSize(width:620,height:440)
            window.contentMinSize=window.referenceMinimumContentSize;window.minSize=window.referenceMinimumFrameSize
            if window.contentLayoutRect.height < 440 { window.setContentSize(NSSize(width: max(660, window.contentLayoutRect.width), height: 440)) }
        }
        model.onOptions = { [weak window] in
            guard let window else { return };RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Bisect start", preferences: preferences)
            window.referenceMinimumContentSize=NSSize(width:620,height:180)
            window.contentMinSize=window.referenceMinimumContentSize;window.minSize=window.referenceMinimumFrameSize
            window.setContentSize(NSSize(width:max(660,window.contentLayoutRect.width),height:180))
        }
        model.chooseRevision = { [weak self] good in self?.chooseRevision(good: good) }
        model.cancelPrompt = { [weak self] in self?.finishStash(false) }
        model.confirmCancellation = { [weak self] reply in
            guard let self else {reply(false);return}
            let alert=NSAlert();alert.messageText="The process is still running.";alert.informativeText="Are you sure to abort?"
            alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No")
            self.ask(.cancellation,alert:alert){reply($0 == .alertFirstButtonReturn)}
        }
        model.confirmStash = { [weak self, weak window] in
            guard let self, !self.retired, let window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Stash local changes before bisect?"
            alert.informativeText = "Bisect checks out revisions. Stash saves your tracked changes; the stash stays available after bisect."
            alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Stash")
            return await withCheckedContinuation { continuation in
                self.stashReply = { continuation.resume(returning: $0) }
                self.ask(.stash,alert:alert){ [weak self] response in self?.finishStash(response == .alertSecondButtonReturn) }
            }
        }
        model.load(good: good, bad: bad, operation: operation, revisions: revisions, requireStart: requireStart, command: command)

        DialogGeometry.attach(window, identifier: "BisectWindowController")
    }
    func chooseRevision(good: Bool) {
        guard !retired, model.canPickRevision, picker == nil, let window, window.attachedSheet == nil else { return }
        let revision=good ? model.good : model.bad
        model.hasPicker=true
        let request=PickerSession(context:model.formContext,draft:model.draftRevision,good:good,original:revision)
        pickerSession=request;pickerRequest=request.id
        let child=makePicker(model.repository,model.access,revision.isEmpty ? nil : revision,model.preferences) { [weak self] entry in
            guard let self,self.pickerSession===request,!request.answered else{return}
            request.answered=true
            if !self.retired,!self.model.confirmingQuit,self.model.formContext==request.context {request.entry=entry}
            self.drainPicker(request)
        }
        picker=child
        let previous=child.onClosed
        child.onClosed={ [weak self] in previous();request.closed=true;self?.drainPicker(request) }
        child.window?.alphaValue=window.alphaValue;child.window?.appearance=window.appearance
        guard !retired,pickerSession===request,model.formContext==request.context,!model.confirmingQuit else{child.close();return}
        guard let childWindow=child.window else {request.answered=true;request.closed=true;drainPicker(request);return}
        guard presentPicker(window,childWindow) else {request.answered=true;request.entry=nil;child.close();return}
    }
    private func drainPicker(_ request:PickerSession) {
        guard pickerSession===request,pickerDrain==nil,let child=picker else{return}
        pickerDrain=Task { @MainActor [self,child] in
            // Log's onClosed may precede its accepted selection callback in the
            // same stack. Keep the actual child until that callback and its reads
            // have retired, rather than publishing an early parent acceptance.
            await Task.yield()
            while !request.closed || child.model.pendingHistoryLoads>0 || child.model.noteWorkPending || child.window?.attachedSheet != nil || child.window?.sheetParent != nil {
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            let accepted = !retired && !model.confirmingQuit && pickerSession===request &&
                model.formContext==request.context && model.draftRevision==request.draft &&
                GitReferenceName.equal(request.good ? model.good:model.bad,request.original)
            if pickerSession===request {
                pickerSession=nil;pickerRequest=nil;picker=nil;model.hasPicker=false
                if accepted,model.canPickRevision,let entry=request.entry {
                    if request.good {model.good=entry.hash}else{model.bad=entry.hash}
                }
            }
            pickerDrain=nil
        }
    }
    private func ask(_ kind:BisectQuestion,alert:NSAlert,completion:@escaping(NSApplication.ModalResponse)->Void) {
        guard !retired,!model.confirmingQuit,question==nil,let window,window.attachedSheet==nil else{completion(.abort);return}
        let context=model.formContext,request=QuestionSession(alert);question=request
        alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
        let reply:(NSApplication.ModalResponse)->Void={ [self,request] response in
            guard !request.answered else{return};request.answered=true
            let release=BisectOwnerRelease(window:alert.window,parent:window,closeWindow:true) { [self,request] in
                let accepted = !retired && !model.confirmingQuit && question===request && model.formContext==context
                if question===request {question=nil};request.reply=nil;request.release=nil
                completion(accepted ? response:.abort)
            }
            request.release=release;release.start()
        }
        request.reply=reply
        if let presentQuestion {presentQuestion(kind,alert,window,reply)}else{alert.beginSheetModal(for:window,completionHandler:reply)}
    }
    private func finishStash(_ accepted: Bool) {
        if let question,!question.answered {question.reply?(.abort);return}
        let reply=stashReply;stashReply=nil;reply?(accepted)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { guard !model.confirmingQuit else{return false};if model.busy { model.cancel(); return false }; return !activeOperation }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window,!retired else { return }
        retired=true;model.saveActionLog();model.retire();question?.reply?(.abort);finishStash(false)
        if let window,let sheet=window.attachedSheet {retiringSheets.append(sheet);window.endSheet(sheet,returnCode:.abort);sheet.close()}
        if let child=picker?.window {child.sheetParent?.endSheet(child,returnCode:.abort);child.close()}
        if let request=pickerSession {drainPicker(request)}
        let action=pendingSubmodule;pendingSubmodule=nil
        guard let window else{onClosed();return}
        let release=BisectOwnerRelease(window:window,parent:parent ?? window.sheetParent,ready:{[self] in !underlyingWork}) { [self] in
            self.release=nil;retiringSheets=[];let done=onClosed;onClosed={};done()
            if !model.confirmingQuit {action?()}
        }
        self.release=release;release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

enum BisectPostAction: Hashable {
    case submoduleUpdate, operation(BisectOperation)
}
enum BisectQuestion {case stash,cancellation}
@MainActor final class BisectWindowModel: ObservableObject {
    struct FormContext:Equatable {let owner:ObjectIdentifier;let revision:UUID}
    @Published private(set) var formRevision=UUID()
    var formContext:FormContext {.init(owner:ObjectIdentifier(self),revision:formRevision)}
    @Published var confirmingQuit=false {didSet {if oldValue != confirmingQuit {formRevision=UUID();quitStateChanged(confirmingQuit)}}}
    var quitStateChanged:(Bool)->Void = {_ in}
    @Published private(set) var pendingOperations=0
    var hasPendingWork:Bool {pendingOperations>0}
    @Published private(set) var completionRange:NSRange?
    private var startedAt:TimeInterval=0
    private var submoduleDispatched=false
    var activeReview:Bool {busy || hasPendingWork || hasPicker || confirmingCancellation || confirmingQuit}
    var presentationAvailable:()->Bool = {true}
    var closeForSubmoduleHandoff:((@escaping ()->Void)->Void)?
    func revision(_ key:ReferenceWritableKeyPath<BisectWindowModel,String>,context:FormContext)->Binding<String> {
        Binding(get:{self[keyPath:key]},set:{value in guard self.canPickRevision,self.formContext == context else{return};self[keyPath:key]=value})
    }
    func pickRevision(good:Bool,context:FormContext) {guard canPickRevision,formContext == context else{return};chooseRevision(good)}
    let progressPresentation: GitCommandPresentation
    private(set) static var activeOperations = 0
    private(set) var retired = false
    private var token: OperationCancellation?
    @Published private(set) var cancelling = false
    @Published var hasPicker = false {didSet {if oldValue != hasPicker {formRevision=UUID()}}}
    var cancelPrompt: () -> Void = {}
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var showingProgress = false {didSet {if oldValue != showingProgress {formRevision=UUID()}}}
    private(set) var hasStartReview = false
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var cancelled = false
    private var awaitingStash = false
    private var autoClosePolicy: GitProgressAutoClose?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { !retired && !confirmingQuit && busy && !cancelling && !confirmingCancellation }
    var canPickRevision: Bool { !retired && !confirmingQuit && !showingProgress && !hasPicker && !busy && !hasPendingWork && !confirmingCancellation && presentationAvailable() && state?.active == false }
    func cancel() {
        guard canCancel, let captured=token else { return }
        if showingProgress && !awaitingStash && preferences.bool(forKey:"ConfirmKillProcess") {
            confirmingCancellation=true;let context=formContext;var answered=false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.retired else { return };answered=true;self.confirmingCancellation=false
                if self.busy,self.formContext==context,!self.confirmingQuit,self.token === captured,accepted {self.cancelling=true;captured.cancel();self.cancelPrompt()}
                self.finishAutomaticClose()
            }
        } else { cancelling=true;captured.cancel();cancelPrompt() }
    }
    func retire() { guard !retired else { return }; retired=true;formRevision=UUID();token?.cancel();cancelPrompt();confirmingCancellation=false;logObservers.removeAll() }
    private func begin(progress: Bool = false) -> OperationCancellation {
        let value=OperationCancellation();token=value;busy=true;formRevision=UUID();cancelling=false;error=nil;pendingOperations += 1;Self.activeOperations += 1
        if progress {
            ProgressActionLog.nextAttempt(self, savePrevious: showingProgress)
            showingProgress=true;output="";lastExitCode=nil;cancelled=false;currentWork="";percentage=nil;completionRange=nil;startedAt=ProcessInfo.processInfo.systemUptime;submoduleDispatched=false
            autoClosePolicy=GitProgressAutoClose(preferences:preferences);onProgress()
        }
        return value
    }
    private func finish() {
        token=nil;busy=false;cancelling=false;formRevision=UUID()
        if !retired,showingProgress,lastExitCode != nil {
            let completion=SubmoduleProgressCompletion(success:lastExitCode == 0 && !cancelled,cancelled:cancelled,exitCode:lastExitCode,elapsed:ProcessInfo.processInfo.systemUptime-startedAt,preferences:preferences)
            currentWork=completion.currentWork;percentage=100;completionRange=completion.append(to:&output)
        } else if !retired {currentWork="";percentage=nil}
        pendingOperations -= 1;Self.activeOperations -= 1;withExtendedLifetime(access) {};finishAutomaticClose()
    }
    private func finishAutomaticClose() {
        guard !retired, !confirmingQuit, !busy,!hasPendingWork, showingProgress, !confirmingCancellation, !awaitingStash, !cancelled, error == nil, lastExitCode == 0 else { return }
        let count=(state?.active == true ? 4 : 0) + (hasSubmodules ? 1 : 0)
        if autoClosePolicy?.shouldClose(success:true,postActionCount:count) == true { saveActionLog();close() }
    }
    private func stream<T>(token captured: OperationCancellation, resultText: @escaping (T) -> String,
                           operation: @escaping (@escaping @Sendable (GitOutputChunk) -> Void) async throws -> T) async throws -> T {
        let prefix=output
        LocalGitCommandProgress.begin();defer { LocalGitCommandProgress.end() }
        return try await LocalGitCommandProgress.stream(preferences:preferences,update: { [weak self] state in
            guard let self, !self.retired, self.token === captured else { return }
            self.output=LocalGitCommandProgress.bounded(prefix + state.output,preferences:self.preferences)
            self.currentWork=state.currentWork;self.percentage=state.percentage
        },resultText:resultText,operation:operation)
    }
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    private(set) var draftRevision=UUID()
    @Published var good = "" {didSet{if !GitReferenceName.equal(good,oldValue){draftRevision=UUID()}}}
    @Published var bad = "" {didSet{if !GitReferenceName.equal(bad,oldValue){draftRevision=UUID()}}}
    @Published var choices: [String] = []
    @Published var state: BisectState? {didSet{formRevision=UUID()}}
    @Published var busy = false {didSet {if oldValue != busy {formRevision=UUID()}}}
    @Published var error: String?
    @Published var output = ""
    @Published var lastExitCode: Int32? {didSet{formRevision=UUID()}}
    @Published var hasSubmodules = false {didSet{if oldValue != hasSubmodules {formRevision=UUID()}}}
    var close: () -> Void = {}
    var onProgress: () -> Void = {}
    var onOptions: () -> Void = {}
    var chooseRevision: (Bool) -> Void = { _ in }
    var confirmStash: () async -> Bool = { false }
    var onChanged: (String) -> Void = { _ in }
    var onAttemptCompleted:(BisectMutationResult)->Void = {_ in}
    private func mutation(_ result:BisectMutationResult) {if result.attempted {onAttemptCompleted(result)}}
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
        for observer in logObservers { observer.model?.requestRepositoryRefresh() }
    }
    var onSubmoduleUpdate: (() -> Void)? {didSet{formRevision=UUID()}}
    var canUpdateSubmodules: Bool { !retired && !confirmingQuit && !submoduleDispatched && presentationAvailable() && !hasPicker && !busy && !hasPendingWork && !confirmingCancellation && hasSubmodules && lastExitCode == 0 && onSubmoduleUpdate != nil }
    func updateSubmodules(context:FormContext? = nil) {
        guard context == nil || context == formContext,canUpdateSubmodules,let action=onSubmoduleUpdate else{return}
        submoduleDispatched=true
        if let closeForSubmoduleHandoff {closeForSubmoduleHandoff(action)} else {close();action()}
    }
    var postActions:[BisectPostAction] {
        guard !retired,!busy,showingProgress else{return []}
        return (hasSubmodules && lastExitCode == 0 && onSubmoduleUpdate != nil ? [.submoduleUpdate]:[]) + postOperations.map {.operation($0)}
    }
    func title(_ action:BisectPostAction)->String {switch action {case .submoduleUpdate:return "Submodule Update…";case .operation(let operation):return title(operation)}}
    func icon(_ action:BisectPostAction)->MenuIcon {switch action {case .submoduleUpdate:return .fetch;case .operation(let operation):return operation.icon}}
    func perform(_ action:BisectPostAction,context:FormContext) {
        guard formContext == context,postActions.contains(action) else{return}
        switch action {case .submoduleUpdate:updateSubmodules(context:context);case .operation(let operation):perform(operation)}
    }
    var canStart: Bool { !retired && !confirmingQuit && !showingProgress && !hasPicker && !busy && !hasPendingWork && !confirmingCancellation && presentationAvailable() && state?.active == false && !good.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !bad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func canPerform(_ operation: BisectOperation) -> Bool { !retired && !confirmingQuit && !hasPicker && !busy && !hasPendingWork && !confirmingCancellation && presentationAvailable() && state?.active == true && (operation == .reset || lastExitCode == nil || lastExitCode == 0) }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; self.preferences = preferences; progressPresentation = GitCommandPresentation(defaults: preferences) }
    static func orderedChoices(_ values:[String])->[String] {
        // CBS_SORT puts branches and tags in one alphabetic list. Use native
        // locale collation, then a literal UTF-16 tie break to retain distinct
        // Git names even when the platform comparator regards them as equal.
        values.sorted {
            let order=$0.compare($1,options:[.caseInsensitive,.literal],locale:.current)
            return order == .orderedSame ? $0.utf16.lexicographicallyPrecedes($1.utf16):order == .orderedAscending
        }
    }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func requireLive(_ token: OperationCancellation) throws {
        if retired || self.token !== token || token.isCancelled { throw OperationCancellationFailure.cancelled }
    }
    func load(good presetGood: String? = nil, bad presetBad: String? = nil, operation: BisectOperation? = nil, revisions: [String] = [], requireStart: Bool = false, command: BisectCommandRequest? = nil, preserveStartDraft: Bool = false) {
        guard !retired,!confirmingQuit, !hasPicker, !busy,!hasPendingWork else { return }; let token = begin()
        Task {
            var selectedOperation = operation, selectedRevisions = revisions
            do {
                try validateAccess()
                guard try await !repository.isBare(cancellation: token) else { throw BisectFailure.workingTree }
                let references=try await repository.checkoutReferences(cancellation:token).filter { $0.symbolicTarget == nil }
                var choices: [String]=[]
                for reference in references.filter({ $0.target == .branch }) + references.filter({ $0.target == .tag }) {
                    if !choices.contains(where:{ GitReferenceName.equal($0,reference.label) }) { choices.append(reference.label) }
                }
                let freshState = try await repository.bisectState(cancellation: token)
                let metadata = try await repository.finderMetadata(cancellation: token)
                try requireLive(token)
                self.choices = Self.orderedChoices(choices); state = freshState; hasSubmodules = metadata.hasSubmoduleConfig
                if freshState.active { showingProgress=true;if output.isEmpty { output=LocalGitCommandProgress.bounded(freshState.log,preferences:preferences) };onProgress() }
                var chosenGood = presetGood, chosenBad = presetBad, startOnly = requireStart
                var resetStartDefaults = false
                let commandAction = try command.map { try $0.action(active:freshState.active) }
                switch commandAction {
                case .start(let good, let bad):
                    startOnly = true
                    if !preserveStartDraft { resetStartDefaults=true;chosenGood=good ?? "";chosenBad=bad }
                case .operation(let action, let revisions): selectedOperation=action;selectedRevisions=revisions
                case nil: break
                }
                let branch = chosenBad == nil && (resetStartDefaults || bad.isEmpty) ? try await repository.branch(cancellation: token) : ""
                try requireLive(token)
                if startOnly && !freshState.active { showingProgress=false;onOptions() }
                if startOnly && (freshState.active || metadata.mergeActive) { throw BisectFailure.active }
                if selectedOperation != nil && !freshState.active { throw BisectFailure.inactive }
                if let chosenGood { good = chosenGood }
                if let chosenBad { bad = chosenBad }
                else if resetStartDefaults || bad.isEmpty { bad = branch.isEmpty ? "HEAD" : branch }
                lastExitCode = nil
                if !freshState.active && selectedOperation == nil { hasStartReview = true }
            } catch { if !retired { self.error = error.localizedDescription } }
            finish()
            if !retired, !token.isCancelled, error == nil, let selectedOperation { perform(selectedOperation, revisions: selectedRevisions) }
        }
    }
    func start(context:FormContext? = nil) {
        guard context == nil || context == formContext,canStart else { return }
        func normalized(_ value:String) -> String { let trimmed=value.trimmingCharacters(in:.whitespacesAndNewlines);return trimmed.hasPrefix("remotes/") ? String(trimmed.dropFirst(8)) : trimmed }
        let good=normalized(self.good),bad=normalized(self.bad)
        let token=begin(progress:true)
        Task {
            defer { finish() }
            do {
                try validateAccess()
                let result:BisectWorkflowExecution
                do { result=try await stream(token:token,resultText:{$0.execution.output}) {[repository] emit in try await repository.startBisectWorkflow(good:good,bad:bad,cancellation:token,onOutput:emit)} }
                catch BisectFailure.dirty {
                    awaitingStash=true;let accepted=await confirmStash();awaitingStash=false
                    guard accepted else { if !retired && !token.isCancelled { showingProgress=false;onOptions() };return }
                    try requireLive(token); try validateAccess()
                    let stash=try await stream(token:token,resultText:{$0.stash.output}) {[repository] emit in try await repository.stashBeforeBisectWorkflow(cancellation:token,onOutput:emit)}
                    mutation(stash.mutation);try requireLive(token);changed(stash.stash.output)
                    result=try await stream(token:token,resultText:{$0.execution.output}) {[repository] emit in try await repository.startBisectWorkflow(good:good,bad:bad,cancellation:token,onOutput:emit)}
                }
                mutation(result.mutation);try await accept(result.execution, token: token)
            } catch { await recover(error) }
        }
    }
    func perform(_ operation: BisectOperation, revisions: [String] = []) {
        guard canPerform(operation) else { return }; let token=begin(progress:true)
        Task {
            defer { finish() }
            do {
                try validateAccess()
                let result=try await stream(token:token,resultText:{$0.execution.output}) {[repository] emit in try await repository.bisectWorkflow(operation,revisions:revisions,cancellation:token,onOutput:emit)}
                mutation(result.mutation);try await accept(result.execution,token:token)
            }
            catch { await recover(error) }
        }
    }
    private func accept(_ result: BisectExecution, token: OperationCancellation) async throws {
        let metadata = try await repository.finderMetadata(cancellation: token)
        try requireLive(token)
        state = result.state; lastExitCode = result.exitCode
        hasSubmodules = metadata.hasSubmoduleConfig
        onProgress(); changed(result.output)
        if result.exitCode != 0 { error = result.output.isEmpty ? "Bisect failed (\(result.exitCode))." : result.output }
    }
    private func recover(_ reported:Error) async {
        let failure:Error
        if let partial=reported as? BisectMutationFailure {mutation(partial.mutation);failure=partial.underlying} else {failure=reported}
        guard !retired else { return }
        // Cancellation can leave Git's session active. Read its actual state with
        // a fresh owned token so Reset remains available; never undo it implicitly.
        let recovery = OperationCancellation(); token = recovery
        let recoveredState = try? await repository.bisectState(cancellation: recovery)
        let metadata = try? await repository.finderMetadata(cancellation: recovery)
        guard !retired, !recovery.isCancelled else { return }
        cancelled = failure is OperationCancellationFailure || failure is GitCommandCancellationFailure || cancelling
        error = failure.localizedDescription; lastExitCode = 1; state = recoveredState
        hasSubmodules = metadata?.hasSubmoduleConfig ?? false
        output=LocalGitCommandProgress.failure(failure,existing:output,preferences:preferences)
        if state?.active == true { onProgress() }
        changed(failure.localizedDescription)
    }
    func returnToOptions() {
        guard !retired,!confirmingQuit, !busy,!hasPendingWork, !hasPicker, !confirmingCancellation, state?.active == false else { return };saveActionLog();formRevision=UUID();showingProgress=false;onOptions()
    }
    var postOperations: [BisectOperation] {
        guard !busy, state?.active == true else { return [] }
        return lastExitCode == nil || lastExitCode == 0 ? BisectOperation.allCases : [.reset]
    }
    func title(_ operation: BisectOperation) -> String {
        "Bisect " + (operation == .good ? state?.goodTerm ?? "good" : operation == .bad ? state?.badTerm ?? "bad" : operation.rawValue)
    }
}

private struct BisectDialog: View {
    @ObservedObject var model: BisectWindowModel
    private func commands(_ context:BisectWindowModel.FormContext)->[ReferenceFormCommand] {
        [
            .init(id:"bisectGood",title:"Last known good",key:"g",sourceKey:"g",icon:.bisectGood,enabled:model.canPickRevision,focus:"Last known good",action:{}),
            .init(id:"bisectBad",title:"First known bad",key:"b",sourceKey:"b",icon:.bisectBad,enabled:model.canPickRevision,focus:"First known bad",action:{}),
            .init(id:"bisectGoodLog",title:"Choose last known good commit",key:"l",icon:.log,enabled:model.canPickRevision,action:{model.pickRevision(good:true,context:context)}),
            .init(id:"bisectBadLog",title:"Choose first known bad commit",key:"r",icon:.log,enabled:model.canPickRevision,action:{model.pickRevision(good:false,context:context)})
        ]
    }
    var body: some View {
        let context=model.formContext
        VStack(alignment: .leading, spacing: 12) {
            if !model.showingProgress { VStack(spacing: 10) {
                HStack { Text("Last known good:").frame(width: 135, alignment: .leading); BisectCombo(value: model.revision(\.good,context:context), choices: model.choices, label: "Last known good"); Button { model.pickRevision(good:true,context:context) } label: { CommandLabel(title:"…",icon:.log) }.accessibilityLabel("Choose last known good commit") }
                HStack { Text("First known bad:").frame(width: 135, alignment: .leading); BisectCombo(value: model.revision(\.bad,context:context), choices: model.choices, label: "First known bad"); Button { model.pickRevision(good:false,context:context) } label: { CommandLabel(title:"…",icon:.log) }.accessibilityLabel("Choose first known bad commit") }
            }.disabled(!model.canPickRevision) }
            if model.showingProgress {
                if let hash = model.state?.firstBadCommit { Text("First \(model.state?.badTerm ?? "bad") commit: \(hash)").foregroundStyle(.green).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(hash) }
                else if model.state?.active == true { Text("Testing: \(model.state?.head ?? "")").foregroundStyle(.blue).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(model.state?.head ?? "") }
                SubmoduleProgressOutputView(text:model.output,completed:!model.busy,completionRange:model.completionRange,success:model.lastExitCode == 0,preferences:model.preferences).frame(minHeight:160)

            }
            HStack { if model.busy || model.showingProgress { LocalGitProgressIndicator(percentage: model.percentage, animate: model.busy && model.progressPresentation.animateActivity);Text(model.currentWork).font(.caption).lineLimit(1).truncationMode(.tail).help(model.currentWork) }; Spacer()
                if !model.showingProgress { Button("OK") { model.start(context:context) }.keyboardShortcut(.defaultAction).disabled(!model.canStart) }
                if !model.postActions.isEmpty {BisectCompletionControl(model:model).fixedSize().disabled(model.activeReview)}
                if model.showingProgress && model.state?.active == false && model.lastExitCode != 0 { Button("Back") { model.returnToOptions() }.disabled(model.activeReview) }
                Button(model.busy ? (model.cancelling ? "Cancelling…" : "Cancel") : model.output.isEmpty ? "Cancel" : "Close") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction).disabled(model.confirmingQuit || model.cancelling || model.hasPicker || model.confirmingCancellation)
                Button("Help") { TurtleGitHelp.show(.bisect) }
            }
        }.padding(16)
        .background(ReferenceFormCommands(entries:commands(context),preferences:model.preferences,available:{!model.retired && !model.activeReview && model.presentationAvailable()},changes:model.objectWillChange.eraseToAnyPublisher()).frame(width:0,height:0))
        .alert("Bisect", isPresented: Binding(get: { model.error != nil }, set: { if !$0,!model.retired,!model.confirmingQuit,model.formContext==context { model.error = nil } })) { Button("OK") { guard !model.retired,!model.confirmingQuit,model.formContext==context else{return};model.error = nil } } message: { Text(model.error ?? "") }
    }
}
private struct BisectCombo: NSViewRepresentable {
    @Binding var value: String; let choices: [String]; let label: String
    @AppStorage("UseCustomWordBreak") private var wordBreakMode=2
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox { let view = NSComboBox(); view.delegate = context.coordinator;view.completes=true;view.cell?.usesSingleLineMode=true;view.lineBreakMode = .byTruncatingMiddle; view.setContentHuggingPriority(.defaultLow, for: .horizontal);view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal); return view }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSComboBox,context:Context)->CGSize? {referenceFormControlSize(proposal,height:24)}
    func updateNSView(_ view: NSComboBox, context: Context) {
        context.coordinator.wordCommands.policy=GitInputWordBreak(mode:UInt32(truncatingIfNeeded:wordBreakMode))
        let c = context.coordinator; c.updating = true; defer { c.updating = false }; c.enabled=enabled;c.change = { value = $0 }
        if !c.choices.elementsEqual(choices,by:{$0.utf8.elementsEqual($1.utf8)}) { view.removeAllItems(); view.addItems(withObjectValues: choices); c.choices = choices }
        if !view.stringValue.utf8.elementsEqual(value.utf8) { view.stringValue = value }; view.isEnabled = enabled; view.setAccessibilityLabel(label);view.identifier = .init(label);view.toolTip=value
    }
    static func dismantleNSView(_ view:NSComboBox,coordinator:Coordinator) { coordinator.enabled=false;coordinator.change={_ in};view.delegate=nil }
    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        let wordCommands=GitInputWordCommands()
        func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
            wordCommands.handle(control,text:textView,selector:commandSelector,combo:true,owner:self)
        }
        var updating = false; var enabled=false; var choices: [String] = []; var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) { guard !updating, enabled, let view = notification.object as? NSComboBox, view.isEnabled else { return }; change(view.stringValue) }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard !updating, enabled, let view = notification.object as? NSComboBox, view.isEnabled, choices.indices.contains(view.indexOfSelectedItem) else { return }; change(choices[view.indexOfSelectedItem]) }
    }
}
extension BisectOperation {
    var icon: MenuIcon { switch self { case .good: return .bisectGood; case .bad: return .bisectBad; case .skip: return .bisect; case .reset: return .bisectReset } }
}

@MainActor private final class BisectOwnerRelease {
    static private(set) var activeCount=0
    private let window:NSWindow,parent:NSWindow?
    private var completion:()->Void
    private var observer:NSObjectProtocol?
    private var waiter:Task<Void,Never>?
    private var started=false,finished=false
    private let ready:()->Bool
    private let closeWindow:Bool
    init(window:NSWindow,parent:NSWindow?,closeWindow:Bool=false,ready:@escaping()->Bool={true},completion:@escaping ()->Void) {
        self.window=window;self.parent=parent;self.closeWindow=closeWindow;self.ready=ready;self.completion=completion
    }
    func start() {
        guard !started else{return};started=true
        Self.activeCount += 1
        observer=NotificationCenter.default.addObserver(forName:NSWindow.didEndSheetNotification,object:parent,queue:.main) {[self] _ in DispatchQueue.main.async {self.drain()}}
        window.sheetParent?.endSheet(window);window.orderOut(nil)
        if closeWindow {window.close()}
        waiter=Task { @MainActor [self] in
            await Task.yield()
            while !finished {drain();if !finished {try? await Task.sleep(nanoseconds:10_000_000)}}
        }
    }
    private func drain() {
        guard !finished,window.sheetParent == nil,window.attachedSheet==nil,parent?.attachedSheet !== window,ready() else{return};finished=true
        if let observer {NotificationCenter.default.removeObserver(observer);self.observer=nil}
        waiter=nil
        Self.activeCount -= 1;let done=completion;completion={};done()
    }
}
