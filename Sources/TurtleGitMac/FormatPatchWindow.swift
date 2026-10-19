import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor final class FormatPatchWindowController: NSWindowController, NSWindowDelegate {
    let model: FormatPatchWindowModel
    var onClosed: () -> Void = {}
    private(set) var picker: LogWindowController?
    private(set) var referencePicker: ReferenceBrowserWindowController?
    private(set) var directoryPanel: NSOpenPanel?
    private var retired = false
    var canReuse:Bool{!retired && !model.isRetired}
    private(set) var progressController: FormatPatchProgressWindowController?
    static var activeReleases: Int { FormatPatchRelease.activeCount }
    var presentProgress: (NSWindow,NSWindow)->Bool = { parent, child in guard parent.attachedSheet == nil else{return false};parent.beginSheet(child);return true }
    private(set) var cancellationAlert: NSAlert?
    var presentCancellation: ((NSAlert,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    private var cancellationAnswer: ((NSApplication.ModalResponse)->Void)?
    private var ownerRelease: FormatPatchRelease?
    private var observations: Set<AnyCancellable> = []
    private var directoryAnswer:((NSApplication.ModalResponse)->Void)?
    private var retiredReferencePicker:ReferenceBrowserWindowController?
    private var retiredLogPicker:LogWindowController?
    private var interactionEpoch=0
    private var presentationEpoch=0
    private struct Options: Equatable {
        let values: [GitReferenceName]
        let count: Int
        let mode: FormatPatchWindowModel.Mode
        let sendMail: Bool, noPrefix: Bool
    }
    private var options: Options { Options(values: [model.directory, model.since, model.from, model.to].map { GitReferenceName($0) }, count: model.count, mode: model.mode, sendMail: model.sendMail, noPrefix: model.noPrefix) }
    private var choiceRequest: UUID?
    private var pendingDirectory: (UUID, Options, URL?)?
    var selectedDirectory: (NSOpenPanel) -> URL? = { $0.url }
    private var pendingChoice: (UUID, Options, FormatPatchWindowModel.Mode, String?)?
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    var presentPicker: (NSWindow, NSWindow) -> Bool = { parent, child in
        guard parent.attachedSheet == nil else { return false }; parent.beginSheet(child); return true
    }
    var presentDirectory: (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { panel, parent, completion in panel.beginSheetModal(for: parent, completionHandler: completion) }
    var makeLogPicker: (GitRepository, RepositoryAccessLease?, String?, UserDefaults, @escaping (LogEntry?) -> Void) -> LogWindowController = { repository, access, revision, preferences, choose in
        LogWindowController(repository: repository, access: access, onChoose: choose, labelDefaults: preferences, initialRevision: revision)
    }
    private(set) var patch: PatchWindowController?
    private var sendPatch: SendMailWorkflow?
    private let mailPreferences: UserDefaults
    private let mailPresentation: ((NSWindowController) -> Void)?
    private var mailSnapshot:MergeWindowPresentation?
    var activeOperation: Bool { model.hasOptionSheet || model.busy || model.progress || model.confirmingCancellation || model.finishScheduled || model.waitingForOwnerClose || model.composingMail || model.openingViewer }
    init(repository: GitRepository, access: RepositoryAccessLease?, preset: FormatPatchPreset? = nil, sendMail: Bool = false, preferences: UserDefaults = .standard, mailPresentation: ((NSWindowController) -> Void)? = nil) {
        mailPreferences = preferences; self.mailPresentation = mailPresentation
        model = FormatPatchWindowModel(repository: repository, access: access, preferences: preferences)
        model.apply(preset)
        if sendMail { model.sendMail = true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 365), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Format Patch", preferences: preferences)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FormatPatchDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 680, height: 365))
        window.contentMinSize = NSSize(width: 650, height: 365); window.contentMaxSize = NSSize(width: 4000, height: 365)
        window.center()
        model.close = { [weak self] in self?.requestOwnerClose() }
        model.chooseDirectory = { [weak self] in self?.chooseDirectory() }
        model.chooseRevision = { [weak self] target in self?.chooseRevision(target) }
        model.showPatch = { [weak self] bytes, alternate in self?.showPatch(bytes, alternate: alternate) }
        model.composeMail = { [weak self] files in self?.composeMail(files) }
        model.presentProgress = { [weak self] in self?.showProgress() }
        model.finishProgress = { [weak self] done in
            guard let self,!self.retired,let progress=self.progressController else{done();return}
            self.presentationEpoch=self.interactionEpoch
            progress.finish(done)
        }
        model.confirmCancellation = { [weak self] choose in
            guard let self,!self.retired,!self.model.confirmingQuit,self.cancellationAlert == nil,
                  let parent=self.progressController?.window ?? self.window,parent.attachedSheet == nil else{choose(false);return}
            let alert=NSAlert();alert.alertStyle = .informational
            alert.messageText="The process is still running.";alert.informativeText="Are you sure to abort?"
            let yes=alert.addButton(withTitle:"Yes"),no=alert.addButton(withTitle:"No")
            alert.layout();yes.keyEquivalent="\r";no.keyEquivalent="\u{1b}";alert.window.defaultButtonCell=yes.cell as? NSButtonCell
            MergeWindowPresentation(parent).apply(to:alert.window)
            self.cancellationAlert=alert;let epoch=self.interactionEpoch;var answered=false
            let answer:(NSApplication.ModalResponse)->Void={ [weak self] response in
                guard let self,!answered,self.cancellationAlert === alert else{return};answered=true
                let release=FormatPatchRelease(window:alert.window,parent:parent,closeWindow:true){ [self] in
                    let accepted = !self.retired && !self.model.confirmingQuit && self.interactionEpoch == epoch
                    self.cancellationAlert=nil;self.cancellationAnswer=nil
                    choose(accepted && response == .alertFirstButtonReturn)
                };release.start()
            }
            self.cancellationAnswer=answer
            if let presentCancellation=self.presentCancellation{presentCancellation(alert,parent,answer)}else{alert.beginSheetModal(for:parent,completionHandler:answer)}
        }
        model.$confirmingQuit.dropFirst().sink { [weak self] _ in self?.interactionEpoch += 1 }.store(in:&observations)
        NotificationCenter.default.addObserver(self, selector: #selector(optionSheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        model.load()

        DialogGeometry.attach(window, identifier: "FormatPatchDialog", legacyName: "FormatPatchDialog")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.confirmingQuit{return false}
        if model.cancelRead(closeAfter: true) { return false }
        guard !activeOperation && sender.attachedSheet == nil && patch?.model.busy != true && patch?.window?.attachedSheet == nil else { return false }
        return PatchDocumentSession.permitOwnerClose(patch.map { [$0] } ?? [])
    }
    override func close(){super.close();if !retired,window?.isVisible != true{retireClosedWindow()}}
    func windowWillClose(_ notification: Notification) {guard notification.object as? NSWindow === window else{return};retireClosedWindow()}
    private func retireClosedWindow(){
        guard !retired else{return};retired=true
        NotificationCenter.default.removeObserver(self)
        choiceRequest=nil;pendingChoice=nil;pendingDirectory=nil;model.hasOptionSheet=false
        model.saveActionLog();model.invalidate();cancellationAnswer?(.abort);sendPatch?.invalidate();sendPatch=nil;model.composingMail=false
        let progress=progressController;progress?.close()
        directoryAnswer?(.cancel)
        retiredReferencePicker=referencePicker;retiredLogPicker=picker
        referencePicker?.abandonPresentation();referencePicker=nil;picker?.close();picker=nil;patch?.close();patch=nil
        if let window,let sheet=window.attachedSheet,sheet !== progress?.window{window.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil)}
        let release=FormatPatchRelease(window:window,parent:window?.sheetParent,ready:{ [self] in !model.hasPendingWork && cancellationAlert == nil && progressController == nil && directoryPanel == nil && retiredReferencePicker?.window?.sheetParent == nil && retiredLogPicker?.window?.sheetParent == nil && (retiredReferencePicker?.model.pendingReferenceReads ?? 0) == 0 && (retiredLogPicker?.model.pendingHistoryLoads ?? 0) == 0 }){ [self] in
            self.ownerRelease=nil;retiredReferencePicker=nil;retiredLogPicker=nil;observations.removeAll();model.saveDrainedActionLog();let done=onClosed;onClosed={};done()
        };ownerRelease=release;release.start()
    }
    private func showProgress(){
        guard !retired,!model.confirmingQuit,progressController == nil,let window,window.attachedSheet == nil else{model.invalidate();close();return}
        let child=FormatPatchProgressWindowController(model:model)
        progressController=child;presentationEpoch=interactionEpoch;mailSnapshot=MergeWindowPresentation(window)
        child.onClosed={ [weak self,weak child] in guard let self,self.progressController === child else{return};self.progressController=nil }
        child.onForcedClose={ [weak self] in self?.close() }
        guard let childWindow=child.window else{child.close();return}
        MergeWindowPresentation(window).apply(to:childWindow)
        guard presentProgress(window,childWindow) else{child.close();return}
    }
    func chooseDirectory() {
        guard !retired, model.optionsAvailable, let window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(nil)
        let captured = options, request = UUID()
        choiceRequest = request; model.hasOptionSheet = true
        let panel = NSOpenPanel(); directoryPanel = panel
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.title = "Output Directory"; panel.directoryURL = URL(fileURLWithPath: model.directory)
        let epoch=interactionEpoch;var answered=false
        let answer:(NSApplication.ModalResponse)->Void={ [weak self] response in
            guard let self,!answered,self.directoryPanel === panel else{return};answered=true
            let selected=response == .OK ? self.selectedDirectory(panel):nil
            let release=FormatPatchRelease(window:panel,parent:window,closeWindow:true){ [self] in
                self.directoryPanel=nil;self.directoryAnswer=nil
                guard !self.retired,self.choiceRequest == request else{return}
                self.pendingDirectory=(request,captured,self.interactionEpoch == epoch ? selected:nil);self.drainDirectory()
            };release.start()
        }
        directoryAnswer=answer;MergeWindowPresentation(window).apply(to:panel)
        presentDirectory(panel,window,answer)
    }

    private func acceptDirectory(_ folder: URL) {
        let lease = RepositoryAccessLease(url: folder)
        guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { model.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
        model.outputAccess = lease; model.directory = folder.path
    }
    func chooseRevision(_ target: FormatPatchWindowModel.Mode) {
        guard target != .number, !retired, model.optionsAvailable,
              picker == nil, referencePicker == nil, let window, window.attachedSheet == nil else { return }
        // Commit the field editor before capturing the entered range.
        window.makeFirstResponder(nil)
        let captured = options, request = UUID(),epoch=interactionEpoch
        choiceRequest = request; model.hasOptionSheet = true
        let receive: (String?) -> Void = { [weak self] value in
            guard let self, !self.retired, self.choiceRequest == request else { return }
            self.pendingChoice = (request, captured, target, self.interactionEpoch == epoch ? value:nil); self.drainChoice()
        }
        let child: NSWindowController
        if target == .since {
            let browser = ReferenceBrowserWindowController(repository: model.repository, access: model.access, initial: model.since, preferences: mailPreferences, scope: .excludingTags, onChoose: receive)
            referencePicker = browser; configureReferencePicker(browser.model)
            browser.onClosed = { [weak self, weak browser] in
                guard let self, self.referencePicker === browser else { return }
                self.referencePicker = nil; self.drainChoice()
            }
            child = browser
        } else {
            let revision = target == .from ? model.from : model.to
            let log = makeLogPicker(model.repository, model.access, revision.isEmpty ? nil : revision, mailPreferences) { receive($0?.hash) }
            picker = log; configureLogPicker(log.model); log.model.showWorkingTree = false
            log.onClosed = { [weak self, weak log] in
                guard let self, self.picker === log else { return }
                self.picker = nil; self.drainChoice()
            }
            child = log
        }
        guard let childWindow = child.window else { abandonChoice(); return }
        childWindow.appearance = window.appearance; childWindow.alphaValue = window.alphaValue
        guard presentPicker(window, childWindow) else { abandonChoice(); return }
        referencePicker?.model.load()
    }
    private func abandonChoice() {
        choiceRequest = nil; pendingChoice = nil; pendingDirectory = nil; model.hasOptionSheet = false
        referencePicker?.abandonPresentation(); referencePicker = nil
        picker?.close(); picker = nil
    }
    private func requestOwnerClose() {
        guard !retired,!model.confirmingQuit else { return }
        if model.cancelRead(closeAfter: true) { return }
        guard !activeOperation, let window else { return }
        // SwiftUI dismisses the progress sheet asynchronously. Keep the
        // acknowledgement until AppKit releases that sheet instead of losing
        // performClose to windowShouldClose's attached-sheet guard.
        guard window.attachedSheet == nil else { model.waitingForOwnerClose = true; return }
        window.performClose(nil)
    }
    @objc private func optionSheetEnded() {
        drainChoice(); drainDirectory()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.retired, self.model.waitingForOwnerClose, self.window?.attachedSheet == nil else { return }
            self.model.waitingForOwnerClose = false; self.requestOwnerClose()
        }
    }
    private func drainDirectory() {
        guard !retired, let pending = pendingDirectory, choiceRequest == pending.0,
              window?.attachedSheet == nil, directoryPanel == nil else { return }
        pendingDirectory = nil; choiceRequest = nil; model.hasOptionSheet = false
        guard options == pending.1, model.optionsAvailable else { return }
        if let folder = pending.2 { acceptDirectory(folder) }
        window?.makeKeyAndOrderFront(nil)
    }
    private func drainChoice() {
        guard !retired, let pending = pendingChoice, choiceRequest == pending.0,
              window?.attachedSheet == nil, referencePicker == nil, picker == nil else { return }
        pendingChoice = nil; choiceRequest = nil; model.hasOptionSheet = false
        guard options == pending.1, model.optionsAvailable else { return }
        if let value = pending.3 {
            switch pending.2 {
            case .since: model.since = value; model.mode = .since
            case .from: model.from = value; model.mode = .from
            case .to: model.to = value; model.mode = .from
            case .number: break
            }
        }
        window?.makeKeyAndOrderFront(nil)
    }
    private func showPatch(_ bytes: Data, alternate: Bool) {
        guard !retired, patch?.model.busy != true, patch?.window?.attachedSheet == nil else { return }
        let preferences = UnifiedDiffViewerPreferences.load(from: mailPreferences)
        do {
            if case .external(let application) = try preferences.choice(alternate: alternate) {
                let preview = try UnifiedDiffPreview.create(bytes)
                UnifiedDiffPreviewFiles.retain(preview)
                model.openingViewer = true
                UnifiedDiffApplication.open(preview.file, application: application, bookmark: preferences.bookmark, arguments: preferences.arguments, title: "HEAD → Working tree", permissions: model.access.map { [$0] } ?? []) { [weak model] error in
                    model?.openingViewer = false
                    if let error { UnifiedDiffPreviewFiles.discard(preview.file); if model?.isRetired == false { model?.error = error } }
                }
                return
            }
        } catch { model.error = error.localizedDescription; return }
        let controller = patch ?? PatchWindowController(repository: model.repository, access: model.access)
        controller.presentDocument(bytes, title: "Unified Diff – TurtleGit", comparison: "HEAD → Working tree",
            information: "Unified diff since HEAD. Right-click to save the patch.", refreshAvailable: true, refresh: { [weak model = model, weak controller] in
                guard let controller else { return }; let identity = controller.documentSession.documentIdentity
                model?.unifiedDiff(onResult: { [weak controller] bytes in
                    guard let controller, controller.documentSession.documentIdentity == identity else { return }
                    controller.documentSession.replace(bytes)
                })
            })
        controller.onClosed = { [weak self] in self?.patch = nil }
        controller.window?.appearance = window?.appearance; controller.window?.alphaValue = window?.alphaValue ?? 1
        patch = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func composeMail(_ files: [URL]) {
        guard !retired,!model.confirmingQuit,interactionEpoch == presentationEpoch,progressController == nil,window?.attachedSheet == nil else{return}
        guard !files.isEmpty else { model.error = "No patches were created to attach."; return }
        do {
            model.composingMail = true
            let leases = [model.access, model.submittedOutputAccess].compactMap { $0 }
            let workflow = SendMailWorkflow(files: files, repository: model.repository, access: model.access,
                fileAccess: leases, preferences: mailPreferences, presentation: { [snapshot=mailSnapshot,present=mailPresentation] owner in
                    if let window=owner.window{snapshot?.apply(to:window)}
                    if let present{present(owner)}else{owner.showWindow(nil);owner.window?.makeKeyAndOrderFront(nil)}
                }) { [weak self] _ in
                guard let self else{return};self.sendPatch=nil;self.model.composingMail=false
                guard !self.retired,!self.model.confirmingQuit else{return}
                // Format Patch reports export success independently of mail outcome.
                // The retained mail result has already been reviewed before close.
                self.model.close()
            }
            sendPatch = workflow; workflow.start(); return
        }

    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class FormatPatchWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    enum Mode: Equatable { case since, number, from, to }
    @Published private(set) var pendingOperations=0
    private var pendingQuestions=0
    var hasPendingWork:Bool{pendingOperations>0 || pendingQuestions>0}
    var workDidDrain:(()->Void)?
    private var interactionGeneration=0
    @Published var confirmingQuit=false {didSet{if oldValue != confirmingQuit{interactionGeneration += 1;formRevision=UUID()};if !confirmingQuit{finishAutomatically()}}}
    private var formRevision=UUID()
    struct FormContext:Equatable{let owner:ObjectIdentifier;let revision:UUID}
    var formContext:FormContext{.init(owner:ObjectIdentifier(self),revision:formRevision)}
    func field<Value>(_ key:ReferenceWritableKeyPath<FormatPatchWindowModel,Value>,context:FormContext)->Binding<Value>{Binding(get:{self[keyPath:key]},set:{if self.optionsAvailable,self.formContext==context{self[keyPath:key]=$0}})}
    private func beginWork(){pendingOperations += 1;Self.activeOperations += 1}
    private func endWork(){pendingOperations -= 1;Self.activeOperations -= 1;if !hasPendingWork{workDidDrain?()}}
    var outputClipboard:NSPasteboard = .general
    var outputPreferences:UserDefaults{preferences}
    @Published private(set) var commandFinished=false
    @Published private(set) var commandSucceeded=false
    private(set) var submittedOutputAccess:RepositoryAccessLease?
    var runFormatPatch:((FormatPatchSelection,URL,Bool,OperationCancellation,@escaping @Sendable(GitOutputChunk)->Void,@escaping @Sendable(GitCommandInvocation)->Void,@escaping @Sendable(FormatPatchCommandCompletion)->Void) async throws->GitResult)?
    var presentProgress:()->Void={}
    var finishProgress:(@escaping()->Void)->Void={$0()}

    @Published var hasOptionSheet = false
    var optionsAvailable: Bool { !invalidated && !confirmingQuit && !hasPendingWork && !hasOptionSheet && !busy && !progress && !finishScheduled && !waitingForOwnerClose && !confirmingCancellation && !composingMail && !openingViewer }
    var isRetired: Bool { invalidated }
    private var readCancellation: OperationCancellation?
    private var closeAfterRead = false
    func cancelRead(closeAfter: Bool = false) -> Bool {
        guard let token = readCancellation else { return false }
        closeAfterRead = closeAfterRead || closeAfter; token.cancel(); return true
    }
    private func beginRead() -> OperationCancellation {
        let token = OperationCancellation(); readCancellation = token; busy = true; beginWork(); return token
    }
    private func finishRead(_ token: OperationCancellation) {
        endWork(); withExtendedLifetime(access) {}
        guard readCancellation === token else { return }
        readCancellation = nil; busy = false
        if closeAfterRead, !invalidated { closeAfterRead = false; close() }
    }
    let repository: GitRepository
    let access: RepositoryAccessLease?
    var outputAccess: RepositoryAccessLease?
    @Published var directory: String
    @Published var since: String
    @Published var from: String
    @Published var to: String
    @Published var count = 1
    @Published var mode = Mode.since {didSet{if mode != oldValue{formRevision=UUID()}}}
    @Published var sendMail: Bool
    @Published var noPrefix: Bool
    @Published var busy = false
    @Published var composingMail = false
    @Published var openingViewer = false
    @Published var hasHead = false
    @Published var bare = false
    @Published var references: [String] = []
    @Published var error: String?
    @Published var progress = false
    @Published var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var completionRange: NSRange?
    private var outputState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { outputState.presentation }
    private var attemptStarted=false
    private var drainedLog=""
    var actionLogOutput:String{invalidated ? drainedLog:output}
    var actionLogEligible:Bool{attemptStarted && !busy && !hasPendingWork}
    func saveDrainedActionLog(){guard actionLogEligible else{return};ProgressActionLog.record(owner:self,repository:repository.root,output:actionLogOutput,cancelled:cancelled,failed:!success,notify:!invalidated)}
    var canCancel: Bool { busy && !commandFinished && cancellation != nil && !cancelRequested && !confirmingCancellation && !confirmingQuit && !invalidated }
    @Published var success = false
    @Published var cancelRequested = false
    @Published var cancelled = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var finishScheduled = false
    @Published var waitingForOwnerClose = false
    let preferences: UserDefaults
    private var invalidated = false
    private var progressClosePolicy = GitProgressAutoClose.manual
    private var cancellation: OperationCancellation?
    private var files: [URL] = []
    private var exportSendMail = false
    var close: () -> Void = {}
    var chooseDirectory: () -> Void = {}
    var chooseRevision: (Mode) -> Void = { _ in }
    var showPatch: (Data, Bool) -> Void = { _, _ in }
    var composeMail: ([URL]) -> Void = { _ in }
    var onOutputChanged: (String) -> Void = { _ in }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    func invalidate() { invalidated = true;formRevision=UUID();waitingForOwnerClose = false;readCancellation?.cancel();progress = false;cancellation?.cancel() }
    func apply(_ preset: FormatPatchPreset?) {
        guard let preset, optionsAvailable else { return }
        from = preset.from; to = preset.to
        switch preset.selection {
        case .since(let value): since = value; mode = .since
        case .range: mode = .from
        case .number(let value): count = value; mode = .number
        }
    }
    var dirs: [String] { preferences.stringArray(forKey: "FormatPatchDirectories") ?? [] }
    var fromHistory: [String] { preferences.stringArray(forKey: "FormatPatchFrom") ?? [] }
    var toHistory: [String] { preferences.stringArray(forKey: "FormatPatchTo") ?? [] }
    private var sinceKey: String { "FormatPatchSince:" + repository.root.path }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.preferences = preferences; outputState = GitProgressOutputState(preferences: preferences); directory = repository.root.path
        let defaults = preferences
        since = defaults.string(forKey: "FormatPatchSince:" + repository.root.path) ?? ""
        from = defaults.stringArray(forKey: "FormatPatchFrom")?.first ?? ""
        to = defaults.stringArray(forKey: "FormatPatchTo")?.first ?? ""
        sendMail = defaults.bool(forKey: "FormatPatchSendMail"); noPrefix = defaults.bool(forKey: "FormatPatchNoPrefix")
    }
    func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load() {
        guard optionsAvailable else { return }
        let token = beginRead()
        Task {
            defer { finishRead(token) }
            do {
                try checkAccess()
                let head = try await repository.run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], successfulExitCodes: 0...1, cancellation: token).exitCode == 0
                let isBare = try await repository.isBare(cancellation: token)
                let names = try await repository.checkoutReferences(includeFetchHead: preferences.includesFetchHead, localBranchesFirst: AdvancedListBehavior(defaults: preferences).localBranchesFirst, cancellation: token).filter { !$0.name.hasPrefix("refs/tags/") && $0.symbolicTarget == nil }.map(\.name)
                guard !invalidated, !token.isCancelled else { return }
                hasHead = head; bare = isBare; references = names
            } catch { if !invalidated && !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func remember(_ value: String, key: String) {
        guard !value.isEmpty else { return }
        let old = preferences.stringArray(forKey: key) ?? []
        preferences.set(Array(([value] + old.filter { !GitReferenceName.equal($0, value) }).prefix(25)), forKey: key)
    }
    var valid: Bool { hasHead && !directory.isEmpty && (mode == .number ? (1...Int(Int32.max)).contains(count) : (mode == .since ? !since.isEmpty : !from.isEmpty && !to.isEmpty)) }
    var progressStatus: String {
        if commandFinished{return commandSucceeded ? "Finished":cancelled ? "Cancelled":"Failed"}
        if busy { return cancelRequested ? "Stopping Git…" : "Creating patches…" }
        if cancelled { return "Cancelled" }
        return success ? "Finished" : "Failed"
    }
    func export() {
        guard optionsAvailable, valid else { return }
        let folder = URL(fileURLWithPath: directory).standardizedFileURL
        if GitRuntime.isAppStoreBuild && !((access?.hasSecurityScope == true && access?.contains(folder) == true) || (outputAccess?.hasSecurityScope == true && outputAccess?.contains(folder) == true)) { chooseDirectory(); return }
        let selection: FormatPatchSelection = mode == .since ? .since(since) : mode == .number ? .number(count) : .range(from: from, to: to)
        let prefix = noPrefix, capturedOutputAccess = outputAccess;submittedOutputAccess=capturedOutputAccess;exportSendMail = sendMail
        remember(directory, key: "FormatPatchDirectories"); remember(from, key: "FormatPatchFrom"); remember(to, key: "FormatPatchTo")
        if mode == .since { preferences.set(since, forKey: sinceKey) }
        preferences.set(sendMail, forKey: "FormatPatchSendMail"); preferences.set(prefix, forKey: "FormatPatchNoPrefix")
        progressClosePolicy = GitProgressAutoClose(preferences: preferences)
        ProgressActionLog.nextAttempt(self, savePrevious: !output.isEmpty)
        outputState = GitProgressOutputState(preferences: preferences)
        attemptStarted=true;drainedLog="";busy = true; progress = true; success = false; output = ""; files = [];commandFinished=false;commandSucceeded=false;formRevision=UUID()
        currentWork = ""; percentage = nil; completionRange = nil
        cancelRequested = false; cancelled = false
        let token = OperationCancellation(); cancellation = token
        beginWork();presentProgress()
        let startedAt = ProcessInfo.processInfo.systemUptime
        Task {
            var exitCode: Int32?
            defer {
                endWork(); withExtendedLifetime(access) {}; withExtendedLifetime(capturedOutputAccess) {}
                busy = false; cancellation = nil
                if !invalidated {
                    if !commandFinished {let completion = SubmoduleProgressCompletion(success: success, cancelled: cancelled, exitCode: exitCode,
                        elapsed: ProcessInfo.processInfo.systemUptime - startedAt, preferences: preferences)
                    currentWork = completion.currentWork; percentage = 100; completionRange = completion.append(to: &output)}
                    onOutputChanged(output); finishAutomatically()
                }else{saveDrainedActionLog()}
            }
            do {
                try checkAccess()
                let parser = GitCliOutputParser(limit: outputState.limit)
                var receivedCommand=false
                enum Update:Sendable{case output,finished(FormatPatchCommandCompletion)}
                let (updates,continuation)=AsyncStream<Update>.makeStream(bufferingPolicy:.bufferingNewest(1))
                let operation=Task{ [self] in
                    defer{continuation.finish()}
                    let emit:@Sendable(GitOutputChunk)->Void={chunk in parser.appendChunk(chunk.data);continuation.yield(.output)}
                    let command:@Sendable(GitCommandInvocation)->Void={value in parser.appendChunk(value.preamble);continuation.yield(.output)}
                    let finished:@Sendable(FormatPatchCommandCompletion)->Void={continuation.yield(.finished($0))}
                    if let runFormatPatch{return try await runFormatPatch(selection,folder,prefix,token,emit,command,finished)}
                    return try await repository.formatPatch(selection:selection,to:folder,noPrefix:prefix,cancellation:token,onOutput:emit,onCommand:command,onCommandFinished:finished)
                }
                for await update in updates{
                    consume(parser.processPending(),parser:parser)
                    if case .finished(let receipt)=update{
                        receivedCommand=true
                        consume(parser.finish(),parser:parser)
                        let completion=SubmoduleProgressCompletion(success:receipt.success,cancelled:receipt.cancelled,exitCode:receipt.exitCode,elapsed:receipt.elapsed,finished:receipt.finished,preferences:preferences)
                        drainedLog=outputState.output;let range=completion.append(to:&drainedLog)
                        if !invalidated{commandFinished=true;commandSucceeded=receipt.success;cancelled=receipt.cancelled;currentWork=completion.currentWork;percentage=100;completionRange=range;output=drainedLog}
                    }
                }
                if !receivedCommand{consume(parser.processPending(),parser:parser);consume(parser.finish(),parser:parser)}
                let result = try await operation.value
                guard !invalidated else { return }
                guard !token.isCancelled else {cancelled=true;presentFailure(OperationCancellationFailure.cancelled,context:"Any patches written before cancellation remain in the output directory.");return}
                if result.stdout.isEmpty { appendDiagnostic("No patches created for this selection.") }
                // Use the full stdout, independently of the visible output limit.
                // A newline in the directory remains literal; Git sanitizes names.
                let resolved = folder.resolvingSymlinksInPath()
                files = String(decoding: result.stdout, as: UTF8.self).components(separatedBy: resolved.path + "/").dropFirst().compactMap { part in
                    let name = part.hasSuffix("\n") ? String(part.dropLast()) : part
                    guard !name.isEmpty, !name.contains("/"), !name.contains("\n"), name != ".", name != ".." else { return nil }
                    let file = resolved.appendingPathComponent(name)
                    return FileManager.default.fileExists(atPath: file.path) ? file : nil
                }
                success = true; exitCode = 0
            } catch let failure as GitCommandCancellationFailure {
                cancelled = true; exitCode = failure.result.exitCode
                if !invalidated {presentFailure(failure,context:"Any patches written before cancellation remain in the output directory.")}
            } catch let failure as OperationCancellationFailure {
                cancelled = true
                if !invalidated {presentFailure(failure,context:"Any patches written before cancellation remain in the output directory.")}
            } catch {
                exitCode = (error as? GitFailure)?.code
                if !invalidated {presentFailure(error)}
            }
        }
    }
    private func presentFailure(_ error:Error,context:String="") {
        if commandFinished {
            // Actual command diagnostics already arrived through onOutput. A
            // preflight/finalization error without a Git result is independent.
            if !(error is GitCommandCancellationFailure),!(error is GitFailure){output += (output.hasSuffix("\n") ? "":"\n")+error.localizedDescription+"\n"}
            if !context.isEmpty{output += context+"\n"}
        }else{outputState.presentFailure(error,context:context);output=outputState.output;currentWork=outputState.currentWork;percentage=outputState.percentage}
    }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        outputState.consume(emission, parser: parser);drainedLog=outputState.output
        guard !invalidated else{return}
        output = outputState.output
        currentWork = outputState.currentWork; percentage = outputState.percentage
    }
    private func appendDiagnostic(_ text: String) {
        if commandFinished{output += (output.hasSuffix("\n") ? "":"\n")+text+"\n";drainedLog=output;return}
        let parser = GitCliOutputParser(limit: outputState.limit)
        parser.appendChunk(Data(((output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + text).utf8))
        consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser)
    }
    private func finishAutomatically() {
        if !busy,!hasPendingWork,!confirmingQuit, !confirmingCancellation, !invalidated,
           progressClosePolicy.shouldClose(success: success, postActionCount: 0) { finish() }
    }
    func cancelExport() {
        guard busy,!commandFinished,!confirmingQuit, let token = cancellation, !cancelRequested, !confirmingCancellation, !invalidated else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true;pendingQuestions += 1;let generation=interactionGeneration;Self.activeOperations += 1;var answered=false
            confirmCancellation { [weak self] accepted in
                guard !answered else{return};answered=true;Self.activeOperations -= 1
                guard let self,self.confirmingCancellation else{return};self.confirmingCancellation=false;self.pendingQuestions -= 1;if !self.hasPendingWork{self.workDidDrain?()};if self.invalidated{self.saveDrainedActionLog()}
                guard !self.invalidated,!self.confirmingQuit,self.interactionGeneration==generation else{return}
                if self.busy,!self.commandFinished, self.cancellation === token, accepted { self.cancelRequested = true; token.cancel() }
                self.finishAutomatically()
            }
        } else { cancelRequested = true; token.cancel() }
    }
    func finish() {
        guard !busy,!hasPendingWork,!confirmingQuit,progress,!confirmingCancellation,!finishScheduled,!invalidated else{return}
        saveActionLog();finishScheduled=true;let generation=interactionGeneration,acceptedFiles=files,mail=exportSendMail,succeeded=success
        finishProgress { [weak self] in
            guard let self else{return};self.finishScheduled=false;self.progress=false
            guard !self.invalidated,!self.confirmingQuit,self.interactionGeneration==generation else{return}
            if succeeded{if mail{self.composeMail(acceptedFiles)}else{self.close()}}
        }
    }
    func unifiedDiff(alternate: Bool = false, onResult: ((Data) -> Void)? = nil) {
        guard optionsAvailable, hasHead, !bare else { return }
        let prefix = noPrefix
        preferences.set(prefix, forKey: "FormatPatchNoPrefix"); let token = beginRead()
        Task {
            defer { finishRead(token) }
            do {
                try checkAccess()
                let result = try await repository.run(["diff", "--no-ext-diff", "--no-color", "--stat", "--patch"] + (prefix ? ["--no-prefix"] : []) + ["--end-of-options", "HEAD", "--"], cancellation: token)
                guard !invalidated, !token.isCancelled else { return }
                if let onResult { onResult(result.stdout) } else { showPatch(result.stdout, alternate) }
            } catch { if !invalidated && !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct FormatPatchDialog: View {
    @ObservedObject var model: FormatPatchWindowModel
    func radio(_ title: String, mode: FormatPatchWindowModel.Mode) -> some View {
        let context=model.formContext
        return FormatPatchRadio(title: title, selected: model.mode == mode) { if model.optionsAvailable,model.formContext==context {model.mode = mode} }.frame(width: 145, alignment: .leading)
    }
    var body: some View {
        let context=model.formContext
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Output Directory") { HStack {
                Text("Directory:").frame(width: 90, alignment: .leading)
                FormatPatchCombo(value: model.field(\.directory,context:context), choices: model.dirs, label: "Output directory")
                Button("…") { model.chooseDirectory() }.accessibilityLabel("Choose output directory")
            }.padding(8) }
            GroupBox("Version") { VStack(spacing: 8) {
                HStack { radio("Since", mode: .since)
                    FormatPatchCombo(value: model.field(\.since,context:context), choices: model.references, label: "Since revision").disabled(model.mode != .since)
                    Button("…") { model.chooseRevision(.since) }.accessibilityLabel("Browse branches").disabled(model.mode != .since)
                }
                HStack { radio("Number Commits", mode: .number)
                    TextField("Commit count", value: model.field(\.count,context:context), format: .number.grouping(.never)).disabled(model.mode != .number)
                    Stepper("", value: model.field(\.count,context:context), in: 1...Int(Int32.max)).labelsHidden().disabled(model.mode != .number)
                }
                HStack { radio("Range", mode: .from); Text("From:").frame(width: 40, alignment: .leading)
                    FormatPatchCombo(value: model.field(\.from,context:context), choices: model.fromHistory, label: "From revision").disabled(model.mode != .from)
                    Button("…") { model.chooseRevision(.from) }.accessibilityLabel("Choose From commit").disabled(model.mode != .from)
                }
                HStack { Color.clear.frame(width: 145); Text("To:").frame(width: 40, alignment: .leading)
                    FormatPatchCombo(value: model.field(\.to,context:context), choices: model.toHistory, label: "To revision").disabled(model.mode != .from)
                    Button("…") { model.chooseRevision(.to) }.accessibilityLabel("Choose To commit").disabled(model.mode != .from)
                }
            }.padding(8) }
            Toggle("Send Mail after create", isOn: model.field(\.sendMail,context:context))
            Toggle("No a/ and b/ prefixes", isOn: model.field(\.noPrefix,context:context))
            HStack {
                Button("Save unified diff since HEAD") { model.unifiedDiff(alternate: NSEvent.modifierFlags.contains(.shift)) }.disabled(!model.hasHead || model.bare)
                Spacer(); if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
                Button("OK") { model.export() }.keyboardShortcut(.defaultAction).disabled(!model.valid)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                    .environment(\.isEnabled, !model.isRetired && !model.hasOptionSheet && !model.progress && !model.finishScheduled && !model.composingMail && !model.openingViewer)
                Button("Help") { TurtleGitHelp.show(.patches) }
            }
        }.padding(16).disabled(!model.optionsAvailable)
        .alert("Format Patch", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

struct FormatPatchProgressDialog: View {
    @ObservedObject var model: FormatPatchWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            Text(model.currentWork.isEmpty ? " " : model.currentWork).font(.caption).lineLimit(1).help(model.currentWork)
            ProgressView(value: Double(model.busy ? model.percentage ?? 0 : 100), total: 100)
                .tint(model.commandFinished ? (model.commandSucceeded ? .blue:.red):model.busy ? .accentColor:model.success ? .blue:.red).accessibilityLabel("Git command progress")
            SubmoduleProgressOutputView(text: model.output, completed: model.commandFinished || !model.busy, completionRange: model.completionRange, success: model.commandFinished ? model.commandSucceeded:model.success, preferences:model.outputPreferences, clipboard:model.outputClipboard)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if model.busy && !model.commandFinished { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
                Text(model.progressStatus).foregroundStyle(model.commandFinished ? (model.commandSucceeded ? Color.green:.red):model.busy ? Color.primary:model.success ? .green:.red)
                Spacer()
                Button("Close") { model.finish() }.keyboardShortcut(.defaultAction).disabled(model.busy || model.confirmingCancellation)
                Button("Abort") { if model.busy { model.cancelExport() } else { model.finish() } }.keyboardShortcut(.cancelAction)
                    .disabled(model.success || model.confirmingCancellation || model.busy && !model.canCancel)
            }
        }.padding(16).frame(minWidth: 650, idealWidth: 760, minHeight: 320, idealHeight: 430).disabled(model.confirmingQuit)
        .gitDockProgress(.command(busy: model.busy && !model.commandFinished, success: model.commandFinished ? model.commandSucceeded:model.success, waiting: model.confirmingCancellation, percentage: model.percentage))
    }
}

private struct FormatPatchRadio: NSViewRepresentable {
    let title: String; let selected: Bool; let select: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:))) }
    func updateNSView(_ button: NSButton, context: Context) { button.state = selected ? .on : .off; button.isEnabled = enabled; context.coordinator.select = select }
    static func dismantleNSView(_ view:NSButton,coordinator:Coordinator){coordinator.live=false;view.target=nil;view.action=nil;coordinator.select={}}
    final class Coordinator: NSObject {var live=true;var select:()->Void={};@objc func clicked(_ sender:NSButton){guard live,sender.isEnabled,sender.window != nil else{return};select()} }
}

private struct FormatPatchCombo: NSViewRepresentable {
    @Binding var value: String; let choices: [String]; let label: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox { let view = NSComboBox(); view.delegate = context.coordinator; view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view }
    func updateNSView(_ view: NSComboBox, context: Context) {
        let c = context.coordinator; c.updating = true; defer { c.updating = false }; c.change = { value = $0 }
        if c.choices != choices { view.removeAllItems(); view.addItems(withObjectValues: choices); c.choices = choices }
        if view.stringValue != value { view.stringValue = value }; view.isEnabled = enabled; view.setAccessibilityLabel(label)
    }
    static func dismantleNSView(_ view:NSComboBox,coordinator:Coordinator){coordinator.live=false;coordinator.change={_ in};view.delegate=nil}
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var live=true
        var updating = false; var choices: [String] = []; var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) { guard live,!updating, let view = notification.object as? NSComboBox,view.isEnabled,view.window != nil else { return }; change(view.stringValue) }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard live,!updating, let view = notification.object as? NSComboBox,view.isEnabled,view.window != nil, choices.indices.contains(view.indexOfSelectedItem) else { return }; change(choices[view.indexOfSelectedItem]) }
    }
}

