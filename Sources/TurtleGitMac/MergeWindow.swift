import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class MergeWindowController: NSWindowController, NSWindowDelegate {
    let model: MergeWindowModel
    var onClosed: () -> Void = {}
    private var pickers: VersionPickerCoordinator!
    var referencePicker: ReferenceBrowserWindowController? { pickers.referencePicker }
    var commitPicker: LogWindowController? { pickers.commitPicker }
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void { get { pickers.configureReferencePicker } set { pickers.configureReferencePicker = newValue } }
    var presentPicker: (NSWindow, NSWindow) -> Bool { get { pickers.presentPicker } set { pickers.presentPicker = newValue } }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void, UserDefaults, String?) -> LogWindowController { get { pickers.makeCommitPicker } set { pickers.makeCommitPicker = newValue } }
    private(set) var historyWindow: NSWindow?
    private var historyAnswered=false
    private var identitySettings: SettingsSheetController?
    var identitySettingsWindow: NSWindow? { identitySettings?.window }
    var identityNavigation: SettingsNavigationController? { identitySettings?.navigation }
    private var closingPreparation = false
    static var activeChildReleases: Int { MergeChildRelease.activeCount }
    private(set) var progressController: MergeProgressWindowController?
    var presentProgress: (NSWindow, NSWindow) -> Void = { owner, child in child.alphaValue=owner.alphaValue;child.appearance=owner.appearance;owner.beginSheet(child) }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = MergeWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 570), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Merge", preferences: preferences)
        window.minSize = NSSize(width: 660, height: 540); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MergeDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        pickers = VersionPickerCoordinator(window: window, model: model, access: access, preferences: preferences)
        pickers.configureCommitPicker = { [weak model] log in model?.configureLogPicker(log) }
        window.setContentSize(NSSize(width: 680, height: 570)); window.center()
        model.close = { [weak self] in
            guard let self, !self.model.confirmingQuit, !self.model.busy, !self.model.hasHistory, !self.model.hasIdentitySettings, self.model.pickerTarget == nil, self.window?.attachedSheet == nil else { return }
            self.window?.close()
        }
        model.onProgress = { [weak self] progress in
            guard let self else { progress.invalidate(); return }
            guard let window = self.window, window.attachedSheet == nil else { self.model.abandonProgressPresentation(progress); return }
            let controller = MergeProgressWindowController(model: progress)
            controller.onClosed = { [weak self, weak progress, weak controller] in
                guard let self, let progress, let controller, self.progressController === controller else { return }
                self.progressController = nil; self.model.finish(progress)
            }
            self.progressController = controller
            if let child = controller.window { self.presentProgress(window, child) }
        }
        model.becameIdle = { [weak self] in if self?.closingPreparation == true { self?.model.close() } }
        model.retireIdentitySettings = { [weak self] in self?.identitySettings?.retire() }
        model.repairIdentity = { [weak self] in await self?.showIdentitySettings() ?? false }
        model.showMessageHistory = { [weak self] insert in self?.showHistory(insert: insert) }

        DialogGeometry.attach(window, identifier: "MergeWindowController")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.confirmingQuit else { return false }
        if model.preparing { closingPreparation=true;model.cancelPreparation();return false }
        return !model.busy && !model.hasHistory && !model.hasIdentitySettings && model.pickerTarget == nil && sender.attachedSheet == nil
    }
    func showIdentitySettings() async -> Bool {
        guard !model.closed, identitySettings == nil, let window, window.attachedSheet == nil else { return false }
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
        workspace.root=model.repository.root;workspace.settingsContextOverride=(model.repository,model.repositoryAccess,true)
        let child=SettingsSheetController(workspace:workspace,preferences:model.presentationPreferences,initialPage:.git,title:"Settings – TurtleGit for Mac")
        identitySettings=child;model.hasIdentitySettings=true;child.window?.appearance=window.appearance
        return await withCheckedContinuation { continuation in
            child.onClosed = { [weak self,weak child] accepted in
                if let self,self.identitySettings === child { self.identitySettings=nil;self.model.hasIdentitySettings=false }
                continuation.resume(returning:accepted)
            }
            child.presentSheet(for:window)
        }
    }
    func windowWillClose(_ notification: Notification) {
        model.saveMessageHistoryForClose(); model.invalidate(); identitySettings?.retire(); pickers.invalidate()
        let controller = progressController; progressController = nil
        controller?.close()
        if let child=historyWindow {historyAnswered=true;let release=MergeChildRelease(window:child,parent:window,closeWindow:true) {[model] in model.hasHistory=false};release.start();child.close()};historyWindow=nil
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }
        onClosed()
    }
    func showHistory(insert: @escaping (String) -> Void) {
        guard let window, window.attachedSheet == nil, historyWindow == nil, model.canEditMessage else { return }
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        child.title = "Log History – TurtleGit"; child.minSize = NSSize(width: 400, height: 260); child.isReleasedWhenClosed = false
        let draft=model.message
        model.hasHistory=true;child.alphaValue=window.alphaValue;child.appearance=window.appearance
        child.contentView = MessageHistoryPickerView(history: model.messageHistory) { [weak self, weak window, weak child] text in
            guard let self, let child, self.historyWindow === child, !self.historyAnswered, !self.model.closed else { return }
            self.historyAnswered=true
            let release=MergeChildRelease(window:child,parent:window,closeWindow:true) { [self] in
                self.historyWindow=nil;self.model.hasHistory=false
                if self.model.canEditMessage,self.model.message == draft,let text {insert(text)}
            }
            release.start()
        }
        DialogGeometry.attach(child, identifier: "HistoryDlg")
        historyAnswered=false;historyWindow = child; window.beginSheet(child)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class MergeWindowModel: ObservableObject, VersionPickerModel {
    private(set) static var activeReads = 0
    @Published var confirmingQuit=false { didSet { if confirmingQuit != oldValue {formRevision=UUID()};progress?.confirmingQuit=confirmingQuit } }
    @Published var hasHistory=false {didSet {if hasHistory != oldValue {formRevision=UUID()}}}
    @Published var hasIdentitySettings=false {didSet {if hasIdentitySettings != oldValue {formRevision=UUID()}}}
    @Published private(set) var prepared=false
    @Published private(set) var preparing=false
    @Published private(set) var formRevision=UUID()
    var repositoryAccess:RepositoryAccessLease? {access}
    var becameIdle:()->Void = {}
    var retireIdentitySettings:()->Void = {}
    var readPreparation:((OperationCancellation) async throws -> MergePreparation)?
    var repairIdentity:() async -> Bool = {false}
    struct FormContext:Equatable {let revision:UUID}
    var formContext:FormContext {.init(revision:formRevision)}
    var canEditForm:Bool {prepared && !closed && !confirmingQuit && !busy && !hasHistory && !hasIdentitySettings && pickerTarget == nil && progress == nil}
    var canEditMessage:Bool {canEditForm && !options.squash}
    func field<Value>(_ key:ReferenceWritableKeyPath<MergeWindowModel,Value>,context:FormContext)->Binding<Value> {
        Binding(get:{self[keyPath:key]},set:{value in guard self.canEditForm,self.formContext == context else{return}
            if key == \MergeWindowModel.branchRevision,self.target != .branch {return}
            if key == \MergeWindowModel.tagRevision,self.target != .tag {return}
            if key == \MergeWindowModel.commitRevision,self.target != .commit {return}
            if key == \MergeWindowModel.messageCount,!self.messages {return}
            if key == \MergeWindowModel.message,self.options.squash {return}
            self[keyPath:key]=value})
    }
    func option<Value>(_ key:WritableKeyPath<MergeOptions,Value>,context:FormContext)->Binding<Value> {
        Binding(get:{self.options[keyPath:key]},set:{value in
            guard self.canEditForm,self.formContext == context else{return}
            if key == \MergeOptions.squash,self.options.noFastForward {return}
            if key == \MergeOptions.noFastForward,self.options.squash || self.options.fastForwardOnly {return}
            if key == \MergeOptions.fastForwardOnly,self.options.noFastForward {return}
            if key == \MergeOptions.strategyOption,self.options.strategy != "recursive" {return}
            if key == \MergeOptions.strategyParameter,self.options.strategy != "recursive" || !["rename-threshold","subtree"].contains(self.options.strategyOption) {return}
            self.options[keyPath:key]=value
        })
    }
    private func requirePreparation(_ token:OperationCancellation) async throws {
        while true {
            try token.check();guard !closed else{throw OperationCancellationFailure.cancelled}
            let state:MergePreparation
            if let readPreparation {state=try await readPreparation(token)} else {state=try await repository.prepareMerge(cancellation:token)}
            try token.check();guard !closed else{throw OperationCancellationFailure.cancelled}
            if !state.identity.complete {guard await repairIdentity(),!closed else{throw OperationCancellationFailure.cancelled};continue}
            guard !state.replayActive else {throw MergeFailure.activeReplay}
            return
        }
    }
    func cancelPreparation() {loadToken?.cancel();retireIdentitySettings()}
    private var closeAfterPreparation=false
    func cancel() {if preparing {closeAfterPreparation=true;cancelPreparation()} else {close()}}
    var versionPickerDraft: [GitReferenceName] { [target.rawValue, branchRevision, tagRevision, commitRevision].map { GitReferenceName($0) } }
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    let messageHistory: MergeMessageHistory
    static let defaultMessage = "<Auto Generated by Git>"
    @Published var references: [CheckoutReference] = []
    @Published var currentBranch = ""
    @Published var target = CheckoutTarget.branch {didSet {if target != oldValue {formRevision=UUID()}}}
    @Published var branchRevision = ""
    @Published var tagRevision = ""
    @Published private(set) var commitChoices: [String] = []
    @Published var commitRevision = "HEAD"
    @Published var options = MergeOptions() {didSet {if options.strategy != oldValue.strategy || options.strategyOption != oldValue.strategyOption || options.noFastForward != oldValue.noFastForward || options.fastForwardOnly != oldValue.fastForwardOnly || options.squash != oldValue.squash || options.noCommit != oldValue.noCommit {formRevision=UUID()}}}
    @Published var messages = false {didSet {if messages != oldValue {formRevision=UUID()}}}
    @Published var messageCount = "20"
    @Published var message = MergeWindowModel.defaultMessage
    @Published var projectSettings = ProjectDialogSettings()
    @Published private(set) var issueProperties = IssueTrackerProperties()
    @Published var busy = false
    @Published var error: String?
    var close: () -> Void = {}
    var showMessageHistory: (@escaping (String) -> Void) -> Void = { _ in }
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    var onChanged: (String) -> Void = { _ in }
    var showStashPop = false
    var onAbortRequested: (() -> Void)?
    @Published private(set) var progress: MergeProgressWindowModel?
    var onProgress: ((MergeProgressWindowModel) -> Void)?
    var onPostAction: ((MergePostAction, MergeOptions) -> Void)?
    var messageEditorPreferences: UserDefaults { preferences }
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    private var loadToken: OperationCancellation?
    private var invalidated = false
    private var acknowledged = false
    var closed: Bool { invalidated }
    @Published private(set) var pickerTarget: CheckoutTarget?
    @Published private(set) var referenceFocusRequest = 0
    private var appliedReferenceFocusRequest = 0
    private var referenceSelectionToken: OperationCancellation?
    var onBrowsePicker: ((CheckoutTarget) -> Void)?
    func canBrowse(_ target: CheckoutTarget) -> Bool { canEditForm && self.target == target && target != .tag }
    func beginPicker(_ target: CheckoutTarget) -> Bool { guard canBrowse(target) else { return false }; pickerTarget = target; return true }
    func browse(_ target: CheckoutTarget) { guard canBrowse(target) else { return }; onBrowsePicker?(target) }
    func finishPicker() { referenceSelectionToken?.cancel(); referenceSelectionToken = nil; pickerTarget = nil; busy = false }
    func focusReference(_ control: NSControl, target: CheckoutTarget) {
        guard !invalidated, referenceFocusRequest > appliedReferenceFocusRequest, self.target == target,
              !busy, pickerTarget == nil, progress == nil, error == nil, control.isEnabled,
              let window = control.window, window.attachedSheet == nil else { return }
        if window.makeFirstResponder(control) { appliedReferenceFocusRequest = referenceFocusRequest }
    }
    func acceptReferenceSelection(_ name: String?, completion: @escaping () -> Void) {
        guard !invalidated, pickerTarget == .branch else { return }
        let requested = name ?? revision, draft = commitRevision, selectionDraft = versionPickerDraft
        let token = OperationCancellation(); referenceSelectionToken = token; busy = true
        Self.activeReads += 1
        Task {
            var applied = false
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {}; if referenceSelectionToken === token { referenceSelectionToken = nil; busy = false; pickerTarget = nil; if applied { referenceFocusRequest += 1 }; completion() } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let catalog = try await repository.checkoutReferences(includeFetchHead: preferences.includesFetchHead, localBranchesFirst: AdvancedListBehavior(defaults: preferences).localBranchesFirst, cancellation: token)
                let current = try await repository.branch(cancellation: token)
                guard !invalidated, !confirmingQuit, referenceSelectionToken === token, !token.isCancelled, versionPickerDraft == selectionDraft else { return }
                references = catalog; currentBranch = current
                if let reference = catalog.first(where: { GitReferenceName.equal($0.name, requested) }), let target = reference.target {
                    self.target = target
                    if target == .branch { branchRevision = requested } else { tagRevision = requested }
                    commitRevision = draft
                } else { target = .commit; selectCustomRevision(requested) }
                applied = true
            } catch { if !invalidated, referenceSelectionToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func selectCustomRevision(_ value: String) {
        guard !invalidated, let selected = RevisionSessionChoices.select(value, choices: &commitChoices) else { return }
        commitRevision = selected
    }
    func acceptCommitSelection(_ entry: LogEntry?) {
        guard !invalidated, !confirmingQuit, pickerTarget == .commit else { return }
        if let entry { selectCustomRevision(entry.hash); referenceFocusRequest += 1 }
        finishPicker()
    }
    private var historyHandled = false
    var branches: [CheckoutReference] { references.filter { ($0.name.hasPrefix("refs/heads/") || $0.remote || $0.isFetchHead) && ($0.symbolicTarget == nil || GitReferenceName.equal($0.name, branchRevision)) && !GitReferenceName.equal($0.name, "refs/heads/" + currentBranch) } }
    var tags: [CheckoutReference] { let values = references.filter { $0.name.hasPrefix("refs/tags/") }; return preferences.bool(forKey: "SortTagsReversed") ? Array(values.reversed()) : values }
    var revision: String { switch target { case .branch: return branchRevision; case .tag: return tagRevision; case .commit: return commitRevision } }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.preferences = preferences; messageHistory = MergeMessageHistory(defaults: preferences)
    }
    func saveMessageHistoryForClose() { saveAcceptedMessageHistory(message:message,noCommit:options.noCommit) }
    private func saveAcceptedMessageHistory(message:String,noCommit:Bool) {
        guard !historyHandled else { return }
        historyHandled = true
        if !noCommit, message != Self.defaultMessage { messageHistory.add(message) }
    }
    func load(revision preset: String? = nil) {
        guard !closed,!confirmingQuit,!busy,!hasHistory,!hasIdentitySettings,pickerTarget == nil,progress == nil else{return}; busy = true; preparing=true;prepared=false;formRevision=UUID()
        let token = OperationCancellation(); loadToken = token
        Self.activeReads += 1
        Task {
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {}; if loadToken === token { loadToken = nil; busy = false;preparing=false;if !closed {becameIdle();if closeAfterPreparation {close()}} } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await requirePreparation(token)
                let current = try await repository.branch(cancellation: token), catalog = try await repository.checkoutReferences(includeFetchHead: preferences.includesFetchHead, localBranchesFirst: AdvancedListBehavior(defaults: preferences).localBranchesFirst, cancellation: token)
                let defaults = try await repository.pushDefaults(source: "HEAD", cancellation: token)
                let destination = defaults.destination.hasPrefix("refs/heads/") ? String(defaults.destination.dropFirst(11)) : defaults.destination
                let tracked = "refs/remotes/" + defaults.remote + "/" + destination
                let count = try await repository.mergeMessageCount(cancellation: token)
                let project = try await repository.projectDialogSettings(source: .effective, cancellation: token)
                let issues = try await repository.issueTrackerProperties(cancellation: token)
                guard !invalidated, loadToken === token, !token.isCancelled else { return }
                prepared=true;currentBranch = current; references = catalog
                branchRevision = preset ?? ""
                branchRevision = branches.first { GitReferenceName.equal($0.name, tracked) }?.name ?? branches.first?.name ?? ""
                tagRevision = tags.first?.name ?? ""; messageCount = String(count); projectSettings = project; issueProperties = issues
                if let preset {
                    if catalog.contains(where: { GitReferenceName.equal($0.name, preset) && $0.target == .branch }) { target = .branch; branchRevision = preset }
                    else if tags.contains(where: { GitReferenceName.equal($0.name, preset) }) { target = .tag; tagRevision = preset }
                    else { target = .commit; selectCustomRevision(preset) }
                }
            } catch { if !invalidated, loadToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func merge() {
        guard canEditForm, !revision.isEmpty else { return }
        var snapshot = options; snapshot.revision = revision
        if messages {
            guard let count = Int(messageCount), count >= 0 else { error = MergeFailure.logCount.localizedDescription; return }
            snapshot.logCount = count
        }
        snapshot.message = message == Self.defaultMessage ? "" : message
        snapshot.requireIdentity=true
        snapshot.stripComments=preferences.bool(forKey:"StripCommentedLines")
        snapshot.sanitizeMessage=preferences.object(forKey:"SanitizeCommitMsg") as? Bool ?? true
        let acceptedTarget=target,acceptedStashPop=showStashPop,acceptedMessage=message
        busy=true;preparing=true;formRevision=UUID()
        let token=OperationCancellation();loadToken=token;Self.activeReads += 1
        Task {
            defer {Self.activeReads -= 1;withExtendedLifetime(access) {};if loadToken === token {loadToken=nil;preparing=false;if progress == nil {busy=false};if !closed {becameIdle();if closeAfterPreparation {close()}}}}
            do {try await requirePreparation(token);try token.check();guard !closed else{return}}
            catch {if !closed,!token.isCancelled {self.error=error.localizedDescription};return}
            saveAcceptedMessageHistory(message:acceptedMessage,noCommit:snapshot.noCommit)
            beginMerge(snapshot,target:acceptedTarget,showStashPop:acceptedStashPop)
        }
    }
    private func beginMerge(_ snapshot:MergeOptions,target:CheckoutTarget,showStashPop:Bool) {
        let progress = MergeProgressWindowModel(repository: repository, access: access, options: snapshot, target: target, showStashPop: showStashPop, preferences: preferences)
        self.progress = progress
        progress.onChanged = { [weak self, weak progress] output in guard let self, let progress, !self.invalidated, self.progress === progress else { return }; self.onChanged(output) }
        if onPostAction != nil { progress.onPostAction = { [self] action, request in guard !invalidated || acknowledged else { return }; self.onPostAction?(action, request) } }
        if onAbortRequested != nil { progress.onAbortRequested = { [self] in guard !invalidated || acknowledged else { return }; self.onAbortRequested?() } }
        progress.close = { [weak self, weak progress] in if let progress { self?.finish(progress) } }
        onProgress?(progress); progress.start()
    }
    func abandonProgressPresentation(_ progress: MergeProgressWindowModel) { guard self.progress === progress else { return }; progress.invalidate(); self.progress = nil; busy = false }
    func invalidate() { invalidated = true; formRevision=UUID();retireIdentitySettings(); finishPicker(); referenceFocusRequest = 0; loadToken?.cancel(); loadToken = nil; progress?.invalidate(); progress = nil; busy = false }
    func finish(_ progress: MergeProgressWindowModel) {
        guard self.progress === progress, !progress.busy, !progress.confirmingCancellation, !progress.confirmingDeletion else { return }
        self.progress = nil; busy = false; guard !invalidated else { return }; acknowledged = true; close()
    }
}

private struct MergeDialog: View {
    @ObservedObject var model: MergeWindowModel
    var body: some View {
        let context=model.formContext
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Current branch:").frame(width: 115, alignment: .leading); Text(model.currentBranch.isEmpty ? "Detached HEAD" : model.currentBranch).foregroundStyle(.blue) }
            GroupBox("From") {
                VStack(spacing: 8) {
                    HStack {
                        SwitchRadio(title: "Branch", target: .branch, selection: model.field(\.target,context:context)).frame(width: 95)
                        ReferencePopup(references: model.branches, selection: model.field(\.branchRevision,context:context), accessibilityLabel: "Merge branch revision", focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .branch) }).disabled(model.target != .branch)
                        Button("…") { model.browse(.branch) }.accessibilityLabel("Browse references").disabled(model.target != .branch)
                    }
                    HStack {
                        SwitchRadio(title: "Tag", target: .tag, selection: model.field(\.target,context:context)).frame(width: 95)
                        ReferencePopup(references: model.tags, selection: model.field(\.tagRevision,context:context), accessibilityLabel: "Merge tag revision", focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .tag) }).disabled(model.target != .tag)
                        Color.clear.frame(width: 29)
                    }
                    HStack {
                        SwitchRadio(title: "Commit", target: .commit, selection: model.field(\.target,context:context)).frame(width: 95)
                        VersionRevisionField(text: model.field(\.commitRevision,context:context), choices: model.commitChoices, accessibilityLabel: "Merge commit revision", focusRequest: model.referenceFocusRequest, onFocus: { model.focusReference($0, target: .commit) }).disabled(model.target != .commit)
                        Button("…") { model.browse(.commit) }.accessibilityLabel("Choose commit").disabled(model.target != .commit)
                    }
                }.padding(8)
            }.disabled(!model.canEditForm)
            GroupBox("Option") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("Squash", isOn: model.option(\.squash,context:context)).frame(width: 260, alignment: .leading).disabled(model.options.noFastForward)
                        Toggle("Messages", isOn: model.field(\.messages,context:context))
                        TextField("Count", text: model.field(\.messageCount,context:context)).frame(width: 55).disabled(!model.messages).accessibilityLabel("Number of commit messages")
                    }
                    HStack {
                        Toggle("No Fast Forward", isOn: model.option(\.noFastForward,context:context)).frame(width: 260, alignment: .leading).disabled(model.options.squash || model.options.fastForwardOnly)
                        Toggle("Fast Forward Only", isOn: model.option(\.fastForwardOnly,context:context)).disabled(model.options.noFastForward)
                    }
                    Toggle("No Commit", isOn: model.option(\.noCommit,context:context))
                    HStack {
                        Text("Strategy")
                        Picker("Merge strategy", selection: model.option(\.strategy,context:context)) { Text("").tag(""); ForEach(MergeOptions.strategies, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 125)
                        Picker("Strategy option", selection: model.option(\.strategyOption,context:context)) { Text("").tag(""); ForEach(MergeOptions.strategyOptions, id: \.self) { Text($0).tag($0) } }.labelsHidden().disabled(model.options.strategy != "recursive")
                        TextField("Parameter", text: model.option(\.strategyParameter,context:context)).frame(width: 75).disabled(model.options.strategy != "recursive" || !["rename-threshold", "subtree"].contains(model.options.strategyOption))
                    }
                }.toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.disabled(!model.canEditForm)
            GroupBox("Merge Message") {
                MergeMessageEditor(model: model).frame(minHeight: 110).disabled(!model.canEditMessage).padding(5)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                if !model.prepared && !model.busy {Button("Retry loading") {model.load()}.disabled(model.confirmingQuit)}
                Button("OK") { model.merge() }.keyboardShortcut(.defaultAction).disabled(!model.canEditForm || model.revision.isEmpty)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(model.confirmingQuit || model.hasHistory || model.busy && !model.preparing)
                Button("Help") { TurtleGitHelp.show(.merge) }
            }
        }.padding(16)
        .alert("Merge failed", isPresented: Binding(get: { !model.closed && model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

enum MergePostAction: String, CaseIterable, Hashable {
    case resolve, commit, mergeUnrelated, stash, stashPop, removeBranch, push, svnDCommit
    var title: String {
        switch self {
        case .resolve: return "Resolve…"
        case .commit: return "Commit…"
        case .mergeUnrelated: return "Merge unrelated histories"
        case .stash: return "Stash Save…"
        case .stashPop: return "Stash Pop"
        case .removeBranch: return "Remove branch"
        case .push: return "Push…"
        case .svnDCommit: return "SVN DCommit…"
        }
    }
    var icon: MenuIcon {
        switch self { case .resolve: return .resolve; case .commit: return .commit; case .mergeUnrelated: return .merge; case .stash: return .stash; case .stashPop: return .stashPop; case .removeBranch: return .remove; case .push: return .push;case .svnDCommit:return .commit }
    }
}
@MainActor final class MergeProgressWindowModel: ObservableObject {
    private(set) static var activeOperations=0
    @Published var confirmingQuit=false
    var presentationAvailable:()->Bool = {true}
    var closeForHandoff:((@escaping ()->Void)->Void)?
    private func finishAndPerform(_ action:@escaping ()->Void) {if let closeForHandoff {closeForHandoff(action)} else {close();action()}}
    let repository: GitRepository
    let options: MergeOptions
    let target: CheckoutTarget
    let showStashPop: Bool
    private let access: RepositoryAccessLease?
    private var cancellation = OperationCancellation()
    private var started = false, invalidated = false, dispatched = false
    private var inspectionCancellation: OperationCancellation?
    private var dismissalCancellation: OperationCancellation?
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    static let conflictHintPreference = "MergeConflictsNeedsCommit"
    static let conflictHint = """
    While merging, i.e. integrating changes of another (remote) branch into your local branch, a conflict in at least one file occurred. This means that you need to resolve this manually (i.e., you need to integrate your changes into a file which was also modified on another branch).

    After resolving all files, you need to perform a commit in order to complete the merge.

    If you want to abort the merge, do a hard reset on HEAD or select abort merge on the context menu.

    See help for more information.
    """
    @Published private(set) var confirmingConflictHint = false
    var presentConflictHint: (() async -> Bool)?
    @Published private(set) var checkingDismissal = false
    var onAbortRequested: (() -> Void)?
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var output = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var currentWork = ""
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    private(set) var rawOutput = ""
    private var outputState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { outputState.presentation }
    var outputLimit: Int { outputState.limit }
    var canCancel: Bool { !confirmingQuit && busy && !cancelling && !confirmingCancellation && !confirmingConflictHint }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    @Published private(set) var postActions: [MergePostAction] = []
    @Published private(set) var confirmingDeletion = false
    @Published var deletionError: String?
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onPostAction: ((MergePostAction, MergeOptions) -> Void)?
    var confirmDeletion: (String, @escaping (Bool) -> Void) -> Void = { _, choose in choose(false) }
    init(repository: GitRepository, access: RepositoryAccessLease?, options: MergeOptions, target: CheckoutTarget, showStashPop: Bool, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; self.options = options; self.target = target; self.showStashPop = showStashPop; self.preferences = preferences; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences); outputState = GitProgressOutputState(preferences: preferences) }
    func start() { Task { await run() } }
    func run() async { guard !started, !invalidated else { return }; started = true; await execute(options) }
    func invalidate() {
        invalidated = true; cancellation.cancel(); inspectionCancellation?.cancel(); dismissalCancellation?.cancel()
        confirmingCancellation = false; confirmingConflictHint = false; confirmingDeletion = false; checkingDismissal = false; busy = false
    }
    func cancel() {
        guard canCancel, !invalidated else { return }; let token = cancellation
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true; var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.invalidated, self.confirmingCancellation, self.cancellation === token else { return }
                answered = true; self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; token.cancel() }
                self.finishResult()
            }
        } else { cancelling = true; token.cancel() }
    }
    private func finishResult() {
        guard !invalidated, !busy, !confirmingCancellation, !confirmingConflictHint else { return }
        if autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() }
        else if cancelled, onAbortRequested != nil { cancelResult() }
    }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        guard !invalidated else { return }
        outputState.consume(emission, parser: parser)
        output = outputState.output; percentage = outputState.percentage; currentWork = outputState.currentWork
    }
    private func streamMerge(_ snapshot: MergeOptions) async throws -> String {
        let parser = GitCliOutputParser(limit: outputState.limit)
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let operation = Task {
            defer { continuation.finish() }
            return try await repository.merge(snapshot, cancellation: cancellation, onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) })
        }
        for await _ in updates { consume(parser.processPending(), parser: parser) }
        consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser)
        return try await operation.value
    }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func execute(_ snapshot: MergeOptions) async {
        guard !invalidated else { return }
        Self.activeOperations += 1;defer {Self.activeOperations -= 1;withExtendedLifetime(access) {}}
        busy = true; success = false; cancelled = false; cancelling = false; outputState.reset(); output = ""; rawOutput = ""; percentage = nil; currentWork = ""; postActions = []
        do { try validateAccess() }
        catch { guard !invalidated else { return }; output = error.localizedDescription; rawOutput = output; busy = false; onChanged(rawOutput); return }
        do {
            let result = try await streamMerge(snapshot)
            guard !invalidated else { return }
            rawOutput = result; if !outputState.hasOutput { output = rawOutput }; success = true
        } catch {
            guard !invalidated else { return }
            if let failure = error as? GitCommandCancellationFailure { rawOutput = failure.result.text + "\n" + failure.localizedDescription }
            else { rawOutput = error.localizedDescription }
            output=GitProgressFailureOutput.render(error,existing:output,limit:outputState.limit); cancelled = cancellation.isCancelled
        }
        var actions: [MergePostAction] = []
        if success {
            if showStashPop { actions.append(.stashPop) }
            if options.noCommit || options.squash { actions.append(.commit) }
            else if target == .branch {
                if options.revision.hasPrefix("refs/heads/") { actions.append(.removeBranch) }
                actions.append(.push)
            }
            if !options.noCommit && !options.squash, (try? await repository.prepareMerge(cancellation:cancellation).hasGitSVN) == true {actions.append(.svnDCommit)}
        } else {
            // Normal Cancel still inspects recovery state using a fresh token.
            // Forced cleanup cancels this read as well as the original merge.
            let inspection = OperationCancellation(); inspectionCancellation = inspection
            defer { if inspectionCancellation === inspection { inspectionCancellation = nil } }
            let conflicts = (try? await repository.status(refreshIndex: false, cancellation: inspection).contains { $0.state == .conflicted }) == true
            guard !invalidated else { return }
            if conflicts {
                if !preferences.bool(forKey: Self.conflictHintPreference), let presentConflictHint {
                    confirmingConflictHint = true
                    let suppress = await presentConflictHint()
                    guard !invalidated else { return }
                    confirmingConflictHint = false
                    if suppress { preferences.set(true, forKey: Self.conflictHintPreference) }
                }
                actions += [.resolve, .commit]
            }
            let head = try? await repository.run(["rev-parse", "--verify", "--end-of-options", "HEAD^{commit}"], cancellation: inspection).text.trimmingCharacters(in: .newlines)
            let revision = try? await repository.run(["rev-parse", "--verify", "--end-of-options", options.revision + "^{commit}"], cancellation: inspection).text.trimmingCharacters(in: .newlines)
            var common = false
            if let head, let revision { common = (try? await repository.run(["merge-base", head, revision], successfulExitCodes: 0...1, cancellation: inspection).stdout.isEmpty) == false }
            guard !invalidated else { return }
            if !common { actions.append(.mergeUnrelated) }
            actions.append(.stash)
        }
        guard !invalidated else { return }
        postActions = actions; busy = false; cancelling = false; onChanged(rawOutput); finishResult()
    }
    func cancelResult() {
        guard !invalidated, !confirmingQuit, !busy, !confirmingCancellation, !confirmingConflictHint, !confirmingDeletion, !checkingDismissal else { return }
        checkingDismissal = true
        let token = OperationCancellation(); dismissalCancellation = token
        Self.activeOperations += 1
        Task {
            defer {Self.activeOperations -= 1;withExtendedLifetime(access) {}}
            var conflicts = false
            do { try validateAccess(); conflicts = try await repository.status(refreshIndex: false, cancellation: token).contains { $0.state == .conflicted } } catch {}
            guard !invalidated, dismissalCancellation === token, !token.isCancelled else { return }
            dismissalCancellation = nil; checkingDismissal = false
            let abort=onAbortRequested
            finishAndPerform {if conflicts {abort?()}}
        }
    }
    func perform(_ action: MergePostAction) {
        guard !invalidated, !confirmingQuit, presentationAvailable(), !dispatched, !busy, !confirmingCancellation, !confirmingDeletion, !checkingDismissal, postActions.contains(action) else { return }
        if action == .mergeUnrelated {
            ProgressActionLog.nextAttempt(self)
            var snapshot = options; snapshot.allowUnrelatedHistories = true
            busy = true; cancellation = OperationCancellation()
            Task { await execute(snapshot) }
        } else if action == .removeBranch {
            confirmingDeletion = true; var answered = false
            confirmDeletion(String(options.revision.dropFirst("refs/heads/".count))) { [weak self] accepted in
                guard !answered, let self, !self.invalidated, self.confirmingDeletion else { return }
                answered = true; self.confirmingDeletion = false
                if accepted && !self.confirmingQuit { self.deleteBranch() }
            }
        } else if let onPostAction { dispatched = true; let options=self.options;finishAndPerform {onPostAction(action, options)} }
    }
    private func deleteBranch() {
        guard !invalidated, !confirmingQuit, !busy, options.revision.hasPrefix("refs/heads/") else { return }; busy = true
        let token = OperationCancellation(); cancellation = token
        Self.activeOperations += 1
        Task {
            defer {Self.activeOperations -= 1;withExtendedLifetime(access) {}}
            do {
                try validateAccess()
                let result = try await repository.run(["branch", "-D", "--", String(options.revision.dropFirst("refs/heads/".count))], cancellation: token)
                guard !invalidated, cancellation === token else { return }
                rawOutput += "\n" + result.text; output += "\n" + result.text
                postActions.removeAll { $0 == .removeBranch }; deletionError = nil
            } catch { guard !invalidated, cancellation === token else { return }; deletionError = error.localizedDescription; rawOutput += "\n" + error.localizedDescription; output += "\n" + error.localizedDescription }
            busy = false; cancelling = false; onChanged(rawOutput)
        }
    }
}
@MainActor final class MergeProgressWindowController: NSWindowController, NSWindowDelegate {
    private var pendingHandoff:(()->Void)?
    private var release:MergeChildRelease?
    private var presentationParent:NSWindow?
    private var finished=false
    let model: MergeProgressWindowModel
    var onClosed: () -> Void = {}
    init(model: MergeProgressWindowModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: model.repository.root, dialog: "Merge Progress", preferences: model.presentationPreferences)
        window.contentMinSize = NSSize(width: 560, height: 300); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MergeProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in
            guard let self, !self.model.confirmingQuit, !self.model.busy, !self.model.confirmingDeletion, !self.model.confirmingCancellation, !self.model.checkingDismissal, self.window?.attachedSheet == nil else { return }
            if let window = self.window {self.presentationParent=window.sheetParent;window.close()}
        }
        model.presentationAvailable = { [weak window] in window != nil && window?.attachedSheet == nil }
        model.closeForHandoff = { [weak self] action in
            guard let self,!self.finished,self.pendingHandoff == nil else{return};self.pendingHandoff=action;self.model.close()
        }
        model.presentConflictHint = { [weak window] in
            guard let window, window.attachedSheet == nil else { return false }
            return await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.alertStyle = .informational
                alert.messageText = "TurtleGit"; alert.informativeText = MergeProgressWindowModel.conflictHint
                alert.addButton(withTitle: "OK")
                alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Don't show this message again"
                alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
                alert.beginSheetModal(for: window) { _ in continuation.resume(returning: alert.suppressionButton?.state == .on) }
            }
        }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
        model.confirmDeletion = { [weak window] branch, choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Delete branch \"\(branch)\"?"
            alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Abort")
            alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }

        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.confirmingQuit || model.confirmingConflictHint || model.confirmingCancellation { return false }
        if model.busy { model.cancel(); return false }
        guard !model.confirmingDeletion, !model.checkingDismissal, sender.attachedSheet == nil else { return false }
        model.cancelResult(); return false
    }
    func windowWillClose(_ notification: Notification) {
        guard !finished else{return};finished=true
        model.saveActionLog();model.invalidate();model.closeForHandoff=nil
        guard let window else{onClosed();return}
        if let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.abort);sheet.close()}
        let action=pendingHandoff;pendingHandoff=nil
        let release=MergeChildRelease(window:window,parent:presentationParent ?? window.sheetParent) { [self] in
            self.release=nil;onClosed();action?()
        }
        self.release=release;release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
