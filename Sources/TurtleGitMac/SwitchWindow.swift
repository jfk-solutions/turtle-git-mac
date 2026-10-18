// SPDX-License-Identifier: GPL-2.0-or-later
// Native Switch form adapted from GitSwitchDlg, TortoiseGit 2008-2024.
import AppKit
import SwiftUI
import TurtleGitCore

extension UserDefaults {
    var includesFetchHead: Bool { object(forKey: "BranchesIncludeFetchHead") as? Bool ?? true }
    var usesMailmap: Bool { object(forKey: "UseMailmap") as? Bool ?? true }
}

@MainActor protocol VersionPickerModel: AnyObject {
    var repository: GitRepository { get }
    var revision: String { get }
    var commitRevision: String { get }
    var versionPickerDraft: [GitReferenceName] { get }
    var error: String? { get }
    var onBrowsePicker: ((CheckoutTarget) -> Void)? { get set }
    func beginPicker(_ target: CheckoutTarget) -> Bool
    func finishPicker()
    func acceptReferenceSelection(_ name: String?, completion: @escaping () -> Void)
    func acceptCommitSelection(_ entry: LogEntry?)
    func invalidate()
}

@MainActor final class VersionPickerCoordinator {
    private weak var window: NSWindow?
    private let model: any VersionPickerModel
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    private let allowed: () -> Bool
    private var invalidated = false
    var onSelection: () -> Void = {}
    var contextualDraft: () -> [GitReferenceName] = { [] }
    private(set) var referencePicker: ReferenceBrowserWindowController?
    private(set) var commitPicker: LogWindowController?
    private var pickerRequest: UUID?
    private var pendingResult: (() -> Void)?
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var configureCommitPicker: (LogWindowModel) -> Void = { _ in }
    var presentPicker: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void, UserDefaults, String?) -> LogWindowController = { repository, access, choose, preferences, revision in
        LogWindowController(repository: repository, access: access, onChoose: choose, labelDefaults: preferences, initialRevision: revision)
    }
    init(window: NSWindow, model: any VersionPickerModel, access: RepositoryAccessLease?, preferences: UserDefaults, allowed: @escaping () -> Bool = { true }) {
        self.window = window; self.model = model; self.access = access; self.preferences = preferences; self.allowed = allowed
        model.onBrowsePicker = { [weak self] target in self?.showPicker(target) }
        NotificationCenter.default.addObserver(self, selector: #selector(sheetEnded), name: NSWindow.didEndSheetNotification, object: window)
    }
    @objc private func sheetEnded() { drainResult() }
    private func drainResult() {
        guard !invalidated, window?.attachedSheet == nil, referencePicker == nil, commitPicker == nil, let result = pendingResult else { return }
        pendingResult = nil; result()
    }
    private func showPicker(_ target: CheckoutTarget) {
        guard !invalidated, allowed(), let owner = window, owner.attachedSheet == nil, referencePicker == nil, commitPicker == nil, model.beginPicker(target) else { return }
        let request = UUID(), draft = model.versionPickerDraft, context = contextualDraft(); pickerRequest = request
        if target == .branch {
            let child = ReferenceBrowserWindowController(repository: model.repository, access: access, initial: model.revision, preferences: preferences) { [weak self] name in
                guard let self, !self.invalidated, self.pickerRequest == request, self.pendingResult == nil else { return }
                self.pendingResult = { [weak self] in
                    guard let self, self.pickerRequest == request else { return }
                    guard self.allowed(), self.model.versionPickerDraft == draft, self.contextualDraft() == context else { self.pickerRequest = nil; self.model.finishPicker(); return }
                    self.model.acceptReferenceSelection(name) { [weak self] in
                        guard let self, !self.invalidated, self.pickerRequest == request else { return }
                        self.pickerRequest = nil; if self.model.error == nil { self.onSelection() }
                    }
                }
                self.drainResult()
            }
            referencePicker = child; configureReferencePicker(child.model)
            child.onClosed = { [weak self, weak child] in
                guard let self, let child, self.referencePicker === child else { return }
                if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
                self.referencePicker = nil; self.drainResult()
            }
            guard let window = child.window else { abandonReference(child); return }
            window.appearance = owner.appearance; window.alphaValue = owner.alphaValue
            guard presentPicker(owner, window) else { abandonReference(child); return }
            child.model.load()
        } else {
            let revision = model.commitRevision
            let child = makeCommitPicker(model.repository, access, { [weak self] entry in
                guard let self, !self.invalidated, self.pickerRequest == request, self.pendingResult == nil else { return }
                self.pendingResult = { [weak self] in
                    guard let self, self.pickerRequest == request else { return }; self.pickerRequest = nil
                    guard self.allowed(), self.model.versionPickerDraft == draft, self.contextualDraft() == context else { self.model.finishPicker(); return }
                    self.model.acceptCommitSelection(entry); if entry != nil { self.onSelection() }
                }
                self.drainResult()
            }, preferences, revision.isEmpty ? nil : revision)
            commitPicker = child; configureCommitPicker(child.model)
            child.onClosed = { [weak self, weak child] in
                guard let self, let child, self.commitPicker === child else { return }
                if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
                self.commitPicker = nil; self.drainResult()
            }
            guard let window = child.window else { abandonCommit(child); return }
            window.appearance = owner.appearance; window.alphaValue = owner.alphaValue
            guard presentPicker(owner, window) else { abandonCommit(child); return }
            child.model.reload()
        }
    }
    private func abandonReference(_ child: ReferenceBrowserWindowController) {
        pickerRequest = nil; pendingResult = nil; child.abandonPresentation(); referencePicker = nil; model.finishPicker()
    }
    private func abandonCommit(_ child: LogWindowController) {
        pickerRequest = nil; pendingResult = nil; child.close(); commitPicker = nil; model.finishPicker()
    }
    func invalidate() {
        guard !invalidated else { return }; invalidated = true; pickerRequest = nil; pendingResult = nil
        NotificationCenter.default.removeObserver(self); model.invalidate()
        let reference=referencePicker,commit=commitPicker;referencePicker=nil;commitPicker=nil
        if let child=reference?.window {let release=SwitchChildRelease(window:child,parent:window) {reference?.close()};release.start()}
        if let child=commit?.window {let release=SwitchChildRelease(window:child,parent:window) {commit?.close()};release.start()}
    }
}

