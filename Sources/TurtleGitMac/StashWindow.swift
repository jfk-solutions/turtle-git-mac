import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class StashWindowController: NSWindowController, NSWindowDelegate {
    let model: StashWindowModel
    var onClosed: () -> Void = {}
    private var transportRetiredProgress:StashSaveProgressWindowController?
    var transportBatchWorkPending:Bool {model.pendingTransportReads>0 || transportRetiredProgress?.model.hasPendingWork == true || window?.attachedSheet != nil || window?.sheetParent != nil}

    private(set) var progressController: StashSaveProgressWindowController?
    static var activeChildReleases: Int { StashChildRelease.activeCount }
    private var identitySettings: SettingsSheetController?
    var identitySettingsWindow: NSWindow? { identitySettings?.window }
    var identityNavigation: SettingsNavigationController? { identitySettings?.navigation }
    private var warning: NSAlert?
    private var warningReply: ((Bool) -> Void)?
    private var closingPreparation=false,closed=false
    private var release:StashChildRelease?
    private var childReleases:[UUID:StashChildRelease]=[:]
    private var released=false
    private var closedActions:[()->Void]=[]
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = StashWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Stash", preferences: preferences)
        window.minSize = NSSize(width: 500, height: 272); window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 272)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StashDialog(model: model))
        super.init(window: window); window.delegate = self
        model.afterClose = { [self] action in
            if self.released {action();return}
            self.closedActions.append(action)
            if !self.closed {self.window?.close()}
        }
        window.setContentSize(NSSize(width: 560, height: 240)); window.center()
        model.close = { [weak self] in
            guard let self, !self.model.confirmingQuit, !self.model.busy, !self.model.hasIdentitySettings, !self.model.confirmingUntracked, self.window?.attachedSheet == nil else { return }
            self.window?.close()
        }
        model.onProgress = { [weak self] progress in
            guard let self,!self.closed,let window=self.window,window.attachedSheet == nil else {self?.model.abandonProgressPresentation(progress);return}
            let controller = StashSaveProgressWindowController(model: progress)
            controller.onClosing = { [weak model=self.model] window in model?.handoffPresentation=MergeWindowPresentation(window) }
            controller.window?.alphaValue = window.alphaValue; controller.window?.appearance = window.appearance
            controller.onClosed = { [weak self, weak progress] in
                guard let self, let progress else { return }
                self.progressController = nil; self.model.finish(progress)
            }
            self.progressController = controller
            if let child = controller.window { window.beginSheet(child) }
        }
        model.becameIdle = { [weak self] in if self?.closingPreparation == true {self?.model.close()} }
        model.repairIdentity = { [weak self] in await self?.showIdentitySettings() ?? false }
        model.retireIdentitySettings = { [weak self] in self?.identitySettings?.retire() }
        model.confirmUntracked = { [weak self] choose in
            guard let self, let window=self.window, window.attachedSheet == nil else {choose(false);return}
            let alert=NSAlert();alert.alertStyle = .warning
            alert.messageText="Include untracked files?"
            alert.informativeText="Untracked files will be saved in the stash and removed from the working tree. Restore them by applying or popping the stash."
            alert.addButton(withTitle:"Abort");alert.addButton(withTitle:"Continue")
            alert.showsSuppressionButton=true;alert.suppressionButton?.title="Do not show this warning again (if Continue is selected)"
            alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
            self.warning=alert;var answered=false
            let reply:(Bool)->Void = {value in guard !answered else{return};answered=true;choose(value)}
            self.warningReply=reply
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self,self.warning === alert else {reply(false);return}
                let accepted=response == .alertSecondButtonReturn
                let release=StashChildRelease(window:alert.window,parent:window) { [weak self] in
                    guard let self,self.warning === alert else {reply(false);return}
                    self.warning=nil;self.warningReply=nil
                    if accepted,alert.suppressionButton?.state == .on,!self.model.closed {preferences.set(true,forKey:"Stash.NoIncludeUntrackedWarning")}
                    reply(accepted)
                };release.start()
            }
        }

        DialogGeometry.attach(window, identifier: "StashWindowController")
    }
    func showIdentitySettings() async -> Bool {
        guard !model.closed,identitySettings == nil,let window,window.attachedSheet == nil else{return false}
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
        workspace.root=model.repository.root;workspace.settingsContextOverride=(model.repository,model.repositoryAccess,true)
        let child=SettingsSheetController(workspace:workspace,preferences:model.preferences,initialPage:.git,title:"Settings – TurtleGit for Mac")
        identitySettings=child;model.hasIdentitySettings=true;child.window?.appearance=window.appearance
        return await withCheckedContinuation { continuation in
            child.onClosed = { [weak self,weak child] accepted in
                if let self,self.identitySettings === child {self.identitySettings=nil;self.model.hasIdentitySettings=false}
                continuation.resume(returning:accepted)
            };child.presentSheet(for:window)
        }
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard !model.confirmingQuit else{return false}
        if model.preparing {closingPreparation=true;model.cancelPreparation();return false}
        return !model.busy && !model.confirmingUntracked && !model.hasIdentitySettings && sender.attachedSheet == nil
    }
    func windowWillClose(_ notification:Notification) {
        guard notification.object as? NSWindow === window,!closed else{return};closed=true
        let progress=progressController;transportRetiredProgress=progress;progressController=nil
        model.afterClose=nil;model.invalidate();identitySettings?.retire()
        let warning=warning,reply=warningReply;self.warning=nil;warningReply=nil
        if let warning {
            let id=UUID(),release=StashChildRelease(window:warning.window,parent:window,closeWindow:true) { [self] in childReleases.removeValue(forKey:id);reply?(false)}
            childReleases[id]=release;release.start()
        } else {reply?(false)}
        progress?.close()
        if let window,let sheet=window.attachedSheet,sheet !== warning?.window,sheet !== progress?.window,sheet !== identitySettings?.window {window.endSheet(sheet,returnCode:.abort);sheet.close()}
        guard let window else{released=true;onClosed();let actions=closedActions;closedActions=[];actions.forEach {$0()};return}
        let release=StashChildRelease(window:window,parent:window.sheetParent,ready:{ [self] in
            !model.preparing && identitySettings == nil && childReleases.isEmpty && progress?.presentationClosed != false
        }) { [self] in self.release=nil;released=true;onClosed();let actions=closedActions;closedActions=[];actions.forEach {$0()} }
        self.release=release;release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class StashWindowModel: ObservableObject {
    private let commandProgressScope = CommandProgressContext.current
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    let preferences: UserDefaults
    var repositoryAccess:RepositoryAccessLease? {access}
    var handoffPresentation:MergeWindowPresentation?
    static private(set) var activePreparations=0
    private(set) var pendingTransportReads=0
    private var interactionGeneration=0
    @Published var confirmingQuit=false {didSet {if oldValue != confirmingQuit {formRevision=UUID();interactionGeneration += 1};progress?.confirmingQuit=confirmingQuit}}
    @Published var hasIdentitySettings=false
    @Published private(set) var preparing=false
    @Published private(set) var prepared=false
    @Published private(set) var formRevision=UUID()
    var closed:Bool {invalidated}
    var canEditForm:Bool {prepared && !invalidated && !busy && !preparing && !confirmingUntracked && !hasIdentitySettings && !confirmingQuit}
    struct FormContext:Equatable {let revision:UUID}
    var formContext:FormContext {.init(revision:formRevision)}
    func option<Value>(_ key:WritableKeyPath<StashSaveOptions,Value>,context:FormContext)->Binding<Value> {
        Binding(get:{self.options[keyPath:key]},set:{value in
            guard self.canEditForm,self.formContext == context else{return}
            if key == \StashSaveOptions.includeUntracked,self.options.all {return}
            if key == \StashSaveOptions.all,self.options.includeUntracked {return}
            self.options[keyPath:key]=value
        })
    }
    var readIdentity:((OperationCancellation) async throws -> ReplayUserIdentity)?
    var repairIdentity:() async -> Bool = {false}
    var retireIdentitySettings:()->Void = {}
    var becameIdle:()->Void = {}
    private var preparationToken:OperationCancellation?
    private var closeAfterPreparation=false
    @Published var options = StashSaveOptions()
    @Published var busy = false
    @Published var error: String?
    @Published private(set) var confirmingUntracked = false
    @Published private(set) var progress: StashSaveProgressWindowModel?
    var followUp = StashSaveFollowUp()
    var onProgress: ((StashSaveProgressWindowModel) -> Void)?
    var onPostAction: ((StashSavePostAction, StashSaveFollowUp) -> Void)?
    var afterClose:((@escaping ()->Void)->Void)?
    private var invalidated = false
    private var untrackedRequest: UUID?
    var canStart: () -> Bool = { true }
    var confirmUntracked: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    var close: () -> Void = {}
    var onSaved: (StashSaveResult) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; self.preferences = preferences }
    func save() { CommandProgressContext.perform(commandProgressScope) { saveWithCommandProgressContext() } }
    private func saveWithCommandProgressContext() {
        guard !invalidated, !confirmingQuit, !busy, !preparing, !confirmingUntracked else { return }
        guard prepared else {prepare(saveAfter:true);return}
        var snapshot = options; snapshot.requireIdentity=true
        if snapshot.includeUntracked && !preferences.bool(forKey: "Stash.NoIncludeUntrackedWarning") {
            let request = UUID(); untrackedRequest = request
            confirmingUntracked = true
            confirmUntracked { [weak self] accepted in
                guard let self, !self.invalidated, self.confirmingUntracked, self.untrackedRequest == request else { return }
                self.untrackedRequest = nil
                self.confirmingUntracked = false
                if accepted && !self.confirmingQuit { self.prepareSubmission(snapshot) }
            }
        } else { prepareSubmission(snapshot) }
    }
    func cancelPreparation() {preparationToken?.cancel();retireIdentitySettings()}
    func cancel() {if preparing {closeAfterPreparation=true;cancelPreparation()} else {close()}}
    private func requireIdentity(_ token:OperationCancellation) async throws {
        while true {
            try token.check();guard !invalidated,!confirmingQuit else {throw OperationCancellationFailure.cancelled}
            let identity:ReplayUserIdentity
            if let readIdentity {identity=try await readIdentity(token)} else {identity=try await repository.replayUserIdentity(cancellation:token)}
            try token.check();guard !invalidated,!confirmingQuit else {throw OperationCancellationFailure.cancelled}
            if identity.complete {return}
            guard await repairIdentity(),!invalidated else {throw OperationCancellationFailure.cancelled}
        }
    }
    func prepare(saveAfter:Bool=false) {beginPreparation(snapshot:nil,saveAfter:saveAfter)}
    private func prepareSubmission(_ snapshot:StashSaveOptions) {beginPreparation(snapshot:snapshot,saveAfter:false)}
    private func beginPreparation(snapshot:StashSaveOptions?,saveAfter:Bool) {
        guard !invalidated,!confirmingQuit,!busy,!preparing else{return}
        preparing=true;busy=true;formRevision=UUID();let token=OperationCancellation(),request=followUp;preparationToken=token;Self.activePreparations += 1; pendingTransportReads += 1
        Task { [self,access] in
            var accepted=false
            defer {
                Self.activePreparations -= 1; pendingTransportReads -= 1;withExtendedLifetime(access) {}
                if preparationToken === token {preparationToken=nil;preparing=false;busy=false
                    if !invalidated {becameIdle();if closeAfterPreparation {close()} else if accepted && !confirmingQuit {if let snapshot {perform(snapshot,followUp:request)} else if saveAfter {save()}}}
                }
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) {throw RepositoryAccessFailure.securityScopeUnavailable}
                try await requireIdentity(token);try token.check();guard !invalidated,!confirmingQuit else{return}
                prepared=true;accepted=true
            } catch {if !invalidated,!token.isCancelled,!(error is OperationCancellationFailure) {self.error=error.localizedDescription}}
        }
    }
    func invalidate() {invalidated=true;formRevision=UUID();cancelPreparation();untrackedRequest=nil;progress?.invalidate();progress=nil;busy=false;confirmingUntracked=false}
    func finish(_ progress: StashSaveProgressWindowModel) {
        guard !invalidated, self.progress === progress, !progress.busy,!progress.hasPendingWork,!progress.confirmingCancellation else { return }
        self.progress = nil; busy = false; close()
    }
    func abandonProgressPresentation(_ progress:StashSaveProgressWindowModel) {
        guard self.progress === progress else{return};progress.invalidate();self.progress=nil;busy=false;formRevision=UUID()
    }
    private func perform(_ snapshot: StashSaveOptions,followUp:StashSaveFollowUp) { CommandProgressContext.perform(commandProgressScope) { performWithCommandProgressContext(snapshot,followUp:followUp) } }
    private func performWithCommandProgressContext(_ snapshot: StashSaveOptions,followUp:StashSaveFollowUp) {
        guard !invalidated, !confirmingQuit, !busy else { return }
        guard canStart() else { error = "Wait for the current stash operation to finish."; return }
        busy = true
        let progress = StashSaveProgressWindowModel(repository: repository, access: access, options: snapshot, followUp: followUp, preferences: preferences)
        self.progress = progress
        progress.onFinished = { [weak self] result, details in
            guard let self, !self.invalidated else { return }
            if let result { self.onSaved(result) } else { self.onFailed(details) }
        }
        if let onPostAction {
            let afterClose=afterClose,generation=interactionGeneration
            progress.onPostAction = { [self,weak progress] action,request in
                guard !invalidated || progress?.hasDispatchedAction == true else{return}
                let dispatch=CommandProgressContext.capture(commandProgressScope) { [self] in guard !confirmingQuit,interactionGeneration == generation else{return};onPostAction(action,request)}
                if let afterClose {afterClose(dispatch)} else {dispatch()}
            }
        }
        progress.close = { [weak self, weak progress] in if let progress { self?.finish(progress) } }
        onProgress?(progress); progress.start()
    }
}
private struct StashDialog: View {
    @ObservedObject var model: StashWindowModel
    var body: some View {
        let context=model.formContext
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Stash Message") { TextField("Optional stash message", text: model.option(\.message,context:context)).textFieldStyle(.roundedBorder).padding(8) }.disabled(!model.canEditForm)
            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("include untracked", isOn: model.option(\.includeUntracked,context:context)).disabled(model.options.all)
                    Toggle("--all", isOn: model.option(\.all,context:context)).disabled(model.options.includeUntracked).help("Include untracked and ignored files.")
                }.toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .disabled(!model.canEditForm)
            Spacer(minLength: 0)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.save() }.keyboardShortcut(.defaultAction).disabled(!model.canEditForm)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(model.confirmingQuit || model.confirmingUntracked || model.progress != nil)
                Button("Help") { TurtleGitHelp.show(.stash) }
            }
        }.padding(16)
        .alert("Stash failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

struct StashSaveFollowUp {
    var showPull = false
    var pullShowPush = false
    var mergeRevision: String?
}
enum StashSavePostAction: String, CaseIterable, Hashable {
    case pull, merge, pop, apply
    var title: String {
        switch self { case .pull: return "Pull…"; case .merge: return "Merge…"; case .pop: return "Stash Pop"; case .apply: return "Stash Apply" }
    }
    var icon: MenuIcon {
        switch self { case .pull: return .pull; case .merge: return .merge; case .pop, .apply: return .stashPop }
    }
}
@MainActor final class StashSaveProgressWindowModel: ObservableObject {
    private let commandProgressScope = CommandProgressContext.current
    private final class CommandReceipt:@unchecked Sendable {
        private let lock=NSLock()
        private var receipt:StashSaveCommandCompletion?
        private var observer:(@Sendable()->Void)?
        func observe(_ observer:(@Sendable()->Void)?){lock.lock();self.observer=observer;lock.unlock()}
        func record(_ value:StashSaveCommandCompletion){lock.lock();guard receipt == nil else{lock.unlock();return};receipt=value;let observer=observer;lock.unlock();observer?()}
        func read()->StashSaveCommandCompletion? {lock.lock();defer{lock.unlock()};return receipt}
    }
    private let commandReceipt=CommandReceipt()
    private(set) static var activeOperations=0
    @Published private(set) var pendingOperations=0
    var hasPendingWork:Bool {pendingOperations > 0}
    var active:Bool {!invalidated}
    var workDidDrain:(()->Void)?
    private func beginWork(){pendingOperations += 1;Self.activeOperations += 1;LocalGitCommandProgress.begin()}
    private func endWork(){pendingOperations -= 1;Self.activeOperations -= 1;LocalGitCommandProgress.end();if !hasPendingWork {busy=false;workDidDrain?()}}
    let progressPresentation: GitCommandPresentation
    let repository: GitRepository
    let options: StashSaveOptions
    let followUp: StashSaveFollowUp
    let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private let access: RepositoryAccessLease?
    var repositoryAccess:RepositoryAccessLease? {access}
    var handoffPresentation:MergeWindowPresentation?
    private let cancellation = OperationCancellation()
    private var started = false
    private var invalidated = false
    private var dispatched=false
    var hasDispatchedAction:Bool {dispatched}
    private var interactionGeneration=0
    @Published var confirmingQuit=false {didSet {if oldValue != confirmingQuit {interactionGeneration += 1}}}
    var finishAndPerform:((@escaping ()->Void)->Void)?
    var presentationAvailable:()->Bool = {true}
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var completionRange:NSRange?
    @Published private(set) var commandFinished=false
    @Published private(set) var commandSucceeded=false
    var outputPreferences:UserDefaults {preferences}
    var outputClipboard:NSPasteboard = .general
    var saveOperation:((StashSaveOptions,OperationCancellation,@escaping @Sendable(GitOutputChunk)->Void,@escaping @Sendable(StashSaveCommandCompletion)->Void) async throws->StashSaveResult)?
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { busy && !confirmingQuit && !invalidated && !cancelling && !confirmingCancellation }
    @Published private(set) var result: StashSaveResult?
    @Published private(set) var postActions: [StashSavePostAction] = []
    var close: () -> Void = {}
    var onFinished: (StashSaveResult?, String) -> Void = { _, _ in }
    var onPostAction: ((StashSavePostAction, StashSaveFollowUp) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, options: StashSaveOptions, followUp: StashSaveFollowUp, preferences: UserDefaults = .standard) { self.preferences = preferences; progressPresentation = GitCommandPresentation(defaults: preferences); self.repository = repository; self.access = access; self.options = options; self.followUp = followUp; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences) }
    private func resetAttempt(){busy=true;success=false;cancelled=false;cancelling=false;output="";currentWork="";percentage=nil;completionRange=nil;commandFinished=false;commandSucceeded=false;result=nil;postActions=[]}
    func start() { CommandProgressContext.perform(commandProgressScope) { startWithCommandProgressContext() } }
    private func startWithCommandProgressContext() {guard !started,!invalidated,!confirmingQuit else{return};started=true;resetAttempt();beginWork();Task {await execute()}}
    func cancel() {
        guard canCancel else { return }
        // A question belongs to the phase in which it opened. A late Yes
        // must not move from the Git process to its later metadata inspection.
        let generation=interactionGeneration,commandWasFinished=commandFinished
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true; var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.invalidated else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && self.commandFinished == commandWasFinished && accepted && !self.confirmingQuit && self.interactionGeneration == generation { self.cancelling = true; self.cancellation.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; cancellation.cancel() }
    }
    private func finishAutomaticClose() {
        if !invalidated, !confirmingQuit, !busy, !hasPendingWork, !confirmingCancellation, autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() }
    }
    func invalidate() { invalidated = true; cancellation.cancel(); confirmingCancellation = false;if !hasPendingWork {busy=false};postActions=[] }
    func run() async { await CommandProgressContext.perform(commandProgressScope) { await runWithCommandProgressContext() } }
    private func runWithCommandProgressContext() async {
        guard !started,!invalidated,!confirmingQuit else{return};started=true;resetAttempt();beginWork();await execute()
    }
    private func bounded(_ text:String,bytes limit:Int)->String {
        let bytes=Data(text.utf8),limit=max(0,limit)
        guard bytes.count > limit else{return text}
        let marker="\n[Output truncated at about \(progressPresentation.outputLimit / 1024) KiB]\n"
        var count=max(0,limit-marker.utf8.count)
        while count > 0,bytes[count] & 0xc0 == 0x80 {count -= 1}
        return String(decoding:bytes.prefix(count),as:UTF8.self)+String(decoding:marker.utf8.prefix(limit-count),as:UTF8.self)
    }
    private func completeOutput(succeeded:Bool,error:Error?=nil,startedAt:TimeInterval) {
        guard !invalidated,!commandFinished else{return}
        let receipt=commandReceipt.read(),killed=error as? GitCommandCancellationFailure
        let succeeded=receipt?.success ?? succeeded
        let wasCancelled=receipt?.cancelled ?? (cancellation.isCancelled || killed != nil || error is OperationCancellationFailure || error is CancellationError)
        let code=receipt == nil ? killed?.result.exitCode ?? (error as? GitFailure)?.code:receipt?.exitCode
        let completion=SubmoduleProgressCompletion(success:succeeded,cancelled:wasCancelled && code == nil,exitCode:code,
            elapsed:receipt?.elapsed ?? (ProcessInfo.processInfo.systemUptime-startedAt),finished:receipt?.finished ?? Date(),preferences:preferences)
        output=bounded(output,bytes:progressPresentation.outputLimit-completion.text.utf8.count)
        completionRange=completion.append(to:&output);currentWork=completion.currentWork;percentage=100
        commandSucceeded=succeeded;commandFinished=true;cancelled=wasCancelled;OperationSounds.report(failed:!succeeded,preferences:preferences)
    }
    private func appendDiagnostic(_ text:String) {
        guard !text.isEmpty else{return}
        guard let range=completionRange else{output=GitProgressFailureOutput.renderDetails(text,existing:output,limit:progressPresentation.outputLimit);return}
        let previous=output as NSString
        guard NSMaxRange(range) <= previous.length else{return}
        let footer=previous.substring(with:range)
        let suffix=GitProgressFailureOutput.renderDetails(text,existing:previous.substring(from:NSMaxRange(range)),limit:max(256,progressPresentation.outputLimit-footer.utf8.count))
        let prefix=bounded(previous.substring(to:range.location),bytes:progressPresentation.outputLimit-footer.utf8.count-suffix.utf8.count)
        output=prefix+footer+suffix;completionRange=NSRange(location:(prefix as NSString).length,length:(footer as NSString).length)
    }
    private func streamSave(startedAt:TimeInterval)async throws->StashSaveResult {
        var state=GitProgressOutputState(preferences:preferences)
        let parser=GitCliOutputParser(limit:state.limit)
        let (updates,continuation)=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
        commandReceipt.observe {continuation.yield(())}
        defer {commandReceipt.observe(nil)}
        func consume(_ emission:GitCliOutputParser.Emission) {
            state.consume(emission,parser:parser)
            guard !invalidated,!commandFinished else{return}
            output=state.output;currentWork=state.currentWork;percentage=state.percentage
        }
        var parserFinished=false
        func finishParser(){guard !parserFinished else{return};parserFinished=true;consume(parser.processPending());consume(parser.finish())}
        let receipt=commandReceipt
        let operation=Task {
            defer {continuation.finish()}
            let emit:@Sendable(GitOutputChunk)->Void={chunk in parser.appendChunk(chunk.data);continuation.yield(())}
            let completed:@Sendable(StashSaveCommandCompletion)->Void={receipt.record($0)}
            if let saveOperation {return try await saveOperation(options,cancellation,emit,completed)}
            return try await repository.saveStash(options,cancellation:cancellation,onOutput:emit,onCommand:{emit(GitOutputChunk(stream:.stdout,data:$0.preamble))},onCommandFinished:completed)
        }
        for await _ in updates {
            consume(parser.processPending())
            if let receipt=commandReceipt.read() {finishParser();completeOutput(succeeded:receipt.success,startedAt:startedAt)}
        }
        finishParser()
        let saved:StashSaveResult
        do {saved=try await operation.value}
        catch let failure as GitFailure {
            if !invalidated,!commandFinished {state.presentFailure(failure);output=state.output;currentWork=state.currentWork;percentage=state.percentage}
            throw state.hasOutput && !commandSucceeded ? failure.markingOutputDelivered():failure
        } catch let failure as GitCommandCancellationFailure {
            if !invalidated,!commandFinished {state.presentFailure(failure);output=state.output;currentWork=state.currentWork;percentage=state.percentage}
            throw state.hasOutput && !commandSucceeded ? failure.markingOutputDelivered():failure
        }
        if !state.hasOutput,!commandFinished,!invalidated {output=LocalGitCommandProgress.bounded(saved.output,preferences:preferences)}
        return saved
    }
    private func execute()async {
        defer {endWork();withExtendedLifetime(access) {};if !invalidated,!hasPendingWork {cancelling=false;finishAutomaticClose()}}
        guard !invalidated else{return}
        let startedAt=ProcessInfo.processInfo.systemUptime
        var originalOutput = ""
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let saved=try await streamSave(startedAt:startedAt)
            guard !invalidated else { return }
            result = saved; originalOutput = saved.output; success = true
            completeOutput(succeeded:true,startedAt:startedAt)
            if followUp.showPull { postActions.append(.pull) }
            if followUp.mergeRevision != nil { postActions.append(.merge) }
            if saved.created { postActions += [.pop, .apply] }
        } catch {
            guard !invalidated else { return }; originalOutput = (error as? GitCommandCancellationFailure)?.result.text ?? error.localizedDescription
            let delivered=(error as? GitFailure)?.outputWasDelivered == true || (error as? GitCommandCancellationFailure)?.outputWasDelivered == true
            if commandFinished {if commandSucceeded || !delivered {appendDiagnostic(error.localizedDescription)}} else {output=LocalGitCommandProgress.failure(error,existing:output,preferences:preferences)}
            cancelled=cancelled || cancellation.isCancelled || error is OperationCancellationFailure || error is CancellationError || error is GitCommandCancellationFailure
            completeOutput(succeeded:false,error:error,startedAt:startedAt)
        }
        onFinished(result,originalOutput)
    }
    func perform(_ action: StashSavePostAction) { CommandProgressContext.perform(commandProgressScope) { performWithCommandProgressContext(action) } }
    private func performWithCommandProgressContext(_ action: StashSavePostAction) {
        guard !invalidated,presentationAvailable(),!confirmingQuit,!dispatched,!busy,!hasPendingWork,!confirmingCancellation,success,postActions.contains(action),let onPostAction else{return}
        dispatched=true;let request=followUp,generation=interactionGeneration
        let dispatch=CommandProgressContext.capture(commandProgressScope) { [self] in guard !confirmingQuit,interactionGeneration == generation else{return};onPostAction(action,request)}
        if let finishAndPerform {finishAndPerform(dispatch)} else {close();dispatch()}
    }
}
@MainActor final class StashSaveProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: StashSaveProgressWindowModel
    var onClosed: () -> Void = {}
    var onClosing:(NSWindow)->Void = {_ in}
    private var closed=false,retiring=false,finishing=false,closingForHandoff=false
    var presentationClosed:Bool {closed}
    private var pendingAction:(()->Void)?
    private var presentationParent:NSWindow?
    private var release:StashChildRelease?
    private var cancellationRelease:StashChildRelease?
    private(set) var cancellationAlert:NSAlert?
    var questionWindow:NSWindow? {cancellationAlert?.window}
    var presentCancellation:((NSAlert,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    private var cancellationAnswer:((NSApplication.ModalResponse)->Void)?
    init(model: StashSaveProgressWindowModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 390), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: model.repository.root, dialog: "Stash Save Progress", preferences: model.preferences)
        window.contentMinSize = NSSize(width: 520, height: 280); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StashSaveProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in
            self?.finishResult({})
        }
        model.finishAndPerform = { [weak self] action in self?.finishResult(action) }
        model.workDidDrain = { [weak self] in guard let self,self.finishing else{return};self.closeIfReady() }
        model.presentationAvailable = { [weak self] in guard let self else{return false};return !self.closed && !self.retiring && !self.finishing && self.cancellationAlert == nil && self.window?.attachedSheet == nil }

        model.confirmCancellation = { [weak self] choose in
            guard let self,!self.closed,!self.retiring,self.model.active,!self.model.confirmingQuit,self.cancellationAlert == nil,let window=self.window,window.attachedSheet == nil else {choose(false);return}
            let alert=NSAlert();alert.alertStyle = .informational;alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.effectiveAppearance
            alert.messageText="The process is still running.";alert.informativeText="Are you sure to abort?"
            let yes=alert.addButton(withTitle:"Yes"),no=alert.addButton(withTitle:"No")
            alert.layout();yes.keyEquivalent="\r";no.keyEquivalent="\u{1b}";alert.window.defaultButtonCell=yes.cell as? NSButtonCell
            self.cancellationAlert=alert;var answered=false
            let answer:(NSApplication.ModalResponse)->Void = { [weak self] response in
                guard !answered,let self,self.cancellationAlert === alert else{return};answered=true
                let release=StashChildRelease(window:alert.window,parent:window,closeWindow:true) { [self] in
                    let accepted = !self.retiring && !self.closed && self.model.active && !self.model.confirmingQuit && self.cancellationAlert === alert
                    self.cancellationAlert=nil;self.cancellationAnswer=nil;self.cancellationRelease=nil
                    choose(accepted && response == .alertFirstButtonReturn)
                    if self.finishing {self.closeIfReady()}
                }
                self.cancellationRelease=release;release.start()
            }
            self.cancellationAnswer=answer
            if let presentCancellation=self.presentCancellation {presentCancellation(alert,window,answer)}
            else {alert.beginSheetModal(for:window,completionHandler:answer)}
        }
        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    private func finishResult(_ action:@escaping ()->Void) {
        guard !closed,!retiring,!finishing,model.active,!model.confirmingQuit else{return}
        finishing=true;pendingAction=action;closeIfReady()
    }
    private func closeIfReady() {
        guard !closed,!retiring,finishing,model.active,!model.confirmingQuit,!model.busy,!model.hasPendingWork,!model.confirmingCancellation,cancellationAlert == nil,let window,window.attachedSheet == nil else{return}
        presentationParent=window.sheetParent;closingForHandoff=true;window.close()
        if !retiring,!window.isVisible {retireClosedWindow()}
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.confirmingQuit,!finishing,!retiring else{return false}
        if model.busy { model.cancel(); return false }
        guard !model.hasPendingWork,!model.confirmingCancellation,cancellationAlert == nil,sender.attachedSheet == nil else { return false }
        finishResult({});return false
    }
    private func retireClosedWindow() {
        guard !closed,!retiring else{return};retiring=true
        if let window {model.handoffPresentation=MergeWindowPresentation(window);onClosing(window)}
        model.invalidate();model.finishAndPerform=nil;model.workDidDrain=nil;model.close={}
        cancellationAnswer?(.abort)
        let action=closingForHandoff ? pendingAction:nil;pendingAction=nil
        guard let window else{closed=true;model.saveActionLog();onClosed();action?();return}
        if let sheet=window.attachedSheet,sheet !== questionWindow {window.endSheet(sheet,returnCode:.abort);sheet.close()}
        let release=StashChildRelease(window:window,parent:presentationParent ?? window.sheetParent,ready:{ [self] in !model.hasPendingWork && cancellationAlert == nil}) { [self] in
            self.release=nil;closed=true;model.saveActionLog();onClosed();action?()
        }
        self.release=release;release.start()
    }
    func windowWillClose(_ notification:Notification) {guard notification.object as? NSWindow === window else{return};retireClosedWindow()}
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
struct StashSaveProgressDialog: View {
    @ObservedObject var model: StashSaveProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SubmoduleProgressOutputView(text:model.output,completed:model.commandFinished,completionRange:model.completionRange,success:model.commandSucceeded,preferences:model.outputPreferences,clipboard:model.outputClipboard).frame(maxWidth:.infinity,maxHeight:.infinity)
            if model.commandFinished {ProgressView(value:100,total:100).tint(model.commandSucceeded ? Color.accentColor:Color.red)}
            else {GitCommandProgressBar(percentage:model.percentage,animate:model.progressPresentation.animateActivity)}
            if !model.currentWork.isEmpty {Text(model.currentWork).font(.caption).lineLimit(2)}
            HStack {
                if model.busy {Text(model.cancelling ? "Cancelling…":model.commandFinished ? "Checking stash result…":"Saving stash…")}
                else { Text(model.cancelled ? "Cancelled" : model.success ? "Finished" : "Stash failed").foregroundStyle(model.success ? Color.green : Color.red) }
                Spacer()
            }
            HStack {
                if let first = model.postActions.first {
                    HStack(spacing: 2) {
                        Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                        Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Stash post-actions") }.menuStyle(.borderlessButton).fixedSize()
                    }.disabled(model.onPostAction == nil || model.busy || model.hasPendingWork || model.confirmingCancellation || model.confirmingQuit || !model.presentationAvailable())
                }
                Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else {Button("Close") {model.close()}.keyboardShortcut(.defaultAction).disabled(model.hasPendingWork || model.confirmingCancellation || model.confirmingQuit || !model.presentationAvailable())}
            }
        }.padding(12)
        .gitDockProgress(.command(busy:model.busy && !model.commandFinished,success:model.commandSucceeded,waiting:model.confirmingCancellation,percentage:model.percentage))
    }
}

