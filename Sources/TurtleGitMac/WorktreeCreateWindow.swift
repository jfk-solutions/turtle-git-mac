import AppKit
import SwiftUI
import TurtleGitCore

enum WorktreeFinderRegistrationFailure:LocalizedError {
    case unverified,identityChanged
    var errorDescription:String? {
        switch self {
        case .unverified:return "The created worktree has not been verified. Review it before adding it to TurtleGit."
        case .identityChanged:return "The created worktree no longer matches its accepted repository and revision. Review it before adding it to TurtleGit."
        }
    }
}

@MainActor final class WorktreeCreateWindowController: NSWindowController, NSWindowDelegate {
    var commandProgressScope: CommandProgressScope? { model.commandProgressScope }
    let model: WorktreeCreateWindowModel
    var onClosed: () -> Void = {}
    var externalAvailability: () -> Bool { get { model.externalAvailability } set { model.externalAvailability = newValue } }
    private var closed = false, finishing = false
    private var cancellationAlert: NSAlert?
    private var cancellationReply: ((Bool) -> Void)?
    private var handoffReply: ((Bool) -> Void)?
    private var directoryPanel:NSOpenPanel?
    private var directoryReply:((NSApplication.ModalResponse)->Void)?
    private var retiring=false
    var directoryBookmarkProvider:any RepositoryBookmarkProvider=SystemRepositoryBookmarkProvider()
    var presentDirectoryPanel:(NSOpenPanel,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void={panel,parent,reply in panel.beginSheetModal(for:parent,completionHandler:reply)}
    var selectedDirectoryURL:(NSOpenPanel)->URL?={$0.url}
    var finderServiceCanPresent:Bool {!closed && model.active}
    var finderServiceWorkPending:Bool {retiring || model.busy || model.chooser.busy || referencePicker != nil || commitPicker != nil || directoryPanel != nil || cancellationAlert != nil || handoffReply != nil || window?.attachedSheet != nil}
    private func presentDirectory(_ panel:NSOpenPanel,parent:NSWindow,reply:@escaping(NSApplication.ModalResponse)->Void){
        var answered=false
        let answer:(NSApplication.ModalResponse)->Void={ [weak self] response in guard !answered else{return};answered=true;self?.directoryReply=nil;reply(response)}
        directoryReply=answer;presentDirectoryPanel(panel,parent,answer)
    }
    private var pickers: VersionPickerCoordinator!
    var referencePicker: ReferenceBrowserWindowController? { pickers.referencePicker }
    var commitPicker: LogWindowController? { pickers.commitPicker }
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void { get { pickers.configureReferencePicker } set { pickers.configureReferencePicker = newValue } }
    var configureCommitPicker: (LogWindowModel) -> Void { get { pickers.configureCommitPicker } set { pickers.configureCommitPicker = newValue } }
    var presentPicker: (NSWindow, NSWindow) -> Bool { get { pickers.presentPicker } set { pickers.presentPicker = newValue } }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void, UserDefaults, String?) -> LogWindowController { get { pickers.makeCommitPicker } set { pickers.makeCommitPicker = newValue } }

    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, initialDirectory: URL? = nil) {
        model = WorktreeCreateWindowModel(repository: repository, access: access, preferences: preferences, initialDirectory: initialDirectory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "New Worktree", preferences: preferences)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WorktreeCreateDialog(model: model, chooser: model.chooser).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        pickers = VersionPickerCoordinator(window: window, model: model.chooser, access: access, preferences: preferences, allowed: { [weak model] in model?.canPickBase == true },resultAllowed:{[weak model] in model?.canAcceptBasePicker==true})
        pickers.contextualDraft = { [weak model] in guard let model else { return [] }; return [String(model.useHead), model.directory, model.branchName, String(model.createBranch), String(model.detach), String(model.force), String(model.checkout)].map { GitReferenceName($0) } }
        pickers.onSelection = { [weak model] in if model?.useHead == false { model?.changedBase() } }
        window.setContentSize(NSSize(width: 660, height: 420)); window.contentMinSize = NSSize(width: 640, height: 420)
        window.center()
        model.close = { [weak self] in self?.window?.performClose(nil) }
        model.finishAndPerform = { [weak self] reply in
            guard let self else { reply(false); return }; self.finishResult(reply)
        }
        model.chooseDirectory = { [weak self] in self?.chooseDirectory() }
        model.authorizeDestination = { [weak self] path, token in await self?.authorizeDestination(path, cancellation: token) }
        model.confirmCancellation = { [weak self] reply in
            guard let self, let window = self.window, window.attachedSheet == nil else { reply(false); return }
            let alert = NSAlert(); alert.messageText = String(localized: "The process is still running."); alert.informativeText = String(localized: "Are you sure to abort?")
            alert.addButton(withTitle: String(localized: "Yes")); alert.addButton(withTitle: String(localized: "No"))
            alert.window.alphaValue = window.alphaValue; alert.window.appearance = window.appearance
            self.cancellationAlert = alert
            var answered = false
            let answer: (Bool) -> Void = { accepted in guard !answered else { return }; answered = true; reply(accepted) }
            self.cancellationReply = answer
            alert.beginSheetModal(for: window) { [weak self] response in
                Task { @MainActor in
                    await Self.detach(alert.window)
                    guard let self, self.cancellationAlert === alert else { answer(false); return }
                    self.cancellationAlert = nil; self.cancellationReply = nil
                    answer(response == .alertFirstButtonReturn)
                }
            }
        }
        model.load()

        DialogGeometry.attach(window, identifier: "CreateWorktreeDialog", legacyName: "CreateWorktreeDialog")
    }
    private static func detach(_ child: NSWindow) async {
        let parent = child.sheetParent
        parent?.endSheet(child, returnCode: .cancel); child.orderOut(nil)
        while child.sheetParent != nil || parent?.attachedSheet === child {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private func finishResult(_ reply: ((Bool) -> Void)? = nil) {
        guard !closed, !finishing, model.active, !model.confirmingQuit, model.externalAvailability(),
              !model.busy, !model.confirmingCancellation, !model.chooser.busy,
              model.chooser.pickerTarget == nil, window?.attachedSheet == nil else { reply?(false); return }
        finishing = true; handoffReply = reply
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        close()
        if !closed { retireClosedWindow() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closed, !finishing, !model.confirmingQuit, model.externalAvailability() else { return false }
        if model.busy && model.progress { model.cancel(); return false }
        guard !model.busy, !model.confirmingCancellation, !model.chooser.busy,
              model.chooser.pickerTarget == nil, sender.attachedSheet == nil else { return false }
        finishResult(); return false
    }
    override func close() { super.close(); if !closed { retireClosedWindow() } }
    func windowWillClose(_ notification: Notification) { retireClosedWindow() }
    private func retireClosedWindow() {
        guard !closed else { return }; closed = true
        let acceptedHandoff = finishing
        let reply = handoffReply; handoffReply = nil
        let alert = cancellationAlert, cancelReply = cancellationReply
        cancellationAlert = nil; cancellationReply = nil
        let panel = directoryPanel; directoryPanel = nil
        let directoryResponse=directoryReply;directoryReply=nil;retiring=true
        let sheets = [window?.attachedSheet, panel, alert?.window].compactMap { $0 }
        model.saveActionLog(); model.invalidate(); pickers.invalidate();directoryResponse?(.cancel)
        WorktreeCreateWindowModel.activeOperations += 1
        Task { [self] in
            defer { WorktreeCreateWindowModel.activeOperations -= 1 }
            for sheet in sheets { await Self.detach(sheet) }
            cancelReply?(false)
            if let window { await Self.detach(window) }
            while model.busy || model.chooser.busy || referencePicker != nil || commitPicker != nil {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            retiring=false;let done=onClosed;onClosed={};done()
            reply?(acceptedHandoff && !model.confirmingQuit && model.externalAvailability())
        }
    }
    private func chooseDirectory() {
        guard model.commandsAvailable, !finishing, !model.chooser.busy, let window, window.attachedSheet == nil, !model.busy, model.chooser.pickerTarget == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.title = "Worktree Directory"; panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: model.directory).deletingLastPathComponent()
        panel.alphaValue = window.alphaValue; panel.appearance = window.appearance
        directoryPanel=panel
        let draft = [model.directory, model.branchName, String(model.useHead), String(model.createBranch), String(model.detach), String(model.force), String(model.checkout)].map { GitReferenceName($0) }
        WorktreeCreateWindowModel.activeOperations += 1
        presentDirectory(panel,parent:window) { [weak self] response in
            Task { @MainActor in
                defer { WorktreeCreateWindowModel.activeOperations -= 1 }
                await Self.detach(panel)
                guard let self, self.directoryPanel === panel else { return }; self.directoryPanel=nil
                let current = [self.model.directory, self.model.branchName, String(self.model.useHead), String(self.model.createBranch), String(self.model.detach), String(self.model.force), String(self.model.checkout)].map { GitReferenceName($0) }
                guard self.model.commandsAvailable, !self.finishing, draft == current, response == .OK, let folder = self.selectedDirectoryURL(panel) else { return }
                let lease = RepositoryAccessLease(url:folder,provider:self.directoryBookmarkProvider)
                guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { self.model.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
                self.model.destinationAccess = lease; self.model.directory = folder.path
            }
        }
    }
    private func authorizeDestination(_ path: URL, cancellation: OperationCancellation) async -> RepositoryAccessLease? {
        guard model.commandsAvailable, !finishing, !cancellation.isCancelled, let window, window.attachedSheet == nil, directoryPanel == nil else { return nil }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.title = "Worktree Directory"; panel.prompt = "Authorize"
        panel.message = "Choose the worktree directory or an existing parent folder to allow TurtleGit to create it."
        panel.directoryURL = path.deletingLastPathComponent(); panel.alphaValue = window.alphaValue; panel.appearance = window.appearance; directoryPanel = panel
        return await withCheckedContinuation { continuation in
            presentDirectory(panel,parent:window) { [weak self] response in
                Task { @MainActor in
                    await Self.detach(panel)
                    guard let self, self.directoryPanel === panel else { continuation.resume(returning: nil); return }
                    self.directoryPanel = nil
                    guard self.model.commandsAvailable, !self.finishing, !cancellation.isCancelled, response == .OK, let selected = self.selectedDirectoryURL(panel) else { continuation.resume(returning: nil); return }
                    continuation.resume(returning: RepositoryAccessLease(url:selected,provider:self.directoryBookmarkProvider))
                }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class WorktreeCreateWindowModel: ObservableObject {
    let commandProgressScope = CommandProgressContext.current
    let progressPresentation: GitCommandPresentation
    static var activeOperations=0
    var active:Bool { !invalidated }
    @Published var confirmingQuit = false
    var externalAvailability: () -> Bool = { true }
    var commandsAvailable: Bool { active && !confirmingQuit && externalAvailability() && !handoffPending }
    @Published private(set) var handoffPending = false
    var finishAndPerform: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canUpdateSubmodules: Bool { commandsAvailable && acceptedCreation?.verified == true && success && hasSubmodules && !busy && !confirmingCancellation && !chooser.busy && chooser.pickerTarget == nil && createdPath != nil }
    let chooser: SwitchWindowModel
    let access: RepositoryAccessLease?
    var destinationAccess: RepositoryAccessLease?
    var requiresSecurityScope = GitRuntime.isAppStoreBuild
    var authorizeDestination: (URL, OperationCancellation) async throws -> RepositoryAccessLease? = { _, _ in nil }
    @Published private(set) var authorizingDestination = false
    @Published var directory: String
    @Published var currentBranch = ""
    @Published var useHead = true
    @Published var createBranch = false
    @Published var branchName = ""
    @Published var checkout = true
    @Published var force = false
    @Published var detach = false
    @Published var busy = false
    @Published var progress = false
    @Published var success = false
    @Published var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var completionRange: NSRange?
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { commandsAvailable && busy && progress && !cancelling && !confirmingCancellation }
    @Published var error: String?
    @Published var hasSubmodules = false
    @Published var cancelled = false
    private var invalidated = false
    struct BaseContext:Equatable {
        let owner:ObjectIdentifier
        let chooser:SwitchWindowModel.FormContext
        let draft:[GitReferenceName]
    }
    var baseContext:BaseContext {
        .init(owner:ObjectIdentifier(self),chooser:chooser.formContext,draft:[String(useHead),directory,branchName,String(createBranch),String(detach),String(force),String(checkout)].map{GitReferenceName($0)})
    }
    private var baseAvailableIgnoringOwnedPicker:Bool {commandsAvailable && acceptedCreation==nil && !busy && !progress && !chooser.busy}
    var canEditBase:Bool {baseAvailableIgnoringOwnedPicker && chooser.pickerTarget==nil}
    // Begin requires no picker; its immutable accepted result necessarily
    // returns while the same owned picker is still attached/draining.
    var canAcceptBasePicker:Bool {baseAvailableIgnoringOwnedPicker && !useHead && chooser.pickerTarget != nil}
    private func acceptsBase(_ context:BaseContext)->Bool {canEditBase && context==baseContext}
    func field<Value>(_ key:ReferenceWritableKeyPath<WorktreeCreateWindowModel,Value>,context:BaseContext,changed:(()->Void)?=nil)->Binding<Value> {
        Binding(get:{self[keyPath:key]},set:{if self.acceptsBase(context) {self[keyPath:key]=$0;changed?()}})
    }
    func baseRevision(_ target:CheckoutTarget,context:BaseContext)->Binding<String> {
        Binding(get:{switch target {case .branch:return self.chooser.branchRevision;case .tag:return self.chooser.tagRevision;case .commit:return self.chooser.commitRevision}},set:{
            guard self.acceptsBase(context),!self.useHead,self.chooser.options.target==target else{return}
            switch target {case .branch:self.chooser.branchRevision=$0;case .tag:self.chooser.tagRevision=$0;case .commit:self.chooser.commitRevision=$0}
        })
    }
    func selectBase(_ target:CheckoutTarget?,context:BaseContext) {
        guard acceptsBase(context) else{return};useHead=target==nil
        if let target {chooser.options.target=target};changedBase()
    }
    func browseBase(_ target:CheckoutTarget,context:BaseContext) {
        guard acceptsBase(context),!useHead,chooser.options.target==target else{return};chooser.browse(target)
    }
    func focusBase(_ reference:NSControl,target:CheckoutTarget,context:BaseContext) {
        guard acceptsBase(context),!useHead,chooser.options.target==target else{return};chooser.focusReference(reference,target:target)
    }
    func browseDirectory(context:BaseContext) {guard acceptsBase(context) else{return};chooseDirectory()}
    var canPickBase: Bool { canEditBase && !useHead }
    func invalidate() { invalidated = true; cancellation?.cancel(); finderRegistrationRequest=nil; confirmingCancellation = false; chooser.invalidate() }
    private var cancellation: OperationCancellation?
    private(set) var createdPath: URL?
    private(set) var acceptedCreation:WorktreeCreationReceipt?
    private var notifiedCreation=false,acceptedLateCancellation=false
    var performCreation:((GitRepository,URL,WorktreeCreationOptions,OperationCancellation)async throws->WorktreeCreationReceipt)?
    /// The accepted checkout remains successful even if optional Finder setup
    /// fails. A retry uses this same receipt/grant, never another worktree add.
    var registerCreatedWorktree:((WorktreeCreationReceipt,RepositoryAccessLease,OperationCancellation) async throws->Void)?
    @Published private(set) var finderRegistrationWarning:String?
    @Published private(set) var finderRegistrationComplete=false
    private var finderRegistrationRequest:(WorktreeCreationReceipt,RepositoryAccessLease)?
    var canRetryFinderRegistration:Bool {commandsAvailable && success && !busy && !confirmingCancellation && !chooser.busy && chooser.pickerTarget==nil && finderRegistrationWarning != nil && finderRegistrationRequest != nil && registerCreatedWorktree != nil && !finderRegistrationComplete}
    private func registerAcceptedWorktree(_ receipt:WorktreeCreationReceipt,lease:RepositoryAccessLease?,token:OperationCancellation) async {
        guard let register=registerCreatedWorktree else{return}
        guard receipt.verified else{return}
        guard let lease else {
            if active {finderRegistrationWarning="The worktree was created, but its accepted folder permission is unavailable. Add this repository in Icon Overlays settings.";output += "\n"+finderRegistrationWarning!+"\n"}
            return
        }
        finderRegistrationRequest=(receipt,lease)
        do {
            try token.check();guard active,externalAvailability(),!confirmingQuit else{throw OperationCancellationFailure.cancelled}
            currentWork="Adding worktree to TurtleGit…"
            try await register(receipt,lease,token)
            // A completed durable publication remains completed when Cancel
            // arrives with its receipt; do not offer a duplicate registration.
            if active {finderRegistrationComplete=true;finderRegistrationRequest=nil;finderRegistrationWarning=nil}
        } catch {
            guard active,externalAvailability() else{return}
            let warning=token.isCancelled ? "The worktree was created. Finder registration was stopped. Retry to add this checkout to TurtleGit.":"The worktree was created, but its Finder registration could not be saved. Retry without recreating the worktree.\n"+error.localizedDescription
            finderRegistrationWarning=warning;output += "\n"+warning+"\n"
        }
    }
    func retryFinderRegistration() {
        guard canRetryFinderRegistration,let (receipt,lease)=finderRegistrationRequest else{return}
        let token=OperationCancellation(),startedAt=ProcessInfo.processInfo.systemUptime
        cancellation=token;busy=true;cancelling=false;completionRange=nil;output += "\nRetrying Finder registration…\n";Self.activeOperations += 1
        Task { [self,lease] in
            defer {busy=false;cancellation=nil;cancelling=false;Self.activeOperations -= 1;withExtendedLifetime(lease) {};if active {finishOutput(startedAt:startedAt);finishAutomaticClose()}}
            await registerAcceptedWorktree(receipt,lease:lease,token:token)
        }
    }
    private var shortHashLength = 7
    var close: () -> Void = {}
    var chooseDirectory: () -> Void = {}
    var onCreated: (String) -> Void = { _ in }
    var onSubmodules: (URL, RepositoryAccessLease?) -> Void = { _, _ in }
    var automaticDetach: Bool { !createBranch && !useHead && (chooser.options.target != .branch || chooser.remote) }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, initialDirectory: URL? = nil) {
        self.preferences = preferences; progressPresentation = GitCommandPresentation(defaults: preferences); autoClosePolicy = GitProgressAutoClose(preferences: preferences); self.access = access; chooser = SwitchWindowModel(repository: repository, access: access, preferences: preferences)
        let root = repository.root.path
        directory = initialDirectory?.path ?? (root.hasSuffix(".git") ? String(root.dropLast(4)) : root + "-worktree")
    }
    func checkAccess() throws {
        if requiresSecurityScope && (access?.hasSecurityScope != true || access?.contains(chooser.repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load() {
        guard commandsAvailable, !busy, !progress, chooser.pickerTarget == nil else { return }
        let token=OperationCancellation(); cancellation=token
        busy = true; Self.activeOperations += 1
        Task {
            defer { busy = false; cancellation=nil; Self.activeOperations -= 1; withExtendedLifetime(access) {} }
            do {
                try checkAccess()
                let branch = try await chooser.repository.branch(cancellation:token)
                let length = (try? await chooser.repository.run(["rev-parse", "--short", "HEAD"],cancellation:token).text.trimmingCharacters(in: .newlines).count) ?? 7
                if token.isCancelled { throw OperationCancellationFailure.cancelled }; guard !invalidated else { return }; currentBranch = branch; shortHashLength = length
                chooser.load(); applyBase()
            } catch { if !invalidated, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private var suggestedBaseDraft: [GitReferenceName]?
    func changedBase() { guard commandsAvailable, !busy, !progress, chooser.pickerTarget == nil else { return }; applyBase() }
    private func applyBase() {
        let reference = chooser.references.first(where: { GitReferenceName.equal($0.name, chooser.branchRevision) })
        let values: [String]
        if useHead { values = ["HEAD", directory] }
        else if chooser.options.target == .branch { values = ["branch", chooser.revision, reference?.suggestedBranch ?? "", String(reference?.remote ?? false)] }
        else if chooser.options.target == .tag { values = ["tag", chooser.revision, chooser.tags.first(where: { GitReferenceName.equal($0.name, chooser.tagRevision) })?.label ?? chooser.revision] }
        else { values = ["commit", chooser.revision, String(shortHashLength)] }
        let draft = values.map { GitReferenceName($0) }
        // Deferred SwiftUI notifications must not rewrite a captured picker
        // context or reset custom options for an unchanged base after Cancel.
        guard suggestedBaseDraft != draft else { return }
        suggestedBaseDraft = draft
        if useHead {
            branchName = URL(fileURLWithPath: directory).lastPathComponent; createBranch = false
        } else if chooser.options.target == .branch, let reference = chooser.references.first(where: { GitReferenceName.equal($0.name, chooser.branchRevision) }) {
            branchName = reference.suggestedBranch; createBranch = reference.remote
        } else {
            let revision = chooser.options.target == .commit ? String(chooser.commitRevision.prefix(shortHashLength)) : chooser.tags.first(where: { GitReferenceName.equal($0.name, chooser.tagRevision) })?.label ?? chooser.revision
            branchName = "Branch_" + revision; createBranch = chooser.options.target != .branch
        }
        detach=automaticDetach
    }
    func changedBranch() { guard commandsAvailable, !busy, !progress else { return }; detach = automaticDetach }
    func changedDetach() { guard commandsAvailable, !busy, !progress else { return }; if detach { createBranch = false } }
    func create() {
        CommandProgressContext.perform(commandProgressScope) { createInCommandProgressScope() }
    }
    private func createInCommandProgressScope() {
        guard commandsAvailable,acceptedCreation==nil,!busy,!chooser.busy,!progress,chooser.pickerTarget==nil else{return}
        guard !directory.isEmpty, directory.hasPrefix("/"), !directory.contains("\0") else { error = "Enter an absolute worktree directory."; return }
        let path = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        var options = WorktreeCreationOptions()
        options.checkout = checkout; options.force = force; options.detach = detach
        options.newBranch = createBranch ? branchName : nil; options.revision = useHead ? "HEAD" : chooser.revision
        // CChooseVersion uses short branch/tag labels unless both share a name.
        // Passing refs/heads/foo directly to worktree add would detach HEAD.
        if !useHead, chooser.options.target != .commit,
           let reference = chooser.references.first(where: { $0.name == chooser.revision }) {
            let ambiguous = chooser.branches.contains(where: { $0.label == reference.label }) && chooser.tags.contains(where: { $0.label == reference.label })
            if !ambiguous { options.revision = reference.label }
        }
        let token = OperationCancellation(); cancellation = token
        let capturedOptions = options,repository=chooser.repository,creationCallback=onCreated,perform=performCreation
        var destinationLease = destinationAccess
        var startedAt: TimeInterval = 0
        busy = true; authorizingDestination = true; error = nil; cancelled = false; success = false
        Self.activeOperations += 1
        Task {
            var startedProgress = false
            defer {
                busy = false; authorizingDestination = false; cancellation = nil; cancelling = false
                Self.activeOperations -= 1
                if startedProgress { LocalGitCommandProgress.end() }
                withExtendedLifetime(access) {}; withExtendedLifetime(destinationLease) {}; finishAutomaticClose()
            }
            do {
                try token.check(); guard active else { return }; try checkAccess()
                if requiresSecurityScope && !(access?.hasSecurityScope == true && access?.contains(path) == true || destinationLease?.hasSecurityScope == true && destinationLease?.contains(path) == true) {
                    guard let permission = try await authorizeDestination(path, token) else { return }
                    try token.check(); guard active else { return }
                    guard permission.hasSecurityScope, permission.contains(path) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(path.path) }
                    destinationLease = permission; destinationAccess = permission
                }
                try token.check(); guard active else { return }
                authorizingDestination = false
                ProgressActionLog.nextAttempt(self, savePrevious: progress)
                currentWork = ""; percentage = nil; completionRange = nil; cancelling = false; confirmingCancellation = false
                progress = true; success = false; output = ""
                LocalGitCommandProgress.begin(); startedProgress = true; startedAt = ProcessInfo.processInfo.systemUptime
                let receipt = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in
                    guard let self, self.active, self.cancellation === token else { return }
                    self.output = state.output; self.currentWork = state.currentWork; self.percentage = state.percentage
                }, resultText: { $0.output }, operation: { emit in
                    if let perform{return try await perform(repository,path,capturedOptions,token)}
                    return try await repository.createWorktreeAccepted(at:path,options:capturedOptions,cancellation:token,onOutput:emit)
                })
                acceptedCreation=receipt;createdPath=receipt.path
                acceptedLateCancellation=token.isCancelled || receipt.cancelledAfterCreation
                if !notifiedCreation {notifiedCreation=true;creationCallback(receipt.output)}
                guard active else{return}
                success=true;cancelled=false
                hasSubmodules=receipt.verified && capturedOptions.checkout && FileManager.default.fileExists(atPath:path.appendingPathComponent(".gitmodules").path)
                if !receipt.verified {output += "\nWorktree created, but its current identity could not be verified. Review the repository before continuing.\n"+(receipt.verificationError ?? "")}
                else if acceptedLateCancellation {output += "\nWorktree created. Cancellation stopped further actions.\n"}
                let primary=destinationLease?.contains(receipt.path)==true ? destinationLease:(access?.contains(receipt.path)==true ? access:nil)
                let acceptedPrimary=primary ?? (requiresSecurityScope ? nil:RepositoryAccessLease(url:receipt.path))
                let acceptedLease=acceptedPrimary?.retainingRelatedScopes(access.map{[$0]} ?? [])
                if acceptedLateCancellation {token.cancel()}
                await registerAcceptedWorktree(receipt,lease:acceptedLease,token:token)
                guard active else{return}
                finishOutput(startedAt:startedAt)
            } catch let failure as GitCommandCancellationFailure { guard active else { return }; cancelled = true; output = LocalGitCommandProgress.failure(failure, existing: output, preferences: preferences); finishOutput(startedAt: startedAt) }
            catch OperationCancellationFailure.cancelled { guard active else { return }; cancelled = true; output = "Cancelled before worktree creation."; if startedProgress { finishOutput(startedAt: startedAt) } }
            catch { if active { if startedProgress { output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences); finishOutput(startedAt: startedAt, exitCode: (error as? GitFailure)?.code) } else { self.error = error.localizedDescription } } }
        }
    }
    private func finishOutput(startedAt: TimeInterval, exitCode: Int32? = nil) {
        let completion = SubmoduleProgressCompletion(success: success, cancelled: cancelled, exitCode: exitCode,
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt, preferences: preferences)
        currentWork = completion.currentWork; percentage = 100; completionRange = completion.append(to: &output)
    }
    private func finishAutomaticClose() {
        guard commandsAvailable,!busy,!confirmingCancellation,success,!acceptedLateCancellation,acceptedCreation?.verified == true,finderRegistrationWarning==nil else{return}
        if autoClosePolicy.shouldClose(success: true, postActionCount: hasSubmodules ? 1 : 0) { saveActionLog(); close() }
    }
    func cancel() {
        guard canCancel, let token = cancellation else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true; Self.activeOperations += 1; var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered else { return }; answered = true; Self.activeOperations -= 1
                guard let self else { return }; self.confirmingCancellation = false
                guard self.commandsAvailable else { return }
                if accepted,self.acceptedCreation != nil {self.acceptedLateCancellation=true}
                if self.busy, self.cancellation === token, accepted { self.cancelling = true; token.cancel() }
                self.finishAutomaticClose()
            }
        } else { if acceptedCreation != nil {acceptedLateCancellation=true};cancelling = true; token.cancel() }
    }
    func returnToOptions() { guard commandsAvailable,acceptedCreation==nil,!busy,!confirmingCancellation else { return }; saveActionLog(); progress = false }
    func updateSubmodules() {
        CommandProgressContext.perform(commandProgressScope) { updateSubmodulesInCommandProgressScope() }
    }
    private func updateSubmodulesInCommandProgressScope() {
        guard canUpdateSubmodules, let createdPath else { return }
        let primary = destinationAccess?.contains(createdPath) == true ? destinationAccess : access
        // The linked checkout must retain both destination and common Git-dir
        // authority after this creation owner has actually detached and closed.
        let lease = primary?.retainingRelatedScopes(access.map { [$0] } ?? [])
        let callback = onSubmodules
        let dispatch=CommandProgressContext.capture(commandProgressScope) {callback(createdPath,lease)}
        handoffPending = true; Self.activeOperations += 1
        var answered = false
        finishAndPerform { [self] accepted in
            guard !answered else { return }; answered = true
            defer { handoffPending = false; Self.activeOperations -= 1; withExtendedLifetime(lease) {} }
            if accepted, !confirmingQuit, externalAvailability() { dispatch() }
        }
    }
}

private struct WorktreeCreateDialog: View {
    @ObservedObject var model: WorktreeCreateWindowModel
    @ObservedObject var chooser: SwitchWindowModel
    func radio(_ title: String, target: CheckoutTarget, context:WorktreeCreateWindowModel.BaseContext) -> some View {
        BaseRadio(title: title, selected: !model.useHead && chooser.options.target == target) {
            model.selectBase(target,context:context)
        }.frame(width: 100)
    }
    var body: some View {
        let context=model.baseContext
        VStack(spacing: 12) {
            if model.progress { progress }
            else {
                GroupBox("Location") { HStack {
                    Text("Directory:").frame(width: 100, alignment: .leading)
                    PathEntryField(text: model.field(\.directory,context:context), label: "Worktree directory", permissions: [model.access, model.destinationAccess].compactMap { $0 }, preferences: model.preferences, mayEdit: { model.canEditBase }).frame(height: 22)
                    Button("Browse…") { model.browseDirectory(context:context) }
                }.padding(8) }
                GroupBox("Base On") { VStack(spacing: 6) {
                    BaseRadio(title: "HEAD (\(model.currentBranch.isEmpty ? "detached" : model.currentBranch))", selected: model.useHead) { model.selectBase(nil,context:context) }.frame(height: 22)
                    HStack { radio("Branch", target: .branch,context:context)
                        ReferencePopup(references: chooser.branches, selection: model.baseRevision(.branch,context:context), accessibilityLabel: "Base branch revision", focusRequest: chooser.referenceFocusRequest, onFocus: { model.focusBase($0,target:.branch,context:context) }).disabled(model.useHead || chooser.options.target != .branch)
                        Button("…") { model.browseBase(.branch,context:context) }.accessibilityLabel("Browse references").disabled(model.useHead || chooser.options.target != .branch)
                    }.frame(height: 26)
                    HStack { radio("Tag", target: .tag,context:context)
                        ReferencePopup(references: chooser.tags, selection: model.baseRevision(.tag,context:context), accessibilityLabel: "Base tag revision", focusRequest: chooser.referenceFocusRequest, onFocus: { model.focusBase($0,target:.tag,context:context) }).disabled(model.useHead || chooser.options.target != .tag)
                        Color.clear.frame(width: 29)
                    }.frame(height: 26)
                    HStack { radio("Commit", target: .commit,context:context)
                        VersionRevisionField(text: model.baseRevision(.commit,context:context), choices: chooser.commitChoices, accessibilityLabel: "Base commit revision", focusRequest: chooser.referenceFocusRequest, onFocus: { model.focusBase($0,target:.commit,context:context) }).disabled(model.useHead || chooser.options.target != .commit)
                        Button("…") { model.browseBase(.commit,context:context) }.accessibilityLabel("Choose commit").disabled(model.useHead || chooser.options.target != .commit)
                    }.frame(height: 26)
                }.padding(8) }
                GroupBox("Options") { VStack(spacing: 8) {
                    HStack { Toggle("Create New Branch", isOn: model.field(\.createBranch,context:context,changed:{model.changedBranch()})).frame(width: 180, alignment: .leading)
                        TextField("New branch name", text: model.field(\.branchName,context:context)).disabled(!model.createBranch)
                    }
                    HStack { Toggle("Checkout", isOn: model.field(\.checkout,context:context)); Toggle("Force", isOn: model.field(\.force,context:context)).help("Allow checking out a branch that is already checked out in another worktree.")
                        Toggle("Detach", isOn: model.field(\.detach,context:context,changed:{model.changedDetach()})).disabled(model.automaticDetach); Spacer()
                    }
                }.padding(8) }
                HStack { if model.busy || chooser.busy || chooser.pickerTarget != nil { ProgressView().controlSize(.small) }; Spacer()
                    Button("OK") { model.create() }.keyboardShortcut(.defaultAction).disabled(model.directory.isEmpty || model.createBranch && model.branchName.isEmpty)
                    Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                    Button("Help") { TurtleGitHelp.show(.worktrees) }
                }
            }
        }.padding(16)
        .disabled(!model.commandsAvailable || !model.progress && (model.busy || chooser.busy || chooser.pickerTarget != nil))
        .onChange(of: chooser.pickerTarget) { value in if value == nil { model.changedBase() } }
        .onChange(of: chooser.branchRevision) { _ in if !model.useHead && chooser.options.target == .branch { model.changedBase() } }
        .onChange(of: chooser.tagRevision) { _ in if !model.useHead && chooser.options.target == .tag { model.changedBase() } }
        .onChange(of: chooser.commitRevision) { _ in if !model.useHead && chooser.options.target == .commit { model.changedBase() } }
        .alert("New Worktree", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(item: $chooser.browser) { target in SwitchReferenceChooser(model: chooser, target: target) }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.busy ? "Creating worktree…" : model.success ? "Worktree created" : model.cancelled ? "Cancelled" : "Worktree creation failed").font(.headline)
            SubmoduleProgressOutputView(text: model.output, completed: !model.busy, completionRange: model.completionRange, success: model.success, preferences: model.preferences).frame(maxHeight: .infinity)
            HStack { if model.progress { LocalGitProgressIndicator(percentage: model.percentage, animate: model.progressPresentation.animateActivity); Text(model.cancelling ? "Cancelling…" : model.currentWork).font(.caption) }; Spacer()
                if model.finderRegistrationWarning != nil { Button("Retry Finder registration") {model.retryFinderRegistration()}.disabled(!model.canRetryFinderRegistration).help(model.finderRegistrationWarning ?? "") }
                if model.success && model.hasSubmodules { Button { model.updateSubmodules() } label: { CommandLabel(title: "Submodule Update…", icon: .fetch) }.disabled(!model.canUpdateSubmodules) }
                if model.busy { Button("Cancel") { model.cancel() }.disabled(!model.canCancel) }
                else {
                    if !model.success { Button("Back") { model.returnToOptions() }.disabled(model.confirmingCancellation || model.confirmingQuit || model.handoffPending) }
                    Button("Close") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.confirmingCancellation || model.confirmingQuit || model.handoffPending)
                }
            }
        }
    }
}