@MainActor final class SwitchWindowController: NSWindowController, NSWindowDelegate {
    let model: SwitchWindowModel
    var onClosed: () -> Void = {}
    private(set) var progressController: SwitchProgressWindowController?
    static var activeChildReleases:Int {SwitchChildRelease.activeCount}
    private var closed=false
    private var tagAlert:NSAlert?
    private var tagReply:((Bool)->Void)?
    var presentProgress: (NSWindow, NSWindow, @escaping () -> Void) -> Bool = { owner, child, completed in
        guard owner.attachedSheet == nil else { return false }
        owner.beginSheet(child) { _ in completed() }; return true
    }
    private var pickers: VersionPickerCoordinator!
    var referencePicker: ReferenceBrowserWindowController? { pickers.referencePicker }
    var commitPicker: LogWindowController? { pickers.commitPicker }
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void { get { pickers.configureReferencePicker } set { pickers.configureReferencePicker = newValue } }
    var configureCommitPicker: (LogWindowModel) -> Void { get { pickers.configureCommitPicker } set { pickers.configureCommitPicker = newValue } }
    var presentPicker: (NSWindow, NSWindow) -> Bool { get { pickers.presentPicker } set { pickers.presentPicker = newValue } }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void, UserDefaults, String?) -> LogWindowController { get { pickers.makeCommitPicker } set { pickers.makeCommitPicker = newValue } }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, preferences: UserDefaults = .standard) {
        model = SwitchWindowModel(repository: repository, access: access, revision: revision, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 370),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Switch/Checkout", preferences: preferences)
        window.contentMinSize = NSSize(width: 600, height: 390); window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: SwitchDialog(model: model).defaultAppStorage(preferences)); host.sizingOptions = []; window.contentViewController = host
        super.init(window: window); window.delegate = self
        pickers = VersionPickerCoordinator(window: window, model: model, access: access, preferences: preferences,allowed:{ [weak model] in model?.presentationAvailable == true })
        pickers.contextualDraft = { [weak model] in guard let model else { return [] }; return [model.options.branchName, String(model.options.createBranch), String(model.options.overwriteChanges), String(model.options.merge), model.options.tracking.rawValue, String(model.options.overrideBranch)].map { GitReferenceName($0) } }
        window.setContentSize(NSSize(width: 620, height: 430)); window.center()
        model.close = { [weak self] in guard let self, !self.model.confirmingQuit, !self.model.busy, self.model.progress == nil, !self.model.hasPendingTagConflict, self.model.browser == nil, self.model.pickerTarget == nil, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        model.onProgress = { [weak self] result in
            guard let self else { result.abandonPresentation(); return }
            guard let window = self.window, window.attachedSheet == nil else { self.model.abandonProgressPresentation(result); return }
            let controller = SwitchProgressWindowController(model: result)
            self.progressController = controller
            controller.onClosed = { [weak self,weak result,weak controller] in
                guard let self,let result,let controller,self.progressController === controller else{return}
                self.progressController=nil;self.model.finish(result)
            }
            controller.window?.alphaValue=window.alphaValue;controller.window?.appearance=window.appearance
            if let child = controller.window, self.presentProgress(window, child, { [weak self, weak result, weak controller] in
                // AppKit's endSheet completion can precede actual detachment and
                // controller closure. Only the closed controller may acknowledge
                // the options owner. Injected presentations may route onClosed
                // through this same completion, so keep that contract too.
                guard let self, let result, let controller, controller.presentationClosed, self.progressController === controller else { return }
                self.progressController = nil; self.model.finish(result)
            }) { return }
            self.progressController = nil; self.model.abandonProgressPresentation(result)
            controller.close()
        }

        model.showTagConflict = { [weak self] request,choose in
            guard let self,let window=self.window,window.attachedSheet == nil,!self.closed else{choose(false);return}
            let alert=NSAlert();alert.alertStyle = .warning;alert.messageText="Branch and tag share a name"
            alert.informativeText=CheckoutFailure.tagNameConflict.localizedDescription
            alert.addButton(withTitle:"Continue");alert.addButton(withTitle:"Abort")
            alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
            self.tagAlert=alert;var answered=false
            let reply:(Bool)->Void = {value in guard !answered else{return};answered=true;choose(value)}
            self.tagReply=reply
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self,self.tagAlert === alert else{reply(false);return}
                let release=SwitchChildRelease(window:alert.window,parent:window) { [weak self] in
                    guard let self,self.tagAlert === alert else{reply(false);return}
                    self.tagAlert=nil;self.tagReply=nil;reply(response == .alertFirstButtonReturn)
                };release.start()
            }
        }
        DialogGeometry.attach(window, identifier: "SwitchWindowController")
    }
    func windowWillClose(_ notification:Notification) {
        guard !closed else{return};closed=true;model.invalidate();pickers.invalidate()
        let alert=tagAlert,reply=tagReply;tagAlert=nil;tagReply=nil
        if let alert {let release=SwitchChildRelease(window:alert.window,parent:window) {reply?(false)};release.start()} else {reply?(false)}
        let controller=progressController;progressController=nil
        if let child=controller?.window {let release=SwitchChildRelease(window:child,parent:window) {controller?.close()};release.start()}
        onClosed()
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {!model.confirmingQuit && !model.busy && model.progress == nil && model.browser == nil && model.pickerTarget == nil && !model.hasPendingTagConflict && sender.attachedSheet == nil}
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class SwitchWindowModel: ObservableObject, VersionPickerModel {
    private(set) static var activeReads = 0
    @Published var confirmingQuit=false {didSet {
        if confirmingQuit != oldValue {formRevision=UUID()};progress?.confirmingQuit=confirmingQuit
        if !confirmingQuit,let decision=pendingTagDecision {pendingTagDecision=nil;answerTagConflict(decision.0,accepted:decision.1)}
    }}
    var presentationPreferences:UserDefaults {preferences}
    var closed:Bool {invalidated}
    var presentationAvailable:Bool {!invalidated && !finished && !confirmingQuit}
    var showTagConflict:((UUID,@escaping (Bool)->Void)->Void)?
    private var tagConflictRequest:UUID?
    private var pendingTagDecision:(UUID,Bool)?
    private var historyToken:OperationCancellation?
    var onInitialReadSettled: () -> Void = {}
    var initialReadActive: Bool { initialLoadToken != nil }
    @discardableResult func cancelInitialRead() -> Bool { guard let initialLoadToken else { return false }; initialLoadToken.cancel(); return true }
    var readInitialReferences: (OperationCancellation) async throws -> ([CheckoutReference], String)
    var versionPickerDraft: [GitReferenceName] { [options.target.rawValue, branchRevision, tagRevision, commitRevision].map { GitReferenceName($0) } }
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let initialRevision: String?
    private let preferences: UserDefaults
    @Published private(set) var formRevision = UUID()
    @Published private(set) var initialFocusRequest = 0
    private var invalidated = false, finished = false
    private var initialLoadToken: OperationCancellation?
    private var checkoutToken: OperationCancellation?
    private var conflictSnapshot: CheckoutOptions?
    var hasPendingTagConflict: Bool { tagConflict || conflictSnapshot != nil }
    @Published private(set) var progress: SwitchProgressWindowModel?
    var onProgress: ((SwitchProgressWindowModel) -> Void)?
    var onChanged: (String) -> Void = { _ in }
    var onPostAction: ((SwitchPostAction, String) -> Void)?
    func abandonProgressPresentation(_ result: SwitchProgressWindowModel) {
        guard progress === result else { return }
        // A controller that was never presented must release its owner without
        // starting Git or waiting for an acknowledgement from its closed window.
        result.abandonPresentation(); result.invalidate(); progress = nil; busy = false; formRevision = UUID()
    }
    func invalidate() {
        invalidated = true; formRevision = UUID(); initialLoadToken?.cancel(); initialLoadToken = nil
        checkoutToken?.cancel(); checkoutToken = nil; historyToken?.cancel();historyToken=nil;tagConflictRequest=nil;pendingTagDecision=nil;conflictSnapshot = nil; tagConflict = false
        finishPicker(); referenceFocusRequest = 0; progress?.invalidate(); progress = nil; busy = false
    }
    func abortTagConflict() {tagConflictRequest=nil;pendingTagDecision=nil;tagConflict=false;conflictSnapshot=nil;formRevision=UUID()}
    private func answerTagConflict(_ request:UUID,accepted:Bool) {
        guard !invalidated,!finished,tagConflictRequest == request else{return}
        if busy || confirmingQuit {if pendingTagDecision == nil {pendingTagDecision=(request,accepted)};return}
        tagConflictRequest=nil
        if accepted {checkout(allowTagConflict:true)} else {abortTagConflict()}
    }
    func finish(_ result: SwitchProgressWindowModel) {
        guard !confirmingQuit, progress === result, !result.busy, !result.confirmingCancellation else { return }
        progress = nil; result.invalidate(); busy = false; formRevision = UUID()
        guard !invalidated else { return }
        if result.success || result.hasDispatchedAction {finished=true;close();if result.success {onSwitched(result.output)}}
    }
    @Published var references: [CheckoutReference] = []
    @Published var options = CheckoutOptions()
    @Published var branchRevision = ""
    @Published var tagRevision = ""
    @Published private(set) var commitChoices: [String] = []
    @Published var commitRevision = "HEAD"
    @Published var busy = false
    @Published var error: String?
    @Published var tagConflict = false
    @Published var browser: CheckoutTarget?
    @Published var commits: [LogEntry] = []
    @Published private(set) var pickerTarget: CheckoutTarget?
    @Published private(set) var referenceFocusRequest = 0
    private var appliedReferenceFocusRequest = 0
    private var referenceSelectionToken: OperationCancellation?
    var onBrowsePicker: ((CheckoutTarget) -> Void)?
    func canBrowse(_ target: CheckoutTarget) -> Bool { !confirmingQuit && !busy && progress == nil && !hasPendingTagConflict && browser == nil && pickerTarget == nil && !invalidated && !finished && options.target == target && target != .tag }
    func beginPicker(_ target: CheckoutTarget) -> Bool { guard canBrowse(target) else { return false }; formRevision = UUID(); pickerTarget = target; return true }
    func finishPicker() { if referenceSelectionToken != nil { referenceSelectionToken?.cancel(); referenceSelectionToken = nil; busy = false }; pickerTarget = nil; formRevision = UUID() }
    func focusReference(_ control: NSControl, target: CheckoutTarget) {
        guard !confirmingQuit, !invalidated, !finished, referenceFocusRequest > appliedReferenceFocusRequest, options.target == target,
              !busy, pickerTarget == nil, browser == nil, progress == nil, !hasPendingTagConflict, error == nil,
              control.isEnabled, let window = control.window, window.attachedSheet == nil else { return }
        if window.makeFirstResponder(control) { appliedReferenceFocusRequest = referenceFocusRequest }
    }
    func acceptReferenceSelection(_ name: String?, completion: @escaping () -> Void) {
        guard !confirmingQuit, !invalidated, !finished, pickerTarget == .branch else { return }
        referenceSelectionToken?.cancel(); let token = OperationCancellation(); referenceSelectionToken = token; busy = true
        let requested = name ?? revision, draft = commitRevision, selectionDraft = versionPickerDraft
        Self.activeReads += 1
        Task {
            var applied = false
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {}; if referenceSelectionToken === token { referenceSelectionToken = nil; busy = false; pickerTarget = nil; formRevision = UUID(); if applied { referenceFocusRequest += 1 }; completion() } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let catalog = try await repository.checkoutReferences(includeFetchHead: preferences.includesFetchHead, localBranchesFirst: AdvancedListBehavior(defaults: preferences).localBranchesFirst, cancellation: token)
                guard !confirmingQuit, !invalidated, !finished, referenceSelectionToken === token, !token.isCancelled, versionPickerDraft == selectionDraft else { return }
                references = catalog
                if let reference = catalog.first(where: { GitReferenceName.equal($0.name, requested) }), let target = reference.target {
                    options.target = target
                    if target == .branch { branchRevision = requested } else { tagRevision = requested }; commitRevision = draft
                } else { options.target = .commit; selectCustomRevision(requested) }
                defaults(); applied = true
            } catch { if !invalidated, referenceSelectionToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func acceptCommitSelection(_ entry: LogEntry?) {
        guard !confirmingQuit, !invalidated, !finished, pickerTarget == .commit else { return }
        if let entry { selectCustomRevision(entry.hash); defaults(); referenceFocusRequest += 1 }; finishPicker()
    }
    var close: () -> Void = {}
    var onSwitched: (String) -> Void = { _ in }
    var branches: [CheckoutReference] { references.filter { $0.target == .branch && ($0.symbolicTarget == nil || GitReferenceName.equal($0.name, branchRevision)) } }
    var tags: [CheckoutReference] { let values = references.filter { $0.target == .tag }; return preferences.bool(forKey: "SortTagsReversed") ? Array(values.reversed()) : values }
    var revision: String { switch options.target { case .branch: return branchRevision; case .tag: return tagRevision; case .commit: return commitRevision } }
    var remote: Bool { options.target == .branch && references.first { $0.name.utf8.elementsEqual(branchRevision.utf8) }?.remote == true }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; initialRevision = revision; self.preferences = preferences
        readInitialReferences = { token in
            let catalog = try await repository.checkoutReferences(includeFetchHead: preferences.includesFetchHead, localBranchesFirst: AdvancedListBehavior(defaults: preferences).localBranchesFirst, cancellation: token)
            let current = try await repository.branch(cancellation: token)
            return (catalog, current)
        }
    }
    func load(revision preset: String? = nil) {
        guard !confirmingQuit, !busy, pickerTarget == nil, progress == nil, !hasPendingTagConflict, !invalidated, !finished else { return }; formRevision = UUID(); busy = true
        let token = OperationCancellation(); initialLoadToken = token
        let revision = preset ?? initialRevision
        Self.activeReads += 1
        Task {
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {}; if initialLoadToken === token { initialLoadToken = nil; busy = false; formRevision = UUID(); if !invalidated && !token.isCancelled && error == nil { initialFocusRequest += 1 } }; onInitialReadSettled() }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let (catalog, current) = try await readInitialReferences(token)
                guard !confirmingQuit, !invalidated, !finished, initialLoadToken === token, !token.isCancelled else { return }
                references = catalog
                branchRevision = branches.first { GitReferenceName.equal($0.name, "refs/heads/" + current) }?.name ?? branches.first?.name ?? ""
                tagRevision = tags.first?.name ?? ""
                commitRevision = revision ?? "HEAD"; options = CheckoutOptions()
                if let revision, references.contains(where: { GitReferenceName.equal($0.name, revision) }) {
                    if GitReferenceName.removingPrefix("refs/tags/", from: revision) != nil { options.target = .tag; tagRevision = revision }
                    else { options.target = .branch; branchRevision = revision }
                } else { options.target = revision == nil ? .branch : .commit; if let revision { selectCustomRevision(revision) } }
                defaults()
            } catch { if !invalidated, initialLoadToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func selectCustomRevision(_ value: String) {
        guard !confirmingQuit, !invalidated, !finished, let selected = RevisionSessionChoices.select(value, choices: &commitChoices) else { return }
        commitRevision = selected
    }
    func defaults() {
        options.overrideBranch = false
        options.tracking = remote ? .automatic : .noTrack
        let reference = references.first { GitReferenceName.equal($0.name, revision) }
        options.branchName = reference?.suggestedBranch ?? "Branch_" + String(commitRevision.prefix(8))
        switch options.target {
        case .branch: options.createBranch = remote
        case .tag: options.createBranch = preferences.object(forKey: "SwitchToTagNewBranch") as? Bool ?? true
        case .commit: options.createBranch = preferences.object(forKey: "SwitchToCommitNewBranch") as? Bool ?? true
        }
    }
    struct FormContext: Equatable { let owner: ObjectIdentifier; let revision: UUID }
    var formContext: FormContext { .init(owner: ObjectIdentifier(self), revision: formRevision) }
    var canEditForm: Bool { !confirmingQuit && !invalidated && !finished && !busy && progress == nil && pickerTarget == nil && browser == nil && !hasPendingTagConflict && error == nil }
    private func accepts(_ context: FormContext) -> Bool { canEditForm && context == formContext }
    func selectTarget(_ target: CheckoutTarget, context: FormContext) {
        guard accepts(context) else { return }; options.target = target; defaults(); formRevision = UUID()
    }
    func revisionBinding(_ target: CheckoutTarget, context: FormContext) -> Binding<String> {
        Binding(get: { switch target { case .branch: return self.branchRevision; case .tag: return self.tagRevision; case .commit: return self.commitRevision } }, set: { value in
            guard self.accepts(context), self.options.target == target else { return }
            switch target { case .branch: self.branchRevision = value; case .tag: self.tagRevision = value; case .commit: self.commitRevision = value }
            self.defaults()
        })
    }
    func option<Value>(_ key: WritableKeyPath<CheckoutOptions,Value>, context: FormContext) -> Binding<Value> {
        Binding(get: { self.options[keyPath:key] }, set: { value in
            guard self.accepts(context) else { return }
            if key == \CheckoutOptions.branchName || key == \CheckoutOptions.overrideBranch { guard self.options.createBranch else { return } }
            if key == \CheckoutOptions.tracking { guard self.options.createBranch && self.remote else { return } }
            self.options[keyPath:key] = value
            if key == \CheckoutOptions.branchName { self.branchNameChanged() }
            if key == \CheckoutOptions.createBranch, !self.options.createBranch { self.options.overrideBranch = false; self.options.tracking = .noTrack }
        })
    }
    private func branchNameChanged() {
        guard remote, let reference = references.first(where: { GitReferenceName.equal($0.name,branchRevision) }) else { return }
        let remoteName = reference.symbolicTarget ?? reference.name, suffix = Array(("/" + options.branchName).utf8)
        if !remoteName.utf8.suffix(suffix.count).elementsEqual(suffix) { options.tracking = .noTrack }
    }
    func browse(_ target: CheckoutTarget, context: FormContext) { guard accepts(context) else { return }; browse(target) }
    func focusReference(_ control: NSControl, target: CheckoutTarget, context: FormContext) { guard accepts(context) else { return }; focusReference(control,target:target) }
    private func rememberSelection(_ snapshot: CheckoutOptions) {
        if snapshot.target == .tag { preferences.set(snapshot.createBranch,forKey:"SwitchToTagNewBranch") }
        if snapshot.target == .commit { preferences.set(snapshot.createBranch,forKey:"SwitchToCommitNewBranch") }
    }
    func browse(_ target: CheckoutTarget) {
        if let onBrowsePicker { guard canBrowse(target) else { return }; onBrowsePicker(target); return }
        guard presentationAvailable,!busy,progress == nil,pickerTarget == nil,!hasPendingTagConflict else{return}
        if target != .commit {browser=target;return}
        busy=true;let token=OperationCancellation();historyToken=token;Self.activeReads += 1
        Task { [self,access] in
            defer {Self.activeReads -= 1;withExtendedLifetime(access) {};if historyToken === token {historyToken=nil;busy=false}}
            do {var history=HistoryOptions();history.useMailmap=preferences.usesMailmap;history.allBranches=true;history.limit=200
                let entries=try await repository.history(options:history,cancellation:token)
                guard presentationAvailable,historyToken === token,!token.isCancelled else{return};commits=entries;browser=target
            } catch {if presentationAvailable,historyToken === token,!token.isCancelled {self.error=error.localizedDescription}}
        }
    }
    func checkout(allowTagConflict: Bool = false) {
        guard !confirmingQuit, !busy, pickerTarget == nil, progress == nil, browser == nil, !invalidated, !finished else { return }
        var snapshot = options; snapshot.revision = revision; snapshot.allowTagNameConflict = allowTagConflict
        if allowTagConflict, let captured = conflictSnapshot { snapshot = captured; snapshot.allowTagNameConflict = true }
        else if hasPendingTagConflict { return }
        conflictSnapshot = nil; tagConflict = false
        formRevision = UUID(); busy = true; error = nil
        let token = OperationCancellation(); checkoutToken = token;Self.activeReads += 1
        Task {
            defer {
                Self.activeReads -= 1;withExtendedLifetime(access) {}
                if checkoutToken === token {checkoutToken=nil;if progress == nil {busy=false;formRevision=UUID()};if let decision=pendingTagDecision {pendingTagDecision=nil;answerTagConflict(decision.0,accepted:decision.1)}}
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await repository.validateCheckout(snapshot, cancellation: token)
                guard !confirmingQuit, !invalidated, checkoutToken === token, !token.isCancelled else { return }
                rememberSelection(snapshot)
                if let onProgress {
                    let result = SwitchProgressWindowModel(repository: repository, access: access, options: snapshot, preferences: preferences)
                    result.onFinished = { [weak self, weak result] output, _ in guard let self, let result, !self.invalidated, self.progress === result else { return }; self.onChanged(output) }
                    // Hold the captured options owner through its close callback; the
                    // root can release its controller before this approved action runs.
                    result.onPostAction = { [self] action,branch in guard !self.invalidated || self.finished else{return};self.onPostAction?(action,branch) }
                    result.close = { [weak self, weak result] in guard let self, let result else { return }; self.finish(result) }
                    progress = result; onProgress(result); result.start()
                } else {
                    let output = try await repository.checkout(snapshot, cancellation: token)
                    guard !confirmingQuit, !invalidated, checkoutToken === token, !token.isCancelled else { return }; busy = false; finished = true; onSwitched(output); close()
                }
            } catch CheckoutFailure.tagNameConflict {
                if presentationAvailable,checkoutToken === token,!token.isCancelled {
                    conflictSnapshot=snapshot;tagConflict=true;let request=UUID();tagConflictRequest=request
                    showTagConflict?(request,{ [weak self] accepted in self?.answerTagConflict(request,accepted:accepted) })
                }
            }
            catch { if !invalidated, checkoutToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }

}

struct SwitchDialog: View {
    @ObservedObject var model: SwitchWindowModel
    @FocusState private var createBranchFocused: Bool
    var body: some View {
        let context = model.formContext
        VStack(spacing: 16) {
            GroupBox("Switch To") {
                VStack(spacing: 6) {
                    HStack {
                        SwitchRadio(title: "Branch", target: .branch, selection: Binding(get: { model.options.target }, set: { model.selectTarget($0,context:context) })).frame(width: 100)
                        ReferencePopup(references: model.branches, selection: model.revisionBinding(.branch,context:context), accessibilityLabel: "Switch branch revision", focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .branch, context:context) }).disabled(model.options.target != .branch)
                        Button("…") { model.browse(.branch,context:context) }.accessibilityLabel("Browse references").disabled(model.options.target != .branch)
                    }.frame(height: 26)
                    HStack {
                        SwitchRadio(title: "Tag", target: .tag, selection: Binding(get: { model.options.target }, set: { model.selectTarget($0,context:context) })).frame(width: 100)
                        ReferencePopup(references: model.tags, selection: model.revisionBinding(.tag,context:context), accessibilityLabel: "Switch tag revision", focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .tag, context:context) }).disabled(model.options.target != .tag)
                        Color.clear.frame(width: 29)
                    }.frame(height: 26)
                    HStack {
                        SwitchRadio(title: "Commit", target: .commit, selection: Binding(get: { model.options.target }, set: { model.selectTarget($0,context:context) })).frame(width: 100)
                        VersionRevisionField(text: model.revisionBinding(.commit,context:context), choices: model.commitChoices, focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .commit, context:context) }).disabled(model.options.target != .commit)
                        Button("…") { model.browse(.commit,context:context) }.accessibilityLabel("Choose commit").disabled(model.options.target != .commit)
                    }.frame(height: 26)
                }.padding(8)
            }
            GroupBox("Option") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("Create New Branch", isOn: model.option(\.createBranch,context:context)).focused($createBranchFocused).frame(width: 180, alignment: .leading)
                        TextField("New branch name", text: model.option(\.branchName,context:context)).disabled(!model.options.createBranch)
                    }
                    HStack {
                        Toggle("Overwrite working tree changes (force)", isOn: model.option(\.overwriteChanges,context:context))
                        Spacer(); Toggle("Merge", isOn: model.option(\.merge,context:context))
                    }
                    TrackingCheckbox(value: model.option(\.tracking,context:context), enabled: model.remote && model.options.createBranch)
                        .frame(height: 18).help("Mixed: use Git's automatic tracking configuration. Checked: track this remote branch. Unchecked: no tracking.")
                    Toggle("Override branch if exists", isOn: model.option(\.overrideBranch,context:context)).disabled(!model.options.createBranch)
                }.padding(8)
            }
            Spacer(minLength: 0)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.checkout() }.keyboardShortcut(.defaultAction).disabled(model.revision.isEmpty)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { TurtleGitHelp.show(.checkout) }
            }
        }.padding(16).disabled(model.confirmingQuit || model.busy || model.pickerTarget != nil || model.progress != nil || model.hasPendingTagConflict)
        .onAppear { if model.canEditForm { createBranchFocused = true } }
        .onChange(of: model.busy) { busy in if busy { createBranchFocused = false } }
        .onChange(of: model.initialFocusRequest) { _ in if model.canEditForm { createBranchFocused = true } }
        .alert("Switch/Checkout failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Branch and tag share a name", isPresented: Binding(get:{model.showTagConflict == nil && model.tagConflict},set:{if !$0 && model.showTagConflict == nil {model.tagConflict=false}})) {
            Button("Continue") { model.checkout(allowTagConflict: true) }; Button("Abort", role: .cancel) { model.abortTagConflict() }
        } message: { Text(CheckoutFailure.tagNameConflict.localizedDescription) }
        .sheet(item: $model.browser) { target in SwitchReferenceChooser(model: model, target: target) }
    }
}

