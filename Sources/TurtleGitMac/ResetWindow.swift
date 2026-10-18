import AppKit
import SwiftUI
import TurtleGitCore

struct ResetChooserDraft: Equatable {
    let target: CheckoutTarget
    let branch: GitReferenceName
    let tag: GitReferenceName
    let commit: GitReferenceName
    let mode: ResetMode
}

@MainActor final class ResetWindowController: NSWindowController, NSWindowDelegate {
    static var activeChildReleases:Int {ResetChildRelease.activeCount}
    let model: ResetWindowModel
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
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Reset", preferences: preferences)
        window.contentMinSize = size; window.contentMaxSize = NSSize(width: 4000, height: size.height); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ResetDialog(model: model, chooser: model.chooser).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        window.setContentSize(size); window.center()
        model.afterClose = { [self] action in
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
        guard !closed else { return }; closed = true; pendingSheetResult = nil;model.afterClose=nil; NotificationCenter.default.removeObserver(self); model.invalidate()
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
    private(set) static var activeReads = 0
    struct FormContext:Equatable {let owner:ObjectIdentifier;let generation:Int;let draft:ResetChooserDraft}
    private var formGeneration=0
    var formContext:FormContext {FormContext(owner:ObjectIdentifier(self),generation:formGeneration,draft:pickerDraft)}
    var presentationPreferences:UserDefaults {preferences}
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
    var onChanged: (String) -> Void = { _ in }
    func finish(_ result: ResetProgressWindowModel) {
        guard !invalidated, progress === result, !result.busy, !result.confirmingCancellation else { return }
        progress = nil; result.invalidate(); busy = false; error = nil
        if result.success {
            let completed=onReset,output=result.output
            if let afterClose {afterClose {completed(output)}} else {close();completed(output)}
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
        Self.activeReads += 1
        Task {
            var applied = false
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {}; if referenceSelectionToken === token { referenceSelectionToken = nil; showingReferencePicker = false; if applied { initialModeFocusPending = false; referenceFocusRequest += 1 }; completion() } }
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
        Self.activeReads += 1
        loadTask = Task { [self, access] in
            defer {
                Self.activeReads -= 1
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
        guard !invalidated, !confirmingQuit, !closeAfterRead, !busy, !showingReferencePicker, !showingCommitPicker, !showingModifiedFiles, !confirmingHard, progress == nil, !chooser.busy else { return }; busy = true
        let revision = chooser.revision, mode = mode, request = OperationCancellation()
        resetCancellation = request
        let context = formContext
        Self.activeReads += 1
        Task { [self, access] in
            defer {
                Self.activeReads -= 1
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
        guard !invalidated, !confirmingQuit, !closeAfterRead, !busy, !showingReferencePicker, !showingCommitPicker, !showingModifiedFiles, !confirmingHard, progress == nil else { return }; busy = true; error = nil
        do { try validateAccess() } catch { self.error = error.localizedDescription; busy = false; return }
        if let onProgress {
            let result = ResetProgressWindowModel(repository: chooser.repository, plan: plan, preferences: preferences, access: access)
            result.close = { [weak self, weak result] in guard let result else { return }; self?.finish(result) }
            result.onChanged = onChanged
            let actionCallback=onPostAction,afterClose=afterClose
            result.onPostAction = { action in if let afterClose {afterClose {actionCallback?(action)}} else {actionCallback?(action)} }
            progress = result; onProgress(result); if progress === result { result.start() }
        } else {
            let request = OperationCancellation(); resetCancellation = request; LocalGitCommandProgress.begin()
            Task { [self, access, repository = chooser.repository] in
                var completedOutput: String?
                defer {
                    LocalGitCommandProgress.end(); withExtendedLifetime(access) {}
                    if resetCancellation === request {
                        resetCancellation = nil; busy = false
                        if let output = completedOutput { onChanged(output); onReset(output); close() }
                        else { onReadSettled() }
                    }
                }
                do {
                    let output = try await repository.reset(plan, cancellation: request)
                    guard !invalidated, resetCancellation === request, !request.isCancelled else { return }
                    completedOutput = output
                } catch { if !invalidated, resetCancellation === request, !request.isCancelled { self.error = error.localizedDescription } }
            }
        }
    }
}
private struct ResetDialog: View {
    @ObservedObject var model: ResetWindowModel
    @ObservedObject var chooser: SwitchWindowModel
    var body: some View {
        let context=model.formContext
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Current branch:").frame(width: 110, alignment: .leading); Text(model.currentBranch.isEmpty ? "detached HEAD" : model.currentBranch).textSelection(.enabled); Spacer() }
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
                Button("OK") { model.reset() }.keyboardShortcut(.defaultAction).disabled(chooser.revision.isEmpty)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button { TurtleGitHelp.show(.reset) } label: { CommandLabel(title: "Help", icon: .help) }
            }
        }.padding(12).disabled(!model.canEditForm).onAppear { model.load() }
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
        button.title = title; button.state = selection == value ? .on : .off; button.isEnabled = enabled
        context.coordinator.select = { selection = value }
        button.focus = { [weak button, weak model] in
            guard let button, let model, model.mode == value, model.canFocusInitialMode,
                  button.isEnabled, let owner = button.window, owner.attachedSheet == nil else { return }
            if owner.makeFirstResponder(button) { model.acknowledgeInitialModeFocus() }
        }
        button.scheduleFocus()
    }
    static func dismantleNSView(_ button: Button, coordinator: Coordinator) { button.focus = nil; coordinator.select = {} }
    final class Coordinator: NSObject { var select: () -> Void = {}; @objc func clicked(_ sender: NSButton) { select() } }
    final class Button: NSButton {
        var focus: (() -> Void)?
        private var focusQueued = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleFocus() }
        func scheduleFocus() {
            guard let owner = window, !focusQueued else { return }; focusQueued = true
            DispatchQueue.main.async { [weak self, weak owner] in
                guard let self else { return }; self.focusQueued = false
                guard let owner, self.window === owner else { return }; self.focus?()
            }
        }
    }
}

enum ResetPostAction: String, Hashable {
    case retry, submoduleUpdate, bisectGood, bisectBad, bisectSkip, bisectReset, clean
    var title: String { switch self { case .retry: return "Retry"; case .submoduleUpdate: return "Submodule Update…"; case .bisectGood: return "Bisect good"; case .bisectBad: return "Bisect bad"; case .bisectSkip: return "Bisect skip"; case .bisectReset: return "Bisect reset"; case .clean: return "Clean up…" } }
    var icon: MenuIcon { switch self { case .retry: return .refresh; case .submoduleUpdate: return .fetch; case .bisectGood: return .bisectGood; case .bisectBad: return .bisectBad; case .bisectSkip: return .bisect; case .bisectReset: return .bisectReset; case .clean: return .clean } }
}
@MainActor final class ResetProgressWindowModel: ObservableObject {
    private(set) static var activeOperations=0
    private var interactionGeneration=0
    @Published var confirmingQuit=false {didSet {if oldValue != confirmingQuit {interactionGeneration += 1}}}
    var closeForHandoff:((@escaping ()->Void)->Void)?
    let progressPresentation: GitCommandPresentation
    let repository: GitRepository
    let plan: ResetPlan
    private let access: RepositoryAccessLease?
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
    @Published private(set) var postActions: [ResetPostAction] = []
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onPostAction: ((ResetPostAction) -> Void)?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { busy && !confirmingQuit && !cancelling && !confirmingCancellation }
    init(repository: GitRepository, plan: ResetPlan, preferences: UserDefaults = .standard, access: RepositoryAccessLease? = nil) { self.access = access; self.repository = repository; self.plan = plan; self.preferences = preferences; progressPresentation = GitCommandPresentation(defaults: preferences); self.autoClosePolicy = GitProgressAutoClose(preferences: preferences) }
    func invalidate() { invalidated = true; cancellation.cancel(); confirmingCancellation = false; busy = false; postActions = [] }
    func abandonPresentation() { abandoned = true; cancellation.cancel() }
    func start() { guard !confirmingQuit else{return};Task { await run() } }
    func run() async { guard !started, !invalidated, !confirmingQuit else { return }; started = true; await execute() }
    private func execute() async {
        guard !invalidated else { return }
        let token = cancellation;Self.activeOperations += 1; LocalGitCommandProgress.begin(); defer { Self.activeOperations -= 1;LocalGitCommandProgress.end(); withExtendedLifetime(access) {} }
        var originalOutput = ""
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            originalOutput = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in
                guard let self, !self.invalidated, self.cancellation === token else { return }
                self.output = state.output; self.currentWork = state.currentWork; self.percentage = state.percentage
            }, resultText: { $0 }, operation: { [repository, plan] emit in try await repository.reset(plan, cancellation: token, onOutput: emit) })
            guard !invalidated, cancellation === token else { return }; success = true
            if plan.mode == .hard, FileManager.default.fileExists(atPath: repository.root.appendingPathComponent(".gitmodules").path) { postActions.append(.submoduleUpdate) }
            if (try? await repository.bisectState().active) == true { postActions += [.bisectGood, .bisectBad, .bisectSkip, .bisectReset] }
            if plan.mode == .hard { postActions.append(.clean) }
        } catch {
            guard !invalidated, cancellation === token else { return }
            originalOutput = (error as? GitCommandCancellationFailure)?.result.text ?? error.localizedDescription
            output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences); cancelled = token.isCancelled; postActions = [.retry]
        }
        guard !invalidated, cancellation === token else { return }
        busy = false; cancelling = false; currentWork = ""; percentage = nil; onChanged(originalOutput)
        finishAutomaticClose()
    }
    private func finishAutomaticClose() { if !busy, !confirmingQuit, !confirmingCancellation, !invalidated, abandoned || autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() } }
    func cancel() {
        guard canCancel, !invalidated else { return }
        let token = cancellation,generation=interactionGeneration
        if preferences.bool(forKey:"ConfirmKillProcess") {
            confirmingCancellation = true
            var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.invalidated, self.cancellation === token else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && accepted && !self.confirmingQuit && self.interactionGeneration == generation { self.cancelling = true; token.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: ResetPostAction) {
        guard !busy, !confirmingQuit, !invalidated, !confirmingCancellation, !dispatched, postActions.contains(action) else { return }
        if action == .retry {
            ProgressActionLog.nextAttempt(self);
            busy = true; success = false; cancelled = false; output = ""; postActions = []; cancellation = OperationCancellation()
            Task { await execute() }; return
        }
        guard let onPostAction else { return }; dispatched = true;if let closeForHandoff {closeForHandoff {onPostAction(action)}} else {close();onPostAction(action)}
    }
}
@MainActor final class ResetProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: ResetProgressWindowModel
    private var pendingHandoff:(()->Void)?
    private var release:ResetChildRelease?
    private var finished=false
    private var presentationParent:NSWindow?
    private var pendingCancellation:(()->Void)?
    private(set) var cancellationAlert:NSAlert?
    var onClosed: () -> Void = {}
    init(model: ResetProgressWindowModel) {
        self.model = model
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:430),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        RepositoryWindowTitles.set(window, repository: model.repository.root, dialog: "Reset", preferences: model.preferences); window.minSize = NSSize(width:650,height:320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:ResetProgressDialog(model:model)); super.init(window:window); window.delegate = self
        model.close = { [weak self] in guard let self, !self.model.confirmingQuit, !self.model.busy, !self.model.confirmingCancellation, self.window?.attachedSheet == nil else { return }; if let window = self.window { self.presentationParent=window.sheetParent;window.close() } }
        model.closeForHandoff = { [weak self] action in
            guard let self,!self.finished,self.pendingHandoff == nil else{return};self.pendingHandoff=action;self.model.close()
        }
        model.confirmCancellation = { [weak self] choose in
            guard let self,let window=self.window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle:"Yes"); alert.addButton(withTitle:"No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.window.appearance=window.appearance;alert.window.alphaValue=window.alphaValue;self.cancellationAlert=alert
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self,!self.finished else{return}
                self.pendingCancellation = { self.cancellationAlert=nil;choose(response == .alertFirstButtonReturn) };self.drainCancellation()
            }
        }

        NotificationCenter.default.addObserver(self,selector:#selector(sheetEnded),name:NSWindow.didEndSheetNotification,object:window)
        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    @objc private func sheetEnded() {drainCancellation();DispatchQueue.main.async { [weak self] in self?.drainCancellation() }}
    private func drainCancellation() {guard !finished,window?.attachedSheet == nil,let done=pendingCancellation else{return};pendingCancellation=nil;done()}
    func windowShouldClose(_ sender:NSWindow) -> Bool { if model.confirmingQuit {return false};if model.busy { model.cancel(); return false }; guard !model.confirmingCancellation, sender.attachedSheet == nil else { return false }; return true }
    func windowWillClose(_ notification:Notification) {
        guard !finished else{return};finished=true;pendingCancellation=nil;NotificationCenter.default.removeObserver(self)
        if let window,let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.abort);sheet.close()}
        model.saveActionLog();model.invalidate();model.closeForHandoff=nil
        let handoff=pendingHandoff;pendingHandoff=nil
        guard let window else{onClosed();handoff?();return}
        let release=ResetChildRelease(window:window,parent:presentationParent ?? window.sheetParent) { [self] in self.release=nil;onClosed();handoff?() }
        self.release=release;release.start()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
}
struct ResetProgressDialog: View {
    @ObservedObject var model: ResetProgressWindowModel
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: model.success, preferences: model.preferences).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack { if model.busy { LocalGitProgressIndicator(percentage: model.percentage, animate: model.progressPresentation.animateActivity) }; Text(model.busy ? model.cancelling ? "Cancelling…" : model.currentWork.isEmpty ? "Resetting…" : model.currentWork : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Reset failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red); Spacer() }
            HStack { if let first = model.postActions.first { Button { model.perform(first) } label: { CommandLabel(title:first.title,icon:first.icon) }; Menu { ForEach(model.postActions,id:\.self) { action in Button { model.perform(action) } label: { CommandLabel(title:action.title,icon:action.icon) } } } label: { Image(systemName:"chevron.down").accessibilityLabel("Reset post-actions") }.menuStyle(.borderlessButton).fixedSize() }; Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.confirmingCancellation || model.confirmingQuit)
        }.padding(12)
        .gitDockProgress(.command(busy: model.busy, success: model.success, waiting: model.confirmingCancellation, percentage: model.percentage))
    }
}

