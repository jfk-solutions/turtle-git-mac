// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of PushDlg, TortoiseGit.
import AppKit
import SwiftUI
import TurtleGitCore

/// Captured from the successful Commit attempt, before its mutable form can
/// change. The progress-menu Push command always requests the ordinary dialog.
struct CommitPushContinuation {
    enum Origin {case footer,progress}
    let origin:Origin
    let amend:Bool
}

/// PushDlg's F5 refresh belongs to this owner, never a sheet or another window.
@MainActor final class PushNativeWindow:NSWindow {
    var refreshAction:()->Void = {}
    var keyOwnerQuery:(NSWindow)->Bool = {$0.isKeyWindow}
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        if event.keyCode==96,event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
           event.window === self,keyOwnerQuery(self),attachedSheet==nil,NSApp.modalWindow==nil {
            refreshAction();return true
        }
        return super.performKeyEquivalent(with:event)
    }
}

@MainActor final class PushWindowController: NSWindowController, NSWindowDelegate {
    let model: PushWindowModel
    var onClosed: () -> Void = {}
    private var serviceRetiredSheet:NSWindow?
    var transportBatchWorkPending:Bool {serviceWorkPending}
    var serviceWorkPending:Bool {model.pendingOperations>0 || window?.attachedSheet != nil || serviceRetiredSheet?.sheetParent != nil}
    private var closingPreparation = false
    private(set) var referencePicker: ReferenceBrowserWindowController?
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    private let historyRegexExecutable: URL?
    private enum PickerKind { case source, destination, log, reflog }
    private struct PickerContext: Equatable { let values: [GitReferenceName]; let flags: [Bool] }
    private var pickerRequest: UUID?
    private var pendingPicker: (UUID, PickerContext, PickerKind, String?)?
    private weak var pickerFocus: NSResponder?
    private var pickerContext: PickerContext {
        PickerContext(values: model.submissionIdentity + [model.options.source, model.options.destination, model.options.remote, model.url].map { GitReferenceName($0) },
                      flags: [model.options.arbitraryURL, model.options.allRemotes, model.options.allBranches])
    }
    private(set) var progressController: PushProgressWindowController?
    private(set) var progressOnly=false
    private(set) var sourceLogPicker: LogWindowController?
    private(set) var sourceRefLogPicker: ReferenceLogWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, historyRegexExecutable: URL? = nil) {
        self.historyRegexExecutable = historyRegexExecutable
        model = PushWindowModel(repository: repository, access: access, preferences: preferences)
        let window = PushNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 590), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Push", preferences: preferences); window.contentMinSize = NSSize(width: 720, height: 620); window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: PushDialog(model: model).defaultAppStorage(preferences)); host.sizingOptions = []; window.contentViewController = host
        super.init(window: window); model.window=window; model.clientHooks.windowProvider = { [weak window] in window?.attachedSheet ?? window }; window.delegate = self; window.setContentSize(NSSize(width: 750, height: 620)); window.center()
        window.refreshAction = { [weak self] in self?.model.refreshFromSourceCommand() }
        model.becameIdle = { [weak self] in if self?.closingPreparation == true { self?.window?.performClose(nil) } }
        model.close = { [weak self] in guard let self, !self.model.busy, self.model.progress == nil, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        model.onProgress = { [weak self] result in
            guard let self, let window = self.window, window.attachedSheet == nil else { result.abandonPresentation(); return }
            let controller = PushProgressWindowController(owner: self.model, result: result)
            controller.onClosed = { [weak self, weak result] in guard let self, let result else { return }; self.progressController = nil; self.model.finish(result) }
            self.progressController = controller
            if let child = controller.window {
                child.alphaValue = window.alphaValue;child.appearance=window.effectiveAppearance
                if self.progressOnly {controller.showWindow(nil);child.makeKeyAndOrderFront(nil)}
                else {window.beginSheet(child)}
            } else { result.abandonPresentation() }
        }
        model.clientHooks.windowProvider = { [weak self] in
            guard let self else{return nil};let owner=self.progressController?.window ?? self.window
            return owner?.attachedSheet ?? owner
        }
        model.pickReferences = { [weak self] destination in self?.showReferencePicker(destination: destination) }
        model.pickSourceLog = { [weak self] in self?.showSourceHistory(referenceLog: false) }
        model.pickSourceRefLog = { [weak self] in self?.showSourceHistory(referenceLog: true) }
        NotificationCenter.default.addObserver(self, selector: #selector(pickerSheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        model.confirmPush = { [weak window] message, allBranches, deletion, choose in
            guard let window, window.attachedSheet == nil else { choose(false, false); return }
            let alert = Self.submissionAlert(message: message, allBranches: allBranches, deletion: deletion)
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn, alert.suppressionButton?.state == .on) }
        }
        model.sshSettings.present = { [weak self] controller in
            guard let owner = self?.progressController?.window ?? self?.window, owner.attachedSheet == nil,
                  let child = controller.window else { return false }
            owner.makeFirstResponder(nil); owner.beginSheet(child); return true
        }
        model.confirmCancellation = { [weak self] choose in
            guard let window = self?.progressController?.window ?? self?.window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "The process is still running."
            alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for: window) { [weak self] response in choose(response == .alertFirstButtonReturn); self?.model.progress?.tryAutomaticClose() }
        }

        DialogGeometry.attach(window, identifier: "PushWindowController")
    }
    /// No Push form is displayed when the successful ordinary footer already
    /// has an explicit source mapping. The existing result owner handles I/O.
    func startCommitContinuation(usePushDialog:Bool=false) {
        guard !model.closed,!model.busy,!model.confirmingQuit else{return}
        progressOnly=true;model.directContinuation=true
        model.prepareCommitContinuation(usePushDialog:usePushDialog) { [weak self] result in
            guard let self,!self.model.closed,!self.model.confirmingQuit else{return}
            switch result {
            case .success(.push(let options)):
                self.model.options=options;self.model.url=options.arbitraryURL ? options.remote:""
                self.model.sshSettings.load(self.model.settingsPreferences,key:"Push."+self.model.repository.root.path+".autoload")
                self.model.push(confirmed:true,progressBeforePreflight:true)
            case .success(.dialog):
                self.progressOnly=false;self.model.directContinuation=false;self.model.load();self.showWindow(nil);self.window?.makeKeyAndOrderFront(nil)
            case .success(.noBranch):self.close()
            case .failure(let error):
                self.progressOnly=false;self.model.directContinuation=false;self.model.preparationFailed(error)
                self.showWindow(nil);self.window?.makeKeyAndOrderFront(nil)
            }
        }
    }
    private func beginPicker() -> (UUID, PickerContext)? {
        guard let window, window.attachedSheet == nil, pickerRequest == nil, model.canChooseReference else { return nil }
        pickerFocus = (window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSResponder : $0 } ?? window.firstResponder
        let request = UUID(), context = pickerContext; pickerRequest = request; model.choosingReference = true
        return (request, context)
    }
    private func finishPicker(_ request: UUID, context: PickerContext, kind: PickerKind, value: String?) {
        guard pickerRequest == request, !model.closed else { return }
        referencePicker = nil; sourceLogPicker = nil; sourceRefLogPicker = nil
        pendingPicker = (request, context, kind, value); pickerSheetEnded()
    }
    @objc private func pickerSheetEnded() {
        guard let window, window.attachedSheet == nil, let (request, context, kind, value) = pendingPicker,
              pickerRequest == request, !model.closed else { return }
        pendingPicker = nil; pickerRequest = nil; model.choosingReference = false
        if let focus = pickerFocus { window.makeFirstResponder(focus) }; pickerFocus = nil
        guard context == pickerContext, !model.preparing, !model.busy, let value else { return }
        switch kind {
        case .source: model.pick(CheckoutReference(name: value, symbolicTarget: nil), destination: false)
        case .destination: model.pick(CheckoutReference(name: value, symbolicTarget: nil), destination: true)
        case .log, .reflog: model.chooseSourceRevision(value)
        }
    }
    func showReferencePicker(destination: Bool) {
        guard let (request, context) = beginPicker(), let window else { return }
        let initial = destination ? RemoteTrackingSelection.initialReference(remote: model.options.remote, branch: model.options.destination) : model.options.source
        let picker = ReferenceBrowserWindowController(repository: model.repository, access: model.repositoryAccess, initial: initial,
            preferences: model.settingsPreferences, scope: destination ? .remotes : .headsAndTags) { [weak self] value in
                self?.finishPicker(request, context: context, kind: destination ? .destination : .source, value: value)
            }
        referencePicker = picker; configureReferencePicker(picker.model)
        if let child = picker.window { child.alphaValue = window.alphaValue; window.beginSheet(child) }
        picker.model.load()
    }
    func showSourceHistory(referenceLog: Bool) {
        guard let (request, context) = beginPicker(), let window else { return }
        if referenceLog {
            let child = ReferenceLogWindowController(repository: model.repository, access: model.repositoryAccess, reference: "HEAD", onChoose: { [weak self] entry in
                self?.finishPicker(request, context: context, kind: .reflog, value: entry?.hash)
            }, preferences: model.settingsPreferences)
            sourceRefLogPicker = child
            if let sheet = child.window { sheet.alphaValue = window.alphaValue; window.beginSheet(sheet) }
        } else {
            let revision = FetchDialogHistory.trim(model.options.source)
            let child = LogWindowController(repository: model.repository, access: model.repositoryAccess, onChoose: { [weak self] entry in
                self?.finishPicker(request, context: context, kind: .log, value: entry?.hash)
            }, labelDefaults: model.settingsPreferences, savesGeometry: model.settingsPreferences === UserDefaults.standard,
               initialRevision: revision.isEmpty ? nil : revision, historyRegexExecutable: historyRegexExecutable)
            child.model.allBranches = false; child.model.showWorkingTree = false; child.model.historyPaths = []; child.model.showWholeProject = true
            sourceLogPicker = child; configureLogPicker(child.model)
            if let sheet = child.window { sheet.alphaValue = window.alphaValue; window.beginSheet(sheet) }
        }
    }
    static func submissionAlert(message: String, allBranches: Bool, deletion: Bool) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = deletion ? .warning : .informational
        alert.messageText = message
        let yes = alert.addButton(withTitle: "Yes"), no = alert.addButton(withTitle: "No")
        if allBranches {
            yes.keyEquivalent = ""; no.keyEquivalent = "\r"; alert.window.defaultButtonCell = no.cell as? NSButtonCell
            alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Don't show this message again"
        } else { yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell }
        return alert
    }
    func windowWillClose(_ notification: Notification) {
        serviceRetiredSheet=window?.attachedSheet
        (window as? PushNativeWindow)?.refreshAction = {}
        NotificationCenter.default.removeObserver(self); pickerRequest = nil; pendingPicker = nil; pickerFocus = nil
        model.invalidate(); referencePicker?.abandonPresentation(); referencePicker = nil; progressController?.close(); progressController = nil
        let logPicker = sourceLogPicker, refLogPicker = sourceRefLogPicker
        sourceLogPicker = nil; sourceRefLogPicker = nil
        for child in [logPicker?.window, refLogPicker?.window].compactMap({ $0 }) {
            child.sheetParent?.endSheet(child)
            child.close()
        }
        if serviceWorkPending {
            Task { [self] in
                while serviceWorkPending {try? await Task.sleep(nanoseconds:20_000_000)}
                onClosed()
            }
        } else {onClosed()}
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.confirmingQuit else { return false }
        if model.preparing { closingPreparation = true; model.cancelPreparation(); return false }
        if model.progress != nil { if model.transportRunning { model.cancel() }; return false }
        guard model.transportRunning else { return !model.busy && sender.attachedSheet == nil }
        model.cancel(); return false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class PushWindowModel: ObservableObject {
    static var activePreparationReads = 0
    private(set) var pendingOperations=0
    static var activePushWorkflows = 0
    let repository: GitRepository
    let sshSettings: SSHTransportSettings
    private var invalidated = false
    var directContinuation=false
    func invalidate() {
        clientHooks.retire(); invalidated = true; formRevision = UUID(); confirmationRequest = nil; choosingReference = false; generation += 1
        metadataToken?.cancel(); sourceToken?.cancel(); cancellation?.cancel()
        progress?.invalidate(); progress = nil; busy = false; preparingSource = false; confirmation = nil
        becameIdle = {}; close = {}
    }
    weak var window:NSWindow?
    var closed: Bool { invalidated }
    private var metadataToken: OperationCancellation?
    private var sourceToken: OperationCancellation?
    @Published private(set) var preparingSource = false
    var preparing: Bool { metadataToken != nil || preparingSource }
    var becameIdle: () -> Void = {}
    @Published private(set) var preparationNeedsRetry = false
    private var metadataLoaded = false
    private var loadPresetSource: String?
    private var loadPresetPreserveAll = false
    private var retryRemoteCatalog = false
    func retryPreparation() {
        guard !closed, !confirmingQuit, !busy, !preparing else { return }
        if retryRemoteCatalog { refreshRemoteCatalog() } else if !metadataLoaded { load(source: loadPresetSource, preserveAllBranches: loadPresetPreserveAll) } else { sourceChanged() }
    }
    private func validateRepositoryAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private let access: RepositoryAccessLease?
    var repositoryAccess: RepositoryAccessLease? { access }
    var settingsPreferences: UserDefaults { preferences }
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    lazy var clientHooks = ClientHookSession(preferences: preferences)
    private var postHookFailure: String?
    @Published private(set) var formRevision = UUID()
    @Published var confirmingQuit=false { didSet { if confirmingQuit != oldValue { formRevision=UUID() } } }
    var canRefresh:Bool { !closed && !confirmingQuit && !busy && !preparing && !choosingReference && !managingRemotes && confirmation==nil && progress==nil && window?.attachedSheet==nil && NSApp.modalWindow==nil }
    func refreshFromSourceCommand() {
        guard canRefresh else{return}
        if metadataLoaded {refreshRemoteCatalog()} else {load(source:loadPresetSource,preserveAllBranches:loadPresetPreserveAll)}
    }
    private var confirmationRequest: UUID?
    @Published var options = PushOptions()
    @Published var remotes: [String] = []
    @Published var references: [CheckoutReference] = []
    @Published var localBranch: String?
    @Published var busy = false
    @Published private(set) var progress: PushProgressWindowModel?
    var onProgress: ((PushProgressWindowModel) -> Void)?
    var onPostAction: ((PushPostAction, PushOptions, URL?) -> Void)?
    func finish(_ result: PushProgressWindowModel) {
        guard progress === result, !result.busy, !confirmingCancellation else { return }
        progress = nil; result.invalidate(); busy = false; formRevision = UUID(); if let postHookFailure,!directContinuation { error = postHookFailure;return };error=nil;close()
    }
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    private var cancellation: OperationCancellation?
    var transportRunning: Bool { cancellation != nil }
    var canCancel: Bool { !invalidated && !confirmingQuit && !choosingReference && (preparing || !busy || transportRunning && !cancelling && !confirmingCancellation) }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    @Published var url = ""
    @Published var urls: [String] = []
    @Published var destinationHistory: [String] = []
    @Published var pushOptionHistory: [String] = []
    @Published var managingRemotes = false { didSet { if managingRemotes != oldValue { formRevision = UUID() } } }
    @Published var error: String?
    @Published var confirmation: String?
    var confirmPush: (String, Bool, Bool, @escaping (Bool, Bool) -> Void) -> Void = { _, _, _, _ in }
    @Published var choosingReference = false { didSet { if choosingReference != oldValue { formRevision = UUID() } } }
    var canChooseReference: Bool { !invalidated && !confirmingQuit && !busy && !preparing && !choosingReference && !preparationNeedsRetry && !options.allBranches && confirmation == nil && progress == nil }
    var pickReferences: (Bool) -> Void = { _ in }
    func browseReferences(destination: Bool) { guard canChooseReference else { return }; pickReferences(destination) }
    var clipboardText: () -> String? = { NSPasteboard.general.string(forType: .string) ?? NSPasteboard.general.string(forType: .fileURL) }
    var close: () -> Void = {}
    var onPushed: (String) -> Void = { _ in }
    var onTransportResult: (String, Bool) -> Void = { _, _ in }
    var pickSourceLog: () -> Void = {}
    var pickSourceRefLog: () -> Void = {}
    private var generation = 0
    private var key: String { "Push." + repository.root.path }
    var urlHistoryKey: String { "History.PushURLS." + repository.root.path }
    var destinationHistoryKey: String { "History.RemoteBranch." + repository.root.path }
    var pushOptionHistoryKey: String { "History.PushOption." + repository.root.path }
    var submodulePreferenceKey: String { "History.PushRecurseSubmodules." + repository.root.path }
    // PushDlg gates these controls on source text, independently of whether
    // Git resolves it to a branch, tag or selected Log/RefLog revision. Only
    // actual local branches receive remembered configuration during execution.
    var canSave: Bool { !options.arbitraryURL && !options.allRemotes && !options.allBranches && !FetchDialogHistory.trim(options.source).isEmpty && !options.setUpstream }
    var canTrack: Bool { !options.arbitraryURL && (options.allBranches || !FetchDialogHistory.trim(options.source).isEmpty) }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; self.preferences = preferences; sshSettings = SSHTransportSettings(repository: repository) }
    func preparationFailed(_ error:Error) {guard !invalidated else{return};preparationNeedsRetry=true;self.error=error.localizedDescription}
    func prepareCommitContinuation(usePushDialog:Bool=false,_ completion:@escaping(Result<CommitPushContinuationPlan,Error>)->Void) {
        guard !invalidated,!confirmingQuit,!busy,!preparing,progress==nil else{return}
        let token=OperationCancellation();metadataToken=token;busy=true
        Self.activePreparationReads += 1;pendingOperations += 1
        Task { [self,access] in
            defer{Self.activePreparationReads -= 1;pendingOperations -= 1;withExtendedLifetime(access){}}
            let result:Result<CommitPushContinuationPlan,Error>
            do {try validateRepositoryAccess();result = .success(try await repository.commitPushContinuationPlan(usePushDialog:usePushDialog,cancellation:token))}
            catch {result = .failure(error)}
            guard !invalidated,metadataToken===token else{return}
            metadataToken=nil;busy=false
            if !token.isCancelled,!confirmingQuit {completion(result)}
            becameIdle()
        }
    }
    func load(source: String? = nil, preserveAllBranches: Bool = false) {
        guard !invalidated, !confirmingQuit, !busy, progress == nil else { return }
        retryRemoteCatalog = false
        formRevision = UUID(); loadPresetSource = source; loadPresetPreserveAll = preserveAllBranches
        sourceToken?.cancel(); generation += 1
        busy = true; error = nil; preparationNeedsRetry = false
        let token = OperationCancellation(); metadataToken = token; Self.activePreparationReads += 1; pendingOperations += 1
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        Task { [self, access] in
            defer {
                Self.activePreparationReads -= 1; pendingOperations -= 1
                if metadataToken === token { metadataToken = nil; busy = false; if !invalidated { becameIdle() } }
                withExtendedLifetime(access) {}
            }
            do {
                try validateRepositoryAccess()
                let names = try await repository.remoteNames(cancellation: token)
                let refs = try await repository.checkoutReferences(cancellation: token)
                let current = try await repository.branch(cancellation: token)
                var snapshot = PushOptions()
                snapshot.source = PushSourcePresentation.normalized(source ?? (current.isEmpty ? "HEAD" : current))
                snapshot.allBranches = (source == nil || preserveAllBranches) && preferences.bool(forKey: key + ".allBranches")
                snapshot.allRemotes = names.count > 1 && preferences.bool(forKey: key + ".allRemotes")
                snapshot.submodules = try await repository.pushSubmoduleDefault(cancellation: token)
                if let stored = preferences.object(forKey: submodulePreferenceKey) as? NSNumber,
                   PushSubmodules.allCases.indices.contains(stored.intValue) { snapshot.submodules = PushSubmodules.allCases[stored.intValue] }
                let defaults = try await repository.pushDefaults(source: snapshot.source, cancellation: token)
                snapshot.remote = defaults.remote; snapshot.destination = defaults.destination; snapshot.setUpstream = defaults.setUpstream
                if snapshot.remote.isEmpty, let saved = preferences.string(forKey: key + ".remote"), names.contains(where:{GitReferenceName.equal($0,saved)}) { snapshot.remote = saved }
                try token.check(); guard !invalidated, metadataToken === token else { return }
                remotes = names; references = refs; options = snapshot; localBranch = defaults.localBranch
                sshSettings.load(preferences, key: key + ".autoload")
                urls = FetchDialogHistory.load(preferences, key: urlHistoryKey, caseSensitive: true)
                pushOptionHistory = FetchDialogHistory.load(preferences, key: pushOptionHistoryKey, caseSensitive: true)
                url = ""; loadDestination(defaults.destination); metadataLoaded = true; preparationNeedsRetry = false
            } catch { if !invalidated, metadataToken === token { preparationNeedsRetry = true; self.error = error.localizedDescription } }
        }
    }
    /// Refresh after the remote manager without resetting the user's operation draft.
    func refreshRemoteCatalog() {
        guard !invalidated, !confirmingQuit, !busy, progress == nil else { return }
        formRevision = UUID(); sourceToken?.cancel(); generation += 1
        let snapshot = options, token = OperationCancellation()
        metadataToken = token; busy = true; error = nil; preparationNeedsRetry = false; retryRemoteCatalog = true
        Self.activePreparationReads += 1; pendingOperations += 1
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        Task { [self, access] in
            defer {
                Self.activePreparationReads -= 1; pendingOperations -= 1
                if metadataToken === token { metadataToken = nil; busy = false; if !invalidated { becameIdle() } }
                withExtendedLifetime(access) {}
            }
            do {
                try validateRepositoryAccess()
                let names = try await repository.remoteNames(cancellation: token)
                let refs = try await repository.checkoutReferences(cancellation: token)
                let defaults = try await repository.pushDefaults(source: snapshot.source, cancellation: token)
                try token.check(); guard !invalidated, metadataToken === token else { return }
                remotes = names; references = refs; localBranch = defaults.localBranch
                if !snapshot.arbitraryURL, !names.contains(where:{GitReferenceName.equal($0,snapshot.remote)}) {
                    options.remote = names.contains(where:{GitReferenceName.equal($0,defaults.remote)}) ? defaults.remote : names.first ?? ""
                }
                if names.count < 2 { options.allRemotes = false }
                metadataLoaded = true; retryRemoteCatalog = false; adjustSettings()
            } catch { if !invalidated, metadataToken === token { preparationNeedsRetry = true; self.error = error.localizedDescription } }
        }
    }
    struct FormContext: Equatable {
        let owner: ObjectIdentifier; let revision: UUID; let base: [GitReferenceName]
    }
    var formContext: FormContext { .init(owner:ObjectIdentifier(self),revision:formRevision,base:[options.source,options.remote,String(options.arbitraryURL),String(options.allRemotes),String(options.allBranches)].map { GitReferenceName($0) }) }
    var canEditSource: Bool { !closed && !confirmingQuit && !busy && metadataToken == nil && metadataLoaded && !choosingReference && !managingRemotes && confirmation == nil && progress == nil && window?.attachedSheet==nil && NSApp.modalWindow==nil }
    var canEditForm: Bool { canEditSource && !preparingSource && !preparationNeedsRetry }
    func accepts(_ context: FormContext, source: Bool = false) -> Bool {
        context.owner == ObjectIdentifier(self) && context.revision == formRevision && (source ? canEditSource : canEditForm && context == formContext)
    }
    var submissionIdentity: [GitReferenceName] {
        [options.source,options.destination,options.remote,url,options.pushOption,String(options.arbitraryURL),String(options.allRemotes),String(options.allBranches),String(options.forceWithLease),String(options.force),String(options.includeTags),String(options.setUpstream),String(options.savePushRemote),String(options.savePushBranch),String(describing:options.submodules),String(sshSettings.enabled)].map { GitReferenceName($0) }
    }
    func option<Value>(_ key: WritableKeyPath<PushOptions,Value>, context: FormContext) -> Binding<Value> {
        Binding(get:{self.options[keyPath:key]},set:{value in
            if key == \PushOptions.source {
                guard self.accepts(context,source:true), !self.options.allBranches else { return }
                self.options[keyPath:key] = value; self.sourceChanged(); return
            }
            guard self.accepts(context) else { return }
            if key == \PushOptions.destination, self.options.allBranches { return }
            if key == \PushOptions.forceWithLease, self.options.force || self.options.includeTags { return }
            if key == \PushOptions.force || key == \PushOptions.includeTags, self.options.forceWithLease { return }
            if key == \PushOptions.setUpstream, !self.canTrack || self.options.savePushRemote || self.options.savePushBranch { return }
            if key == \PushOptions.savePushRemote || key == \PushOptions.savePushBranch, !self.canSave { return }
            self.options[keyPath:key] = value; self.adjustSettings()
        })
    }
    func urlBinding(_ context: FormContext) -> Binding<String> { Binding(get:{self.url},set:{if self.accepts(context),self.options.arbitraryURL {self.url=$0}}) }
    func remoteBinding(_ context: FormContext) -> Binding<String> {
        Binding(get:{self.options.allRemotes ? "*" : self.options.remote},set:{value in
            guard self.accepts(context),!self.options.arbitraryURL else {return}
            self.options.allRemotes = value == "*"; if value != "*" {self.options.remote=value};self.adjustSettings()
        })
    }
    func selectMode(arbitrary: Bool, context: FormContext) {
        guard accepts(context) else {return}; if arbitrary {selectArbitraryURL()} else {options.arbitraryURL=false;adjustSettings()}
    }
    func manage(_ context: FormContext) {guard accepts(context),!options.arbitraryURL else{return};managingRemotes=true}
    func deleteHistory(_ kind: Int, at index: Int, context: FormContext, entries: [String]) {
        guard accepts(context) else{return}
        let current = kind == 0 ? urls : kind == 1 ? destinationHistory : pushOptionHistory
        guard current.map({GitReferenceName($0)}) == entries.map({GitReferenceName($0)}) else{return}
        if kind == 0 {guard options.arbitraryURL else{return};deleteURLHistory(at:index)}
        else if kind == 1 {guard !options.allBranches else{return};deleteDestinationHistory(at:index)}
        else {deletePushOptionHistory(at:index)}
    }
    func browseSourceHistory(referenceLog: Bool) {
        guard canChooseReference else { return }
        if referenceLog { pickSourceRefLog() } else { pickSourceLog() }
    }
    func configureSourceLog(_ log: LogWindowModel) {
        let source = FetchDialogHistory.trim(options.source)
        log.endRevision = source.isEmpty ? nil : source
        log.allBranches = false; log.showWorkingTree = false; log.historyPaths = []; log.showWholeProject = true
        log.reload()
    }
    func chooseSourceRevision(_ hash: String?) {
        guard !invalidated, !busy, !choosingReference, let hash, !hash.isEmpty else { return }
        options.source = hash; sourceChanged()
    }
    func sourceChanged() {
        guard !invalidated, !busy, progress == nil, confirmation == nil else { return }
        retryRemoteCatalog = false
        generation += 1; let request = generation, source = options.source
        sourceToken?.cancel(); sourceToken = nil
        guard !FetchDialogHistory.trim(source).isEmpty else { preparingSource = false; preparationNeedsRetry = false; localBranch = nil; adjustSettings(); becameIdle(); return }
        let token = OperationCancellation(); sourceToken = token; preparingSource = true; preparationNeedsRetry = false
        Self.activePreparationReads += 1; pendingOperations += 1
        Task { [self, access] in
            defer {
                Self.activePreparationReads -= 1; pendingOperations -= 1
                if sourceToken === token { sourceToken = nil; preparingSource = false; if !invalidated { becameIdle() } }
                withExtendedLifetime(access) {}
            }
            do {
                try validateRepositoryAccess()
                let defaults = try await repository.pushDefaults(source: source, cancellation: token)
                guard !invalidated, sourceToken === token, !token.isCancelled, request == generation,
                      options.source.utf8.elementsEqual(source.utf8), !busy else { return }
                localBranch = defaults.localBranch; loadDestination(defaults.destination)
                if !options.arbitraryURL, !options.allRemotes { options.remote = defaults.remote }
                options.setUpstream = defaults.setUpstream; preparationNeedsRetry = false; adjustSettings()
            } catch { if !invalidated, sourceToken === token, request == generation { preparationNeedsRetry = true; self.error = error.localizedDescription } }
        }
    }
    func cancelPreparation() { if preparing { preparationNeedsRetry = true }; metadataToken?.cancel(); sourceToken?.cancel() }
    func adjustSettings() {
        if !canTrack { options.setUpstream = false }
        if !canSave { options.savePushRemote = false; options.savePushBranch = false }
    }
    private func loadDestination(_ destination: String) {
        destinationHistory = FetchDialogHistory.load(preferences, key: destinationHistoryKey, caseSensitive: false)
        options.destination = ""
        if !destination.isEmpty { selectDestination(destination, atFront: false) }
    }
    func selectDestination(_ destination: String, atFront: Bool = true) {
        destinationHistory = FetchDialogHistory.inserting(destination, into: destinationHistory, atFront: atFront, caseSensitive: false)
        let normalized = FetchDialogHistory.trim(destination.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))
        options.destination = destinationHistory.first { $0.compare(normalized, options: .caseInsensitive) == .orderedSame } ?? destination
    }
    func deleteURLHistory(at index: Int) {
        guard !invalidated, !busy, !preparing, !choosingReference, confirmation == nil, let result = FetchDialogHistory.removing(index, entries: urls, preferences: preferences, key: urlHistoryKey) else { return }
        urls = result.entries; url = result.selection
    }
    func deleteDestinationHistory(at index: Int) {
        guard !invalidated, !busy, !preparing, !choosingReference, confirmation == nil, let result = FetchDialogHistory.removing(index, entries: destinationHistory, preferences: preferences, key: destinationHistoryKey) else { return }
        destinationHistory = result.entries; options.destination = result.selection
    }
    func deletePushOptionHistory(at index: Int) {
        guard !invalidated, !busy, !preparing, !choosingReference, confirmation == nil, let result = FetchDialogHistory.removing(index, entries: pushOptionHistory, preferences: preferences, key: pushOptionHistoryKey) else { return }
        pushOptionHistory = result.entries; options.pushOption = result.selection
    }
    func selectArbitraryURL() {
        options.arbitraryURL = true; options.allRemotes = false
        if let input = clipboardText().flatMap({ FetchClipboardInput.selection($0, isPull: true) }) {
            url = input.url; if let branch = input.branch { options.destination = branch }
        } else { url = urls.first ?? "" }
        adjustSettings()
    }
    private func saveHistories(_ snapshot: PushOptions) {
        // PushDlg excludes all-branch submissions and remote deletions from URL/branch history.
        if !snapshot.allBranches && !(snapshot.source.isEmpty && !snapshot.destination.isEmpty) {
            if snapshot.arbitraryURL { urls = FetchDialogHistory.save(snapshot.remote, entries: urls, preferences: preferences, key: urlHistoryKey, caseSensitive: true) }
            destinationHistory = FetchDialogHistory.save(snapshot.destination, entries: destinationHistory, preferences: preferences, key: destinationHistoryKey, caseSensitive: false)
            // PushDlg remembers its selected remote in the same non-removal
            // branch as URL/destination history. A one-off deletion or an
            // all-branches push must not replace the next ordinary default.
            if !snapshot.arbitraryURL && !snapshot.allRemotes { preferences.set(snapshot.remote, forKey: key + ".remote") }
        }
        pushOptionHistory = FetchDialogHistory.save(snapshot.pushOption, entries: pushOptionHistory, preferences: preferences, key: pushOptionHistoryKey, caseSensitive: true)
    }
    func cancel() {
        guard !invalidated, !confirmingQuit else { return }
        if preparing { cancelPreparation(); return }
        if let progress, !progress.busy { progress.close(); return }
        guard busy else { close(); return }
        guard let token = cancellation, !cancelling, !confirmingCancellation else { return }
        func stop() { cancelling = true; token.cancel() }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] proceed in
                guard let self, self.cancellation === token else { return }
                self.confirmingCancellation = false
                if proceed { self.cancelling = true; token.cancel() }
            }
        } else { stop() }
    }
    private func askToPush(_ message: String, allBranches: Bool, deletion: Bool) {
        formRevision = UUID(); let request = UUID(), draft = submissionIdentity; confirmationRequest = request; confirmation = message
        confirmPush(message, allBranches, deletion) { [weak self] proceed, remember in
            guard let self, !self.invalidated, self.confirmationRequest == request, self.confirmation != nil else { return }
            self.confirmationRequest = nil; self.confirmation = nil
            guard self.submissionIdentity == draft else { return }
            // PushDlg explicitly remembers Yes even when this invocation chose No.
            if allBranches && remember { self.preferences.set(true, forKey: "PushAllBranches") }
            if proceed { self.push(confirmed: true) }
        }
    }
    func push(confirmed: Bool = false,progressBeforePreflight:Bool=false) {
        guard !choosingReference else { return }
        guard !invalidated, !confirmingQuit, !busy, !preparing, !preparationNeedsRetry, progress == nil, confirmed || confirmation == nil else { return }
        if !confirmed {
            let source = FetchDialogHistory.trim(options.source), destination = FetchDialogHistory.trim(options.destination)
            if options.allBranches && !preferences.bool(forKey: "PushAllBranches") {
                askToPush("Do you really want to push all local branches?", allBranches: true, deletion: false); return
            }
            if !options.allBranches && source.isEmpty {
                askToPush(destination.isEmpty ? "The local branch name and the remote branch name are empty.\nContinue?" : "The local branch/tag name is empty. This results in a remote removal.\nContinue?", allBranches: false, deletion: !destination.isEmpty); return
            }
        }
        formRevision = UUID(); confirmationRequest = nil; confirmation = nil; postHookFailure = nil
        var snapshot = options
        snapshot.showBranchRevisionNumber = preferences.bool(forKey: "ShowBranchRevisionNumber")
        snapshot.source = FetchDialogHistory.trim(snapshot.source); snapshot.destination = FetchDialogHistory.trim(snapshot.destination)
        if snapshot.arbitraryURL { snapshot.remote = FetchDialogHistory.trim(url) }
        let sshFactory = sshSettings.capture()
        let token = OperationCancellation(); cancellation = token; cancelling = false; error = nil
        busy = true; Self.activePushWorkflows += 1; pendingOperations += 1
        Task { [self, access] in
            let earlyResult:PushProgressWindowModel?
            if progressBeforePreflight,let onProgress {
                let captured=makeProgress(snapshot,cancellation:token,superproject:nil)
                earlyResult=captured;progress=captured;onProgress(captured)
            } else {earlyResult=nil}
            defer { Self.activePushWorkflows -= 1; pendingOperations -= 1; withExtendedLifetime(access) {}; cancellation = nil; cancelling = false; confirmingCancellation = false; if !invalidated { busy = progress != nil } }
            do {
                try validateRepositoryAccess()
                try await repository.validatePushOptions(snapshot, cancellation: token)
                guard !token.isCancelled else { throw OperationCancellationFailure.cancelled }
                guard !invalidated else { return }
                _ = try await clientHooks.run(.prePush, repository: repository, access: access, cancellation: token, allowContinue: true)
                guard !invalidated else{return};try token.check()
                if !progressBeforePreflight {
                saveHistories(snapshot); sshSettings.save(preferences, key: key + ".autoload")
                preferences.set(snapshot.allBranches, forKey: key + ".allBranches")
                preferences.set(!snapshot.arbitraryURL && snapshot.allRemotes, forKey: key + ".allRemotes")
                preferences.set(PushSubmodules.allCases.firstIndex(of: snapshot.submodules)!, forKey: submodulePreferenceKey)
                }
                let result: PushProgressWindowModel?
                if let earlyResult {
                    let parentText=((try? await repository.run(["rev-parse","--show-superproject-working-tree"],cancellation:token).text) ?? "").trimmingCharacters(in:.newlines)
                    try token.check();guard !invalidated else{return}
                    earlyResult.installSuperproject(parentText.isEmpty ? nil:URL(fileURLWithPath:parentText));result=earlyResult
                }
                else if let onProgress {
                    let parentText = ((try? await repository.run(["rev-parse", "--show-superproject-working-tree"], cancellation: token).text) ?? "").trimmingCharacters(in: .newlines)
                    try token.check(); guard !invalidated else { return }
                    let parent = parentText.isEmpty ? nil : URL(fileURLWithPath: parentText)
                    let captured = makeProgress(snapshot,cancellation:token,superproject:parent)
                    progress = captured; result = captured; onProgress(captured)
                } else { result = nil }
                do {
                let output = try await runPush(snapshot, cancellation: token, result: result, sshFactory: sshFactory)
                guard !token.isCancelled else { throw OperationCancellationFailure.cancelled }
                cancellation = nil; cancelling = false; confirmingCancellation = false
                guard !invalidated else { return }
                do { try await runPostPushHook() }
                catch { postHookFailure = "The push succeeded, but its post-push hook failed.\n\n" + error.localizedDescription; if !directContinuation {self.error = postHookFailure} }
                guard !invalidated else { return }
                onTransportResult(output, true); onPushed(output)
                if let result { result.complete(output: directContinuation ? output:output + (postHookFailure.map { "\n" + $0 } ?? ""), success: true, cancelled: false,completionWarning:directContinuation ? postHookFailure:nil) }
                else if postHookFailure == nil { close() }
                } catch {
                    cancellation = nil; cancelling = false; confirmingCancellation = false
                    guard !invalidated else { return }
                    do { try await runPostPushHook() }
                    catch { postHookFailure = "The post-push hook also failed.\n\n" + error.localizedDescription }
                    guard !invalidated else { return }
                    onTransportResult(error.localizedDescription, false)
                    if let result { result.complete(output: error.localizedDescription + (postHookFailure.map { "\n" + $0 } ?? ""), success: false, cancelled: token.isCancelled, failure: error as? PushExecutionFailure) }
                    else { self.error = error.localizedDescription + (postHookFailure.map { "\n" + $0 } ?? "") }
                }
            }
            catch {
                guard !invalidated else{return}
                onTransportResult(error.localizedDescription,false)
                if let earlyResult {earlyResult.complete(output:error.localizedDescription,success:false,cancelled:token.isCancelled)}
                else {self.error=error.localizedDescription}
            }
        }
    }
    private func makeProgress(_ snapshot:PushOptions,cancellation token:OperationCancellation,superproject:URL?)->PushProgressWindowModel {
        let captured=PushProgressWindowModel(options:snapshot,superproject:superproject,preferences:preferences)
        captured.close = { [weak self,weak captured] in guard let captured else{return};self?.finish(captured) }
        captured.cancelWithoutPresenter={token.cancel()}
        captured.onPostAction = { [weak self,weak captured] action in
            guard let self,let captured else{return};self.onPostAction?(action,captured.options,captured.superproject)
        }
        return captured
    }
    private func runPostPushHook() async throws {
        guard !invalidated else { return }
        let token = OperationCancellation(); cancellation = token
        defer { if cancellation === token { cancellation = nil; cancelling = false; confirmingCancellation = false } }
        _ = try await clientHooks.run(.postPush, repository: repository, access: access, cancellation: token)
    }
    private func runPush(_ snapshot: PushOptions, cancellation: OperationCancellation, result: PushProgressWindowModel?, sshFactory: SSHTransportFactory?) async throws -> String {
        let coordinator = sshFactory?(); defer { coordinator?.close() }; let preparation = coordinator?.preparation
        guard let result else { return try await repository.push(snapshot, cancellation: cancellation, prepareTransport: preparation) }
        let parser = GitCliOutputParser(limit: result.outputLimit)
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let operation = Task {
            defer { continuation.finish() }
            return try await repository.push(snapshot, cancellation: cancellation, onOutput: { chunk in
                parser.appendChunk(chunk.data); continuation.yield(())
            }, prepareTransport: preparation)
        }
        for await _ in updates { result.consume(parser.processPending(), parser: parser) }
        result.consume(parser.processPending(), parser: parser); result.consume(parser.finish(), parser: parser)
        return try await operation.value
    }
    func pick(_ reference: CheckoutReference, destination: Bool) {
        guard !invalidated, !busy, !choosingReference, progress == nil else { return }
        if !destination {
            guard reference.name.utf8.starts(with: "refs/heads/".utf8) || reference.name.utf8.starts(with: "refs/tags/".utf8) else { return }
            options.source = PushSourcePresentation.normalized(reference.name); sourceChanged() }
        else {
            guard let selection = RemoteTrackingSelection(reference: reference.name, remotes: remotes) else { return }
            options.remote = selection.remote; selectDestination(selection.branch); options.arbitraryURL = false; options.allRemotes = false
        }
    }
}