struct SwitchReferenceChooser: View {
    @ObservedObject var model: SwitchWindowModel
    let target: CheckoutTarget
    @State private var search = ""
    @State private var selected: String?
    var choices: [(String, String)] {
        let choices = target == .commit ? model.commits.map { ($0.hash, String($0.hash.prefix(8)) + "  " + $0.subject) } : model.branches.map { ($0.name, $0.label) }
        return choices.filter { search.isEmpty || $0.1.localizedCaseInsensitiveContains(search) || $0.0.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target == .commit ? "Choose commit" : "Browse references").font(.headline)
            TextField("Filter", text: $search)
            List(selection: $selected) { ForEach(choices, id: \.0) { choice in Text(choice.1).tag(choice.0) } }
            HStack { Spacer(); Button("Cancel") {guard model.presentationAvailable,model.browser == target else{return};model.browser=nil}.keyboardShortcut(.cancelAction)
                Button("OK") {
                    guard model.presentationAvailable,model.browser == target,let selected else {return}
                    if target == .commit { model.commitRevision = selected } else { model.branchRevision = selected }
                    model.defaults(); model.browser = nil
                }.keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }.padding(16).frame(width: 650, height: 430)
    }
}

/// Shared native reference choices retire their target on owner closure, even
/// when a cached host keeps its NSButton alive after the window closes.
@MainActor final class ReferenceChoiceButton: NSButton {
    private(set) var retired = false
    private weak var observedWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !retired, let window, observedWindow !== window else { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        observedWindow = window
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.retired = true; self.isEnabled = false; self.target = nil; self.action = nil }
        }
    }
}