struct MergeProgressDialog: View {
    @ObservedObject var model: MergeProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(model.options.revision)").font(.headline)
            ScrollViewReader { reader in
                ScrollView { VStack(alignment: .leading, spacing: 0) { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading); Color.clear.frame(height: 1).id("merge-output-end") } }
                    .onChange(of: model.output) { _ in reader.scrollTo("merge-output-end", anchor: .bottom) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor))
            if model.busy, let percentage = model.percentage { ProgressView(value: Double(percentage), total: 100).tint(.green) }
            if !model.currentWork.isEmpty { Text(model.currentWork).font(.caption).lineLimit(2) }
            HStack {
                if model.busy { if model.percentage == nil { GitCommandActivity(animate: model.progressPresentation.animateActivity) }; Text(model.cancelling ? "Cancelling…" : "Running…") }
                else { Text(model.cancelled ? "Cancelled" : model.success ? "Finished" : "Merge failed").foregroundStyle(model.success ? Color.green : Color.red) }
                Spacer()
            }
            HStack {
                if let first = model.postActions.first {
                    HStack(spacing: 2) {
                        Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                        Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Merge post-actions") }.menuStyle(.borderlessButton).fixedSize()
                    }.disabled(model.busy || model.confirmingCancellation || model.confirmingDeletion || model.checkingDismissal)
                }
                Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else {
                    if !model.success { Button("Cancel") { model.cancelResult() }.keyboardShortcut(.cancelAction).disabled(model.confirmingCancellation || model.confirmingDeletion || model.checkingDismissal) }
                    Button("Close") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.confirmingCancellation || model.confirmingDeletion || model.checkingDismissal)
                }
            }
        }.padding(12)
        .alert("Delete branch failed", isPresented: Binding(get: { model.deletionError != nil }, set: { if !$0 { model.deletionError = nil } })) { Button("OK") { model.deletionError = nil } } message: { Text(model.deletionError ?? "") }
        .gitDockProgress(.command(busy: model.busy, success: model.success, waiting: model.confirmingCancellation || model.confirmingDeletion, percentage: model.percentage))
    }
}