private struct PushDialog: View {
    @ObservedObject var model: PushWindowModel
    var body: some View {
        let context = model.formContext
        let urlEntries = model.urls, destinationEntries = model.destinationHistory, optionEntries = model.pushOptionHistory
        VStack(spacing: 14) {
            Group {
            GroupBox("Ref") { VStack(alignment: .leading, spacing: 8) {
                Toggle("Push all branches", isOn: model.option(\.allBranches,context:context))
                HStack { Text("Local:").frame(width: 115, alignment: .leading); PushRefCombo(value: model.option(\.source,context:context), choices: ["HEAD"] + model.references.filter { $0.name.hasPrefix("refs/heads/") || $0.remote }.map(\.name), local: true, normalizeSource: true)
                    Menu {
                        Button { if model.accepts(context) { model.browseReferences(destination:false) } } label: { CommandLabel(title: "Browse References", icon: .repositoryBrowser) }
                        Button { if model.accepts(context) { model.browseSourceHistory(referenceLog:false) } } label: { CommandLabel(title: "Log", icon: .log) }
                        Button { if model.accepts(context) { model.browseSourceHistory(referenceLog:true) } } label: { CommandLabel(title: "RefLog", icon: .log) }
                    } label: { Text("…") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Choose local source using references, Log or RefLog")
                }.disabled(model.options.allBranches)
                HStack { Text("Remote:").frame(width: 115, alignment: .leading); FetchHistoryCombo(value: model.option(\.destination,context:context), choices: model.destinationHistory, label: "Remote branch or tag", onDelete: { model.deleteHistory(1,at:$0,context:context,entries:destinationEntries) })
                    Button("…") { if model.accepts(context) { model.browseReferences(destination:true) } }.accessibilityLabel("Browse remote references")
                }.disabled(model.options.allBranches || model.preparingSource)
            }.padding(8) }
            GroupBox("Destination") { VStack(spacing: 8) {
                HStack { PushDestinationRadio(title: "Remote:", selected: !model.options.arbitraryURL) { model.selectMode(arbitrary:false,context:context) }.frame(width: 115)
                    PushRemotePopup(values: [""] + (model.remotes.count > 1 ? ["*"] : []) + model.remotes,
                        selection: model.remoteBinding(context)).disabled(model.options.arbitraryURL)
                    Button("Manage") { model.manage(context) }.disabled(model.options.arbitraryURL)
                }
                HStack { PushDestinationRadio(title: "Arbitrary URL:", selected: model.options.arbitraryURL) { model.selectMode(arbitrary:true,context:context) }.frame(width: 115)
                    FetchHistoryCombo(value: model.urlBinding(context), choices: model.urls, label: "Destination URL or path", onDelete: { model.deleteHistory(0,at:$0,context:context,entries:urlEntries) }).disabled(!model.options.arbitraryURL)
                }
            }.padding(8) }.disabled(model.preparingSource)
            GroupBox("Options") { VStack(alignment: .leading, spacing: 8) {
                HStack { Toggle("Force with lease", isOn: model.option(\.forceWithLease,context:context)).disabled(model.options.force || model.options.includeTags)
                    Toggle("Force", isOn: model.option(\.force,context:context)).disabled(model.options.forceWithLease); Spacer() }
                Toggle("Include Tags", isOn: model.option(\.includeTags,context:context)).disabled(model.options.forceWithLease)
                SSHAutoloadToggle(settings: model.sshSettings)
                Toggle("Set upstream/track remote branch", isOn: model.option(\.setUpstream,context:context)).disabled(!model.canTrack || model.options.savePushRemote || model.options.savePushBranch)
                Toggle("Always push to the selected remote archive for this local branch", isOn: model.option(\.savePushRemote,context:context)).disabled(!model.canSave)
                Toggle("Always push to the selected remote branch for this local branch", isOn: model.option(\.savePushBranch,context:context)).disabled(!model.canSave)
                HStack { Text("Recurse submodule").frame(width: 155, alignment: .leading); Picker("Recurse submodule", selection: model.option(\.submodules,context:context)) { Text("None").tag(PushSubmodules.none); Text("Check").tag(PushSubmodules.check); Text("On-demand").tag(PushSubmodules.onDemand) }.labelsHidden(); Spacer() }
                HStack { Text("Push option:").frame(width: 155, alignment: .leading); FetchHistoryCombo(value: model.option(\.pushOption,context:context), choices: model.pushOptionHistory, label: "Push option", onDelete: { model.deleteHistory(2,at:$0,context:context,entries:optionEntries) }) }
            }.padding(8) }.disabled(model.preparingSource)
            }.disabled(model.busy || model.choosingReference || model.confirmation != nil || model.managingRemotes)
            Spacer(minLength: 0)
            HStack { if model.busy || model.preparingSource { ProgressView().controlSize(.small) }; if model.preparationNeedsRetry { Button("Retry loading", action: model.retryPreparation).disabled(model.busy || model.preparing) }; Spacer()
                Button("OK") { model.push() }.keyboardShortcut(.defaultAction).disabled(model.busy || model.preparing || model.choosingReference || model.preparationNeedsRetry)
                Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel)
                Button("Help") { TurtleGitHelp.show(.push) }
            }
        }.padding(16).disabled(model.confirmingQuit)
        .alert("Push failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.managingRemotes) { PushRemoteSettings(model: model) }
    }
}
struct PushDestinationRadio: NSViewRepresentable {
    let title: String; let selected: Bool; let select: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { ReferenceChoiceButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:))) }
    func updateNSView(_ button: NSButton, context: Context) { button.state = selected ? .on : .off; button.isEnabled = enabled && (button as? ReferenceChoiceButton)?.retired != true; context.coordinator.select = select }
    static func dismantleNSView(_ button:NSButton,coordinator:Coordinator) {coordinator.live=false;button.isEnabled=false;button.target=nil;button.action=nil}
    final class Coordinator: NSObject {var live=true;var select:()->Void={};@objc func clicked(_ sender:NSButton) {guard live,sender.isEnabled,sender.window != nil else{return};select()}}
}