struct TrackingCheckbox: NSViewRepresentable {
    @Binding var value: CheckoutTracking
    let enabled: Bool
    @Environment(\.isEnabled) private var parentEnabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = ReferenceChoiceButton(checkboxWithTitle: "Track", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true; return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = value == .automatic ? .mixed : (value == .track ? .on : .off); button.isEnabled = enabled && parentEnabled && (button as? ReferenceChoiceButton)?.retired != true
        context.coordinator.change = { value = $0 }; context.coordinator.value = value
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) { coordinator.live = false; button.isEnabled = false; button.target = nil; button.action = nil }
    final class Coordinator: NSObject {
        var change: (CheckoutTracking) -> Void = { _ in }; var value = CheckoutTracking.automatic; var live = true
        @objc func clicked(_ sender: NSButton) {
            guard live, sender.isEnabled, sender.window != nil else { return }
            value = value == .automatic ? .noTrack : value == .noTrack ? .track : .automatic
            sender.state = value == .automatic ? .mixed : value == .track ? .on : .off
            change(value)
        }
    }
}

struct SwitchRadio: NSViewRepresentable {
    let title: String
    let target: CheckoutTarget
    @Binding var selection: CheckoutTarget
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        ReferenceChoiceButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = selection == target ? .on : .off; button.isEnabled = enabled && (button as? ReferenceChoiceButton)?.retired != true
        context.coordinator.change = { selection = target }
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) { coordinator.live = false; button.isEnabled = false; button.target = nil; button.action = nil }
    final class Coordinator: NSObject {
        var change: () -> Void = {}; var live = true
        @objc func clicked(_ sender: NSButton) { guard live, sender.isEnabled, sender.window != nil else { return }; change() }
    }
}