/// EndSheet acknowledgement precedes actual detachment. Keep owners and Quit
/// fenced until the native parent has released the exact child window.
@MainActor private final class ResetChildRelease {
    static private(set) var activeCount=0
    private let window:NSWindow,parent:NSWindow?
    private var completion:()->Void
    private var observer:NSObjectProtocol?
    private var finished=false
    init(window:NSWindow,parent:NSWindow?,completion:@escaping ()->Void) {self.window=window;self.parent=parent;self.completion=completion}
    func start() {
        Self.activeCount += 1
        if window.attachedSheet == nil && window.sheetParent == nil && parent?.attachedSheet !== window {drain();return}
        observer=NotificationCenter.default.addObserver(forName:NSWindow.didEndSheetNotification,object:nil,queue:.main) { [self] _ in DispatchQueue.main.async {self.drain()} }
        window.sheetParent?.endSheet(window);window.orderOut(nil);DispatchQueue.main.async { [self] in drain()}
    }
    private func drain() {
        guard !finished,window.attachedSheet == nil,window.sheetParent == nil,parent?.attachedSheet !== window else{return};finished=true
        if let observer {NotificationCenter.default.removeObserver(observer);self.observer=nil}
        Self.activeCount -= 1;let done=completion;completion={};done()
    }
}