struct PushRefCombo: NSViewRepresentable {
    @Binding var value: String
    let choices: [String]
    let local: Bool
    var normalizeSource = false
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = EditableHistoryCombo(); combo.delegate = context.coordinator; combo.completes = true
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal); return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        if let owned=combo as? EditableHistoryCombo,owned.lifetime.retired {owned.delegate=nil;owned.isEnabled=false;return}
        let coordinator = context.coordinator; coordinator.updating = true
        defer { coordinator.updating = false }
        coordinator.local = local; coordinator.change = { value = $0 }
        var seen=Set<GitReferenceName>();let values=choices.map { normalizeSource ? PushSourcePresentation.normalized($0) : $0 }.filter {seen.insert(GitReferenceName($0)).inserted}.sorted {$0.utf8.lexicographicallyPrecedes($1.utf8)}; let labels = values.map { local && $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 }
        if coordinator.values.map({GitReferenceName($0)}) != values.map({GitReferenceName($0)}) { combo.removeAllItems(); combo.addItems(withObjectValues: labels) }
        coordinator.values = values; coordinator.labels = labels
        let display = !normalizeSource && local && value.hasPrefix("refs/heads/") ? String(value.dropFirst(11)) : value
        if !GitReferenceName.equal(combo.stringValue,display) { combo.stringValue = display }
        combo.isEnabled = enabled && (combo as? EditableHistoryCombo)?.lifetime.retired != true; combo.setAccessibilityLabel(local ? "Local ref or revision" : "Remote branch or tag")
    }
    static func dismantleNSView(_ combo:NSComboBox,coordinator:Coordinator) {coordinator.live=false;(combo as? EditableHistoryCombo)?.lifetime.retire();combo.delegate=nil;combo.isEnabled=false}
    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        var live=true
        func accepts(_ combo:NSComboBox)->Bool {live && combo.isEnabled && combo.window != nil && (combo as? EditableHistoryCombo)?.lifetime.retired != true}
        var values: [String] = [], labels: [String] = []; var local = false, updating = false
        var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) {
            guard !updating, let combo = notification.object as? NSComboBox, accepts(combo) else { return }
            let text = combo.stringValue; change(labels.firstIndex(where:{GitReferenceName.equal($0,text)}).map { values[$0] } ?? text)
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !updating, let combo = notification.object as? NSComboBox, accepts(combo), values.indices.contains(combo.indexOfSelectedItem) else { return }; change(values[combo.indexOfSelectedItem])
        }
    }
}
struct PushRemotePopup: NSViewRepresentable {
    let values: [String]
    @Binding var selection: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = TransportRemotePopup(frame: .zero, pullsDown: false); button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:)); button.setContentHuggingPriority(.defaultLow, for: .horizontal); return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        if let owned=button as? TransportRemotePopup,owned.lifetime.retired {owned.target=nil;owned.action=nil;owned.isEnabled=false;return}
        if context.coordinator.values.map({GitReferenceName($0)}) != values.map({GitReferenceName($0)}) || button.numberOfItems == 0 { button.removeAllItems(); for value in values {button.menu?.addItem(NSMenuItem(title:value == "*" ? "– All –" : value.isEmpty ? "Choose remote" : value,action:nil,keyEquivalent:""))} }
        context.coordinator.values = values; context.coordinator.change = { selection = $0 }
        if let index = values.firstIndex(where:{GitReferenceName.equal($0,selection)}) { button.selectItem(at: index) }
        button.isEnabled = enabled && (button as? TransportRemotePopup)?.lifetime.retired != true; button.setAccessibilityLabel("Remote archive")
    }
    static func dismantleNSView(_ button:NSPopUpButton,coordinator:Coordinator) {coordinator.live=false;(button as? TransportRemotePopup)?.lifetime.retire();button.target=nil;button.action=nil;button.isEnabled=false}
    @MainActor final class Coordinator: NSObject {var live=true; var values: [String] = []; var change: (String) -> Void = { _ in }
        @objc func changed(_ sender: NSPopUpButton) { guard live,sender.isEnabled,sender.window != nil,(sender as? TransportRemotePopup)?.lifetime.retired != true,values.indices.contains(sender.indexOfSelectedItem) else { return }; change(values[sender.indexOfSelectedItem]) }
    }
}