/// Retains the actual AppKit detach transition, including forced owner closure.
@MainActor final class StashChildRelease {
    static private(set) var activeCount=0
    private let window:NSWindow,parent:NSWindow?
    private let closeWindow:Bool
    private let ready:()->Bool
    private var completion:()->Void
    private var observer:NSObjectProtocol?
    private var finished=false
    private var started=false
    private var waiter:Task<Void,Never>?
    init(window:NSWindow,parent:NSWindow?,closeWindow:Bool=false,ready:@escaping ()->Bool={true},completion:@escaping ()->Void) {self.window=window;self.parent=parent;self.closeWindow=closeWindow;self.ready=ready;self.completion=completion}
    func start() {
        guard !started else{return};started=true
        Self.activeCount += 1
        if window.sheetParent != nil || parent?.attachedSheet === window {
            observer=NotificationCenter.default.addObserver(forName:NSWindow.didEndSheetNotification,object:parent,queue:.main) { [self] _ in DispatchQueue.main.async {self.drain()} }
            (window.sheetParent ?? parent)?.endSheet(window);window.orderOut(nil)
        }
        drain()
        if !finished {waiter=Task { @MainActor [self] in while !finished {try? await Task.sleep(nanoseconds:5_000_000);drain()}}}
    }
    private func drain() {
        guard !finished,window.attachedSheet == nil,window.sheetParent == nil,parent?.attachedSheet !== window,ready() else{return};finished=true
        waiter?.cancel();waiter=nil
        if let observer {NotificationCenter.default.removeObserver(observer);self.observer=nil}
        Self.activeCount -= 1;if closeWindow {window.close()};let done=completion;completion={};done()
    }
}