enum MergeAbortPostAction: String, CaseIterable, Hashable {
    case retry, submoduleUpdate, good, bad, skip, reset, clean
    var title: String {
        switch self { case .retry: return "Retry"; case .submoduleUpdate: return "Submodule Update…"; case .good: return "Bisect good"; case .bad: return "Bisect bad"; case .skip: return "Bisect skip"; case .reset: return "Bisect reset"; case .clean: return "Clean up…" }
    }
    var icon: MenuIcon {
        switch self { case .retry: return .refresh; case .submoduleUpdate: return .fetch; case .good: return .bisectGood; case .bad: return .bisectBad; case .skip: return .bisect; case .reset: return .bisectReset; case .clean: return .clean }
    }
    var bisectOperation: BisectOperation? { BisectOperation(rawValue: rawValue) }
}
@MainActor final class MergeAbortWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    private var invalidated = false
    private var cancellation = OperationCancellation()
    private var operationMode = MergeAbortMode.merge
    private var worker: Task<Void, Never>?
    private var outputState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { outputState.presentation }
    private var rawOutput = ""
    private var closeAfterCancellation = false
    private var pendingConfirmation: UUID?
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var cancelling = false
    var canCancel: Bool { busy && !invalidated && !confirmingCancellation && !cancelling }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    @Published var hasChild = false
    @Published var mode = MergeAbortMode.merge
    @Published private(set) var busy = false
    @Published private(set) var showingProgress = false
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var output = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var currentWork = ""
    @Published private(set) var completionRange: NSRange?
    var outputPreferences: UserDefaults { preferences }
    var outputClipboard: NSPasteboard = .general
    @Published private(set) var postActions: [MergeAbortPostAction] = []
    var onChanged: (String) -> Void = { _ in }
    var onShowModified: (() -> Void)?
    var onPostAction: ((MergeAbortPostAction) -> Void)?
    var onResize: (Bool) -> Void = { _ in }
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    private var autoClosePolicy = GitProgressAutoClose.manual
    var close: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; self.preferences = preferences; outputState = GitProgressOutputState(preferences: preferences) }
    func invalidate() { invalidated = true; pendingConfirmation = nil; confirmingCancellation = false; cancellation.cancel(); worker?.cancel() }
    func showModified() { guard !invalidated, !busy, !hasChild, !showingProgress else { return }; onShowModified?() }
    func abort() {
        guard !invalidated, !busy, !hasChild, !showingProgress else { return }
        operationMode = mode; showingProgress = true; onResize(true); start()
    }
    private func streamReset(mode: MergeAbortMode, token: OperationCancellation) async throws -> String {
        let parser = GitCliOutputParser(limit: outputState.limit)
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let operation = Task {
            defer { continuation.finish() }
            return try await repository.abortMerge(mode: mode, cancellation: token, onOutput: { chunk in
                parser.appendChunk(chunk.data); continuation.yield(())
            })
        }
        func consume(_ emission: GitCliOutputParser.Emission) {
            guard !invalidated, cancellation === token else { return }
            outputState.consume(emission, parser: parser); output = outputState.output; percentage = outputState.percentage; currentWork = outputState.currentWork
        }
        for await _ in updates { consume(parser.processPending()) }
        consume(parser.processPending()); consume(parser.finish())
        return try await operation.value
    }
    private func start() {
        ProgressActionLog.nextAttempt(self, savePrevious: !output.isEmpty)
        autoClosePolicy = GitProgressAutoClose(preferences: preferences)
        busy = true; success = false; cancelled = false; cancelling = false; closeAfterCancellation = false; outputState.reset(); output = ""; percentage = nil; currentWork = ""; completionRange = nil; rawOutput = ""; postActions = []; cancellation = OperationCancellation()
        let token = cancellation, selectedMode = operationMode
        let started = ProcessInfo.processInfo.systemUptime
        worker = Task {
            // Keep the operation active until the owned process has actually unwound.
            var result = "", actions: [MergeAbortPostAction] = []
            var succeeded = false, diagnostic = ""
            var exitCode: Int32?, elapsed: TimeInterval = 0, finished = Date()
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                result = try await streamReset(mode: selectedMode, token: token)
                elapsed = ProcessInfo.processInfo.systemUptime - started; finished = Date()
                succeeded = true
                if selectedMode != .merge {
                    if selectedMode == .hard, (try? await repository.submoduleUpdatePaths(cancellation: token).isEmpty) == false { actions.append(.submoduleUpdate) }
                    if let path = try? await repository.run(["rev-parse", "--git-path", "BISECT_START"], cancellation: token).text.trimmingCharacters(in: .newlines) {
                        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repository.root.appendingPathComponent(path)
                        if FileManager.default.fileExists(atPath: url.path) { actions += [.good, .bad, .skip, .reset] }
                    }
                    if selectedMode == .hard { actions.append(.clean) }
                }
            } catch {
                elapsed = ProcessInfo.processInfo.systemUptime - started; finished = Date()
                exitCode = (error as? GitFailure)?.code
                if let failure = error as? GitCommandCancellationFailure { result = failure.result.text + "\n" + failure.localizedDescription }
                else { result = error.localizedDescription }
                if let failure = error as? GitFailure, outputState.hasOutput { diagnostic = "Git command failed (\(failure.code))." }
                else { diagnostic = error.localizedDescription }
                actions = [.retry]
            }
            busy = false; worker = nil
            guard !invalidated else { return }
            rawOutput = result
            if !outputState.hasOutput { output = result }
            else if !diagnostic.isEmpty { output += (output.hasSuffix("\n") ? "" : "\n") + diagnostic }
            success = succeeded; cancelled = !succeeded && token.isCancelled; postActions = actions
            let completion = SubmoduleProgressCompletion(success: success, cancelled: cancelled, exitCode: exitCode, elapsed: elapsed, finished: finished, preferences: preferences)
            currentWork = completion.currentWork; percentage = 100; completionRange = completion.append(to: &output)
            onChanged(rawOutput)
            guard !invalidated else { return }
            finishResult()
        }
    }
    private func finishResult() {
        guard !invalidated, !busy, !confirmingCancellation else { return }
        if closeAfterCancellation || autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() }
    }
    func cancel() {
        guard canCancel else { return }
        let token = cancellation
        if preferences.bool(forKey: "ConfirmKillProcess") {
            let request = UUID(); pendingConfirmation = request; confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, !self.invalidated, self.pendingConfirmation == request, self.cancellation === token else { return }
                self.pendingConfirmation = nil; self.confirmingCancellation = false
                if accepted {
                    self.closeAfterCancellation = true
                    if self.busy { self.cancelling = true; token.cancel() }
                }
                self.finishResult()
            }
        } else { closeAfterCancellation = true; cancelling = true; token.cancel() }
    }
    func perform(_ action: MergeAbortPostAction) {
        guard !invalidated, !busy, !hasChild, !confirmingCancellation, postActions.contains(action) else { return }
        if action == .retry {
            saveActionLog();
            if operationMode == .merge { mode = .merge; showingProgress = false; onResize(false) }
            else { start() }
        } else if let onPostAction { close(); onPostAction(action) }
    }
}
private final class MergeAbortNativeWindow: NSWindow {
    var primary: () -> Void = {}
    var cancelAction: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case 36, 76:
            if attachedSheet == nil { primary() }
            return true
        case 53:
            if attachedSheet == nil { cancelAction() }
            return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}
