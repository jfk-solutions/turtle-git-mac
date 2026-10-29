import AppKit
import SwiftUI
import Combine
import TurtleGitCore

struct ResetChooserDraft: Equatable {
    let target: CheckoutTarget
    let branch: GitReferenceName
    let tag: GitReferenceName
    let commit: GitReferenceName
    let mode: ResetMode
}

@MainActor final class ResetWindowController: NSWindowController, NSWindowDelegate {
    var commandProgressScope: CommandProgressScope? { model.commandProgressScope }
    static var activeChildReleases:Int {ResetChildRelease.activeCount}
    let model: ResetWindowModel
    private var retiredProgress:ResetProgressWindowModel?
    private var retiredLogPickers:[LogWindowController]=[]
    private var retiredReferencePickers:[ReferenceBrowserWindowController]=[]
    var transportBatchWorkPending:Bool {
        model.pendingBatchWorkers>0 || model.chooser.hasPendingReferenceReads ||
        model.progress?.hasPendingWork == true || retiredProgress?.hasPendingWork == true ||
        progressController?.model.hasPendingWork == true ||
        ([commitPicker].compactMap{$0}+retiredLogPickers).contains{$0.model.pendingHistoryLoads>0 || $0.window?.sheetParent != nil} ||
        ([referencePicker].compactMap{$0}+retiredReferencePickers).contains{$0.model.pendingReferenceReads>0 || $0.window?.sheetParent != nil} ||
        !childReleases.isEmpty || release != nil || window?.attachedSheet != nil || window?.sheetParent != nil
    }
    private var release:ResetChildRelease?
    private var childReleases:[UUID:ResetChildRelease]=[:]
    private var closedActions:[()->Void]=[]
    private var released=false
    private var presentationParent:NSWindow?
    private(set) var hardAlert:NSAlert?
    var onClosed: () -> Void = {}
    private(set) var progressController: ResetProgressWindowController?
    private(set) var modifiedComparison: RevisionComparisonWindowController?
    private var closed = false
    private(set) var commitPicker: LogWindowController?
    private var commitPickerRequest: UUID?
    private(set) var referencePicker: ReferenceBrowserWindowController?
    private var referencePickerRequest: UUID?
    private var pendingSheetResult: (() -> Void)?
    private let preferences: UserDefaults
    var configureCommitPicker: (LogWindowModel) -> Void = { _ in }
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var presentReferencePicker: (NSWindow, NSWindow) -> Bool = { owner, child in
        guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true
    }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void, UserDefaults, String?) -> LogWindowController = { repository, access, choose, preferences, revision in
        LogWindowController(repository: repository, access: access, onChoose: choose, labelDefaults: preferences, initialRevision: revision)
    }
    var presentCommitPicker: (NSWindow, NSWindow) -> Bool = { owner, child in
        guard owner.attachedSheet == nil else { return false }
        owner.beginSheet(child); return true
    }
    var configureModifiedComparison: (RevisionComparisonWindowModel) -> Void = { _ in }
    var presentModifiedComparison: (NSWindow, NSWindow) -> Bool = { owner, child in
        guard owner.attachedSheet == nil else { return false }
        owner.beginSheet(child); return true
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        model = ResetWindowModel(repository: repository, access: access, revision: revision, preferences: preferences)
        let size = NSSize(width: 690, height: 405)
        let window = ReferenceFormNativeWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Reset", preferences: preferences)
        window.referenceMinimumContentSize = size; window.contentMaxSize = NSSize(width: 4000, height: size.height); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ResetDialog(model: model, chooser: model.chooser).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        window.setContentSize(size); window.center()
        model.afterClose = { [self] action in
            let action=CommandProgressContext.capture(self.commandProgressScope,action)
            if self.released {action();return}
            self.closedActions.append(action)
            if !self.closed {self.presentationParent=self.window?.sheetParent;self.window?.close()}
        }
        model.onReadSettled = { [weak self] in self?.finishReadClose() }
        model.close = { [weak self] in guard let self else { return }; if self.model.confirmingQuit || self.model.confirmingHard {return}; if self.model.cancelReads(closeAfter: true) { return }; guard !self.model.busy, !self.model.showingModifiedFiles, !self.model.showingCommitPicker, !self.model.showingReferencePicker, self.model.progress == nil, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        model.onShowReferencePicker = { [weak self] in self?.showReferencePicker(preferences: preferences) }
        model.onShowCommitPicker = { [weak self] in self?.showCommitPicker(preferences: preferences) }
        model.onShowModified = { [weak self] in self?.showModifiedFiles() }
        model.onProgress = { [weak self] result in
            guard let self, !self.closed, let window = self.window, window.attachedSheet == nil else { self?.model.abandonProgressPresentation(result); return }
            let controller = ResetProgressWindowController(model: result)
            controller.onClosing = { [weak model = self.model] window in model?.handoffPresentation = MergeWindowPresentation(window) }
            controller.onClosed = { [weak self, weak result] in guard let self, let result else { return }; self.progressController = nil; self.model.finish(result) }
            self.progressController = controller; if let child = controller.window { child.appearance=window.appearance;child.alphaValue=window.alphaValue;window.beginSheet(child) } else { result.abandonPresentation() }
        }
        model.confirmHard = { [weak self] plan, choose in
            guard let self, let window = self.window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Discard all local changes?"
            alert.informativeText = "Hard reset replaces the index and tracked working files with \(plan.revision). Untracked files that obstruct checkout can also be removed."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Reset")
            self.hardAlert=alert;alert.window.appearance=window.appearance;alert.window.alphaValue=window.alphaValue
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, !self.closed else { return }
                self.pendingSheetResult = { self.hardAlert=nil;choose(response == .alertSecondButtonReturn) }; self.drainSheetResult()
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(pickerSheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        DialogGeometry.attach(window, identifier: "ResetDialog", legacyName: "ResetDialog")
    }
    @objc private func pickerSheetEnded() { drainSheetResult();DispatchQueue.main.async { [weak self] in self?.drainSheetResult() } }
    private func drainSheetResult() {
        guard !closed, window?.attachedSheet == nil, referencePicker == nil, commitPicker == nil, let result = pendingSheetResult else { return }
        pendingSheetResult = nil; result()
    }
    private func finishReadClose() {
        guard !closed, model.closeAfterRead, !model.busy, !model.chooser.busy, window?.attachedSheet == nil else { return }
        window?.close()
    }
    private func releaseChild(_ child:NSWindow?,completion:@escaping ()->Void) {
        guard let child else {completion();return}
        let id=UUID(),release=ResetChildRelease(window:child,parent:window) { [self] in childReleases.removeValue(forKey:id);completion() }
        childReleases[id]=release;release.start()
    }
    private func showReferencePicker(preferences: UserDefaults) {
        guard !closed, let owner = window, owner.attachedSheet == nil,
              referencePicker == nil, model.beginReferencePicker() else { return }
        let request = UUID(), context = model.formContext; referencePickerRequest = request
        let picker = ReferenceBrowserWindowController(repository: model.chooser.repository, access: model.access, initial: model.chooser.revision, preferences: preferences) { [weak self] name in
            guard let self, !self.closed, self.referencePickerRequest == request else { return }
            guard self.pendingSheetResult == nil else { return }
            self.pendingSheetResult = { [weak self] in
                guard let self, self.referencePickerRequest == request else { return }
                self.referencePickerRequest = nil
                guard !self.model.confirmingQuit,self.model.formContext == context else { self.model.finishReferencePicker(); return }
                self.model.acceptReferenceSelection(name) {}
            }
            self.drainSheetResult()
        }
        referencePicker = picker; configureReferencePicker(picker.model)
        picker.onClosed = { [weak self, weak picker] in
            guard let self, let picker, self.referencePicker === picker else { return }
            self.releaseChild(picker.window) { [self] in self.referencePicker=nil;self.drainSheetResult() }
        }
        guard let child = picker.window else { picker.abandonPresentation(); referencePicker = nil; referencePickerRequest = nil; pendingSheetResult = nil; model.finishReferencePicker(); return }
        child.appearance = owner.appearance; child.alphaValue = owner.alphaValue
        guard presentReferencePicker(owner, child) else {
            picker.abandonPresentation(); referencePicker = nil; referencePickerRequest = nil; pendingSheetResult = nil; model.finishReferencePicker(); return
        }
        picker.model.load()
    }
    private func showCommitPicker(preferences: UserDefaults) {
        guard !closed, let owner = window, owner.attachedSheet == nil,
              commitPicker == nil, model.beginCommitPicker() else { return }
        let request = UUID(), context = model.formContext; commitPickerRequest = request
        let revision = model.chooser.commitRevision
        let picker = makeCommitPicker(model.chooser.repository, model.access, { [weak self] entry in
            guard let self, self.commitPickerRequest == request else { return }
            guard !self.closed, self.pendingSheetResult == nil else { return }
            self.pendingSheetResult = { [weak self] in
                guard let self, self.commitPickerRequest == request else { return }
                self.commitPickerRequest = nil
                let accepted = !self.model.confirmingQuit && self.model.formContext == context
                self.model.finishCommitPicker()
                if accepted,let entry { self.model.chooser.selectCustomRevision(entry.hash) }
            }
            self.drainSheetResult()
        }, preferences, revision.isEmpty ? nil : revision)
        commitPicker = picker; configureCommitPicker(picker.model)
        picker.onClosed = { [weak self, weak picker] in
            guard let self, let picker, self.commitPicker === picker else { return }
            self.releaseChild(picker.window) { [self] in self.commitPicker=nil;self.drainSheetResult() }
        }
        guard let child = picker.window else { picker.close(); commitPicker = nil; commitPickerRequest = nil; pendingSheetResult = nil; model.finishCommitPicker(); return }
        child.appearance = owner.appearance; child.alphaValue = owner.alphaValue
        guard presentCommitPicker(owner, child) else {
            picker.close(); commitPicker = nil; commitPickerRequest = nil; pendingSheetResult = nil; model.finishCommitPicker(); return
        }
        picker.model.reload()
    }
    private func showModifiedFiles() {
        guard !closed, let owner = window, owner.attachedSheet == nil,
              modifiedComparison == nil, model.beginModifiedFiles() else { return }
        let controller = RevisionComparisonWindowController(repository: model.chooser.repository, access: model.access, from: .revision("HEAD"), to: .workingTree, preferences: preferences)
        modifiedComparison = controller
        configureModifiedComparison(controller.model)
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller, self.modifiedComparison === controller else { return }
            self.releaseChild(controller.window) { [self] in self.modifiedComparison=nil;self.model.finishModifiedFiles() }
        }
        guard let child = controller.window else { controller.close(); modifiedComparison = nil; model.finishModifiedFiles(); return }
        child.appearance = owner.appearance; child.alphaValue = owner.alphaValue
        guard presentModifiedComparison(owner, child) else {
            controller.close(); modifiedComparison = nil; model.finishModifiedFiles(); return
        }
        controller.model.load()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.confirmingQuit {return false}; if model.cancelReads(closeAfter: true) { return false }; return !model.showingModifiedFiles && !model.showingCommitPicker && !model.showingReferencePicker && !model.busy && !model.confirmingHard && model.progress == nil && !model.chooser.busy && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true; retiredProgress=model.progress
        if let commitPicker {retiredLogPickers.append(commitPicker)}
        if let referencePicker {retiredReferencePickers.append(referencePicker)}
        pendingSheetResult = nil;model.afterClose=nil; NotificationCenter.default.removeObserver(self); model.invalidate()
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .abort); sheet.close() }
        progressController?.close(); progressController = nil
        referencePicker?.close(); referencePicker = nil; referencePickerRequest = nil
        commitPicker?.close(); commitPicker = nil; commitPickerRequest = nil; model.finishCommitPicker()
        modifiedComparison?.close(); modifiedComparison = nil
        model.finishModifiedFiles()
        guard let window else {released=true;onClosed();let actions=closedActions;closedActions=[];actions.forEach {$0()};return}
        let release=ResetChildRelease(window:window,parent:presentationParent ?? window.sheetParent) { [self] in
            self.release=nil;released=true;onClosed();let actions=closedActions;closedActions=[];actions.forEach {$0()}
        }
        self.release=release;release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class ResetWindowModel: ObservableObject {
    let commandProgressScope = CommandProgressContext.current
    private(set) static var activeReads = 0
    private(set) var pendingBatchWorkers=0
    struct FormContext:Equatable {let owner:ObjectIdentifier;let generation:Int;let draft:ResetChooserDraft}
    private var formGeneration=0
    var formContext:FormContext {FormContext(owner:ObjectIdentifier(self),generation:formGeneration,draft:pickerDraft)}
    var presentationPreferences:UserDefaults {preferences}
    var handoffPresentation:MergeWindowPresentation?
    @Published var confirmingQuit=false {didSet {if oldValue != confirmingQuit {formGeneration += 1}}}
    var canEditForm:Bool {!invalidated && !confirmingQuit && !closeAfterRead && !busy && !chooser.busy && !confirmingHard && progress == nil && !showingReferencePicker && !showingCommitPicker && !showingModifiedFiles}
    func field<Value>(_ key:ReferenceWritableKeyPath<SwitchWindowModel,Value>,context:FormContext)->Binding<Value> {
        Binding(get:{self.chooser[keyPath:key]},set:{value in guard self.canEditForm,self.formContext == context else{return};if key == \SwitchWindowModel.branchRevision,self.chooser.options.target != .branch {return}
            if key == \SwitchWindowModel.tagRevision,self.chooser.options.target != .tag {return}
            if key == \SwitchWindowModel.commitRevision,self.chooser.options.target != .commit {return}
            self.chooser[keyPath:key]=value})
    }
    func targetBinding(context:FormContext)->Binding<CheckoutTarget> {
        Binding(get:{self.chooser.options.target},set:{value in guard self.canEditForm,self.formContext == context else{return};self.chooser.options.target=value})
    }
    func modeBinding(context:FormContext)->Binding<ResetMode> {
        Binding(get:{self.mode},set:{value in guard self.canEditForm,self.formContext == context,!self.bare || value == .soft else{return};self.mode=value})
    }
    let chooser: SwitchWindowModel
    var readState: (OperationCancellation) async throws -> (String, Bool)
    var preparePlan: (String, ResetMode, OperationCancellation) async throws -> ResetPlan
    var onReadSettled: () -> Void = {}
    private(set) var closeAfterRead = false
    private var hardQuestion: UUID?
    var pickerDraft: ResetChooserDraft { ResetChooserDraft(target: chooser.options.target, branch: GitReferenceName(chooser.branchRevision), tag: GitReferenceName(chooser.tagRevision), commit: GitReferenceName(chooser.commitRevision), mode: mode) }
    func cancelReads(closeAfter: Bool = false) -> Bool {
        let chooserReading = chooser.cancelInitialRead()
        guard loadCancellation != nil || resetCancellation != nil || chooserReading else { return false }
        closeAfterRead = closeAfterRead || closeAfter; loadCancellation?.cancel(); resetCancellation?.cancel(); return true
    }
    func abandonProgressPresentation(_ result: ResetProgressWindowModel) {
        guard progress === result else { return }; result.abandonPresentation(); result.invalidate(); progress = nil; busy = false
    }
    let access: RepositoryAccessLease?
    private let initialRevision: String?
    var formPreferences:UserDefaults {preferences}
    private let preferences: UserDefaults
    @Published var currentBranch = ""
    @Published var mode = ResetMode.mixed
    @Published var bare = false
    @Published var busy = false {didSet {if oldValue != busy {formGeneration += 1}}}
    @Published var error: String?
    @Published private(set) var confirmingHard = false {didSet {if oldValue != confirmingHard {formGeneration += 1}}}
    @Published private(set) var progress: ResetProgressWindowModel?
    var onProgress: ((ResetProgressWindowModel) -> Void)?
    var onPostAction: ((ResetPostAction) -> Void)?
    var onNotificationLog:RemoteProgressLogHandler = {_,_,_,_,_ in}
    var onChanged: (String) -> Void = { _ in }
    var performResetAccepted:((ResetPlan,OperationCancellation) async throws->RepositoryTransitionReceipt)?
    @Published private(set) var acceptedCommand:RepositoryTransitionReceipt?
    private var acceptedCompletionDelivered=false
    var resultInspectionPending:Bool{acceptedCommand != nil && !acceptedCompletionDelivered}
    func finish(_ result: ResetProgressWindowModel) {
        CommandProgressContext.perform(commandProgressScope) { finishInCommandProgressScope(result) }
    }
    private func finishInCommandProgressScope(_ result: ResetProgressWindowModel) {
        guard !invalidated, progress === result, !result.busy, !result.confirmingCancellation else { return }
        progress = nil; result.invalidate(); busy = false; error = nil
        if result.success,!result.cancelled,!result.resultInspectionPending {
            let completed=onReset,output=result.output
            let dispatch=CommandProgressContext.capture(commandProgressScope) {completed(output)}
            if let afterClose {afterClose(dispatch)} else {close();dispatch()}
        }
    }
    var close: () -> Void = {}
    var confirmHard: (ResetPlan, @escaping (Bool) -> Void) -> Void = { _, choose in choose(false) }
    var onReset: (String) -> Void = { _ in }
    var afterClose:((@escaping ()->Void)->Void)?
    private(set) var initialModeFocusPending = true
    private(set) var initialModeFocusAvailable = true
    var canFocusInitialMode: Bool { !confirmingQuit && initialModeFocusAvailable && initialModeFocusPending && !busy && !chooser.busy && !confirmingHard && progress == nil && !showingModifiedFiles && !showingCommitPicker && !showingReferencePicker && error == nil && chooser.error == nil }
    func acknowledgeInitialModeFocus() { initialModeFocusPending = false }
    func invalidateInitialModeFocus() { initialModeFocusAvailable = false; initialModeFocusPending = false }
    @Published private(set) var showingReferencePicker = false {didSet {if oldValue != showingReferencePicker {formGeneration += 1}}}
    private var referenceSelectionAvailable = true
    @Published private(set) var referenceFocusRequest = 0
    private var appliedReferenceFocusRequest = 0
    private var referenceSelectionToken: OperationCancellation?
    var onShowReferencePicker: () -> Void = {}
    var canShowReferencePicker: Bool { !invalidated && !confirmingQuit && !closeAfterRead && referenceSelectionAvailable && !busy && !chooser.busy && chooser.browser == nil && !confirmingHard && progress == nil && !showingModifiedFiles && !showingCommitPicker && !showingReferencePicker && chooser.options.target == .branch }
    func showReferencePicker() { guard canShowReferencePicker else { return }; onShowReferencePicker() }
    func beginReferencePicker() -> Bool { guard canShowReferencePicker else { return false }; showingReferencePicker = true; return true }
    func finishReferencePicker() { referenceSelectionToken?.cancel(); referenceSelectionToken = nil; showingReferencePicker = false }
    func invalidateReferenceSelection() { referenceSelectionAvailable = false; referenceFocusRequest = 0; finishReferencePicker() }
    func focusReference(_ control: NSControl, target: CheckoutTarget) {
        guard !confirmingQuit, referenceSelectionAvailable, referenceFocusRequest > appliedReferenceFocusRequest,
              chooser.options.target == target, !busy, !chooser.busy, !showingReferencePicker, !showingCommitPicker, !showingModifiedFiles,
              !confirmingHard, progress == nil, error == nil, chooser.error == nil,
              control.isEnabled, let window = control.window, window.attachedSheet == nil else { return }
        if window.makeFirstResponder(control) { appliedReferenceFocusRequest = referenceFocusRequest }
    }
    func acceptReferenceSelection(_ name: String?, completion: @escaping () -> Void) {
        guard !confirmingQuit, referenceSelectionAvailable, showingReferencePicker else { return }
        referenceSelectionToken?.cancel(); let token = OperationCancellation(); referenceSelectionToken = token
        let revision = name ?? chooser.revision, commitDraft = chooser.commitRevision, context = formContext
        Self.activeReads += 1;pendingBatchWorkers += 1
        Task {
            var applied = false
            defer { Self.activeReads -= 1;pendingBatchWorkers -= 1; withExtendedLifetime(access) {}; if referenceSelectionToken === token { referenceSelectionToken = nil; showingReferencePicker = false; if applied { initialModeFocusPending = false; referenceFocusRequest += 1 }; completion() } }
            do {
                try validateAccess()
                let references = try await chooser.repository.checkoutReferences(includeFetchHead: preferences.includesFetchHead, localBranchesFirst: AdvancedListBehavior(defaults: preferences).localBranchesFirst, cancellation: token)
                guard !confirmingQuit, referenceSelectionAvailable, referenceSelectionToken === token, !token.isCancelled, formContext == context else { return }
                chooser.references = references
                if let reference = references.first(where: { GitReferenceName.equal($0.name, revision) }), let target = reference.target {
                    chooser.options.target = target
                    if target == .tag { chooser.tagRevision = revision } else { chooser.branchRevision = revision }
                    chooser.commitRevision = commitDraft
                } else { chooser.options.target = .commit; chooser.selectCustomRevision(revision) }
                applied = true
            } catch { if referenceSelectionAvailable, referenceSelectionToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    @Published private(set) var showingCommitPicker = false {didSet {if oldValue != showingCommitPicker {formGeneration += 1}}}
    var onShowCommitPicker: () -> Void = {}
    var canShowCommitPicker: Bool { !invalidated && !confirmingQuit && !closeAfterRead && !busy && !chooser.busy && chooser.browser == nil && !confirmingHard && progress == nil && !showingModifiedFiles && !showingCommitPicker && !showingReferencePicker && chooser.options.target == .commit }
    func showCommitPicker() { guard canShowCommitPicker else { return }; onShowCommitPicker() }
    func beginCommitPicker() -> Bool { guard canShowCommitPicker else { return false }; showingCommitPicker = true; return true }
    func finishCommitPicker() { showingCommitPicker = false }
    @Published private(set) var showingModifiedFiles = false {didSet {if oldValue != showingModifiedFiles {formGeneration += 1}}}
    var onShowModified: () -> Void = {}
    var canShowModifiedFiles: Bool { !invalidated && !confirmingQuit && !closeAfterRead && !bare && !busy && !chooser.busy && chooser.browser == nil && !showingCommitPicker && !showingReferencePicker && !confirmingHard && progress == nil && !showingModifiedFiles }
    func showModifiedFiles() { guard canShowModifiedFiles else { return }; onShowModified() }
    func beginModifiedFiles() -> Bool { guard canShowModifiedFiles else { return false }; showingModifiedFiles = true; return true }
    func finishModifiedFiles() { showingModifiedFiles = false }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String?, preferences: UserDefaults = .standard) {
        chooser = SwitchWindowModel(repository: repository, access: access, preferences: preferences); self.access = access; initialRevision = revision; self.preferences = preferences
        readState = { token in try await (repository.branch(cancellation: token), repository.isBare(cancellation: token)) }
        preparePlan = { try await repository.prepareReset(to: $0, mode: $1, cancellation: $2) }
        chooser.onInitialReadSettled = { [weak self] in self?.onReadSettled() }
    }
    private var invalidated = false
    private var loaded=false
    private var loadCancellation: OperationCancellation?
    private var loadTask: Task<Void, Never>?
    private var resetCancellation: OperationCancellation?
    func invalidate() {
        invalidated = true; hardQuestion = nil; loadCancellation?.cancel(); loadTask?.cancel(); loadCancellation = nil; loadTask = nil
        resetCancellation?.cancel(); resetCancellation = nil
        chooser.invalidate(); progress?.invalidate(); progress = nil; busy = false; confirmingHard = false
        invalidateInitialModeFocus(); invalidateReferenceSelection()
    }
    func load() {
        guard !loaded, !invalidated, !confirmingQuit, !closeAfterRead, !busy, !showingReferencePicker, !showingCommitPicker, !showingModifiedFiles else { return }
        loaded=true;busy = true; chooser.load(revision: initialRevision)
        let request = OperationCancellation()
        loadCancellation = request
        Self.activeReads += 1;pendingBatchWorkers += 1
        loadTask = Task { [self, access] in
            defer {
                Self.activeReads -= 1;pendingBatchWorkers -= 1
                if loadCancellation === request { loadCancellation = nil; loadTask = nil; busy = false; onReadSettled() }
                withExtendedLifetime(access) {}
            }
            do {
                try validateAccess()
                let (branch, bare) = try await readState(request)
                guard !invalidated, loadCancellation === request, !request.isCancelled else { return }
                currentBranch = branch; self.bare = bare; if bare { mode = .soft }
            } catch { if !invalidated, loadCancellation === request, !request.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(chooser.repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func reset() {
        CommandProgressContext.perform(commandProgressScope) { resetInCommandProgressScope() }
    }
    private func resetInCommandProgressScope() {
        guard acceptedCommand == nil,!invalidated, !confirmingQuit, !closeAfterRead, !busy, !showingReferencePicker, !showingCommitPicker, !showingModifiedFiles, !confirmingHard, progress == nil, !chooser.busy else { return }; busy = true
        let revision = chooser.revision, mode = mode, request = OperationCancellation()
        resetCancellation = request
        let context = formContext
        Self.activeReads += 1;pendingBatchWorkers += 1
        Task { [self, access] in
            defer {
                Self.activeReads -= 1;pendingBatchWorkers -= 1
                if resetCancellation === request { resetCancellation = nil; busy = false; onReadSettled() }
                withExtendedLifetime(access) {}
            }
            do {
                try validateAccess()
                let plan = try await preparePlan(revision, mode, request)
                guard !invalidated, !confirmingQuit, resetCancellation === request, !request.isCancelled, formContext == context else { return }
                resetCancellation = nil; busy = false
                if mode == .hard {
                    let question = UUID(); hardQuestion = question; confirmingHard = true
                    let confirmationGeneration=formGeneration
                    confirmHard(plan) { [weak self] accepted in
                        guard let self, !self.invalidated, self.hardQuestion == question else { return }
                        self.hardQuestion = nil; self.confirmingHard = false
                        if accepted, !self.confirmingQuit, self.formGeneration == confirmationGeneration + 1, self.pickerDraft == context.draft { self.apply(plan) }
                    }
                } else { apply(plan) }
            } catch { if !invalidated, resetCancellation === request, !request.isCancelled { self.error = error.localizedDescription } }
        }
    }

    func apply(_ plan: ResetPlan) {
        CommandProgressContext.perform(commandProgressScope) { applyInCommandProgressScope(plan) }
    }
    private func applyInCommandProgressScope(_ plan: ResetPlan) {
        guard acceptedCommand == nil,!invalidated, !confirmingQuit, !closeAfterRead, !busy, !showingReferencePicker, !showingCommitPicker, !showingModifiedFiles, !confirmingHard, progress == nil else { return }; busy = true; error = nil
        do { try validateAccess() } catch { self.error = error.localizedDescription; busy = false; return }
        if let onProgress {
            let result = ResetProgressWindowModel(repository: chooser.repository, plan: plan, preferences: preferences, access: access)
            result.close = { [weak self, weak result] in guard let result else { return }; self?.finish(result) }
            result.onChanged = onChanged; result.onNotificationLog = onNotificationLog
            let actionCallback=onPostAction,afterClose=afterClose,scope=commandProgressScope
            result.onPostAction = { action in
                let dispatch: () -> Void = CommandProgressContext.capture(scope) { _ = actionCallback?(action) }
                if let afterClose {afterClose(dispatch)} else {dispatch()}
            }
            progress = result; onProgress(result); if progress === result { result.start() }
        } else {
            let backend=GitLibGit2Configuration.load(from:preferences),recycle=preferences.object(forKey:"RevertWithRecycleBin") == nil || preferences.bool(forKey:"RevertWithRecycleBin")
            let request = OperationCancellation(); resetCancellation = request;pendingBatchWorkers += 1; LocalGitCommandProgress.begin()
            let publish=onChanged
            Task { [self, access, repository = chooser.repository] in
                var deliverCompletion=false
                defer {
                    pendingBatchWorkers -= 1;LocalGitCommandProgress.end();withExtendedLifetime(access){}
                    if resetCancellation === request{
                        resetCancellation=nil;busy=false
                        if deliverCompletion,!invalidated,!confirmingQuit,!request.isCancelled,let receipt=acceptedCommand{acceptedCompletionDelivered=true;onReset(receipt.output);close()}
                        else{onReadSettled()}
                    }
                }
                do{
                    let receipt:RepositoryTransitionReceipt
                    if let performResetAccepted{receipt=try await performResetAccepted(plan,request)}else{receipt=try await repository.resetAccepted(plan,cancellation:request,backend:backend,recycle:recycle)}
                    acceptedCommand=receipt;publish(receipt.output)
                    guard !invalidated,!confirmingQuit,resetCancellation === request,!request.isCancelled,!receipt.cancelledAfterCommand else{return}
                    deliverCompletion=true
                }catch{if !invalidated,resetCancellation === request,!request.isCancelled{self.error=error.localizedDescription}}
            }
        }
    }
    func retryResultInspection(){
        guard let receipt=acceptedCommand,!acceptedCompletionDelivered,!invalidated,!confirmingQuit,!busy,pendingBatchWorkers == 0 else{return}
        let token=OperationCancellation();resetCancellation=token;busy=true;pendingBatchWorkers += 1;Self.activeReads += 1
        Task{[self,access] in
            var deliverCompletion=false
            let timeout=Task{try? await Task.sleep(nanoseconds:5_000_000_000);if !Task.isCancelled{token.cancel()}}
            defer{
                timeout.cancel();pendingBatchWorkers -= 1;Self.activeReads -= 1;withExtendedLifetime(access){}
                if resetCancellation === token{resetCancellation=nil;busy=false;if deliverCompletion,!invalidated,!confirmingQuit,!token.isCancelled{acceptedCompletionDelivered=true;onReset(receipt.output);close()}else{onReadSettled()}}
            }
            do{try validateAccess();let (branch,bare)=try await readState(token);try token.check();guard !invalidated,!confirmingQuit,resetCancellation === token else{return};currentBranch=branch;self.bare=bare;deliverCompletion=true}
            catch{if !invalidated,!token.isCancelled{self.error=error.localizedDescription}}
        }
    }

}
private struct ResetDialog: View {
    @ObservedObject var model: ResetWindowModel
    @ObservedObject var chooser: SwitchWindowModel
    private func commands(_ context:ResetWindowModel.FormContext)->[ReferenceFormCommand] {[
        .init(id:"branch",title:"Branch",key:"b",sourceKey:"b",icon:.branch,focus:"Reset branch revision",action:{model.targetBinding(context:context).wrappedValue = .branch}),
        .init(id:"tag",title:"Tag",key:"t",sourceKey:"t",icon:.tag,focus:"Reset tag revision",action:{model.targetBinding(context:context).wrappedValue = .tag}),
        .init(id:"commit",title:"Commit",key:"c",sourceKey:"c",icon:.log,focus:"Reset commit revision",action:{model.targetBinding(context:context).wrappedValue = .commit}),
        .init(id:"browseReferences",title:"Browse references",key:"r",icon:.repositoryBrowser,enabled:model.canShowReferencePicker,action:{model.showReferencePicker()}),
        .init(id:"chooseCommit",title:"Choose commit",key:"g",icon:.log,enabled:model.canShowCommitPicker,action:{model.showCommitPicker()}),
        .init(id:"soft",title:"Soft: Leave working tree and index untouched",key:"s",sourceKey:"s",icon:.reset,focus:"ReferenceForm.soft",action:{model.modeBinding(context:context).wrappedValue = .soft}),
        .init(id:"mixed",title:"Mixed: Leave working tree untouched, reset index",key:"m",sourceKey:"m",icon:.reset,enabled:!model.bare,focus:"ReferenceForm.mixed",action:{model.modeBinding(context:context).wrappedValue = .mixed}),
        .init(id:"hard",title:"Hard: Reset working tree and index (discard all local changes)",key:"h",sourceKey:"h",icon:.reset,enabled:!model.bare,focus:"ReferenceForm.hard",action:{model.modeBinding(context:context).wrappedValue = .hard}),
        .init(id:"modifiedFiles",title:"Show modified files in working tree",key:"w",sourceKey:"w",icon:.compare,enabled:model.canShowModifiedFiles,action:{model.showModifiedFiles()})]
    }
    var body: some View {
        let context=model.formContext
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Current branch:").frame(width: 110, alignment: .leading); ReferenceFormCaption(value:model.currentBranch.isEmpty ? "detached HEAD":model.currentBranch,label:"Current branch").frame(maxWidth:.infinity).frame(height:22) }
            GroupBox("Reset active branch") {
                VStack(spacing: 6) {
                    HStack { SwitchRadio(title: "Branch", target: .branch, selection: model.targetBinding(context:context)).frame(width: 100)
                        ReferencePopup(references: chooser.branches, selection: model.field(\.branchRevision,context:context), accessibilityLabel: "Reset branch revision", focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .branch) }).disabled(chooser.options.target != .branch)
                        Button("…") { model.showReferencePicker() }.accessibilityLabel("Browse references").disabled(chooser.options.target != .branch)
                    }.frame(height: 26)
                    HStack { SwitchRadio(title: "Tag", target: .tag, selection: model.targetBinding(context:context)).frame(width: 100)
                        ReferencePopup(references: chooser.tags, selection: model.field(\.tagRevision,context:context), accessibilityLabel: "Reset tag revision", focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .tag) }).disabled(chooser.options.target != .tag); Color.clear.frame(width: 29)
                    }.frame(height: 26)
                    HStack { SwitchRadio(title: "Commit", target: .commit, selection: model.targetBinding(context:context)).frame(width: 100)
                        VersionRevisionField(text: model.field(\.commitRevision,context:context), choices: chooser.commitChoices, accessibilityLabel: "Reset commit revision", focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .commit) }).disabled(chooser.options.target != .commit)
                        Button("…") { model.showCommitPicker() }.accessibilityLabel("Choose commit").disabled(chooser.options.target != .commit)
                    }.frame(height: 26)
                }.padding(8)
            }
            GroupBox("Reset Type") {
                VStack(alignment: .leading, spacing: 7) {
                    ResetRadio(title: "Soft: Leave working tree and index untouched", value: .soft, selection: model.modeBinding(context:context), model: model).frame(height: 22)
                    ResetRadio(title: "Mixed: Leave working tree untouched, reset index", value: .mixed, selection: model.modeBinding(context:context), model: model).frame(height: 22).disabled(model.bare)
                    ResetRadio(title: "Hard: Reset working tree and index (discard all local changes)", value: .hard, selection: model.modeBinding(context:context), model: model).frame(height: 22).disabled(model.bare)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { model.showModifiedFiles() } label: { CommandLabel(title: "Show modified files in working tree", icon: .compare).frame(maxWidth: .infinity) }.disabled(model.bare)
            HStack { if model.busy || chooser.busy { ProgressView().controlSize(.small) }; Spacer()
                if model.acceptedCommand != nil{Button("Inspect reset result"){model.retryResultInspection()}}
                else{Button("OK") {model.reset()}.keyboardShortcut(.defaultAction).disabled(chooser.revision.isEmpty)}
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button { TurtleGitHelp.show(.reset) } label: { CommandLabel(title: "Help", icon: .help) }
            }
        }.padding(12).disabled(!model.canEditForm).onAppear { model.load() }
        .background(ReferenceFormCommands(entries:commands(context),preferences:model.formPreferences,available:{model.canEditForm},changes:model.objectWillChange.merge(with:chooser.objectWillChange).eraseToAnyPublisher()).frame(width:0,height:0))
        .overlay(alignment: .bottomLeading) { if model.busy && model.progress == nil || chooser.initialReadActive { Button("Cancel") { model.cancelReads() }.padding(12) } }
        .sheet(item: $chooser.browser) { target in SwitchReferenceChooser(model: chooser, target: target) }
        .alert("Reset failed", isPresented: Binding(get: { model.error != nil || chooser.error != nil }, set: { if !$0 { model.error = nil; chooser.error = nil } })) { Button("OK") { model.error = nil; chooser.error = nil } } message: { Text(model.error ?? chooser.error ?? "") }
    }
}
private struct ResetRadio: NSViewRepresentable {
    let title: String
    let value: ResetMode
    @Binding var selection: ResetMode
    let model: ResetWindowModel
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Button {
        let button = Button(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.setAccessibilityLabel(title)
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        button.title = title;button.toolTip=title;button.identifier = .init("ReferenceForm."+value.rawValue); button.state = selection == value ? .on : .off; button.isEnabled = enabled && !button.lifetime.retired
        context.coordinator.select = { selection = value }
        button.focus = { [weak button, weak model] in
            guard let button, let model, model.mode == value, model.canFocusInitialMode,
                  button.isEnabled, let owner = button.window, owner.attachedSheet == nil else { return }
            if owner.makeFirstResponder(button) { model.acknowledgeInitialModeFocus() }
        }
        button.scheduleFocus()
    }
    static func dismantleNSView(_ button: Button, coordinator: Coordinator) { button.focus = nil; button.lifetime.retire();coordinator.live=false;coordinator.select = {} }
    final class Coordinator: NSObject { var select: () -> Void = {};var live=true; @objc func clicked(_ sender: NSButton) {guard live,sender.isEnabled,sender.window != nil else{return}; select() } }
    final class Button: NSButton {
        let lifetime=TransportControlLifetime()
        var focus: (() -> Void)?
        private var focusQueued = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); lifetime.observe(self);scheduleFocus() }
        func scheduleFocus() {
            guard !lifetime.retired,let owner = window, !focusQueued else { return }; focusQueued = true
            DispatchQueue.main.async { [weak self, weak owner] in
                guard let self else { return }; self.focusQueued = false
                guard !self.lifetime.retired,let owner, self.window === owner else { return }; self.focus?()
            }
        }
    }
}

enum ResetPostAction: String, Hashable {
    case retry, inspectResult, submoduleUpdate, bisectGood, bisectBad, bisectSkip, bisectReset, clean
    var title: String { switch self { case .retry: return "Retry"; case .inspectResult: return "Inspect reset result"; case .submoduleUpdate: return "Submodule Update…"; case .bisectGood: return "Bisect good"; case .bisectBad: return "Bisect bad"; case .bisectSkip: return "Bisect skip"; case .bisectReset: return "Bisect reset"; case .clean: return "Clean up…" } }
    var icon: MenuIcon { switch self { case .retry,.inspectResult: return .refresh; case .submoduleUpdate: return .fetch; case .bisectGood: return .bisectGood; case .bisectBad: return .bisectBad; case .bisectSkip: return .bisect; case .bisectReset: return .bisectReset; case .clean: return .clean } }
}
private final class ResetNotificationBuffer:@unchecked Sendable {
    private let lock=NSLock()
    private var values:[GitResetNotification]=[]
    func append(_ value:GitResetNotification){lock.lock();values.append(value);lock.unlock()}
    func take()->[GitResetNotification]{lock.lock();defer{lock.unlock()};let copy=values;values=[];return copy}
}
@MainActor final class ResetProgressWindowModel: ObservableObject {
    let commandProgressScope = CommandProgressContext.current
    let backend:GitLibGit2Configuration
    let recycle:Bool
    let notifications:FileOperationProgressState
    var showsNotifications:Bool {backend.requests(.reset)}
    var actionLogOutput:String {showsNotifications ? notifications.output+"\n\n"+output:output}
    @Published var fileActionBusy=false
    @Published private(set) var notificationWarnings:[String]=[]
    var presentationAvailable:()->Bool = {true}
    var notificationOwnerAvailable:Bool {showsNotifications && active && !abandoned && !busy && !hasPendingWork && !confirmingQuit && !confirmingCancellation && !dispatched && presentationAvailable()}
    var notificationActionsAvailable:Bool {notificationOwnerAvailable && !fileActionBusy}
    var notificationKeyboardAvailable:Bool {showsNotifications && active && !abandoned && !confirmingQuit && !fileActionBusy && presentationAvailable()}
    var onNotificationFileAction:(FileOperationProgressAction,FileOperationProgressRow)->Void = {_,_ in}
    var onNotificationLog:RemoteProgressLogHandler = {_,_,_,_,_ in}
    func notificationFailure(_ text:String){appendDiagnostic(text)}

    private(set) static var activeOperations=0
    @Published private(set) var pendingOperations=0
    var hasPendingWork:Bool {pendingOperations > 0}
    var active:Bool {!invalidated}
    var workDidDrain:(()->Void)?
    private func beginWork(){pendingOperations += 1;Self.activeOperations += 1;LocalGitCommandProgress.begin()}
    private func endWork(){pendingOperations -= 1;Self.activeOperations -= 1;LocalGitCommandProgress.end();if !hasPendingWork {busy=false;workDidDrain?()}}
    var runReset:((ResetPlan,OperationCancellation,@escaping @Sendable (GitOutputChunk)->Void) async throws->String)?
    var runResetAccepted:((ResetPlan,OperationCancellation,@escaping @Sendable (GitOutputChunk)->Void) async throws->RepositoryTransitionReceipt)?
    @Published private(set) var acceptedCommand:RepositoryTransitionReceipt?
    @Published private(set) var resultInspectionPending=false
    private var notifiedAcceptedCommand=false
    var readBisect:((OperationCancellation) async throws->BisectState)?
    private var interactionGeneration=0
    @Published var confirmingQuit=false {didSet {if oldValue != confirmingQuit {interactionGeneration += 1}}}
    var closeForHandoff:((@escaping ()->Void)->Void)?
    let progressPresentation: GitCommandPresentation
    let repository: GitRepository
    let plan: ResetPlan
    private let access: RepositoryAccessLease?
    var repositoryAccess:RepositoryAccessLease? {access}
    let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private var cancellation = OperationCancellation()
    private var started = false, invalidated = false, dispatched = false, abandoned = false
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var completionRange:NSRange?
    @Published private(set) var commandFinished=false
    @Published private(set) var commandSucceeded=false
    private(set) var rawOutput=""
    var outputPreferences:UserDefaults {preferences}
    var outputClipboard:NSPasteboard = .general
    @Published private(set) var postActions: [ResetPostAction] = []
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onPostAction: ((ResetPostAction) -> Void)?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { active && busy && (!commandFinished || resultInspectionPending) && !confirmingQuit && !cancelling && !confirmingCancellation }
    init(repository: GitRepository, plan: ResetPlan, preferences: UserDefaults = .standard, access: RepositoryAccessLease? = nil,backend:GitLibGit2Configuration? = nil) { self.access = access; self.repository = repository; self.plan = plan; self.preferences = preferences;self.backend = backend ?? .load(from:preferences);recycle=preferences.object(forKey:"RevertWithRecycleBin") == nil || preferences.bool(forKey:"RevertWithRecycleBin");notifications=FileOperationProgressState(preferences:preferences); progressPresentation = GitCommandPresentation(defaults: preferences); self.autoClosePolicy = GitProgressAutoClose(preferences: preferences) }
    func invalidate() { notifications.retire();invalidated = true; cancellation.cancel(); confirmingCancellation = false; postActions = [];if !hasPendingWork {busy=false} }
    func abandonPresentation() { abandoned = true; cancellation.cancel() }
    private func resetAttempt(){notifications.begin("Reset "+plan.mode.rawValue+" "+plan.revision);notificationWarnings=[];busy=true;success=false;cancelled=false;cancelling=false;output="";rawOutput="";currentWork="";percentage=nil;postActions=[];completionRange=nil;commandFinished=false;commandSucceeded=false}
    func start() {
        CommandProgressContext.perform(commandProgressScope) { startInCommandProgressScope() }
    }
    private func startInCommandProgressScope() {guard !started,!invalidated,!confirmingQuit else{return};started=true;resetAttempt();beginWork();Task {await execute()}}
    func run() async {guard !started,!invalidated,!confirmingQuit else{return};started=true;resetAttempt();beginWork();await execute()}
    private func bounded(_ text:String,bytes limit:Int)->String {
        let bytes=Data(text.utf8),limit=max(0,limit)
        guard bytes.count > limit else{return text}
        let marker="\n[Output truncated at about \(progressPresentation.outputLimit / 1024) KiB]\n"
        var count=max(0,limit-marker.utf8.count)
        while count > 0,bytes[count] & 0xc0 == 0x80 {count -= 1}
        return String(decoding:bytes.prefix(count),as:UTF8.self)+String(decoding:marker.utf8.prefix(limit-count),as:UTF8.self)
    }
    private func completeOutput(succeeded:Bool,error:Error? = nil,startedAt:TimeInterval){
        guard !invalidated,!commandFinished else{return}
        let killed=error as? GitCommandCancellationFailure
        let completion=SubmoduleProgressCompletion(success:succeeded,cancelled:cancelled && killed==nil,exitCode:killed?.result.exitCode ?? (error as? GitFailure)?.code,elapsed:ProcessInfo.processInfo.systemUptime-startedAt,finished:Date(),preferences:preferences)
        output=bounded(output,bytes:progressPresentation.outputLimit-completion.text.utf8.count)
        completionRange=completion.append(to:&output);currentWork=completion.currentWork;percentage=100
        commandSucceeded=succeeded;commandFinished=true;OperationSounds.report(failed:!succeeded,preferences:preferences)
    }
    private func appendDiagnostic(_ text:String){
        guard !text.isEmpty else{return}
        guard let range=completionRange else{output=GitProgressFailureOutput.renderDetails(text,existing:output,limit:progressPresentation.outputLimit);return}
        let previous=output as NSString
        guard NSMaxRange(range) <= previous.length else{return}
        let footer=previous.substring(with:range)
        let suffix=GitProgressFailureOutput.renderDetails(text,existing:previous.substring(from:NSMaxRange(range)),limit:max(256,progressPresentation.outputLimit-footer.utf8.count))
        let prefix=bounded(previous.substring(to:range.location),bytes:progressPresentation.outputLimit-footer.utf8.count-suffix.utf8.count)
        output=prefix+footer+suffix;completionRange=NSRange(location:(prefix as NSString).length,length:(footer as NSString).length)
    }
    private func streamReset(_ token:OperationCancellation) async throws->RepositoryTransitionReceipt {
        let buffer=ResetNotificationBuffer(),started=Date()
        let (events,continuation)=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
        func drain(){
            let values=buffer.take();guard !invalidated,cancellation===token else{return}
            for value in values {
                switch value {
                case .file(let path): notifications.appendCheckout(path:path)
                case .progress(let completed,let total): percentage=total>0 ? Int(min(100,Double(completed)/Double(total)*100)):nil
                case .issue(let issue):notificationWarnings.append(issue.message);notifications.append("Warning",issue.message,kind:.error)
                }
            }
        }
        let pump=Task { @MainActor in for await _ in events {drain()} }
        let notification:(@Sendable(GitResetNotification)->Void)?
        if showsNotifications {notification={value in buffer.append(value);continuation.yield(())}} else {notification=nil}
        let update:(GitProgressOutputState)->Void = { [weak self] state in
            guard let self,!self.invalidated,self.cancellation===token else{return}
            self.output=state.output;self.currentWork=state.currentWork
            if !self.showsNotifications {self.percentage=state.percentage}
        }
        let operation:(@escaping @Sendable(GitOutputChunk)->Void) async throws->RepositoryTransitionReceipt = { [self] emit in
            if let runResetAccepted{return try await runResetAccepted(plan,token,emit)}
            if let runReset {return RepositoryTransitionReceipt(output:try await runReset(plan,token,emit),cancelledAfterCommand:token.isCancelled)}
            let command:@Sendable(GitCommandInvocation)->Void = {invocation in emit(GitOutputChunk(stream:.stdout,data:invocation.preamble))}
            return try await repository.resetAccepted(plan,cancellation:token,onOutput:emit,onCommand:command,backend:backend,recycle:recycle,onNotification:notification)
        }
        let resultText:(RepositoryTransitionReceipt)->String = {$0.output}
        do {
            let result:RepositoryTransitionReceipt=try await LocalGitCommandProgress.stream(preferences:preferences,update:update,resultText:resultText,operation:operation)
            continuation.finish();await pump.value;drain()
            if showsNotifications,!invalidated {notifications.finish(success:true,cancelled:result.cancelledAfterCommand,started:started)}
            return result
        }catch{
            continuation.finish();await pump.value;drain()
            if showsNotifications,!invalidated {notifications.append("Error",GitProgressFailureOutput.render(error,existing:"",limit:progressPresentation.outputLimit),kind:.error);notifications.finish(success:false,cancelled:token.isCancelled,started:started)}
            throw error
        }
    }
    private func execute() async {
        defer {endWork();withExtendedLifetime(access) {};if !invalidated,!hasPendingWork {cancelling=false;finishAutomaticClose()}}
        guard !invalidated,acceptedCommand == nil else{return}
        let token=cancellation,startedAt=ProcessInfo.processInfo.systemUptime,publish=onChanged
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true){throw RepositoryAccessFailure.securityScopeUnavailable}
            let receipt=try await streamReset(token)
            acceptedCommand=receipt;rawOutput=receipt.output;resultInspectionPending=true
            if !notifiedAcceptedCommand{notifiedAcceptedCommand=true;publish(receipt.output)}
            guard !invalidated,!abandoned,cancellation === token else{return}
            success=true;cancelled=token.isCancelled || receipt.cancelledAfterCommand
            completeOutput(succeeded:true,startedAt:startedAt)
            postActions=[.inspectResult]
            guard !cancelled,!confirmingQuit else{return}
            try await inspectAcceptedResult()
        }catch{
            guard !invalidated else{return}
            if acceptedCommand != nil{cancelled=cancelled || cancellation.isCancelled;appendDiagnostic("Could not inspect reset result.\n"+error.localizedDescription);postActions=[.inspectResult]}
            else{
                guard cancellation === token else{return}
                rawOutput=(error as? GitCommandCancellationFailure)?.result.text ?? error.localizedDescription
                output=LocalGitCommandProgress.failure(error,existing:output,preferences:preferences)
                cancelled=token.isCancelled || error is OperationCancellationFailure || error is CancellationError || error is GitCommandCancellationFailure
                completeOutput(succeeded:false,error:error,startedAt:startedAt);postActions=[.retry]
            }
        }
    }
    private func inspectAcceptedResult() async throws{
        guard acceptedCommand != nil else{return}
        let token=OperationCancellation();cancellation=token
        let timeout=Task{try? await Task.sleep(nanoseconds:5_000_000_000);if !Task.isCancelled{token.cancel()}}
        defer{timeout.cancel()}
        let state:BisectState
        if let readBisect{state=try await readBisect(token)}else{state=try await repository.bisectState(cancellation:token)}
        try token.check();guard !invalidated,!abandoned,!confirmingQuit,cancellation === token else{return}
        var actions:[ResetPostAction]=[]
        if plan.mode == .hard,FileManager.default.fileExists(atPath:repository.root.appendingPathComponent(".gitmodules").path){actions.append(.submoduleUpdate)}
        if state.active{actions += [.bisectGood,.bisectBad,.bisectSkip,.bisectReset]}
        if plan.mode == .hard{actions.append(.clean)}
        resultInspectionPending=false;postActions=actions
    }
    private func retryResultInspection(){
        guard acceptedCommand != nil,!invalidated,!confirmingQuit,!busy,!hasPendingWork else{return}
        busy=true;cancelled=false;postActions=[];beginWork()
        Task{[self] in
            defer{endWork();withExtendedLifetime(access){}}
            do{try await inspectAcceptedResult()}
            catch{if !invalidated{appendDiagnostic("Could not inspect reset result.\n"+error.localizedDescription);postActions=[.inspectResult]}}
        }
    }
    private func finishAutomaticClose(){if !busy,!hasPendingWork,!confirmingQuit,!confirmingCancellation,!fileActionBusy,!invalidated,abandoned || !cancelled && !resultInspectionPending && notificationWarnings.isEmpty && autoClosePolicy.shouldClose(success:success,postActionCount:postActions.count){close()}}
    func cancel() {
        guard canCancel, !invalidated else { return }
        let token = cancellation,generation=interactionGeneration
        if preferences.bool(forKey:"ConfirmKillProcess") {
            confirmingCancellation = true
            var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.invalidated, self.cancellation === token else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && (!self.commandFinished || self.resultInspectionPending) && accepted && !self.confirmingQuit && self.interactionGeneration == generation { self.cancelling = true; token.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: ResetPostAction) {
        CommandProgressContext.perform(commandProgressScope) { performInCommandProgressScope(action) }
    }
    private func performInCommandProgressScope(_ action: ResetPostAction) {
        guard !busy,!hasPendingWork, !fileActionBusy, !confirmingQuit, !invalidated, !confirmingCancellation, !dispatched, postActions.contains(action) else { return }
        if action == .inspectResult{retryResultInspection();return}
        if action == .retry {
            guard acceptedCommand == nil else{retryResultInspection();return}
            ProgressActionLog.nextAttempt(self);
            cancellation=OperationCancellation();resetAttempt();beginWork()
            Task { await execute() }; return
        }
        guard let onPostAction else { return }; dispatched = true
        let generation=interactionGeneration
        let dispatch=CommandProgressContext.capture(commandProgressScope) { [self] in guard !confirmingQuit,interactionGeneration==generation else{return};onPostAction(action)}
        if let closeForHandoff {closeForHandoff(dispatch)} else {close();dispatch()}
    }
}
@MainActor final class ResetProgressWindowController: NSWindowController, NSWindowDelegate {
    var commandProgressScope: CommandProgressScope? { model.commandProgressScope }
    let model: ResetProgressWindowModel
    let notificationFiles:RemoteProgressFileActions
    private var pendingHandoff:(()->Void)?
    private var release:ResetChildRelease?
    private var finished=false,closingForHandoff=false
    private var presentationParent:NSWindow?
    private var cancellationAnswer:((NSApplication.ModalResponse)->Void)?
    private(set) var cancellationAlert:NSAlert?
    var questionWindow:NSWindow? {cancellationAlert?.window}
    var presentCancellation:((NSAlert,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Void)?
    var onClosed:()->Void={}
    var onClosing:(NSWindow)->Void={_ in}
    init(model:ResetProgressWindowModel) {
        self.model=model
        notificationFiles=RemoteProgressFileActions(repository:model.repository,access:model.repositoryAccess)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:model.showsNotifications ? 920:760,height:model.showsNotifications ? 560:430),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        RepositoryWindowTitles.set(window,repository:model.repository.root,dialog:"Reset",preferences:model.preferences)
        window.minSize=NSSize(width:650,height:model.showsNotifications ? 560:320);window.isReleasedWhenClosed=false
        window.contentViewController=NSHostingController(rootView:ResetProgressDialog(model:model))
        super.init(window:window);window.delegate=self
        model.presentationAvailable={ [weak window] in window?.attachedSheet==nil }
        notificationFiles.window=window;notificationFiles.available={ [weak model] in model?.notificationOwnerAvailable==true }
        notificationFiles.onBusy={ [weak self,weak model] value in model?.fileActionBusy=value;if !value,self?.pendingHandoff != nil {self?.closeIfReady()} }
        notificationFiles.onError={ [weak model] in model?.notificationFailure($0) }
        notificationFiles.onLog={ [weak model] repository,access,paths,old,new in model?.onNotificationLog(repository,access,paths,old,new) }
        model.onNotificationFileAction={ [weak self] in self?.notificationFiles.perform($0,$1) }
        model.close={ [weak self] in self?.closeIfReady() }
        model.workDidDrain={ [weak self] in guard let self,self.pendingHandoff != nil else{return};self.closeIfReady() }
        model.closeForHandoff={ [weak self] action in
            guard let self,!self.finished,self.pendingHandoff==nil,!self.model.confirmingQuit else{return}
            self.pendingHandoff=action;self.closeIfReady()
        }
        model.confirmCancellation={ [weak self] choose in
            guard let self,!self.finished,self.model.active,!self.model.confirmingQuit,self.cancellationAlert==nil,let window=self.window,window.attachedSheet==nil else{choose(false);return}
            let alert=NSAlert();alert.alertStyle = .informational;alert.messageText="The process is still running.";alert.informativeText="Are you sure to abort?"
            let yes=alert.addButton(withTitle:"Yes"),no=alert.addButton(withTitle:"No")
            alert.layout();yes.keyEquivalent="\r";no.keyEquivalent="\u{1b}";alert.window.defaultButtonCell=yes.cell as? NSButtonCell
            alert.window.appearance=window.effectiveAppearance;alert.window.alphaValue=window.alphaValue
            self.cancellationAlert=alert;var answered=false
            let answer:(NSApplication.ModalResponse)->Void={ [weak self] response in
                guard let self,!answered else{return};answered=true
                let release=ResetChildRelease(window:alert.window,parent:window) { [self] in
                    let accepted = !self.finished && self.model.active && !self.model.confirmingQuit && self.cancellationAlert === alert
                    if self.cancellationAlert === alert {self.cancellationAlert=nil;self.cancellationAnswer=nil}
                    alert.window.close();choose(accepted && response == .alertFirstButtonReturn)
                    if self.pendingHandoff != nil {self.closeIfReady()}
                }
                release.start()
            }
            self.cancellationAnswer=answer
            if let presentCancellation=self.presentCancellation {presentCancellation(alert,window,answer)}
            else {alert.beginSheetModal(for:window,completionHandler:answer)}
        }
        DialogGeometry.attach(window,identifier:"ProgressDlg")
    }
    private func closeIfReady() {
        guard !finished,model.active,!model.confirmingQuit,!model.busy,!model.hasPendingWork,!model.fileActionBusy,!model.confirmingCancellation,cancellationAlert==nil,let window,window.attachedSheet==nil else{return}
        presentationParent=window.sheetParent;closingForHandoff=pendingHandoff != nil;window.close()
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard !model.confirmingQuit,cancellationAlert==nil,!model.confirmingCancellation else{return false}
        if model.busy {model.cancel();return false}
        return !model.hasPendingWork && !model.fileActionBusy && sender.attachedSheet==nil
    }
    func windowWillClose(_ notification:Notification) {
        guard notification.object as? NSWindow === window,!finished else{return};finished=true
        if let window {onClosing(window)}
        notificationFiles.retire();model.invalidate();model.closeForHandoff=nil;model.workDidDrain=nil
        cancellationAnswer?(.abort)
        if let window,let sheet=window.attachedSheet,sheet !== questionWindow {window.endSheet(sheet,returnCode:.abort);sheet.close()}
        let handoff=closingForHandoff ? pendingHandoff:nil;pendingHandoff=nil
        guard let window else{onClosed();return}
        let release=ResetChildRelease(window:window,parent:presentationParent ?? window.sheetParent,ready:{ [self] in !model.hasPendingWork && !notificationFiles.busy && cancellationAlert==nil }) { [self] in
            self.release=nil;model.saveActionLog();onClosed();handoff?()
        }
        self.release=release;release.start()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}
struct ResetProgressDialog: View {
    @ObservedObject var model: ResetProgressWindowModel
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if model.showsNotifications {
                FileOperationProgressTable(state:model.notifications,icon:.reset,available:model.notificationActionsAvailable,repository:model.repository.root,keyboardAvailable:model.notificationKeyboardAvailable,fileRowIcons:true,backgroundIcon:.updateBackdrop,actionAvailability:{model.notificationActionsAvailable},keyboardAvailability:{model.notificationKeyboardAvailable},performRow:model.onNotificationFileAction)
                    .frame(minHeight:300,maxHeight:.infinity).layoutPriority(1)
                SubmoduleProgressOutputView(text:model.output,completed:model.commandFinished,completionRange:model.completionRange,success:model.commandSucceeded,preferences:model.preferences,clipboard:model.outputClipboard).frame(height:100)
            } else {
            SubmoduleProgressOutputView(text: model.output, completed: model.commandFinished, completionRange: model.completionRange, success: model.commandSucceeded, preferences: model.preferences, clipboard:model.outputClipboard).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.commandFinished {ProgressView(value:100,total:100).tint(model.commandSucceeded ? Color.accentColor:Color.red)}
            else {LocalGitProgressIndicator(percentage:model.percentage,animate:model.progressPresentation.animateActivity)}
            HStack { Text(model.cancelling ? "Cancelling…" : model.currentWork.isEmpty ? "Resetting…" : model.currentWork).foregroundStyle(model.commandFinished ? model.commandSucceeded ? Color.primary : Color.red : Color.primary); Spacer() }
            HStack { if let first = model.postActions.first { Button { model.perform(first) } label: { CommandLabel(title:first.title,icon:first.icon) }; Menu { ForEach(model.postActions,id:\.self) { action in Button { model.perform(action) } label: { CommandLabel(title:action.title,icon:action.icon) } } } label: { Image(systemName:"chevron.down").accessibilityLabel("Reset post-actions") }.menuStyle(.borderlessButton).fixedSize() }; Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.confirmingCancellation || model.confirmingQuit || model.hasPendingWork && !model.busy)
        }.padding(12)
        .gitDockProgress(.command(busy: model.busy && !model.commandFinished, success: model.commandSucceeded, waiting: model.confirmingCancellation, percentage: model.percentage))
    }
}

/// EndSheet acknowledgement precedes actual detachment. Keep owners and Quit
/// fenced until the native parent has released the exact child window.
@MainActor private final class ResetChildRelease {
    static private(set) var activeCount=0
    private let window:NSWindow,parent:NSWindow?
    private let ready:()->Bool
    private var completion:()->Void
    private var observer:NSObjectProtocol?
    private var waiter:Task<Void,Never>?
    private var finished=false
    private var started=false
    init(window:NSWindow,parent:NSWindow?,ready:@escaping ()->Bool={true},completion:@escaping ()->Void) {self.window=window;self.parent=parent;self.ready=ready;self.completion=completion}
    func start() {
        guard !started else{return};started=true
        Self.activeCount += 1
        if window.sheetParent != nil || parent?.attachedSheet === window {
            observer=NotificationCenter.default.addObserver(forName:NSWindow.didEndSheetNotification,object:nil,queue:.main) { [self] _ in DispatchQueue.main.async {self.drain()} }
            (window.sheetParent ?? parent)?.endSheet(window);window.orderOut(nil)
        }
        drain()
        if !finished {waiter=Task { @MainActor [self] in while !finished {try? await Task.sleep(nanoseconds:5_000_000);drain()} }}
    }
    private func drain() {
        guard !finished,window.attachedSheet == nil,window.sheetParent == nil,parent?.attachedSheet !== window,ready() else{return};finished=true
        waiter?.cancel();waiter=nil
        if let observer {NotificationCenter.default.removeObserver(observer);self.observer=nil}
        Self.activeCount -= 1;let done=completion;completion={};done()
    }
}