/// PushDlg normalizes initial/local-browser branches, while retaining tag/hash identity.
/// Other consumers of PushRefCombo keep their existing qualified-reference behavior.
enum PushSourcePresentation {
    static func normalized(_ source: String) -> String {
        if source.hasPrefix("refs/heads/") { return String(source.dropFirst(11)) }
        if source.hasPrefix("refs/remotes/") { return String(source.dropFirst(5)) }
        return source
    }
}

// DoPush's retained result and ordered success/rejection follow-ups.
enum PushPostAction: String, Hashable {
    case requestPull, push, switchBranch, commitSuperproject, pull, fetch
    var title: String { switch self { case .requestPull: return "Create pull request"; case .push: return "Push…"; case .switchBranch: return "Switch/Checkout…"; case .commitSuperproject: return "Commit super project"; case .pull: return "Pull…"; case .fetch: return "Fetch…" } }
    var icon: MenuIcon { switch self { case .requestPull: return .unifiedDiff; case .push: return .push; case .switchBranch: return .checkout; case .commitSuperproject: return .commit; case .pull: return .pull; case .fetch: return .fetch } }
}
@MainActor final class PushProgressWindowModel: ObservableObject {
    let progressPresentation: GitCommandPresentation
    let options: PushOptions
    private(set) var superproject: URL?
    func installSuperproject(_ value:URL?){guard busy,!invalidated else{return};superproject=value}
    private let autoClosePolicy: GitProgressAutoClose
    private var invalidated = false, dispatched = false, abandoned = false, automaticCloseRequested = false
    @Published private(set) var busy = true
    @Published private(set) var output = ""
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var hasCompletionWarning=false
    @Published private(set) var postActions: [PushPostAction] = []
    @Published private(set) var percentage: Int?
    @Published private(set) var currentWork = ""
    let outputLimit: Int
    private var displayedBytes = Data(), displayTruncated = false
    var close: () -> Void = {}
    var cancelWithoutPresenter: () -> Void = {}
    var onPostAction: ((PushPostAction) -> Void)?
    init(options: PushOptions, superproject: URL?, preferences: UserDefaults = .standard) { self.options = options; self.superproject = superproject; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences); progressPresentation = GitCommandPresentation(defaults: preferences); outputLimit = progressPresentation.outputLimit }
    func invalidate() { invalidated = true }
    func abandonPresentation() { abandoned = true; cancelWithoutPresenter(); if !busy { close() } }
    func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        guard !invalidated, !displayTruncated else { return }
        if emission.erasePreviousLineBytes > 0 { displayedBytes.removeLast(min(displayedBytes.count, emission.erasePreviousLineBytes)) }
        displayedBytes.append(emission.data)
        output = String(decoding: displayedBytes, as: UTF8.self).replacingOccurrences(of: "\u{1b}\\[[0-9;]*m|\u{1b}\\[K", with: "", options: .regularExpression)
        for line in String(decoding: emission.data, as: UTF8.self).split(separator: "\n") {
            guard let colon = line.lastIndex(of: ":"), let percent = line.firstIndex(of: "%") else { continue }
            currentWork = String(line[..<colon])
            let digits = line[..<percent].reversed().prefix { $0.isASCII && $0.isNumber }.reversed()
            if let value = Int(String(digits)), value > 0 { percentage = min(value, 100) }
        }
        if emission.limited || displayedBytes.count >= outputLimit {
            displayTruncated = true; parser.activateDropMode()
            currentWork = "[Output truncated at about \(displayedBytes.count / 1024) KiB]"; percentage = nil
            output += "\n\n...\n" + currentWork
        }
    }
    func complete(output: String, success: Bool, cancelled: Bool, failure: PushExecutionFailure? = nil,completionWarning:String?=nil) {
        guard busy else { return }
        if success {
            if displayedBytes.isEmpty {self.output=GitProgressFailureOutput.renderDetails(output,existing:"",limit:outputLimit)}
        } else if let failure {
            let context=(failure.completed.isEmpty ? "":"Completed: "+failure.completed.joined(separator:", ")+".\n")+"Push to \(failure.failedRemote) failed."
            if let command=failure.commandFailure {self.output=GitProgressFailureOutput.render(command,existing:self.output,limit:outputLimit,context:context)}
            else {self.output=GitProgressFailureOutput.renderDetails(failure.details,existing:self.output,limit:outputLimit,status:context,preferTail:true)}
        } else {
            self.output=GitProgressFailureOutput.renderDetails(output,existing:self.output,limit:outputLimit,status:cancelled ? "Operation cancelled.":"",preferTail:true)
        }
        if success,let completionWarning,!completionWarning.isEmpty {
            hasCompletionWarning=true
            let pieces=completionWarning.components(separatedBy:"\n\n"),summary=pieces.first ?? completionWarning
            let detail=pieces.count>1 ? pieces.dropFirst().joined(separator:"\n\n"):""
            self.output=GitProgressFailureOutput.renderDetails(detail,existing:self.output,limit:outputLimit,status:summary,preferTail:true)
        }
        self.success = success; self.cancelled = cancelled
        if success { postActions = [.requestPull, .push, .switchBranch]; if superproject != nil { postActions.append(.commitSuperproject) } }
        else {
            // Native transport uses --porcelain, where the ! flag and [rejected]
            // reason are separated by a refspec. Remote hook rejection differs.
            let rejected = output.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("!") && $0.contains("[rejected]") }
            postActions = rejected ? [.pull, .fetch, .push] : [.push]
        }
        busy = false
        if abandoned || !hasCompletionWarning && autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { automaticCloseRequested = true; tryAutomaticClose() }
    }
    func tryAutomaticClose() { if automaticCloseRequested, !busy, !invalidated { close() } }
    func perform(_ action: PushPostAction) {
        guard !busy, !invalidated, !dispatched, postActions.contains(action), let onPostAction else { return }
        dispatched = true; close(); onPostAction(action)
    }
}
@MainActor final class PushProgressWindowController: NSWindowController, NSWindowDelegate {
    let pushModel: PushWindowModel
    let result: PushProgressWindowModel
    var onClosed: () -> Void = {}
    init(owner: PushWindowModel, result: PushProgressWindowModel) {
        self.pushModel = owner; self.result = result
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:760,height:430), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
        RepositoryWindowTitles.set(window, repository: owner.repository.root, dialog: "Push", preferences: owner.presentationPreferences); window.minSize = NSSize(width:650,height:320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:PushProgressDialog(owner:owner,result:result))
        super.init(window:window); window.delegate = self
        result.close = { [weak self] in guard let self, !self.result.busy, !self.pushModel.confirmingCancellation, self.window?.attachedSheet == nil else { return }; if let window = self.window { window.sheetParent?.endSheet(window); window.close() } }

        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if result.busy { pushModel.cancel(); return false }; guard !pushModel.confirmingCancellation, sender.attachedSheet == nil else { return false }; sender.sheetParent?.endSheet(sender); return true }
    func windowWillClose(_ notification: Notification) { ProgressActionLog.record(owner: result, repository: pushModel.repository.root, output: result.output, cancelled: result.cancelled); result.invalidate(); onClosed() }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
}
struct PushProgressDialog: View {
    @ObservedObject var owner: PushWindowModel
    @ObservedObject var result: PushProgressWindowModel
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            ScrollViewReader { reader in
                ScrollView { VStack(alignment:.leading,spacing:0) { Text(result.output).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading); Color.clear.frame(height:1).id("push-output-end") } }
                    .onChange(of: result.output) { _ in reader.scrollTo("push-output-end",anchor:.bottom) }
            }.frame(maxWidth:.infinity,maxHeight:.infinity).padding(8).background(Color(nsColor:.textBackgroundColor))
            if result.busy, let percentage = result.percentage { ProgressView(value:Double(percentage),total:100).tint(.green) }
            if !result.currentWork.isEmpty { Text(result.currentWork).font(.caption).lineLimit(2) }
            HStack { if result.busy && result.percentage == nil { GitCommandActivity(animate: result.progressPresentation.animateActivity) }; Text(result.busy ? owner.cancelling ? "Cancelling…" : "Pushing…" : result.cancelled ? "Cancelled" : result.success ? "Finished" : "Push failed").foregroundStyle(result.busy ? Color.primary : result.success ? Color.green : Color.red); Spacer() }
            HStack {
                if let first = result.postActions.first {
                    Button { result.perform(first) } label: { CommandLabel(title:first.title,icon:first.icon) }
                    Menu { ForEach(result.postActions,id:\.self) { action in Button { result.perform(action) } label: { CommandLabel(title:action.title,icon:action.icon) } } } label: { Image(systemName:"chevron.down").accessibilityLabel("Push post-actions") }.menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                if result.busy { Button(owner.cancelling ? "Cancelling…" : "Cancel") { owner.cancel() }.keyboardShortcut(.cancelAction).disabled(!owner.canCancel) }
                else { if !result.success { Button("Cancel") { result.close() }.keyboardShortcut(.cancelAction) }; Button("Close") { result.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(owner.confirmingCancellation)
        }.padding(12)
        .gitDockProgress(.command(busy: result.busy, success: result.success, waiting: owner.confirmingCancellation, percentage: result.percentage))
    }
}