struct ReferencePopup: NSViewRepresentable {
    let references: [CheckoutReference]
    @Binding var selection: String
    var accessibilityLabel: String? = nil
    var displaysIcons = false
    var tooltip:String? = nil
    var focusRequest = 0
    var onFocus: ((NSPopUpButton) -> Void)? = nil
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        if let accessibilityLabel { button.setAccessibilityLabel(accessibilityLabel) }
        button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let names = references.map(\.name)
        if context.coordinator.names.map({ GitReferenceName($0) }) != names.map({ GitReferenceName($0) }) || button.numberOfItems == 0 {
            button.removeAllItems()
            // addItems(withTitles:) replaces canonically equivalent titles, but Git refs are byte-distinct.
            for title in references.isEmpty ? ["No references"] : references.map({ $0.name.isEmpty ? "Choose revision" : $0.label }) {
                button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        for (index, reference) in references.enumerated() where index < button.numberOfItems {
            button.item(at: index)?.image = displaysIcons && !reference.name.isEmpty ? (reference.isFetchHead ? MenuIcon.fetch : reference.target == .tag ? .tag : .branch).image() : nil
            button.item(at: index)?.toolTip = reference.name
        }
        context.coordinator.names = names
        context.coordinator.live = true
        if let index = names.firstIndex(where: { GitReferenceName.equal($0, selection) }) { button.selectItem(at: index) }
        if let tooltip {button.toolTip=tooltip}
        button.isEnabled = enabled && !references.isEmpty
        context.coordinator.change = { selection = $0 }
        if focusRequest > 0, let onFocus { DispatchQueue.main.async { [weak button, weak coordinator = context.coordinator] in if let button, coordinator?.live == true, button.isEnabled { onFocus(button) } } }
    }
    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        coordinator.live = false; coordinator.change = { _ in }; button.target = nil; button.action = nil; button.isEnabled = false
    }
    final class Coordinator: NSObject {
        var live = true
        var names: [String] = []; var change: (String) -> Void = { _ in }
        @MainActor @objc func changed(_ sender: NSPopUpButton) {
            guard live, sender.isEnabled, names.indices.contains(sender.indexOfSelectedItem) else { return }; change(names[sender.indexOfSelectedItem])
        }
    }
}

