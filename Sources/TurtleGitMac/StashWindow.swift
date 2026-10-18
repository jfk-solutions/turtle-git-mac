import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class StashWindowController: NSWindowController, NSWindowDelegate {
    let model: StashWindowModel
    var onClosed: () -> Void = {}
    private(set) var progressController: StashSaveProgressWindowController?
    static var activeChildReleases: Int { StashChildRelease.activeCount }
    private var identitySettings: SettingsSheetController?
    var identitySettingsWindow: NSWindow? { identitySettings?.window }
    var identityNavigation: SettingsNavigationController? { identitySettings?.navigation }
    private var warning: NSAlert?
    private var warningReply: ((Bool) -> Void)?
    private var closingPreparation=false,closed=false
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = StashWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Stash", preferences: preferences)
        window.minSize = NSSize(width: 500, height: 272); window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 272)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StashDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 560, height: 240)); window.center()
        model.close = { [weak self] in
            guard let self, !self.model.confirmingQuit, !self.model.busy, !self.model.hasIdentitySettings, !self.model.confirmingUntracked, self.window?.attachedSheet == nil else { return }
            self.window?.close()
        }
        model.onProgress = { [weak self] progress in
            guard let self, let window = self.window, window.attachedSheet == nil else { progress.cancel(); return }
            let controller = StashSaveProgressWindowController(model: progress)
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
        guard !closed else{return};closed=true
        model.invalidate();identitySettings?.retire()
        let warning=warning,reply=warningReply;self.warning=nil;warningReply=nil
        if let warning {let release=StashChildRelease(window:warning.window,parent:window) {reply?(false)};release.start()} else {reply?(false)}
        let progress=progressController;progressController=nil
        if let child=progress?.window {let release=StashChildRelease(window:child,parent:window) {progress?.close()};release.start()}
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class StashWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    let preferences: UserDefaults
    var repositoryAccess:RepositoryAccessLease? {access}
    static private(set) var activePreparations=0
    @Published var confirmingQuit=false {didSet {if oldValue != confirmingQuit {formRevision=UUID()};progress?.confirmingQuit=confirmingQuit}}
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
    private var invalidated = false
    private var untrackedRequest: UUID?
    var canStart: () -> Bool = { true }
    var confirmUntracked: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    var close: () -> Void = {}
    var onSaved: (StashSaveResult) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; self.preferences = preferences }
    func save() {
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
        preparing=true;busy=true;formRevision=UUID();let token=OperationCancellation(),request=followUp;preparationToken=token;Self.activePreparations += 1
        Task { [self,access] in
            var accepted=false
            defer {
                Self.activePreparations -= 1;withExtendedLifetime(access) {}
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
        guard !invalidated, self.progress === progress, !progress.busy else { return }
        self.progress = nil; busy = false; close()
    }
    private func perform(_ snapshot: StashSaveOptions,followUp:StashSaveFollowUp) {
        guard !invalidated, !confirmingQuit, !busy else { return }
        guard canStart() else { error = "Wait for the current stash operation to finish."; return }
        busy = true
        let progress = StashSaveProgressWindowModel(repository: repository, access: access, options: snapshot, followUp: followUp, preferences: preferences)
        self.progress = progress
        progress.onFinished = { [weak self] result, details in
            guard let self, !self.invalidated else { return }
            if let result { self.onSaved(result) } else { self.onFailed(details) }
        }
        progress.onPostAction = onPostAction
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
    let progressPresentation: GitCommandPresentation
    let repository: GitRepository
    let options: StashSaveOptions
    let followUp: StashSaveFollowUp
    let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private let access: RepositoryAccessLease?
    private let cancellation = OperationCancellation()
    private var started = false
    private var invalidated = false
    private var dispatched=false
    @Published var confirmingQuit=false
    var finishAndPerform:((@escaping ()->Void)->Void)?
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
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
    func start() { Task { await run() } }
    func cancel() {
        guard canCancel else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true; var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.invalidated else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; self.cancellation.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; cancellation.cancel() }
    }
    private func finishAutomaticClose() {
        if !invalidated, !confirmingQuit, !busy, !confirmingCancellation, autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() }
    }
    func invalidate() { invalidated = true; cancellation.cancel(); confirmingCancellation = false; busy = false; postActions = [] }
    func run() async {
        guard !started, !invalidated else { return }; started = true
        LocalGitCommandProgress.begin(); defer { LocalGitCommandProgress.end(); withExtendedLifetime(access) {} }
        var originalOutput = ""
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let saved = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in
                guard let self, !self.invalidated else { return }
                self.output = state.output; self.currentWork = state.currentWork; self.percentage = state.percentage
            }, resultText: { $0.output }, operation: { [repository, options, cancellation] emit in try await repository.saveStash(options, cancellation: cancellation, onOutput: emit) })
            guard !invalidated else { return }
            result = saved; originalOutput = saved.output; success = true
            if followUp.showPull { postActions.append(.pull) }
            if followUp.mergeRevision != nil { postActions.append(.merge) }
            if saved.created { postActions += [.pop, .apply] }
        } catch {
            guard !invalidated else { return }; originalOutput = (error as? GitCommandCancellationFailure)?.result.text ?? error.localizedDescription
            output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences); cancelled = cancellation.isCancelled
        }
        busy = false; cancelling = false; currentWork = ""; percentage = nil; onFinished(result, originalOutput)
        finishAutomaticClose()
    }
    func perform(_ action: StashSavePostAction) {
        guard !invalidated,!confirmingQuit,!dispatched,!busy,!confirmingCancellation,success,postActions.contains(action),let onPostAction else{return}
        dispatched=true;let request=followUp
        let dispatch={onPostAction(action,request)}
        if let finishAndPerform {finishAndPerform(dispatch)} else {close();dispatch()}
    }
}
@MainActor final class StashSaveProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: StashSaveProgressWindowModel
    var onClosed: () -> Void = {}
    private var closed=false,finishing=false
    private var cancellationAlert:NSAlert?
    private var cancellationReply:((Bool)->Void)?
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

        model.confirmCancellation = { [weak self] choose in
            guard let self,let window=self.window,window.attachedSheet == nil else {choose(false);return}
            let alert=NSAlert();alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
            alert.messageText="The process is still running.";alert.informativeText="Are you sure to abort?"
            let yes=alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No");yes.keyEquivalent="\r";alert.window.defaultButtonCell=yes.cell as? NSButtonCell
            self.cancellationAlert=alert;var answered=false
            let reply:(Bool)->Void = {value in guard !answered else{return};answered=true;choose(value)}
            self.cancellationReply=reply
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self,self.cancellationAlert === alert else{reply(false);return}
                let release=StashChildRelease(window:alert.window,parent:window) { [weak self] in
                    guard let self,self.cancellationAlert === alert else{reply(false);return}
                    self.cancellationAlert=nil;self.cancellationReply=nil;reply(response == .alertFirstButtonReturn)
                };release.start()
            }
        }
        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    private func finishResult(_ action:@escaping ()->Void) {
        guard !closed,!finishing,!model.confirmingQuit,!model.busy,!model.confirmingCancellation,let window,window.attachedSheet == nil else{return}
        finishing=true
        let release=StashChildRelease(window:window,parent:window.sheetParent) { [self] in
            guard !closed else{return};window.close();action()
        };release.start()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.confirmingQuit,!finishing else{return false}
        if model.busy { model.cancel(); return false }
        guard !model.confirmingCancellation, sender.attachedSheet == nil else { return false }
        finishResult({});return false
    }
    func windowWillClose(_ notification:Notification) {
        guard !closed else{return};closed=true
        model.saveActionLog();model.invalidate()
        let alert=cancellationAlert,reply=cancellationReply;cancellationAlert=nil;cancellationReply=nil
        if let alert {let release=StashChildRelease(window:alert.window,parent:window) {reply?(false)};release.start()} else {reply?(false)}
        if let window,window.sheetParent != nil {let release=StashChildRelease(window:window,parent:window.sheetParent) {};release.start()}
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
private struct StashSaveProgressDialog: View {
    @ObservedObject var model: StashSaveProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: model.success, preferences: model.preferences).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if model.busy { LocalGitProgressIndicator(percentage: model.percentage, animate: model.progressPresentation.animateActivity); Text(model.currentWork.isEmpty ? "Saving stash…" : model.currentWork) }
                else { Text(model.cancelled ? "Cancelled" : model.success ? "Finished" : "Stash failed").foregroundStyle(model.success ? Color.green : Color.red) }
                Spacer()
            }
            HStack {
                if let first = model.postActions.first {
                    HStack(spacing: 2) {
                        Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                        Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Stash post-actions") }.menuStyle(.borderlessButton).fixedSize()
                    }.disabled(model.onPostAction == nil)
                }
                Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(12)
        .gitDockProgress(.command(busy: model.busy, success: model.success, waiting: model.confirmingCancellation, percentage: model.percentage))
    }
}

/// Retains the actual AppKit detach transition, including forced owner closure.
@MainActor final class StashChildRelease {
    static private(set) var activeCount=0
    private let window:NSWindow,parent:NSWindow?
    private var completion:()->Void
    private var observer:NSObjectProtocol?
    private var finished=false
    init(window:NSWindow,parent:NSWindow?,completion:@escaping ()->Void) {self.window=window;self.parent=parent;self.completion=completion}
    func start() {
        Self.activeCount += 1
        if window.sheetParent == nil && parent?.attachedSheet !== window {drain();return}
        observer=NotificationCenter.default.addObserver(forName:NSWindow.didEndSheetNotification,object:parent,queue:.main) { [self] _ in DispatchQueue.main.async {self.drain()} }
        window.sheetParent?.endSheet(window);window.orderOut(nil);DispatchQueue.main.async { [self] in drain()}
    }
    private func drain() {
        guard !finished,window.sheetParent == nil,parent?.attachedSheet !== window else{return};finished=true
        if let observer {NotificationCenter.default.removeObserver(observer);self.observer=nil}
        Self.activeCount -= 1;let done=completion;completion={};done()
    }
}
