// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of CreateBranchTagDlg, TortoiseGit 2008-2025.
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

enum BranchTagQuestion: Equatable { case nameConflict, error(String), cancellation }

@MainActor final class BranchTagWindowController: NSWindowController, NSWindowDelegate {
    let model: BranchTagWindowModel
    var onClosed: () -> Void = {}
    static var activeReleases: Int { BranchTagRelease.activeCount }
    private var pickers: VersionPickerCoordinator!
    private var observations: Set<AnyCancellable> = []
    private var question: BranchTagQuestionSession?
    var questionWindow: NSWindow? { question?.alert.window }
    private(set) var cancellationAlert: NSAlert?
    var presentQuestion: ((BranchTagQuestion, NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    private var retiring = false, closed = false, finishing = false, closingForHandoff = false
    private var questionEpoch = 0, observedQuit = false
    private var pendingAction: (() -> Void)?
    private var release: BranchTagRelease?
    private var pickerRetirements: [BranchTagPickerRetirement] = []
    private var presentationParent: NSWindow?
    var referencePicker: ReferenceBrowserWindowController? { pickers.referencePicker }
    var commitPicker: LogWindowController? { pickers.commitPicker }
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void { get { pickers.configureReferencePicker } set { pickers.configureReferencePicker = newValue } }
    var configureCommitPicker: (LogWindowModel) -> Void { get { pickers.configureCommitPicker } set { pickers.configureCommitPicker = newValue } }
    var presentPicker: (NSWindow, NSWindow) -> Bool { get { pickers.presentPicker } set { pickers.presentPicker = newValue } }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void, UserDefaults, String?) -> LogWindowController { get { pickers.makeCommitPicker } set { pickers.makeCommitPicker = newValue } }

    init(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool, preferences: UserDefaults = .standard) {
        model = BranchTagWindowModel(repository: repository, access: access, isTag: isTag, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Create \(isTag ? "Tag" : "Branch")", preferences: preferences)
        window.contentMinSize = NSSize(width: 650, height: 530); window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: BranchTagDialog(model: model, chooser: model.chooser).defaultAppStorage(preferences)); host.sizingOptions = []; window.contentViewController = host
        super.init(window: window); window.delegate = self
        pickers = VersionPickerCoordinator(window: window, model: model.chooser, access: access, preferences: preferences, allowed: { [weak model] in model?.canPickBase == true })
        pickers.contextualDraft = { [weak model] in guard let model else { return [] }; return [String(model.useHead), model.options.name, model.options.message, String(model.options.force), String(model.options.sign), model.options.tracking.rawValue, String(model.switchAfterCreation), String(model.pushAfterCreation)].map { GitReferenceName($0) } }
        pickers.onSelection = { [weak model] in if model?.useHead == false { model?.changedBase() } }
        window.setContentSize(NSSize(width: 660, height: 560)); window.center()
        model.close = { [weak self] in self?.finishResult({}) }
        model.finishAndPerform = { [weak self] action in self?.finishResult(action) }
        model.workDidDrain = { [weak self] in self?.refreshQuestions(); self?.closeIfReady() }
        model.presentationAvailable = { [weak self] in
            guard let self else { return false }
            return !self.retiring && !self.closed && !self.finishing && self.question == nil && self.window?.attachedSheet == nil
        }
        model.confirmCancellation = { [weak self] answer in
            guard let self, !self.retiring, !self.closed, !self.model.confirmingQuit, self.model.hasActiveCreation else { answer(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"), no = alert.addButton(withTitle: "No")
            alert.layout(); yes.keyEquivalent = "\r"; no.keyEquivalent = "\u{1b}"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            self.cancellationAlert = alert
            self.ask(.cancellation, alert: alert) { [weak self] response, accepted in
                self?.cancellationAlert = nil
                answer(accepted && response == .alertFirstButtonReturn)
            }
        }
        model.$confirmingQuit.dropFirst().sink { [weak self] value in
            guard let self else { return }
            if self.observedQuit != value { self.questionEpoch += 1; self.observedQuit = value }
            self.scheduleRefresh()
        }.store(in: &observations)
        model.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observations)
        model.chooser.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observations)
        DialogGeometry.attach(window, identifier: "BranchTagWindowController")
    }
    private func scheduleRefresh() {
        Task { @MainActor [weak self] in await Task.yield(); self?.refreshQuestions(); self?.closeIfReady() }
    }
    private func refreshQuestions() {
        guard !closed, !retiring, !finishing, !model.confirmingQuit, !model.hasPendingWork, !model.busy,
              !model.chooser.busy, !model.confirmingCancellation, model.chooser.pickerTarget == nil,
              referencePicker == nil, commitPicker == nil, question == nil,
              let window, window.attachedSheet == nil else { return }
        if model.hasPendingNameConflict {
            let context = model.formContext
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Branch and tag share a name"; alert.informativeText = ReferenceCreationFailure.nameConflict.localizedDescription
            let proceed = alert.addButton(withTitle: "Continue"), abort = alert.addButton(withTitle: "Abort")
            alert.layout(); proceed.keyEquivalent = ""; abort.keyEquivalent = "\r"; alert.window.defaultButtonCell = abort.cell as? NSButtonCell
            ask(.nameConflict, alert: alert) { [weak self] response, accepted in
                guard let self, !self.retiring, !self.closed, self.model.hasPendingNameConflict else { return }
                if accepted, self.model.formContext == context, response == .alertFirstButtonReturn { self.model.create(allowNameConflict: true) }
                else { self.model.abortNameConflict(); self.model.requestNameFocus() }
            }
        } else if let message = model.error ?? model.chooser.error {
            let modelError = model.error.map { Data($0.utf8) }, chooserError = model.chooser.error.map { Data($0.utf8) }
            let alert = NSAlert(); alert.alertStyle = .critical
            alert.messageText = "Create reference failed"; alert.informativeText = message; alert.addButton(withTitle: "OK")
            ask(.error(message), alert: alert) { [weak self] _, accepted in
                guard let self, accepted else { return }
                if self.model.error.map({ Data($0.utf8) }) == modelError { self.model.error = nil }
                if self.model.chooser.error.map({ Data($0.utf8) }) == chooserError { self.model.chooser.error = nil }
                self.model.requestNameFocus()
            }
        }
    }
    private func ask(_ kind: BranchTagQuestion, alert: NSAlert, completion: @escaping (NSApplication.ModalResponse, Bool) -> Void) {
        guard !closed, !retiring, !model.confirmingQuit, question == nil, let window, window.attachedSheet == nil else { completion(.abort, false); return }
        let request = BranchTagQuestionSession(alert: alert, parent: window), epoch = questionEpoch
        question = request; alert.window.appearance = window.effectiveAppearance; alert.window.alphaValue = window.alphaValue
        request.answer = { [weak self, weak request] response in
            guard let self, let request, !request.answered else { return }; request.answered = true
            let release = BranchTagRelease(window: alert.window, parent: window, closeWindow: true) { [self, request] in
                let accepted = !self.retiring && !self.closed && !self.model.confirmingQuit && self.questionEpoch == epoch && self.question === request
                if self.question === request { self.question = nil }; request.answer = nil; request.release = nil
                completion(response, accepted); self.scheduleRefresh()
            }
            request.release = release; release.start()
        }
        if let presentQuestion { presentQuestion(kind, alert, window, request.answer!) }
        else { alert.beginSheetModal(for: window, completionHandler: request.answer!) }
    }
    private func finishResult(_ action: @escaping () -> Void) {
        guard !closed, !retiring, !finishing, !model.confirmingQuit else { return }
        finishing = true; pendingAction = action; closeIfReady()
    }
    private func closeIfReady() {
        guard finishing, !closed, !retiring, !model.confirmingQuit, !model.hasPendingWork, !model.busy,
              !model.chooser.busy, !model.awaitingSwitch, !model.confirmingCancellation,
              !model.hasPendingNameConflict, question == nil, referencePicker == nil, commitPicker == nil,
              model.chooser.pickerTarget == nil else { return }
        guard let window else { closingForHandoff = true; retireClosedWindow(); return }
        guard window.attachedSheet == nil else { return }
        presentationParent = window.sheetParent; model.handoffPresentation = MergeWindowPresentation(window)
        closingForHandoff = true; window.close()
        if !retiring, !window.isVisible { retireClosedWindow() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closed, !retiring, !finishing, !model.confirmingQuit, question == nil, sender.attachedSheet == nil else { return false }
        model.cancel(); return false
    }
    private func retireClosedWindow() {
        guard !closed, !retiring else { return }; retiring = true
        let action = closingForHandoff ? pendingAction : nil, epoch = questionEpoch; pendingAction = nil
        if let child = referencePicker {
            let retirement = BranchTagPickerRetirement(window: child.window); pickerRetirements.append(retirement)
            let done = child.onClosed; child.onClosed = { done(); retirement.closed = true }
        }
        if let child = commitPicker {
            let retirement = BranchTagPickerRetirement(window: child.window); pickerRetirements.append(retirement)
            let done = child.onClosed; child.onClosed = { done(); retirement.closed = true }
        }
        model.invalidate(); model.finishAndPerform = nil; model.close = {}; model.workDidDrain = nil
        pickers.invalidate(); question?.answer?(.abort)
        if let window, let sheet = window.attachedSheet, sheet !== questionWindow { window.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil) }
        let finish: () -> Void = { [self] in
            release = nil; closed = true; observations.removeAll(); pickerRetirements.removeAll()
            let done = onClosed; onClosed = {}; done()
            if !model.confirmingQuit, questionEpoch == epoch { action?() }
        }
        let release = BranchTagRelease(window: window, parent: presentationParent ?? window?.sheetParent, ready: { [self] in
            !model.hasPendingWork && question == nil && pickerRetirements.allSatisfy { $0.closed && $0.window?.sheetParent == nil && $0.window?.attachedSheet == nil }
        }, completion: finish)
        self.release = release; release.start()
    }
    func windowWillClose(_ notification: Notification) { guard notification.object as? NSWindow === window else { return }; retireClosedWindow() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor private final class BranchTagPickerRetirement {
    let window: NSWindow?
    var closed: Bool
    init(window: NSWindow?) { self.window = window; closed = window == nil }
}
@MainActor private final class BranchTagQuestionSession {
    let alert: NSAlert, parent: NSWindow
    var answered = false
    var answer: ((NSApplication.ModalResponse) -> Void)?
    var release: BranchTagRelease?
    init(alert: NSAlert, parent: NSWindow) { self.alert = alert; self.parent = parent }
}
@MainActor private final class BranchTagRelease {
    static private(set) var activeCount = 0
    private let window: NSWindow?, parent: NSWindow?
    private let closeWindow: Bool, ready: () -> Bool
    private var completion: () -> Void
    private var waiter: Task<Void, Never>?
    private var started = false, finished = false
    init(window: NSWindow?, parent: NSWindow?, closeWindow: Bool = false, ready: @escaping () -> Bool = { true }, completion: @escaping () -> Void) {
        self.window = window; self.parent = parent; self.closeWindow = closeWindow; self.ready = ready; self.completion = completion
    }
    func start() {
        guard !started else { return }; started = true; Self.activeCount += 1
        if let window, window.sheetParent != nil || parent?.attachedSheet === window { (window.sheetParent ?? parent)?.endSheet(window); window.orderOut(nil) }
        drain()
        if !finished { waiter = Task { @MainActor [self] in while !finished { try? await Task.sleep(nanoseconds: 5_000_000); drain() } } }
    }
    private func drain() {
        guard !finished, window?.attachedSheet == nil, window?.sheetParent == nil, window == nil || parent?.attachedSheet !== window, ready() else { return }
        finished = true; waiter?.cancel(); waiter = nil; Self.activeCount -= 1
        if closeWindow { window?.close() }; let done = completion; completion = {}; done()
    }
}

@MainActor final class BranchTagWindowModel: ObservableObject {
    private(set) static var activeReads = 0
    private(set) static var activeCreations = 0
    @Published private(set) var pendingOperations=0
    private var pendingQuestions = 0
    var hasPendingWork:Bool {pendingOperations > 0 || pendingQuestions > 0 || chooser.hasPendingReferenceReads}
    var active:Bool {!invalidated}
    var workDidDrain:(()->Void)?
    private func beginWork(read:Bool=false){pendingOperations += 1;if read {Self.activeReads += 1}else{Self.activeCreations += 1};busy=true}
    private func endWork(read:Bool=false){pendingOperations -= 1;if read {Self.activeReads -= 1}else{Self.activeCreations -= 1};busy=pendingOperations > 0;formRevision=UUID();if !hasPendingWork {workDidDrain?()};finishCloseWhenReady()}
    var presentationPreferences: UserDefaults { preferences }
    var handoffPresentation:MergeWindowPresentation?
    var finishAndPerform:((@escaping()->Void)->Void)?
    var presentationAvailable:()->Bool={true}
    private var interactionGeneration=0
    @Published var confirmingQuit=false {didSet {if oldValue != confirmingQuit {interactionGeneration += 1;formRevision=UUID()};chooser.confirmingQuit=confirmingQuit;if !confirmingQuit {finishCloseWhenReady()}}}
    @Published private(set) var nameFocusRequest=UUID()
    func requestNameFocus(){guard active,!confirmingQuit else{return};nameFocusRequest=UUID()}
    var hasActiveCreation: Bool { creationToken != nil }
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var cancelling = false
    @Published private(set) var awaitingSwitch = false
    private var cancelAnswer: ((Bool) -> Void)?
    private var switchAnswer: (() -> Void)?
    var cancelSwitchPresentation: (() -> Void)?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    private var closeWhenIdle = false, completionReady = false
    private var pendingPush: String?
    private var createdOptions: ReferenceCreationOptions?
    private var createdOutput = ""
    private var notifiedCreation = false
    private var createdShouldSwitch = false, createdShouldPush = false
    private var createdWritesDescription=false
    private var creationGeneration=0
    private var chooserReadOwned=false
    var awaitSwitchCloseOnRetirement=false
    let chooser: SwitchWindowModel
    let isTag: Bool
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    private var loadToken: OperationCancellation?
    private var creationToken: OperationCancellation?
    private var invalidated = false, finished = false
    @Published private(set) var formRevision = UUID()
    private var conflictSnapshot: (ReferenceCreationOptions, Bool, Bool, Bool, Int)?
    private var descriptionSnapshot: ReferenceCreationOptions?
    var hasPendingNameConflict: Bool { nameConflict || conflictSnapshot != nil }
    var retryDescription: Bool { descriptionSnapshot != nil }
    var onSwitch: ((String, @escaping () -> Void) -> Void)?
    var prepareForm:(ReferenceCreationOptions,OperationCancellation) async throws->ReferenceCreationForm
    var prepareReference:(ReferenceCreationForm,OperationCancellation) async throws->ReferenceCreationPlan
    var performReference:(ReferenceCreationPlan,OperationCancellation) async throws->String
    func invalidate() {
        guard !invalidated else { return }; invalidated = true; formRevision = UUID()
        loadToken?.cancel(); creationToken?.cancel(); conflictSnapshot = nil;nameConflict=false
        let stop = cancelSwitchPresentation; cancelSwitchPresentation = nil; stop?()
        if !awaitSwitchCloseOnRetirement {let finish=switchAnswer;switchAnswer=nil;finish?()}
        chooser.invalidate(); busy = pendingOperations > 0; completionReady = false; pendingPush = nil
    }
    var canCancel: Bool {presentationAvailable() && error == nil && chooser.error == nil && !confirmingQuit && !invalidated && !finished && (!chooser.busy || chooser.initialReadActive) && !confirmingCancellation && !cancelling && !awaitingSwitch && chooser.pickerTarget == nil && !hasPendingNameConflict }
    func cancel() {
        guard canCancel else { return }
        guard let token = creationToken else {
            if loadToken != nil || chooser.initialReadActive {
                closeWhenIdle = true; cancelling = true; loadToken?.cancel(); _ = chooser.cancelInitialRead()
                finishCloseWhenReady()
            } else { close() }
            return
        }
        let generation=interactionGeneration
        let stop: (Bool) -> Void = { [weak self] approved in
            guard let self, !self.invalidated,!self.confirmingQuit,self.interactionGeneration==generation, approved,self.creationToken === token else { return }
            self.closeWhenIdle = true; self.abortNameConflict()
            if self.creationToken === token { self.cancelling = true; token.cancel() }
            self.finishCloseWhenReady()
        }
        guard preferences.bool(forKey: "ConfirmKillProcess") else { stop(true); return }
        // A native question owns retirement/Quit lifetime without keeping a finished Git worker busy.
        confirmingCancellation = true; pendingQuestions += 1; Self.activeCreations += 1
        var answered = false
        let answer: (Bool) -> Void = { [self] approved in
            guard !answered else { return }; answered = true
            self.cancelAnswer = nil; self.confirmingCancellation = false
            stop(approved)
            self.pendingQuestions -= 1; Self.activeCreations -= 1
            if !self.hasPendingWork { self.workDidDrain?() }
            self.finishCloseWhenReady(); withExtendedLifetime(self.access) {}
        }
        cancelAnswer = answer; confirmCancellation(answer)
    }
    private func finishCloseWhenReady() {
        guard !confirmingQuit,!invalidated, !busy,!hasPendingWork, loadToken == nil, creationToken == nil, !chooser.busy, !confirmingCancellation, !awaitingSwitch else { return }
        guard completionReady || closeWhenIdle else { return }
        completionReady = false; closeWhenIdle = false; cancelling = false
        let push = pendingPush; pendingPush = nil
        let generation=creationGeneration
        if let push {
            let callback=onPushTag
            let dispatch={ [self] in guard !confirmingQuit,interactionGeneration==generation else{return};callback(push)}
            if let finishAndPerform {finishAndPerform(dispatch)}else{close();dispatch()}
        }else{close()}
    }
    private func complete(push: String? = nil) {
        finished = true; completionReady = true; pendingPush = push
    }
    private func notifyCreated() { if !notifiedCreation,!confirmingQuit,interactionGeneration==creationGeneration { notifiedCreation = true; onCreated(createdOutput) } }
    private func handoffSwitch(_ reference: String, using route: (String, @escaping () -> Void) -> Void) async {
        awaitingSwitch = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var answered = false
            let done: () -> Void = { [weak self] in
                guard !answered else { return }; answered = true
                self?.switchAnswer = nil; self?.cancelSwitchPresentation = nil; self?.awaitSwitchCloseOnRetirement=false;self?.awaitingSwitch = false
                continuation.resume()
            }
            switchAnswer = done; route(reference, done)
        }
    }
    func abortNameConflict() { nameConflict = false; conflictSnapshot = nil; formRevision = UUID();requestNameFocus() }
    @Published var options = ReferenceCreationOptions() { didSet { if !options.name.utf8.elementsEqual(oldValue.name.utf8) { nameChanged() } } }
    @Published var useHead = true
    @Published var currentBranch = ""
    @Published var switchAfterCreation = false
    @Published var canSwitch = true
    @Published var canSign = false
    @Published var pushAfterCreation = false
    @Published var busy = false
    @Published var error: String?
    @Published var nameConflict = false
    @Published var createdBranch: String?
    var close: () -> Void = {}
    var onCreated: (String) -> Void = { _ in }
    var onPushTag: (String) -> Void = { _ in }
    struct FormContext: Equatable { let owner: ObjectIdentifier; let revision: UUID }
    var formContext: FormContext { .init(owner: ObjectIdentifier(self), revision: formRevision) }
    var canEditForm: Bool { !confirmingQuit && presentationAvailable() && error == nil && chooser.error == nil && !busy && !hasPendingWork && !chooser.busy && chooser.pickerTarget == nil && !hasPendingNameConflict && createdBranch == nil && !invalidated && !finished && !confirmingCancellation && !cancelling && !awaitingSwitch }
    private func accepts(_ context: FormContext) -> Bool { canEditForm && context == formContext }
    func option<Value>(_ key: WritableKeyPath<ReferenceCreationOptions,Value>, context: FormContext) -> Binding<Value> {
        Binding(get: { self.options[keyPath:key] }, set: { if self.accepts(context) { self.options[keyPath:key] = $0 } })
    }
    func boolean(_ key: ReferenceWritableKeyPath<BranchTagWindowModel,Bool>, context: FormContext) -> Binding<Bool> {
        Binding(get: { self[keyPath:key] }, set: { if self.accepts(context) { self[keyPath:key] = $0 } })
    }
    func baseRevision(_ target: CheckoutTarget, context: FormContext) -> Binding<String> {
        Binding(get: { switch target { case .branch: return self.chooser.branchRevision; case .tag: return self.chooser.tagRevision; case .commit: return self.chooser.commitRevision } }, set: {
            guard self.accepts(context), !self.useHead, self.chooser.options.target == target else { return }
            switch target { case .branch: self.chooser.branchRevision = $0; case .tag: self.chooser.tagRevision = $0; case .commit: self.chooser.commitRevision = $0 }
        })
    }
    func selectBase(_ target: CheckoutTarget?, context: FormContext) {
        guard accepts(context) else { return }; useHead = target == nil
        if let target { chooser.options.target = target }; formRevision = UUID(); changedBase()
    }
    func browseBase(_ target: CheckoutTarget, context: FormContext) {
        guard accepts(context), !useHead, chooser.options.target == target else { return }; chooser.browse(target)
    }
    func focusBase(_ reference: NSControl, target: CheckoutTarget, context: FormContext) {
        guard accepts(context), !useHead, chooser.options.target == target else { return }; chooser.focusReference(reference,target:target)
    }
    var canPickBase: Bool {canEditForm && !useHead}
    var remote: Bool { !isTag && !useHead && chooser.remote }
    private var previousSuggestion = ""
    init(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool, preferences: UserDefaults = .standard) {
        self.isTag = isTag; self.access = access; self.preferences = preferences; chooser = SwitchWindowModel(repository: repository, access: access, preferences: preferences)
        prepareForm={options,token in try await repository.prepareReferenceCreationForm(options,cancellation:token)}
        prepareReference={form,token in try await repository.prepareReferenceCreation(form,cancellation:token)}
        performReference={plan,token in try await repository.createReference(plan,writeDescription:false,cancellation:token)}
    }
    func load(revision: String?, name: String? = nil) {
        guard presentationAvailable(),error == nil,chooser.error == nil,!confirmingQuit,!busy,!hasPendingWork, !chooser.busy, chooser.pickerTarget == nil, !hasPendingNameConflict, createdBranch == nil, !invalidated, !finished, !confirmingCancellation, !cancelling else { return }
        formRevision = UUID();chooserReadOwned=true;beginWork(read:true)
        chooser.onInitialReadSettled = { [self] in
            chooser.onInitialReadSettled={}
            if chooserReadOwned {chooserReadOwned=false;endWork(read:true)}
            formRevision=UUID();changedBase();finishCloseWhenReady()
        }
        chooser.load(revision: revision); options = ReferenceCreationOptions(); options.isTag = isTag; options.name = name ?? ""
        createdBranch = nil; previousSuggestion = ""
        useHead = revision == nil || revision == "HEAD" || revision?.isEmpty == true
        switchAfterCreation = preferences.bool(forKey: "NewBranchSwitchTo")
        pushAfterCreation = preferences.bool(forKey: "PushTag")
        let token = OperationCancellation(); loadToken = token;let generation=interactionGeneration
        beginWork(read:true)
        Task {
            defer {withExtendedLifetime(access) {};if loadToken === token {loadToken=nil};endWork(read:true);changedBase()}
            guard !invalidated,!confirmingQuit,interactionGeneration==generation,!token.isCancelled else{return}
            do {
                try checkAccess()
                let current = try await chooser.repository.branch(cancellation: token)
                let workingTree = !(try await chooser.repository.isBare(cancellation: token))
                let signing = !((try? await chooser.repository.run(["config", "--get", "user.signingkey"], cancellation: token).stdout).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "").isEmpty
                guard !confirmingQuit,interactionGeneration==generation,!invalidated, loadToken === token, !token.isCancelled else { return }
                currentBranch = current; canSwitch = workingTree; canSign = signing
            } catch { if !confirmingQuit,interactionGeneration==generation,!invalidated, loadToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func changedBase() {
        guard !confirmingQuit,!invalidated, !finished, !busy, !chooser.busy, chooser.pickerTarget == nil, createdBranch == nil, remote, let reference = chooser.references.first(where: { GitReferenceName.equal($0.name, chooser.branchRevision) }) else { return }
        if options.name.isEmpty || GitReferenceName.equal(options.name,previousSuggestion) { options.name = reference.suggestedBranch }
        previousSuggestion = reference.suggestedBranch
    }
    func nameChanged() {
        guard !confirmingQuit,!invalidated, !finished, !busy, !chooser.busy, chooser.pickerTarget == nil, createdBranch == nil, remote,
              let reference = chooser.references.first(where: { GitReferenceName.equal($0.name, chooser.branchRevision) }) else { return }
        let suffix = Array(("/" + options.name).utf16)
        if !reference.name.utf16.suffix(suffix.count).elementsEqual(suffix) { options.tracking = .noTrack }
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(chooser.repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func create(allowNameConflict: Bool = false) {
        guard presentationAvailable(),!confirmingQuit,error == nil,chooser.error == nil,!busy,!hasPendingWork, !chooser.busy, chooser.pickerTarget == nil, !invalidated, !finished, !confirmingCancellation, !cancelling else { return }
        if let snapshot = descriptionSnapshot { saveDescription(snapshot); return }
        var snapshot = options; snapshot.revision = useHead ? "HEAD" : chooser.revision; snapshot.allowNameConflict = allowNameConflict
        snapshot.name = snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var shouldSwitch = !isTag && canSwitch && switchAfterCreation, shouldPush = isTag && pushAfterCreation, switchPreference = switchAfterCreation
        if allowNameConflict, let captured = conflictSnapshot {guard captured.4==interactionGeneration else{abortNameConflict();return};snapshot = captured.0; snapshot.allowNameConflict = true; shouldSwitch = captured.1; shouldPush = captured.2; switchPreference = captured.3 }
        else if hasPendingNameConflict { return }
        conflictSnapshot = nil; nameConflict = false
        if let createdOptions {
            snapshot = createdOptions; shouldSwitch = createdShouldSwitch; shouldPush = createdShouldPush
        }
        let routedSwitch = shouldSwitch ? onSwitch : nil
        let generation=interactionGeneration
        formRevision = UUID();error = nil;let token = OperationCancellation();creationToken=token;beginWork()
        Task {
            defer {if creationToken === token {creationToken=nil};endWork();withExtendedLifetime(access) {}}
            guard !invalidated,!confirmingQuit,interactionGeneration==generation,!token.isCancelled else{return}
            do {
                try checkAccess()
                if createdOptions == nil {
                    let accepted=try await prepareForm(snapshot,token)
                    guard !confirmingQuit,interactionGeneration==generation,!invalidated,creationToken === token,!token.isCancelled else{return}
                    // OnOK saves after form validation and cross-name Continue,
                    // before resolving the base and attempting the Git command.
                    if isTag {preferences.set(shouldPush,forKey:"PushTag")}else{preferences.set(switchPreference,forKey:"NewBranchSwitchTo")}
                    let plan=try await prepareReference(accepted,token)
                    guard !confirmingQuit,interactionGeneration==generation,!invalidated,creationToken === token,!token.isCancelled else{return}
                    snapshot=plan.options;creationGeneration=generation
                    let output=try await performReference(plan,token)
                    guard !invalidated, creationToken === token, !token.isCancelled else { return }
                    createdOutput = output; createdShouldSwitch = shouldSwitch; createdShouldPush = shouldPush;createdWritesDescription=plan.writesBranchDescription
                    // Remember the mutation before any later suspension or phase.
                    // Retrying checkout/description must never create it again.
                    createdOptions = snapshot; createdBranch = snapshot.name
                }
                guard !invalidated, creationToken === token, !token.isCancelled, let created = createdOptions else { return }
                var checkoutFailure:String?
                if let routedSwitch,!confirmingQuit,interactionGeneration==generation {
                    notifyCreated()
                    guard !invalidated, creationToken === token, !token.isCancelled else { return }
                    await handoffSwitch("refs/heads/" + created.name, using: routedSwitch)
                    guard !invalidated, creationToken === token, !token.isCancelled else { return }
                } else if shouldSwitch,!confirmingQuit,interactionGeneration==generation {
                    var checkout = CheckoutOptions(); checkout.revision = "refs/heads/" + created.name
                    do { createdOutput += try await chooser.repository.checkout(checkout, cancellation: token) }
                    catch {
                        guard !invalidated, creationToken === token, !token.isCancelled else { return }
                        checkoutFailure="Branch \(created.name) was created, but checkout failed. Resolve the working-tree changes and retry checkout, or close this dialog.\n\n" + error.localizedDescription
                    }
                }
                guard !invalidated, creationToken === token, !token.isCancelled else { return }
                if createdWritesDescription {
                    descriptionSnapshot = created
                    do { try checkAccess(); try await chooser.repository.updateBranchDescription(created.name, message: created.message, cancellation: token); descriptionSnapshot = nil }
                    catch {
                        guard !invalidated, creationToken === token, !token.isCancelled else { return }
                        notifyCreated(); self.error = "Branch \(created.name) was created, but its description could not be saved. Retry the description or close this dialog.\n\n" + error.localizedDescription; return
                    }
                }
                notifyCreated(); guard !invalidated else { return }
                if let checkoutFailure {self.error=checkoutFailure;return}
                complete(push: shouldPush ? "refs/tags/" + created.name : nil)
            } catch ReferenceCreationFailure.nameConflict { guard !confirmingQuit,interactionGeneration==generation,!invalidated, creationToken === token,!token.isCancelled else { return }; conflictSnapshot = (snapshot, shouldSwitch, shouldPush, switchPreference,generation); nameConflict = true }
            catch { if !confirmingQuit,interactionGeneration==generation,!invalidated, creationToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func saveDescription(_ snapshot: ReferenceCreationOptions) {
        formRevision = UUID();error = nil;let token=OperationCancellation(),generation=interactionGeneration;creationToken=token;beginWork()
        Task {
            defer {if creationToken === token {creationToken=nil};endWork();withExtendedLifetime(access) {}}
            guard !invalidated,!confirmingQuit,interactionGeneration==generation,!token.isCancelled else{return}
            do {
                try checkAccess(); try await chooser.repository.updateBranchDescription(snapshot.name, message: snapshot.message, cancellation: token)
                guard !invalidated, creationToken === token, !token.isCancelled else { return }
                descriptionSnapshot = nil; notifyCreated(); guard !invalidated else { return }; complete()
            } catch { if !confirmingQuit,interactionGeneration==generation,!invalidated, creationToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }

}

struct BranchTagDialog: View {
    @ObservedObject var model: BranchTagWindowModel
    @ObservedObject var chooser: SwitchWindowModel
    @FocusState private var nameFocused: Bool
    func radio(_ title: String, target: CheckoutTarget) -> some View {
        let context = model.formContext
        return BaseRadio(title: title, selected: !model.useHead && chooser.options.target == target) { model.selectBase(target,context:context) }
    }
    var body: some View {
        let context = model.formContext
        VStack(spacing: 14) {
            GroupBox("Name") { HStack { Text(model.isTag ? "Tag:" : "Branch:").frame(width: 100, alignment: .leading)
                TextField(model.isTag ? "Tag name" : "Branch name", text: model.option(\.name,context:context)).focused($nameFocused).accessibilityLabel(model.isTag ? "Tag name" : "Branch name")
            }.padding(8) }.disabled(model.createdBranch != nil || model.busy || chooser.busy || chooser.pickerTarget != nil || model.confirmingCancellation)
            GroupBox("Base On") {
                VStack(spacing: 6) {
                    BaseRadio(title: "HEAD (\(model.currentBranch.isEmpty ? "detached" : model.currentBranch))", selected: model.useHead) { model.selectBase(nil,context:context) }.frame(maxWidth:.infinity,alignment:.leading).frame(height: 22)
                    HStack { radio("Branch", target: .branch).frame(width: 100)
                        ReferencePopup(references: chooser.branches, selection: model.baseRevision(.branch,context:context), accessibilityLabel: "Base branch revision", focusRequest: chooser.referenceFocusRequest, onFocus: { model.focusBase($0,target:.branch,context:context) }).disabled(model.useHead || chooser.options.target != .branch)
                        Button("…") { model.browseBase(.branch,context:context) }.accessibilityLabel("Browse references").disabled(model.useHead || chooser.options.target != .branch)
                    }.frame(height: 26)
                    HStack { radio("Tag", target: .tag).frame(width: 100)
                        ReferencePopup(references: chooser.tags, selection: model.baseRevision(.tag,context:context), accessibilityLabel: "Base tag revision", focusRequest: chooser.referenceFocusRequest, onFocus: { model.focusBase($0,target:.tag,context:context) }).disabled(model.useHead || chooser.options.target != .tag)
                        Color.clear.frame(width: 29)
                    }.frame(height: 26)
                    HStack { radio("Commit", target: .commit).frame(width: 100)
                        VersionRevisionField(text: model.baseRevision(.commit,context:context), choices: chooser.commitChoices, accessibilityLabel: "Base commit revision", focusRequest: chooser.referenceFocusRequest, onFocus: { model.focusBase($0,target:.commit,context:context) }).disabled(model.useHead || chooser.options.target != .commit)
                        Button("…") { model.browseBase(.commit,context:context) }.accessibilityLabel("Choose commit").disabled(model.useHead || chooser.options.target != .commit)
                    }.frame(height: 26)
                }.padding(8)
            }.disabled(model.createdBranch != nil || model.busy || chooser.busy || chooser.pickerTarget != nil || model.confirmingCancellation)
            GroupBox("Options") { HStack {
                TrackingCheckbox(value: model.option(\.tracking,context:context), enabled: model.remote).frame(width: 115).help("Checked passes --track, unchecked passes --no-track; mixed passes neither (see Help).")
                Toggle("Force", isOn: model.option(\.force,context:context)).help("Force creation of branch/tag, even if one with the same name already exists.")
                if model.isTag {
                    Toggle("Sign", isOn: model.option(\.sign,context:context)).disabled(!model.canSign).help("GPG signs the tag; see the manual for details.")
                    Toggle("Push", isOn: model.boolean(\.pushAfterCreation,context:context))
                } else if model.canSwitch { Toggle("Switch to new branch", isOn: model.boolean(\.switchAfterCreation,context:context)) }
                Spacer()
            }.padding(8) }.disabled(model.createdBranch != nil || model.busy || chooser.busy || chooser.pickerTarget != nil || model.confirmingCancellation)
            GroupBox(model.isTag ? "Message" : "Description") { TextEditor(text: model.option(\.message,context:context)).font(.system(.body, design: .monospaced)).frame(minHeight: 75) }.disabled(model.createdBranch != nil || model.busy || chooser.busy || chooser.pickerTarget != nil || model.confirmingCancellation)
            HStack { if model.busy || chooser.busy || chooser.pickerTarget != nil { ProgressView().controlSize(.small) }; Spacer()
                Button(model.retryDescription ? "Retry description" : model.createdBranch == nil ? "OK" : "Retry checkout") { model.create() }.keyboardShortcut(.defaultAction).disabled(model.busy || chooser.busy || chooser.pickerTarget != nil || model.confirmingCancellation || model.options.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel)
                Button("Help") { TurtleGitHelp.show(.branchTag) }
            }
        }.padding(16)
        .onChange(of: Data(chooser.branchRevision.utf8)) { _ in model.changedBase() }
        .onAppear { if model.canEditForm { nameFocused = true } }
        .onChange(of: model.busy) { busy in if busy { nameFocused = false } else if model.canEditForm { nameFocused = true } }
        .onChange(of: chooser.busy) { busy in if busy { nameFocused = false } else if model.canEditForm { nameFocused = true } }
        .onChange(of: model.useHead) { _ in model.changedBase() }
        .onChange(of: model.nameFocusRequest) { _ in if model.canEditForm { nameFocused = true } }
        .disabled(model.confirmingQuit)
        .sheet(item: $chooser.browser) { target in SwitchReferenceChooser(model: chooser, target: target) }
    }
}

struct BaseRadio: NSViewRepresentable {
    let title: String
    let selected: Bool
    let select: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { ReferenceChoiceButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:))) }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title; button.state = selected ? .on : .off; button.isEnabled = enabled && (button as? ReferenceChoiceButton)?.retired != true; context.coordinator.select = select
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) { coordinator.live = false; button.isEnabled = false; button.target = nil; button.action = nil }
    final class Coordinator: NSObject {
        var select: () -> Void = {}; var live = true
        @objc func clicked(_ sender: NSButton) { guard live, sender.isEnabled, sender.window != nil else { return }; select() }
    }
}