// PerformSwitch's immediate branch command and its progress/post-command choices.
enum SwitchPostAction: String, CaseIterable, Hashable {
    case submoduleUpdate, mergePreviousBranch, pull, commit, resolve, stash, retry, switchWithMerge
    var title: String {
        switch self {
        case .submoduleUpdate: return "Submodule Update…"
        case .mergePreviousBranch: return "Merge…"
        case .pull: return "Pull…"
        case .commit: return "Commit…"
        case .resolve: return "Resolve…"
        case .stash: return "Stash Save…"
        case .retry: return "Retry"
        case .switchWithMerge: return "Switch with Merge"
        }
    }
    var icon: MenuIcon {
        switch self {
        case .submoduleUpdate: return .fetch
        case .mergePreviousBranch: return .merge
        case .pull: return .pull
        case .commit: return .commit
        case .resolve: return .resolve
        case .stash: return .stash
        case .retry: return .mergeReload
        case .switchWithMerge: return .checkout
        }
    }
}
@MainActor final class SwitchProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: SwitchProgressWindowModel
    var onClosed: () -> Void = {}
    private var closed=false,finishing=false
    var presentationClosed:Bool {closed}
    private var cancellationAlert:NSAlert?
    private var cancellationReply:((Bool)->Void)?
    convenience init(repository: GitRepository, access: RepositoryAccessLease?, reference: String) {
        self.init(model: SwitchProgressWindowModel(repository: repository, access: access, reference: reference))
    }
    init(model: SwitchProgressWindowModel) {
        self.model = model
        let repository = model.repository
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Switch Progress", preferences: model.preferences)
        window.contentMinSize = NSSize(width: 560, height: 300); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SwitchProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in self?.finishResult({}) }
        model.finishAndPerform = { [weak self] action in self?.finishResult(action) }
        model.confirmCancellation = { [weak self] choose in
            guard let self,let window=self.window,window.attachedSheet == nil else{choose(false);return}
            let alert=NSAlert();alert.alertStyle = .informational;alert.messageText="The process is still running.";alert.informativeText="Are you sure to abort?"
            let yes=alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No");yes.keyEquivalent="\r";alert.window.defaultButtonCell=yes.cell as? NSButtonCell
            alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
            self.cancellationAlert=alert;var answered=false
            let reply:(Bool)->Void = {accepted in guard !answered else{return};answered=true;choose(accepted)}
            self.cancellationReply=reply
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self,self.cancellationAlert === alert else{reply(false);return}
                let release=SwitchChildRelease(window:alert.window,parent:window) { [weak self] in
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
        let release=SwitchChildRelease(window:window,parent:window.sheetParent) { [self] in
            guard !self.closed else{return};self.close()
            if !self.closed,!window.isVisible,window.sheetParent == nil {self.retireClosedWindow()}
            if self.closed {action()}
        };release.start()
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard !model.confirmingQuit,!finishing else{return false}
        if model.busy {model.cancel();return false}
        guard !model.confirmingCancellation,sender.attachedSheet == nil else{return false}
        finishResult({});return false
    }
    private func retireClosedWindow() {
        guard !closed else{return};closed=true;model.saveActionLog();model.invalidate()
        let alert=cancellationAlert,reply=cancellationReply;cancellationAlert=nil;cancellationReply=nil
        if let alert {let release=SwitchChildRelease(window:alert.window,parent:window) {reply?(false)};release.start()} else {reply?(false)}
        if let window,window.sheetParent != nil {let release=SwitchChildRelease(window:window,parent:window.sheetParent) {};release.start()}
        onClosed()
    }
    func windowWillClose(_ notification:Notification) {retireClosedWindow()}
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class SwitchProgressWindowModel: ObservableObject {
    let progressPresentation: GitCommandPresentation
    let repository: GitRepository
    let reference: String
    private let access: RepositoryAccessLease?
    private var cancellation = OperationCancellation()
    private var inspectionCancellation: OperationCancellation?
    private var started = false, invalidated = false, dispatched = false, abandoned = false
    private var merging = false
    var hasDispatchedAction:Bool {dispatched}
    static private(set) var activeOperations=0
    @Published var confirmingQuit=false
    var finishAndPerform:((@escaping ()->Void)->Void)?
    let options: CheckoutOptions
    let preferences: UserDefaults
    var presentationPreferences:UserDefaults {preferences}
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { !confirmingQuit && busy && !cancelling && !confirmingCancellation }
    func invalidate() { invalidated = true; cancellation.cancel(); inspectionCancellation?.cancel(); confirmingCancellation = false; busy = false }
    func abandonPresentation() { abandoned = true; cancellation.cancel() }
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var previousBranch = ""
    @Published private(set) var postActions: [SwitchPostAction] = []
    var onFinished: (String, Bool) -> Void = { _, _ in }
    var checkoutOperation:(CheckoutOptions,OperationCancellation,@escaping @Sendable (GitOutputChunk)->Void) async throws -> String
    var onPostAction: ((SwitchPostAction, String) -> Void)?
    private let autoClosePolicy: GitProgressAutoClose
    var close: () -> Void = {}
    convenience init(repository: GitRepository, access: RepositoryAccessLease?, reference: String, preferences: UserDefaults = .standard) {
        var options = CheckoutOptions(); options.revision = reference
        self.init(repository: repository, access: access, options: options, preferences: preferences)
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, options: CheckoutOptions, preferences: UserDefaults = .standard) {
        checkoutOperation = {try await repository.checkout($0,cancellation:$1,onOutput:$2)}
        self.repository = repository; self.access = access; self.options = options; self.reference = options.revision; self.preferences = preferences; progressPresentation = GitCommandPresentation(defaults: preferences); self.autoClosePolicy = GitProgressAutoClose(preferences: preferences)
    }
    func start() { Task { await run() } }
    func run() async {guard !started,!invalidated,!confirmingQuit else{return};started=true;await execute(merge:options.merge)}
    private func finishAutomaticClose() {
        if !confirmingQuit, !busy, !confirmingCancellation, !invalidated, abandoned || autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() }
    }
    func cancel() {
        guard canCancel, !invalidated else { return }
        let token = cancellation
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, self.cancellation === token, !self.invalidated else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; token.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: SwitchPostAction) {
        guard !confirmingQuit, !busy, !confirmingCancellation, !invalidated, !dispatched, postActions.contains(action) else { return }
        if action == .retry || action == .switchWithMerge {
            ProgressActionLog.nextAttempt(self);
            let merge = action == .switchWithMerge || merging
            busy = true; cancellation = OperationCancellation()
            Task { await execute(merge: merge) }
        } else if let onPostAction {dispatched=true;let branch=previousBranch,dispatch={onPostAction(action,branch)};if let finishAndPerform {finishAndPerform(dispatch)} else {close();dispatch()}}
    }
    private func execute(merge: Bool) async {
        guard !invalidated else { return }
        busy = true; success = false; cancelled = false; cancelling = false; postActions = []; output = ""; merging = merge
        let token = cancellation;Self.activeOperations += 1;LocalGitCommandProgress.begin();defer {Self.activeOperations -= 1;LocalGitCommandProgress.end();withExtendedLifetime(access) {}}
        var nextOutput = "", nextPreviousBranch = "", nextActions: [SwitchPostAction] = [], nextSuccess = false, commandCompleted = false
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            guard try await !repository.isBare(cancellation: cancellation) else { throw CheckoutFailure.invalidRevision }
            nextPreviousBranch = try await repository.branch(cancellation: cancellation)
            var options = self.options; options.merge = merge
            nextOutput = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in
                guard let self, !self.invalidated, self.cancellation === token else { return }
                self.output = state.output; self.currentWork = state.currentWork; self.percentage = state.percentage
            }, resultText: { $0 }, operation: { [self] emit in try await self.checkoutOperation(options,token,emit) })
            commandCompleted = true
            let conflicts = try await repository.status(refreshIndex: false, cancellation: cancellation).contains { $0.state == .conflicted }
            if merge && conflicts { nextOutput += "\nHas merge conflict"; output = LocalGitCommandProgress.bounded(output + "\nHas merge conflict", preferences: preferences) }
            else {
                if FileManager.default.fileExists(atPath: repository.root.appendingPathComponent(".gitmodules").path) { nextActions.append(.submoduleUpdate) }
                if !nextPreviousBranch.isEmpty { nextActions.append(.mergePreviousBranch) }
                if try await !repository.branch(cancellation: cancellation).isEmpty { nextActions.append(.pull) }
                nextActions.append(.commit)
                nextSuccess = true
            }
        } catch {
            nextOutput += (nextOutput.isEmpty ? "" : "\n") + ((error as? GitCommandCancellationFailure)?.result.text ?? error.localizedDescription)
            if !invalidated { output = commandCompleted ? LocalGitCommandProgress.bounded(output + "\n" + error.localizedDescription, preferences: preferences) : LocalGitCommandProgress.failure(error, existing: output, preferences: preferences) }
        }
        guard !invalidated else { return }
        if !nextSuccess {
            nextActions = []
            var conflicts = false
            if merge {
                // Normal Cancel still checks for conflicts after the cancelled
                // attempt. Forced window cleanup also cancels this fresh read.
                let inspection = OperationCancellation(); inspectionCancellation = inspection
                conflicts = (try? await repository.status(refreshIndex: false, cancellation: inspection).contains { $0.state == .conflicted }) == true
                if inspectionCancellation === inspection { inspectionCancellation = nil }
            }
            guard !invalidated else { return }
            if conflicts { nextActions.append(.resolve) }
            if !merge { nextActions.append(.stash) }
            nextActions.append(.retry)
            if !merge { nextActions.append(.switchWithMerge) }
        }
        guard !invalidated else { return }
        if output.isEmpty { output = LocalGitCommandProgress.bounded(nextOutput, preferences: preferences) }; currentWork = ""; percentage = nil; previousBranch = nextPreviousBranch; postActions = nextActions; success = nextSuccess; cancelled = cancellation.isCancelled
        busy = false; onFinished(nextOutput, success)
        finishAutomaticClose()
    }
}
struct SwitchProgressDialog: View {
    @ObservedObject var model: SwitchProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch to \(model.reference)").font(.headline)
            SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: model.success, preferences: model.preferences).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if model.busy { LocalGitProgressIndicator(percentage: model.percentage, animate: model.progressPresentation.animateActivity); Text(model.cancelling ? "Cancelling…" : model.currentWork.isEmpty ? "Switching…" : model.currentWork) }
                else { Text(model.cancelled ? "Cancelled" : model.success ? "Finished" : "Switch failed").foregroundStyle(model.success ? Color.green : Color.red) }
                Spacer()
            }
            HStack {
                if let first = model.postActions.first {
                    HStack(spacing: 2) {
                        Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                        Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Switch post-actions") }.menuStyle(.borderlessButton).fixedSize()
                    }.disabled(model.busy)
                }
                Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.confirmingCancellation || model.confirmingQuit)
        }.padding(12)
        .gitDockProgress(.command(busy: model.busy, success: model.success, waiting: model.confirmingCancellation, percentage: model.percentage))
    }
}