@MainActor final class MergeAbortWindowController: NSWindowController, NSWindowDelegate {
    let model: MergeAbortWindowModel
    var onClosed: () -> Void = {}
    var configureModifiedComparison:(RevisionComparisonWindowModel)->Void = { _ in }
    private let comparisonPreferences:UserDefaults
    private(set) var modifiedFiles: RevisionComparisonWindowController?
    private(set) var progress: MergeAbortProgressWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        comparisonPreferences=preferences
        model = MergeAbortWindowModel(repository: repository, access: access, preferences: preferences)
        let window = MergeAbortNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 265), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Abort Merge", preferences: preferences); window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 660, height: 265)
        window.contentViewController = NSHostingController(rootView: MergeAbortDialog(model: model).frame(width: 660, height: 265))
        super.init(window: window); window.delegate = self; window.setContentSize(NSSize(width: 660, height: 265)); window.center()
        model.close = { [weak self] in guard let self, !self.model.busy, !self.model.hasChild, !self.model.confirmingCancellation, self.window?.attachedSheet == nil, self.progress?.window?.attachedSheet == nil else { return }; self.window?.close() }
        model.onResize = { [weak self] showing in self?.showProgress(showing) }
        window.primary = { [weak model] in model?.abort() }
        window.cancelAction = { [weak model] in guard let model, !model.hasChild else { return }; model.close() }

        model.onShowModified = { [weak self] in self?.showModifiedFiles(access: access) }
        DialogGeometry.attach(window, identifier: "MergeAbortWindowController")
    }
    private func showProgress(_ showing: Bool) {
        guard let window else { return }
        if showing {
            guard progress == nil else { return }
            let controller = MergeAbortProgressWindowController(model: model)
            progress = controller
            controller.onClosed = { [weak self] in self?.progress = nil; self?.window?.close() }
            controller.window?.alphaValue = window.alphaValue
            controller.window?.appearance = window.appearance
            controller.window?.setFrameOrigin(window.frame.origin)
            window.orderOut(nil)
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } else {
            // Upstream Merge retry returns to the options dialog; Mixed/Hard
            // retry remains in the existing progress window.
            progress?.onClosed = {}; progress?.close(); progress = nil
            window.makeKeyAndOrderFront(nil)
        }
    }
    private func showModifiedFiles(access: RepositoryAccessLease?) {
        guard let window, !model.busy, !model.hasChild, !model.showingProgress, window.attachedSheet == nil else { return }
        let child = RevisionComparisonWindowController(repository: model.repository, access: access, from: .revision("HEAD"), to: .workingTree,preferences:comparisonPreferences)
        configureModifiedComparison(child.model)
        guard let sheet = child.window else { return }
        modifiedFiles = child; model.hasChild = true
        child.onClosed = { [weak self, weak sheet] in
            if let sheet, let parent = sheet.sheetParent { parent.endSheet(sheet) }
            self?.modifiedFiles = nil; self?.model.hasChild = false
        }
        sheet.alphaValue = window.alphaValue; sheet.appearance = window.appearance
        window.beginSheet(sheet); child.model.load()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.confirmingCancellation { return false }; if model.busy { model.cancel(); return false }; return !model.hasChild && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        model.saveActionLog(); model.invalidate()
        progress?.onClosed = {}; progress?.close(); progress = nil
        if let child = modifiedFiles { child.close() }
        modifiedFiles = nil; model.hasChild = false; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class MergeAbortProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: MergeAbortWindowModel
    var onClosed: () -> Void = {}
    private(set) var cancellationAlert: NSAlert?
    init(model: MergeAbortWindowModel) {
        self.model = model
        let window = MergeAbortNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: model.repository.root, dialog: "Reset", preferences: model.presentationPreferences); window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 600, height: 300)
        window.contentViewController = NSHostingController(rootView: MergeAbortDialog(model: model).frame(minWidth: 600, minHeight: 300))
        super.init(window: window); window.delegate = self; window.setContentSize(NSSize(width: 760, height: 420))
        window.primary = { [weak model] in guard let model, !model.busy, !model.confirmingCancellation else { return }; model.close() }
        window.cancelAction = { [weak model] in guard let model else { return }; if model.busy { model.cancel() } else { model.close() } }
        model.confirmCancellation = { [weak self] choose in
            guard let self, let window = self.window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"), no = alert.addButton(withTitle: "No")
            yes.keyEquivalent = "\r"; no.keyEquivalent = "\u{1b}"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.window.alphaValue = window.alphaValue; alert.window.appearance = window.appearance
            self.cancellationAlert = alert
            alert.beginSheetModal(for: window) { [weak self] response in
                // NSAlert invokes its reply before AppKit finishes detaching the
                // sheet. Keep the model gate until a close can actually succeed.
                DispatchQueue.main.async {
                    self?.cancellationAlert = nil; choose(response == .alertFirstButtonReturn)
                }
            }
        }
        DialogGeometry.attach(window, identifier: "MergeAbortProgressWindowController")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.confirmingCancellation || sender.attachedSheet != nil { return false }
        if model.busy { model.cancel(); return false }
        return sender.attachedSheet == nil
    }
    func windowWillClose(_ notification: Notification) {
        let callback = onClosed; onClosed = {}; callback()
        if let alert = cancellationAlert {
            window?.endSheet(alert.window, returnCode: .abort); alert.window.close(); cancellationAlert = nil
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
private struct MergeAbortDialog: View {
    @ObservedObject var model: MergeAbortWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.showingProgress {
                HStack { Text(model.currentWork.isEmpty ? "Resetting HEAD…" : model.currentWork).foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red); Spacer() }
                if model.busy && model.percentage == nil { GitCommandProgressBar(percentage: nil, animate: model.progressPresentation.animateActivity) }
                else { ProgressView(value: Double(model.busy ? model.percentage ?? 0 : 100), total: 100).tint(model.busy || model.success ? Color.accentColor : Color.red) }
                SubmoduleProgressOutputView(text: model.output, completed: !model.busy, completionRange: model.completionRange, success: model.success, preferences: model.outputPreferences, clipboard: model.outputClipboard).frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    if let first = model.postActions.first {
                        Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                        Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Reset post-actions") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    Spacer()
                    if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                    else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.confirmingCancellation) }
                }
            } else {
                Text("In order to abort a merge progress a reset (to HEAD) is needed.")
                GroupBox("Reset Type") {
                    Picker("Reset Type", selection: $model.mode) {
                        Text("Merge: Resets the index and try to reconstruct the pre-merge state").tag(MergeAbortMode.merge)
                        Text("Mixed: Leave working tree untouched, reset index").tag(MergeAbortMode.mixed)
                        Text("Hard: Reset working tree and index (discard all local changes)").tag(MergeAbortMode.hard)
                    }.pickerStyle(.radioGroup).labelsHidden().padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { model.showModified() } label: { CommandLabel(title: "Show modified files in working tree", icon: .compare).frame(maxWidth: .infinity) }.disabled(model.hasChild || model.busy)
                HStack { Spacer(); Button("OK") { model.abort() }.keyboardShortcut(.defaultAction); Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction); Button("Help") { TurtleGitHelp.show(.merge) } }
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        .gitDockProgress(model.showingProgress ? .command(busy: model.busy, success: model.success, waiting: model.confirmingCancellation, percentage: model.percentage) : nil)
    }
}

@MainActor private final class MergeChildRelease {
    static private(set) var activeCount=0
    private let window:NSWindow,parent:NSWindow?
    private let closeWindow:Bool
    private var completion:()->Void
    private var observer:NSObjectProtocol?
    private var finished=false
    init(window:NSWindow,parent:NSWindow?,closeWindow:Bool=false,completion:@escaping ()->Void) {self.window=window;self.parent=parent;self.closeWindow=closeWindow;self.completion=completion}
    func start() {
        Self.activeCount += 1
        if window.sheetParent == nil && parent?.attachedSheet !== window {drain();return}
        observer=NotificationCenter.default.addObserver(forName:NSWindow.didEndSheetNotification,object:parent,queue:.main) { [self] _ in DispatchQueue.main.async {self.drain()} }
        window.sheetParent?.endSheet(window);window.orderOut(nil);DispatchQueue.main.async { [self] in drain()}
    }
    private func drain() {
        guard !finished,window.sheetParent == nil,parent?.attachedSheet !== window else{return};finished=true
        if let observer {NotificationCenter.default.removeObserver(observer);self.observer=nil}
        Self.activeCount -= 1;if closeWindow {window.close()};let done=completion;completion={};done()
    }
}