/// An actual native progress owner; a SwiftUI dismissal request is not closure.
@MainActor final class FormatPatchProgressWindowController:NSWindowController,NSWindowDelegate {
    let model:FormatPatchWindowModel
    var onClosed:()->Void={}
    var onForcedClose:()->Void={}
    private(set) var presentationClosed=false
    private var retiring=false,finishing=false,closingForHandoff=false
    private var pending:(()->Void)?
    private var release:FormatPatchRelease?
    private var observation:AnyCancellable?
    init(model:FormatPatchWindowModel){
        self.model=model
        let window=SubmoduleProgressNativeWindow(contentRect:NSRect(x:0,y:0,width:760,height:430),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        RepositoryWindowTitles.set(window,repository:model.repository.root,dialog:"Format Patch",preferences:model.preferences)
        window.isReleasedWhenClosed=false;window.contentMinSize=NSSize(width:650,height:320)
        window.contentViewController=NSHostingController(rootView:FormatPatchProgressDialog(model:model).defaultAppStorage(model.preferences))
        super.init(window:window);window.delegate=self
        window.escapeAction={ [weak model] in guard let model else{return};if model.busy{model.cancelExport()}else{model.finish()} }
        observation=model.objectWillChange.sink{ [weak self] _ in Task{ @MainActor in await Task.yield();self?.closeIfReady()} }
        NotificationCenter.default.addObserver(self,selector:#selector(sheetEnded),name:NSWindow.didEndSheetNotification,object:window)
    }
    @objc private func sheetEnded(){DispatchQueue.main.async{ [weak self] in self?.closeIfReady()}}
    func finish(_ done:@escaping()->Void){guard !retiring,!finishing,!model.confirmingQuit else{return};finishing=true;pending=done;closeIfReady()}
    private func closeIfReady(){
        guard finishing,!retiring,!model.confirmingQuit,!model.busy,!model.hasPendingWork,!model.confirmingCancellation,window?.attachedSheet == nil else{return}
        closingForHandoff=true;close()
    }
    override func close(){super.close();if !retiring,window?.isVisible != true{retire()}}
    func windowShouldClose(_ sender:NSWindow)->Bool{guard !retiring,!model.confirmingQuit else{return false};if model.busy{model.cancelExport()}else{model.finish()};return false}
    func windowWillClose(_ notification:Notification){guard notification.object as? NSWindow === window else{return};retire()}
    private func retire(){
        guard !retiring else{return};retiring=true;NotificationCenter.default.removeObserver(self)
        let action=closingForHandoff ? pending:nil;pending=nil
        if !closingForHandoff{model.invalidate();onForcedClose()}
        let release=FormatPatchRelease(window:window,parent:window?.sheetParent,ready:{ [self] in !model.hasPendingWork && !model.confirmingCancellation }){ [self] in
            self.release=nil;observation=nil;presentationClosed=true;let done=onClosed;onClosed={};done()
            DispatchQueue.main.async{action?()}
        };self.release=release;release.start()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}
@MainActor private final class FormatPatchRelease {
    static private(set) var activeCount=0
    let window:NSWindow?,parent:NSWindow?
    private let closeWindow:Bool,ready:()->Bool
    private var done:()->Void
    private var waiter:Task<Void,Never>?
    private var started=false,finished=false
    init(window:NSWindow?,parent:NSWindow?,closeWindow:Bool=false,ready:@escaping()->Bool={true},completion:@escaping()->Void){self.window=window;self.parent=parent;self.closeWindow=closeWindow;self.ready=ready;done=completion}
    func start(){
        guard !started else{return};started=true;Self.activeCount += 1
        if let window,window.sheetParent != nil || parent?.attachedSheet === window{(window.sheetParent ?? parent)?.endSheet(window);window.orderOut(nil)}
        drain();if !finished{waiter=Task{ @MainActor [self] in while !finished{try? await Task.sleep(nanoseconds:5_000_000);drain()} }}
    }
    private func drain(){
        guard !finished,window?.attachedSheet == nil,window?.sheetParent == nil,window == nil || parent?.attachedSheet !== window,ready() else{return}
        finished=true;waiter?.cancel();waiter=nil;Self.activeCount -= 1
        if closeWindow{window?.close()};let finish=done;done={};finish()
    }
}