enum RevisionSessionChoices {
    static func select(_ value: String, choices: inout [String]) -> String? {
        let value = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !choices.contains(where: { $0.utf8.elementsEqual(value.utf8) }) {
            if choices.count > 25 { choices = Array(choices.prefix(25)) }
            choices.append(value)
        }
        return value
    }
}

// Editable session combo from CChooseVersion. No registry/history persistence.
struct VersionRevisionField: NSViewRepresentable {
    @Binding var text: String
    @AppStorage("UseCustomWordBreak") private var wordBreakMode=2
    var choices: [String] = []
    var accessibilityLabel = "Switch commit revision"
    let focusRequest: Int
    let onFocus: (NSTextField) -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox {
        let field = NSComboBox(); field.isEditable = true; field.completes = false
        field.font = .systemFont(ofSize: NSFont.systemFontSize); field.placeholderString = "Commit"; field.setAccessibilityLabel(accessibilityLabel)
        field.delegate = context.coordinator; return field
    }
    func updateNSView(_ field: NSComboBox, context: Context) {
        context.coordinator.wordCommands.policy=GitInputWordBreak(mode:UInt32(truncatingIfNeeded:wordBreakMode))
        context.coordinator.configure(field, text: text, choices: choices, enabled: enabled) { text = $0 }
        if focusRequest > 0 { DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
            guard let field, let coordinator, !coordinator.retired, field.isEnabled else { return }; onFocus(field)
        } }
    }
    static func dismantleNSView(_ field: NSComboBox, coordinator: Coordinator) { coordinator.retire(field) }
    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        let wordCommands=GitInputWordCommands()
        func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
            guard !retired else{return false}
            return wordCommands.handle(control,text:textView,selector:selector,combo:true,owner:self)
        }
        private var choices: [String] = []
        private(set) var retired = false
        var change: (String) -> Void = { _ in }
        func configure(_ field: NSComboBox, text: String, choices: [String], enabled: Bool, change: @escaping (String) -> Void) {
            guard !retired else { return }
            self.change = change
            let selection = (field.currentEditor() as? NSTextView)?.selectedRange()
            if self.choices.count != choices.count || !zip(self.choices, choices).allSatisfy({ $0.0.utf8.elementsEqual($0.1.utf8) }) {
                self.choices = choices; field.removeAllItems(); field.addItems(withObjectValues: choices)
            }
            if !field.stringValue.utf8.elementsEqual(text.utf8) { field.stringValue = text }
            if let selection, let editor = field.currentEditor() as? NSTextView {
                let length = field.stringValue.utf16.count, start = min(selection.location, length)
                editor.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
            }
            field.isEnabled = enabled
        }
        func retire(_ field: NSComboBox) { retired = true; field.delegate = nil; change = { _ in } }
        func controlTextDidChange(_ notification: Notification) {
            if !retired, let field = notification.object as? NSComboBox, field.isEnabled { change(field.stringValue) }
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !retired, let field = notification.object as? NSComboBox, field.isEnabled, field.indexOfSelectedItem >= 0,
                  let value = field.itemObjectValue(at: field.indexOfSelectedItem) as? String else { return }
            field.stringValue = value; change(value)
        }
    }
}

/// Own actual AppKit detach through normal completion and forced retirement.
@MainActor private final class SwitchChildRelease {
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
