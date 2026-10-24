// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of PullFetchDlg, TortoiseGit.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FetchWindowController: NSWindowController, NSWindowDelegate {
    let model: FetchWindowModel
    static var activeProgressReleases: Int { TransportProgressRelease.activeCount }
    var onClosed: () -> Void = {}
    private var serviceDrainChecks:[()->Bool]=[]
    var transportBatchWorkPending:Bool {serviceWorkPending}
    var serviceWorkPending:Bool {model.pendingOperations>0 || serviceDrainChecks.contains{$0()} || window?.attachedSheet != nil}
    var presentPullProgress: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; child.alphaValue = owner.alphaValue; child.appearance = owner.appearance; owner.beginSheet(child); return true }
    private(set) var remoteReferenceController: RemoteReferenceWindowController?
    var configureRemoteReferences: (RemoteReferenceWindowController) -> Void = { _ in }
    var presentRemoteReferences: (NSWindow,NSWindow) -> Bool = { owner,child in guard owner.attachedSheet == nil else { return false }; child.alphaValue = owner.alphaValue; child.appearance = owner.appearance; owner.beginSheet(child); return true }
    private var remotePickerRequest: UUID?
    private var remotePickerCompletion: (() -> Void)?
    private weak var remotePickerFocus: NSResponder?
    private var closingPreparation = false
    private var rebasePresentation: (parent: NSWindow?, visible: Bool)?
    private(set) var progressController: PullProgressWindowController?
    var presentFetchProgress: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; child.alphaValue = owner.alphaValue; child.appearance = owner.appearance; owner.beginSheet(child); return true }
    private(set) var fetchProgressController: FetchProgressWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?, isPull: Bool = false, preferences: UserDefaults = .standard) {
        model = FetchWindowModel(repository: repository, access: access, isPull: isPull, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "\(isPull ? "Pull" : "Fetch")", preferences: preferences); window.contentMinSize = NSSize(width: 660, height: 440); window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: FetchDialog(model: model).defaultAppStorage(preferences)); host.sizingOptions = []; window.contentViewController = host
        super.init(window: window); model.window=window; window.delegate = self; window.setContentSize(NSSize(width:700,height:480)); window.center()
        model.becameIdle = { [weak self] in if self?.closingPreparation == true { self?.window?.performClose(nil) } }
        model.close = { [weak self] in guard let self, !self.model.confirmingQuit, !self.model.busy, !self.model.browsing, !self.model.preparingRemote, self.model.progress == nil, self.model.fetchProgress == nil, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        model.onProgress = { [weak self] progress in
            guard let self else { progress.invalidate(); return }
            guard let window = self.window, window.attachedSheet == nil else { self.model.abandonPullPresentation(progress); return }
            let controller = PullProgressWindowController(model: progress)
            controller.onClosed = { [weak self, weak progress, weak controller] in
                guard let self, let progress, let controller, self.progressController === controller else { return }
                self.progressController = nil; self.model.finish(progress)
            }
            self.progressController = controller
            guard let child = controller.window, self.presentPullProgress(window, child) else { self.progressController = nil; self.model.abandonPullPresentation(progress); controller.close(); return }
        }
        model.onFetchProgress = { [weak self] progress in
            guard let self else { progress.invalidate(); return }
            guard let window = self.window, window.attachedSheet == nil else { self.model.abandonFetchPresentation(progress); return }
            let controller = FetchProgressWindowController(model: progress)
            controller.onClosed = { [weak self, weak progress, weak controller] in
                guard let self, let progress, let controller, self.fetchProgressController === controller else { return }
                self.fetchProgressController = nil; self.model.finishFetch(progress)
            }
            self.fetchProgressController = controller
            guard let child = controller.window, self.presentFetchProgress(window, child) else {
                self.fetchProgressController = nil; self.model.abandonFetchPresentation(progress); controller.close(); return
            }
        }
        model.sshSettings.present = { [weak self] controller in
            guard let self, let owner = self.fetchProgressController?.window ?? self.progressController?.window ?? self.window,
                  owner.attachedSheet == nil, let child = controller.window else { return false }
            owner.makeFirstResponder(nil); child.alphaValue = owner.alphaValue; child.appearance = owner.appearance; owner.beginSheet(child); return true
        }
        model.beforeOwnedRebase = { [weak self] in
            guard let self, let window = self.window else { return }
            self.rebasePresentation = (window.sheetParent, window.isVisible)
        }
        model.recoverOwnedRebase = { [weak self] in await self?.restoreRebasePresentation() }
        model.onBrowseRemote = { [weak self] remote in self?.showRemoteReferences(remote) }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "The process is still running."
            alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.window.alphaValue = window.alphaValue; alert.window.appearance = window.appearance
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(remotePickerSheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        DialogGeometry.attach(window, identifier: "FetchWindowController")
    }
    private func restoreRebasePresentation() async {
        guard !model.closed, let window, let original = rebasePresentation,
              let progress = fetchProgressController?.window else { return }
        let chain: [(NSWindow,NSWindow)] = original.parent.map { [($0,window),(window,progress)] } ?? [(window,progress)]
        for (parent,child) in chain {
            guard !model.closed else { return }
            if child.sheetParent === parent && parent.attachedSheet === child { continue }
            // endSheet animations may still own attachedSheet after the handoff
            // callback has returned its failure. Reattach only after actual drain.
            await withCheckedContinuation { continuation in
                let release = TransportProgressRelease(window: child, parent: parent) { continuation.resume() }
                release.start()
            }
            guard !model.closed, parent.attachedSheet == nil else { return }
            child.alphaValue = parent.alphaValue; child.appearance = parent.appearance; parent.beginSheet(child, completionHandler: nil)
        }
        if original.parent == nil && original.visible { window.orderFront(nil) }
    }
    @objc private func remotePickerSheetEnded() {
        guard let window, window.attachedSheet == nil, !model.closed, let completion = remotePickerCompletion else { return }
        remotePickerCompletion = nil; remotePickerRequest = nil; model.browsing = false
        if let focus = remotePickerFocus { window.makeFirstResponder(focus) }; remotePickerFocus = nil
        completion()
    }
    func showRemoteReferences(_ remote: String) {
        guard !model.closed, remoteReferenceController == nil, remotePickerRequest == nil, let owner = window, owner.attachedSheet == nil else {
            if remotePickerRequest == nil { model.browsing = false }; return
        }
        let request = UUID(), branch = model.options.branch, arbitrary = model.options.arbitraryURL, allRemotes = model.options.allRemotes, draft = model.submissionIdentity
        remotePickerRequest = request; model.browsing = true
        remotePickerFocus = (owner.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSResponder : $0 } ?? owner.firstResponder
        let child = RemoteReferenceWindowController(repository: model.repository, access: model.repositoryAccess, remote: remote, preferences: model.settingsPreferences) { [weak self] choice in
            guard let self, self.remotePickerRequest == request, !self.model.closed else { return }
            self.remoteReferenceController = nil
            self.remotePickerCompletion = { [weak self] in
                guard let self, !self.model.closed, self.model.currentRemoteDestination.utf8.elementsEqual(remote.utf8),
                      self.model.options.branch.utf8.elementsEqual(branch.utf8), self.model.options.arbitraryURL == arbitrary,
                      self.model.options.allRemotes == allRemotes, self.model.submissionIdentity == draft, let choice else { return }
                self.model.selectBranch(choice)
            }
            self.remotePickerSheetEnded()
        }
        child.makeSSH = model.sshSettings.capture(); configureRemoteReferences(child); remoteReferenceController = child
        guard let window = child.window else { child.close(); return }
        window.alphaValue = owner.alphaValue; window.appearance = owner.appearance
        guard presentRemoteReferences(owner, window) else { child.close(); return }
        child.model.refresh()
    }
    func windowWillClose(_ notification: Notification) {
        // Forced owner retirement can precede cancellation settlement. Retain
        // the exact workers/sheets, rather than waiting on unrelated dialogs.
        if let child=progressController {serviceDrainChecks.append{child.model.pendingOperations>0 || child.window?.sheetParent != nil}}
        if let child=fetchProgressController {serviceDrainChecks.append{child.model.pendingOperations>0 || child.notificationFiles.busy || child.window?.sheetParent != nil}}
        NotificationCenter.default.removeObserver(self); remotePickerRequest = nil; remotePickerCompletion = nil; remotePickerFocus = nil
        if let child=model.remoteManagerModel {serviceDrainChecks.append{child.hasPendingWork}}
        model.invalidate(); remoteReferenceController?.close(); remoteReferenceController = nil
        let fetch = fetchProgressController; fetchProgressController = nil; fetch?.close()
        let pull = progressController; progressController = nil; pull?.close()
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }
        onClosed()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.confirmingQuit else { return false }
        if model.preparing { closingPreparation = true; model.cancelPreparation(); return false }
        if model.progress != nil || model.fetchProgress != nil { if model.transportRunning { model.cancel() }; return false }
        guard model.transportRunning else { return !model.busy && sender.attachedSheet == nil }
        model.cancel(); return false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class FetchWindowModel: ObservableObject {
    static var activePreparationReads = 0
    private(set) var pendingOperations=0
    static var activeProgressOperations: Int { PullProgressWindowModel.activeOperations + FetchProgressWindowModel.activeOperations }
    let repository: GitRepository
    private(set) var acceptedOperationRepository:GitRepository?
    let isPull: Bool
    let sshSettings: SSHTransportSettings
    let remoteSettings: PushWindowModel
    private let access: RepositoryAccessLease?
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    weak var window:NSWindow?
    struct RemoteManagerReceipt:Equatable {let id:UUID,owner:ObjectIdentifier,window:ObjectIdentifier?,draft:[GitReferenceName]}
    private(set) var remoteManagerReceipt:RemoteManagerReceipt?
    private(set) var remoteManagerModel:RemoteSettingsWindowModel?
    private weak var remoteManagerWindow:NSWindow?
    private var retryManagerReceipt:RemoteManagerReceipt?
    var readRefreshDefaults:((OperationCancellation)async throws->([String],FetchDefaults))?
    @Published var urls: [String] = []
    @Published var branchHistory: [String] = []
    @Published private(set) var formRevision = UUID()
    @Published var options = FetchOptions()
    @Published var squash = false
    @Published var noCommit = false
    @Published var noFastForward = false
    @Published var fastForwardOnly = false
    @Published var rebaseRequired = false
    private var preserveMerges = false
    @Published var remotes: [String] = []
    @Published var branches: [String] = []
    @Published var url = ""
    @Published var depthEnabled = false
    @Published var depth = "1"
    @Published var shallow = false
    @Published var bare = false
    @Published var launchRebase = false
    @Published var tagsDefault = ""
    @Published var pruneDefault = ""
    @Published var busy = false
    @Published var confirmingQuit = false { didSet {
        if confirmingQuit != oldValue { formRevision = UUID() }
        progress?.confirmingQuit = confirmingQuit; fetchProgress?.confirmingQuit = confirmingQuit
    } }
    var cancelling: Bool { progress?.cancelling ?? fetchProgress?.cancelling ?? false }
    var confirmingCancellation: Bool { progress?.confirmingCancellation ?? fetchProgress?.confirmingCancellation ?? false }
    @Published private(set) var progress: PullProgressWindowModel?
    @Published private(set) var fetchProgress: FetchProgressWindowModel?
    var onFetchProgress: ((FetchProgressWindowModel) -> Void)?
    var onNotificationLog:RemoteProgressLogHandler = {_,_,_,_,_ in}
    var onFetchPostAction: ((FetchPostAction, String) -> Void)?
    var followUp = PullFollowUp()
    var onProgress: ((PullProgressWindowModel) -> Void)?
    var onPullPostAction: ((PullPostAction, PullProgressContext) -> Void)?
    var onChanged: (String) -> Void = { _ in }
    private var metadataToken: OperationCancellation?
    private var remoteToken: OperationCancellation?
    @Published private(set) var preparingRemote = false
    var preparing: Bool { metadataToken != nil || preparingRemote }
    var becameIdle: () -> Void = {}
    @Published private(set) var preparationNeedsRetry = false
    private var metadataLoaded = false
    private var loadPresetRemote: String?
    private var loadPresetAllRemotes: Bool?
    func retryPreparation() {
        guard !closed, !confirmingQuit, !busy, !preparing else { return }
        if let receipt=retryManagerReceipt {refreshAfterRemoteManager(receipt)} else if !metadataLoaded { load(remote: loadPresetRemote, allRemotes: loadPresetAllRemotes) } else { remoteChanged() }
    }
    private var invalidated = false
    private var completedPresentation = false
    var closed: Bool { invalidated }
    var operationActive: Bool { remoteManagerModel != nil || confirmingQuit || preparationNeedsRetry || busy || preparingRemote || browsing || progress != nil || fetchProgress != nil }
    func invalidate() {
        invalidated = true; remoteManagerReceipt=nil;retryManagerReceipt=nil;remoteManagerModel?.invalidate();remoteManagerModel=nil;remoteManagerWindow=nil;formRevision = UUID(); generation += 1; metadataToken?.cancel(); metadataToken = nil; remoteToken?.cancel(); remoteToken = nil
        remoteSettings.invalidate(); preparingRemote = false; becameIdle = {}; close = {}
        fetchProgress?.invalidate(); fetchProgress = nil; progress?.invalidate(); progress = nil; busy = false; browsing = false; managing = false
    }
    func abandonPullPresentation(_ result: PullProgressWindowModel) { guard progress === result else { return }; result.invalidate(); progress = nil; busy = false }
    func abandonFetchPresentation(_ result: FetchProgressWindowModel) { guard fetchProgress === result else { return }; result.invalidate(); fetchProgress = nil; busy = false }
    func finish(_ result: PullProgressWindowModel) {
        guard !invalidated, progress === result, !result.busy, !result.confirmingConflictHint, !result.confirmingCancellation, !result.dispatchingAction else { return }
        completedPresentation = true; progress = nil; error = nil; result.invalidate(); close()
    }
    func finishFetch(_ result: FetchProgressWindowModel) {
        guard !invalidated, fetchProgress === result, !result.busy, !result.confirmingCancellation, !result.confirmingRebaseDecision, !result.dispatchingAction else { return }
        completedPresentation = true; fetchProgress = nil; error = nil; result.invalidate(); close()
    }
    var transportRunning: Bool { progress?.busy ?? fetchProgress?.busy ?? false }
    var canCancel: Bool { !invalidated && !confirmingQuit && (preparing || (progress?.canCancel ?? fetchProgress?.canCancel ?? !busy)) }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    @Published var error: String?
    @Published var browsing = false { didSet { if browsing != oldValue { formRevision = UUID() } } }
    @Published var managing = false { didSet { if managing != oldValue { formRevision = UUID() } } }
    var clipboardText: () -> String? = { NSPasteboard.general.string(forType: .string) ?? NSPasteboard.general.string(forType: .fileURL) }
    var close: () -> Void = {}
    var onShowStatus: () -> Void = {}
    var onFetched: (String) -> Void = { _ in }
    var onRebase: (String, Bool, Bool) -> Void = { _, _, _ in }
    var onOwnedRebase: ((String, Bool, Bool) async throws -> Void)?
    var beforeOwnedRebase: () -> Void = {}
    var recoverOwnedRebase: () async -> Void = {}
    private var generation = 0
    private var key: String { (isPull ? "Pull." : "Fetch.") + repository.root.path }
    var configuredRebase: Bool { isPull && rebaseRequired && !options.arbitraryURL }
    var canChooseBranch: Bool { launchRebase || isPull || options.arbitraryURL || (!options.namedRemoteFetchAll && !options.allRemotes) }
    init(repository: GitRepository, access: RepositoryAccessLease?, isPull: Bool, preferences: UserDefaults = .standard) {
        self.isPull = isPull; self.repository = repository; self.access = access; self.preferences = preferences; sshSettings = SSHTransportSettings(repository: repository); remoteSettings = PushWindowModel(repository: repository, access: access, preferences: preferences)
    }
    private func validateRepositoryAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load(remote presetRemote: String? = nil, allRemotes presetAllRemotes: Bool? = nil) {
        guard !invalidated, !confirmingQuit, !busy, !preparingRemote, !browsing, progress == nil, fetchProgress == nil else { return }; formRevision = UUID(); busy = true; error = nil; preparationNeedsRetry = false
        loadPresetRemote = presetRemote; loadPresetAllRemotes = presetAllRemotes
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
                let defaults = try await repository.fetchDefaults(cancellation: token)
                let pullDefaults = try await repository.pullDefaults(cancellation: token)
                var snapshot = FetchOptions()
                snapshot.remote = defaults.trackedRemote.isEmpty ? (preferences.string(forKey:key+".remote") ?? ""):defaults.trackedRemote
                let matched=names.contains(where:{GitReferenceName.equal($0,snapshot.remote)})
                snapshot.allRemotes = !isPull && names.count>1 && !matched
                if !matched {snapshot.remote=names.first ?? ""}
                let history = FetchDialogHistory.load(preferences, key: "History.PullRemoteBranch", caseSensitive: true)
                snapshot.branch = defaults.branch.isEmpty ? history.first ?? "" : defaults.branch
                snapshot.namedRemoteFetchAll = preferences.object(forKey: "NamedRemoteFetchAll") as? Bool ?? true
                var tags = defaults.tags, prune = defaults.prune, targetURL = ""
                var rebase = !defaults.bare && !snapshot.allRemotes && (isPull && pullDefaults.rebase || preferences.bool(forKey: key + ".rebase"))
                if let presetRemote, !presetRemote.isEmpty {
                    if names.contains(where:{GitReferenceName.equal($0,presetRemote)}) {
                        snapshot.remote = presetRemote; snapshot.arbitraryURL = false; snapshot.allRemotes = false
                        let preset = try await repository.fetchDefaults(remote: presetRemote, cancellation: token)
                        tags = preset.tags; prune = preset.prune
                    } else { snapshot.arbitraryURL = true; snapshot.allRemotes = false; targetURL = presetRemote; rebase = false }
                }
                if !isPull, let presetAllRemotes { snapshot.allRemotes = presetAllRemotes; if presetAllRemotes { snapshot.arbitraryURL = false; rebase = false } }
                if snapshot.allRemotes {tags="";prune=""}
                else if !snapshot.arbitraryURL,!snapshot.remote.isEmpty,!GitReferenceName.equal(snapshot.remote,defaults.remote) {
                    let selected=try await repository.fetchDefaults(remote:snapshot.remote,cancellation:token);tags=selected.tags;prune=selected.prune
                }
                try token.check(); guard !invalidated, metadataToken === token else { return }
                remotes = names; options = snapshot; url = targetURL
                urls = FetchDialogHistory.load(preferences, key: "History.PullURLS", caseSensitive: true)
                branchHistory = history; selectBranch(snapshot.branch, atFront: false)
                sshSettings.load(preferences, key: key + ".autoload")
                shallow = defaults.shallow; bare = defaults.bare; depthEnabled = defaults.shallow
                tagsDefault = tags; pruneDefault = prune; rebaseRequired = isPull && pullDefaults.rebase
                preserveMerges = isPull && pullDefaults.preserveMerges; launchRebase = rebase
                fastForwardOnly = isPull && preferences.bool(forKey: key + ".ffonly")
                squash = false; noCommit = false; noFastForward = false; remoteSettings.remotes = names; metadataLoaded = true; preparationNeedsRetry = false
            } catch { if !invalidated, metadataToken === token { preparationNeedsRetry = true; self.error = error.localizedDescription } }
        }
    }
    struct FormContext: Equatable { let owner: ObjectIdentifier; let revision: UUID; let base: [GitReferenceName] }
    var formContext: FormContext { .init(owner:ObjectIdentifier(self),revision:formRevision,base:[options.remote,String(options.arbitraryURL),String(options.allRemotes)].map { GitReferenceName($0) }) }
    var canEditForm: Bool { !closed && !operationActive && !managing && metadataLoaded }
    func accepts(_ context: FormContext) -> Bool { canEditForm && context == formContext }
    var submissionIdentity: [GitReferenceName] { [options.remote,options.branch,url,depth,String(options.arbitraryURL),String(options.allRemotes),String(options.namedRemoteFetchAll),String(options.tags.rawValue),String(options.prune.rawValue),String(depthEnabled),String(squash),String(noCommit),String(noFastForward),String(fastForwardOnly),String(launchRebase),String(sshSettings.enabled)].map { GitReferenceName($0) } }
    func option<Value>(_ key: WritableKeyPath<FetchOptions,Value>, context: FormContext) -> Binding<Value> {
        Binding(get:{self.options[keyPath:key]},set:{value in
            guard self.accepts(context) else{return}
            if key == \FetchOptions.branch, !self.canChooseBranch {return}
            self.options[keyPath:key]=value
        })
    }
    func field<Value>(_ key: ReferenceWritableKeyPath<FetchWindowModel,Value>, context: FormContext) -> Binding<Value> {
        Binding(get:{self[keyPath:key]},set:{value in
            guard self.accepts(context) else{return}
            if key == \FetchWindowModel.url, !self.options.arbitraryURL {return}
            if key == \FetchWindowModel.depth, !self.shallow || !self.depthEnabled {return}
            if key == \FetchWindowModel.depthEnabled, !self.shallow {return}
            if key == \FetchWindowModel.squash || key == \FetchWindowModel.noCommit || key == \FetchWindowModel.noFastForward || key == \FetchWindowModel.fastForwardOnly {
                guard self.isPull && !self.launchRebase else{return}
            }
            if key == \FetchWindowModel.noFastForward, self.fastForwardOnly {return}
            if key == \FetchWindowModel.fastForwardOnly, self.noFastForward {return}
            if key == \FetchWindowModel.launchRebase, self.bare || self.options.allRemotes || self.options.arbitraryURL || self.configuredRebase {return}
            self[keyPath:key]=value
        })
    }
    func remoteBinding(_ context: FormContext) -> Binding<String> {
        Binding(get:{self.options.allRemotes ? "*" : self.options.remote},set:{value in
            guard self.accepts(context), !self.options.arbitraryURL else{return}
            self.options.allRemotes = !self.isPull && value == "*"
            if self.options.allRemotes {self.launchRebase=false} else {self.options.remote=value}
            self.remoteChanged()
        })
    }
    func selectMode(arbitrary: Bool, context: FormContext) {
        guard accepts(context) else{return}
        if arbitrary {selectArbitraryURL()} else {options.arbitraryURL=false;launchRebase=rebaseRequired;remoteChanged()}
    }
    func manage(_ context: FormContext) {
        guard accepts(context),window?.attachedSheet==nil,NSApp.modalWindow==nil else{return}
        let receipt=RemoteManagerReceipt(id:UUID(),owner:ObjectIdentifier(self),window:window.map(ObjectIdentifier.init),draft:submissionIdentity)
        let child=RemoteSettingsWindowModel(repository:repository,access:access,preferences:preferences,noFetch:true)
        remoteManagerReceipt=receipt;remoteManagerModel=child
        child.close={ [weak self] in self?.closeRemoteManager(receipt) };managing=true
    }
    func remoteManagerAttached(_ receipt:RemoteManagerReceipt,_ child:NSWindow) {
        guard !closed,remoteManagerReceipt==receipt,child !== window else{return};remoteManagerWindow=child
    }
    func closeRemoteManager(_ receipt:RemoteManagerReceipt) {
        guard !closed,remoteManagerReceipt==receipt else{return};managing=false
    }
    func remoteManagerReturned(_ receipt:RemoteManagerReceipt) {
        guard !closed,remoteManagerReceipt==receipt,let child=remoteManagerModel else{return}
        // The actual embedded child supplies this captured receipt after retiring
        // its native controls. Wait only for that child's workers/sheet ownership.
        let childWindow=remoteManagerWindow
        pendingOperations += 1
        Task { [self,child,childWindow,access] in
            defer{pendingOperations -= 1;withExtendedLifetime(access){}}
            while child.hasPendingWork || childWindow.map({$0.sheetParent != nil || window?.attachedSheet === $0})==true {if closed {return};try? await Task.sleep(nanoseconds:5_000_000)}
            guard !closed,remoteManagerReceipt==receipt,remoteManagerModel === child else{return}
            remoteManagerModel=nil;remoteManagerReceipt=nil;remoteManagerWindow=nil
            guard receipt.owner==ObjectIdentifier(self),receipt.window==window.map(ObjectIdentifier.init),receipt.draft==submissionIdentity,
                  !confirmingQuit,!busy,!browsing,progress==nil,fetchProgress==nil,NSApp.modalWindow==nil else{return}
            refreshAfterRemoteManager(receipt)
        }
    }
    func browse(_ context: FormContext) {guard accepts(context),canChooseBranch else{return};browse()}
    func deleteHistory(url: Bool, at index: Int, context: FormContext, entries: [String]) {
        guard accepts(context), url ? options.arbitraryURL : canChooseBranch else{return}
        let current = url ? urls : branchHistory
        guard current.map({GitReferenceName($0)}) == entries.map({GitReferenceName($0)}) else{return}
        if url {deleteURLHistory(at:index)} else {deleteBranchHistory(at:index)}
    }
    func selectBranch(_ branch: String, atFront: Bool = true) {
        let branch = FetchDialogHistory.trim(branch)
        guard !branch.isEmpty else { return }
        branchHistory = FetchDialogHistory.inserting(branch, into: branchHistory, atFront: atFront, caseSensitive: true)
        options.branch = branch
    }
    func deleteURLHistory(at index: Int) {
        guard !invalidated, !operationActive, let result = FetchDialogHistory.removing(index, entries: urls, preferences: preferences, key: "History.PullURLS") else { return }
        urls = result.entries; url = result.selection
    }
    func deleteBranchHistory(at index: Int) {
        guard !invalidated, !operationActive, let result = FetchDialogHistory.removing(index, entries: branchHistory, preferences: preferences, key: "History.PullRemoteBranch") else { return }
        branchHistory = result.entries; options.branch = result.selection
    }
    func selectArbitraryURL() {
        options.arbitraryURL = true; options.allRemotes = false; launchRebase = false
        let selection = FetchClipboardInput.selection(clipboardText() ?? "", isPull: isPull)
        url = selection?.url ?? urls.first ?? ""
        if let branch = selection?.branch { options.branch = branch }
    }
    func remoteChanged() {
        guard !invalidated, !busy, !browsing, !managing, progress == nil, fetchProgress == nil else { return }
        generation += 1; let request = generation, remote = options.remote
        remoteToken?.cancel(); let token = OperationCancellation(); remoteToken = token; preparingRemote = true; preparationNeedsRetry = false
        Self.activePreparationReads += 1; pendingOperations += 1
        Task { [self, access] in
            defer {
                Self.activePreparationReads -= 1; pendingOperations -= 1
                if remoteToken === token { remoteToken = nil; preparingRemote = false; if !invalidated { becameIdle() } }
                withExtendedLifetime(access) {}
            }
            do {
                try validateRepositoryAccess()
                let defaults = try await repository.fetchDefaults(remote: remote, cancellation: token)
                guard !invalidated, remoteToken === token, !token.isCancelled, request == generation,
                      options.remote.utf8.elementsEqual(remote.utf8) else { return }
                tagsDefault = defaults.tags; pruneDefault = defaults.prune; preparationNeedsRetry = false
            } catch { if !invalidated, remoteToken === token, request == generation { preparationNeedsRetry = true; self.error = error.localizedDescription } }
        }
    }
    func cancelPreparation() { if preparing { preparationNeedsRetry = true }; metadataToken?.cancel(); remoteToken?.cancel() }
    var settingsPreferences: UserDefaults { preferences }
    var repositoryAccess: RepositoryAccessLease? { access }
    var currentRemoteDestination: String { options.arbitraryURL ? url : options.remote }
    var onBrowseRemote: ((String) -> Void)?
    func browse() {
        guard !invalidated, !operationActive, !currentRemoteDestination.isEmpty, let onBrowseRemote else { return }
        browsing = true; onBrowseRemote(currentRemoteDestination)
    }
    private func refreshAfterRemoteManager(_ receipt:RemoteManagerReceipt) {
        guard !closed,!confirmingQuit,!busy,!preparing,!browsing,!managing,progress==nil,fetchProgress==nil,
              receipt.owner==ObjectIdentifier(self),receipt.window==window.map(ObjectIdentifier.init),receipt.draft==submissionIdentity,
              window?.attachedSheet==nil,NSApp.modalWindow==nil else{return}
        formRevision=UUID();let token=OperationCancellation();metadataToken=token;busy=true;error=nil;preparationNeedsRetry=false;retryManagerReceipt=receipt
        Self.activePreparationReads += 1;pendingOperations += 1
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        Task { [self,access] in
            defer {
                Self.activePreparationReads -= 1;pendingOperations -= 1;withExtendedLifetime(access){}
                if metadataToken === token {metadataToken=nil;busy=false;if !closed {becameIdle()}}
            }
            do {
                try validateRepositoryAccess()
                let names:[String],defaults:FetchDefaults
                if let readRefreshDefaults {(names,defaults)=try await readRefreshDefaults(token)}
                else {names=try await repository.remoteNames(cancellation:token);defaults=try await repository.fetchDefaults(cancellation:token)}
                let saved=preferences.string(forKey:key+".remote") ?? ""
                var selected=defaults.trackedRemote.isEmpty ? saved:defaults.trackedRemote
                if let preset=loadPresetRemote,!preset.isEmpty,!options.arbitraryURL {selected=preset}
                let matched=names.contains(where:{GitReferenceName.equal($0,selected)})
                if !matched {selected=names.first ?? ""}
                var all = !isPull && names.count>1 && !matched
                if let preset=loadPresetAllRemotes,!isPull {all=preset && names.count>1}
                let selectedDefaults:FetchDefaults
                if options.arbitraryURL || all || selected.isEmpty || GitReferenceName.equal(selected,defaults.remote) {selectedDefaults=defaults}
                else {selectedDefaults=try await repository.fetchDefaults(remote:selected,cancellation:token)}
                try token.check()
                guard !closed,metadataToken === token,receipt.draft==submissionIdentity,!confirmingQuit,
                      receipt.window==window.map(ObjectIdentifier.init),window?.attachedSheet==nil,NSApp.modalWindow==nil else{return}
                remotes=names;remoteSettings.remotes=names
                if !options.arbitraryURL {options.remote=selected;options.allRemotes=all}
                // PullFetchDlg::Refresh inserts the newly read HEAD/tracking or
                // registered .gitmodules branch, without resetting other options.
                options.branch=defaults.branch
                if !defaults.branch.isEmpty {selectBranch(defaults.branch,atFront:true)}
                tagsDefault=options.allRemotes ? "":selectedDefaults.tags;pruneDefault=options.allRemotes ? "":selectedDefaults.prune
                retryManagerReceipt=nil;preparationNeedsRetry=false
            } catch {
                if !closed,metadataToken === token {preparationNeedsRetry=true;if !token.isCancelled {self.error=error.localizedDescription}}
            }
        }
    }
    func cancel() {
        guard !invalidated else { return }
        if preparing { cancelPreparation(); return }
        if let progress { if progress.busy { progress.cancel() } else { progress.close() }; return }
        if let fetchProgress { if fetchProgress.busy { fetchProgress.cancel() } else { fetchProgress.close() }; return }
        if !busy { close() }
    }

    func fetch() {
        guard !invalidated, !operationActive else { return }
        if options.arbitraryURL {
            urls = FetchDialogHistory.save(url, entries: urls, preferences: preferences, key: "History.PullURLS", caseSensitive: true)
        }
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        let wantsRebase = launchRebase && !bare && !options.arbitraryURL
        let autoStart = configuredRebase
        let keepMerges = preserveMerges
        // PullFetchDlg rejects an empty displayed branch for Pull + Rebase.
        // Fetch can omit its effective refspec and let Rebase use the captured
        // configured tracking preset or its ordinary editable default chooser.
        if wantsRebase && (options.allRemotes || isPull && options.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { error = FetchRebaseFailure.destination.localizedDescription; return }
        var snapshot = options
        snapshot.verbose = GitCommandPresentation(defaults: preferences).fetchVerbose
        snapshot.branch = FetchDialogHistory.trim(snapshot.branch)
        if options.arbitraryURL { snapshot.remote = FetchDialogHistory.trim(url); snapshot.allRemotes = false }
        if shallow && depthEnabled {
            guard let parsed = Int(depth), parsed > 0 else { error = FetchFailure.depth.localizedDescription; return }; snapshot.depth = parsed
        }
        var pullOptions = PullOptions(); pullOptions.fetch = snapshot; pullOptions.squash = squash; pullOptions.noCommit = noCommit; pullOptions.noFastForward = noFastForward; pullOptions.fastForwardOnly = fastForwardOnly
        branchHistory = FetchDialogHistory.save(options.branch, entries: branchHistory, preferences: preferences, key: "History.PullRemoteBranch", caseSensitive: true)
        acceptedOperationRepository=repository
        formRevision = UUID(); error = nil
        busy = true; completedPresentation = false
        let sshFactory = sshSettings.capture(); sshSettings.save(preferences, key: key + ".autoload")
        preferences.set(wantsRebase, forKey: key + ".rebase")
        if isPull { preferences.set(fastForwardOnly, forKey: key + ".ffonly") }
        if !options.arbitraryURL && !options.allRemotes { preferences.set(options.remote, forKey: key + ".remote") }
        if isPull && !wantsRebase {
            let progress = PullProgressWindowModel(repository: repository, access: access, options: pullOptions, followUp: followUp, preferences: preferences)
            progress.makeSSHCoordinator = sshFactory
            self.progress = progress
            progress.confirmCancellation = { [weak self] choose in self?.confirmCancellation(choose) }
            let postAction = onPullPostAction
            progress.onPostAction = { [self] action, context in
                guard !invalidated || completedPresentation else { return }; postAction?(action, context)
            }
            progress.onCompleted = { [weak self, weak progress] in
                guard let self, let progress, !self.invalidated, self.progress === progress else { return }; self.busy = false
                self.error = progress.success ? nil : progress.output
                self.onChanged(progress.output)
                if progress.success { self.onFetched(progress.output) }
            }
            progress.close = { [weak self, weak progress] in if let progress { self?.finish(progress) } }
            onProgress?(progress); progress.start(); return
        }
        let progress = FetchProgressWindowModel(repository: repository, access: access, options: snapshot, preferences: preferences, rebaseMode: wantsRebase ? (autoStart ? .automatic : .manual) : .none, preserveMerges: keepMerges,isPull:isPull,backend:repository.libgit2Configuration)
        progress.makeSSHCoordinator = sshFactory
        progress.onNotificationLog=onNotificationLog
        fetchProgress = progress
        progress.confirmCancellation = { [weak self] choose in self?.confirmCancellation(choose) }
        let postAction = onFetchPostAction, rebase = onRebase
        progress.onPostAction = { [self] action, revision in
            guard !invalidated || completedPresentation else { return }; postAction?(action, revision)
        }
        progress.onRebase = { [self] target, automatic, preserve in
            guard !invalidated || completedPresentation else { return }; rebase(target, automatic, preserve)
        }
        if let onOwnedRebase {
            let prepare = beforeOwnedRebase, recover = recoverOwnedRebase
            progress.onOwnedRebase = { target, automatic, preserve in
                prepare()
                do { try await onOwnedRebase(target, automatic, preserve) }
                catch { await recover(); throw error }
            }
        }
        progress.onCompleted = { [weak self, weak progress] in
            guard let self, let progress, !self.invalidated, self.fetchProgress === progress else { return }; self.busy = false
            self.error = progress.success ? nil : progress.output; self.onChanged(progress.rawOutput)
            if progress.success { self.onFetched(progress.output) }
        }
        progress.close = { [weak self, weak progress] in if let progress { self?.finishFetch(progress) } }
        onFetchProgress?(progress); progress.start()

    }
}
private struct FetchDialog: View {
    @ObservedObject var model: FetchWindowModel
    var body: some View {
        let context = model.formContext, urlEntries = model.urls, branchEntries = model.branchHistory
        VStack(spacing: 14) {
            Group {
            GroupBox("Remote") { VStack(spacing: 10) {
                HStack { PushDestinationRadio(title: "Remote:", selected: !model.options.arbitraryURL) { model.selectMode(arbitrary:false,context:context) }.frame(width: 140)
                    PushRemotePopup(values: (!model.isPull && model.remotes.count > 1 ? ["*"] : []) + (model.remotes.isEmpty ? [""] : model.remotes), selection: model.remoteBinding(context)).disabled(model.options.arbitraryURL)
                }
                HStack { PushDestinationRadio(title: "Arbitrary URL:", selected: model.options.arbitraryURL) { model.selectMode(arbitrary:true,context:context) }.frame(width: 140)
                    FetchHistoryCombo(value: model.field(\.url,context:context), choices: model.urls, label: "Remote URL or path", onDelete: { model.deleteHistory(url:true,at:$0,context:context,entries:urlEntries) }).disabled(!model.options.arbitraryURL)
                }
                HStack { Text("Remote Branch:").frame(width: 140, alignment: .leading); FetchHistoryCombo(value: model.option(\.branch,context:context), choices: model.branchHistory, label: "Remote branch", onDelete: { model.deleteHistory(url:false,at:$0,context:context,entries:branchEntries) })
                    Button("…") { model.browse(context) }.accessibilityLabel("Browse remote branches")
                }.disabled(!model.canChooseBranch)
            }.padding(8) }
            GroupBox("Options") { VStack(alignment: .leading, spacing: 10) {
                HStack { Toggle("Squash", isOn: model.field(\.squash,context:context)).disabled(!model.isPull || model.launchRebase); Spacer(); Toggle("No Commit", isOn: model.field(\.noCommit,context:context)).disabled(!model.isPull || model.launchRebase); Spacer()
                    if model.shallow { Toggle("Depth", isOn: model.field(\.depthEnabled,context:context)); TextField("Depth", text: model.field(\.depth,context:context)).frame(width: 65).disabled(!model.depthEnabled) }
                }
                HStack { Toggle("No Fast Forward", isOn: model.field(\.noFastForward,context:context)).disabled(model.fastForwardOnly); Spacer(); Toggle("Fast Forward Only", isOn: model.field(\.fastForwardOnly,context:context)).disabled(model.noFastForward); Spacer() }.disabled(!model.isPull || model.launchRebase)
                HStack { FetchOverrideCheckbox(title: "Tags", value: model.option(\.tags,context:context)).frame(width: 140, alignment: .leading); Text(model.options.allRemotes || model.options.arbitraryURL ? "Use each destination's configured default" : "Default: " + model.tagsDefault).foregroundStyle(.secondary) }
                HStack { FetchOverrideCheckbox(title: "Prune", value: model.option(\.prune,context:context)).frame(width: 140, alignment: .leading); Text(model.options.allRemotes || model.options.arbitraryURL ? "Use each destination's configured default" : model.pruneDefault.isEmpty ? "" : "Default: " + model.pruneDefault).foregroundStyle(.secondary) }
            }.padding(8) }
            HStack { SSHAutoloadToggle(settings: model.sshSettings); Spacer(); Button("Manage Remotes") { model.manage(context) } }
            Toggle("Launch Rebase After Fetch", isOn: model.field(\.launchRebase,context:context)).disabled(model.bare || model.options.allRemotes || model.options.arbitraryURL || model.configuredRebase).help("Fetch the selected branch and open its native Rebase plan.").frame(maxWidth:.infinity,alignment:.leading)
            if model.rebaseRequired && !model.options.arbitraryURL { Text("Git configuration requires Rebase. Fetch will open and start its native Rebase plan.").font(.caption).foregroundStyle(.secondary) }
            }.disabled(model.operationActive || model.managing)
            Spacer(minLength: 0)
            HStack { if model.busy || model.preparingRemote { ProgressView().controlSize(.small) }; if model.preparationNeedsRetry { Button("Retry loading", action: model.retryPreparation).disabled(model.busy || model.preparing) }; Spacer(); Button("OK") { model.fetch() }.keyboardShortcut(.defaultAction).disabled(model.operationActive); Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel); Button("Help") { TurtleGitHelp.show(model.isPull ? .pull : .fetch) } }
        }.padding(16)
        .alert(model.isPull ? "Pull failed" : "Fetch failed", isPresented: Binding(get: { !model.closed && model.progress == nil && model.fetchProgress == nil && model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil }; if model.isPull { Button("Open Working Tree") { model.error = nil; model.onShowStatus() } } } message: { Text(model.error ?? "") }
        .sheet(isPresented:$model.managing) {
            if let child=model.remoteManagerModel,let receipt=model.remoteManagerReceipt {
                FetchRemoteManagerPage(owner:model,settings:child,receipt:receipt).frame(minWidth:730,minHeight:440)
            }
        }
    }
}
/// Keep the embedded manager's actual window under its parent's appearance
/// and visibility, including invisible receivers. Its retirement callback owns
/// the exact child receipt rather than a later SwiftUI onDismiss projection.
private struct FetchRemoteManagerPage:NSViewRepresentable {
    let owner:FetchWindowModel,settings:RemoteSettingsWindowModel,receipt:FetchWindowModel.RemoteManagerReceipt
    func makeNSView(context:Context)->Container {
        let view=Container(settings:settings,owner:owner.window,onAttach:{owner.remoteManagerAttached(receipt,$0)})
        view.child.onRetired={owner.remoteManagerReturned(receipt)};settings.load();return view
    }
    func updateNSView(_ view:Container,context:Context){view.child.render()}
    static func dismantleNSView(_ view:Container,coordinator:()){view.child.retire()}
    final class Container:NSView {
        let child:RemoteSettingsNativeView
        weak var owner:NSWindow?
        let onAttach:(NSWindow)->Void
        init(settings:RemoteSettingsWindowModel,owner:NSWindow?,onAttach:@escaping(NSWindow)->Void) {
            self.owner=owner;self.onAttach=onAttach;child=RemoteSettingsNativeView(model:settings)
            super.init(frame:.init(x:0,y:0,width:730,height:440))
            child.frame=bounds;child.autoresizingMask=[.width,.height];addSubview(child)
        }
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();guard let window,let owner,window !== owner else{return};window.isReleasedWhenClosed=false;window.alphaValue=owner.alphaValue;window.appearance=owner.appearance;onAttach(window)}
        required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    }
}
struct FetchOverrideCheckbox: NSViewRepresentable {
    let title: String
    @Binding var value: FetchOverride
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { let button = ReferenceChoiceButton(checkboxWithTitle:title,target:context.coordinator,action:#selector(Coordinator.clicked(_:)));button.allowsMixedState=true;return button }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = value == .configured ? .mixed : value == .enabled ? .on : .off;button.isEnabled=enabled && (button as? ReferenceChoiceButton)?.retired != true
        button.toolTip="Mixed: use Git configuration; checked: enable; unchecked: disable"
        context.coordinator.value=value;context.coordinator.change={value=$0}
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {coordinator.live=false;button.isEnabled=false;button.target=nil;button.action=nil}
    final class Coordinator: NSObject {
        var value=FetchOverride.configured,live=true;var change:(FetchOverride)->Void={_ in}
        @objc func clicked(_ sender:NSButton) {
            guard live,sender.isEnabled,sender.window != nil else{return}
            value = value == .configured ? .disabled : value == .disabled ? .enabled : .configured
            sender.state = value == .configured ? .mixed : value == .enabled ? .on : .off;change(value)
        }
    }
}

/// A cached native host can outlive its window. Retire targets/delegates at close.
@MainActor final class TransportControlLifetime {
    private(set) var retired=false
    private weak var control:NSControl?,owner:NSWindow?
    private var observer:NSObjectProtocol?
    var onRetire:()->Void={}
    deinit {if let observer {NotificationCenter.default.removeObserver(observer)}}
    func observe(_ control:NSControl) {
        guard !retired, let window=control.window,owner !== window else{return}
        if let observer {NotificationCenter.default.removeObserver(observer)}
        self.control=control;owner=window
        observer=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in MainActor.assumeIsolated {self?.retire()} }
    }
    func retire() {
        guard !retired else{return};retired=true;control?.isEnabled=false;control?.target=nil;control?.action=nil
        (control as? NSComboBox)?.delegate=nil;onRetire()
    }
}
final class TransportRemotePopup:NSPopUpButton {
    let lifetime=TransportControlLifetime()
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();lifetime.observe(self)}
}

struct FetchHistoryCombo: NSViewRepresentable {
    @Binding var value: String
    let choices: [String]
    let label: String
    var onDelete: ((Int) -> Void)? = nil
    var onSelectionState: ((Bool) -> Void)? = nil
    @AppStorage("UseCustomWordBreak") private var wordBreakMode=2
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = EditableHistoryCombo(); combo.delegate = context.coordinator; combo.completes = true
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal); return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.wordCommands.policy=GitInputWordBreak(mode:UInt32(truncatingIfNeeded:wordBreakMode))
        if let owned=combo as? EditableHistoryCombo,owned.lifetime.retired {owned.delegate=nil;owned.deleteHistory=nil;owned.isEnabled=false;return}
        let coordinator = context.coordinator; coordinator.updating = true; defer { coordinator.updating = false }
        coordinator.change = { value = $0 }; coordinator.selectionState = onSelectionState
        (combo as? EditableHistoryCombo)?.deleteHistory = onDelete
        if !coordinator.choices.elementsEqual(choices, by: { $0.utf16.elementsEqual($1.utf16) }) { (combo as? EditableHistoryCombo)?.replaceHistory(choices); coordinator.choices = choices }
        if let index = choices.firstIndex(where: { $0.utf16.elementsEqual(value.utf16) }) { combo.selectItem(at: index) }
        else if combo.indexOfSelectedItem >= 0 { combo.deselectItem(at: combo.indexOfSelectedItem) }
        if !combo.stringValue.utf16.elementsEqual(value.utf16) { combo.stringValue = value }
        combo.isEnabled = enabled && (combo as? EditableHistoryCombo)?.lifetime.retired != true; combo.setAccessibilityLabel(label)
    }
    static func dismantleNSView(_ combo:NSComboBox,coordinator:Coordinator) {coordinator.live=false;(combo as? EditableHistoryCombo)?.lifetime.retire();combo.delegate=nil;combo.isEnabled=false}
    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        let wordCommands=GitInputWordCommands()
        func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
            wordCommands.handle(control,text:textView,selector:commandSelector,combo:true,owner:self)
        }
        var live=true
        func accepts(_ combo:NSComboBox)->Bool {live && combo.isEnabled && combo.window != nil && (combo as? EditableHistoryCombo)?.lifetime.retired != true}
        var choices: [String] = []; var updating = false; var change: (String) -> Void = { _ in }; var selectionState: ((Bool) -> Void)?
        func comboBoxWillPopUp(_ notification: Notification) { (notification.object as? EditableHistoryCombo)?.historyPopupOpen = true }
        func comboBoxWillDismiss(_ notification: Notification) { (notification.object as? EditableHistoryCombo)?.historyPopupOpen = false }
        func controlTextDidChange(_ notification: Notification) { guard !updating, let combo = notification.object as? NSComboBox, accepts(combo) else { return }; selectionState?(false); change(combo.stringValue) }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard !updating, let combo = notification.object as? NSComboBox, accepts(combo), choices.indices.contains(combo.indexOfSelectedItem) else { return }; selectionState?(true); change(choices[combo.indexOfSelectedItem]) }
    }
}

/// PullFetchDlg shares these histories between Pull, Fetch and repositories.
/// HistoryCombo loads 25 but can save 26: truncation occurs before insertion.
enum FetchDialogHistory {
    static func removing(_ index: Int, entries: [String], preferences: UserDefaults, key: String, maxItems: Int = 25) -> (entries: [String], selection: String)? {
        guard entries.indices.contains(index) else { return nil }
        var result = entries; result.remove(at: index)
        let selection = result.isEmpty ? "" : result[min(index, result.count - 1)]
        // Save without reinserting the selected item, preserving source list order.
        preferences.set(Array(result.prefix(maxItems + 1)), forKey: key)
        return (result, selection)
    }
    static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\u{0B}\u{0C}"))
    }
    static func inserting(_ value: String, into entries: [String], atFront: Bool, caseSensitive: Bool, maxItems: Int = 25) -> [String] {
        let value = trim(value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))
        guard !value.isEmpty else { return entries }
        var result = entries
        if let index = result.firstIndex(where: { caseSensitive ? $0.utf16.elementsEqual(value.utf16) : $0.compare(value, options: .caseInsensitive) == .orderedSame }) {
            if !atFront || index == 0 { return result }
            result.remove(at: index)
        }
        result = Array(result.prefix(maxItems))
        result.insert(value, at: atFront ? 0 : result.count)
        return result
    }
    static func load(_ preferences: UserDefaults, key: String, caseSensitive: Bool, maxItems: Int = 25) -> [String] {
        var result: [String] = []
        for value in (preferences.stringArray(forKey: key) ?? []).prefix(maxItems) {
            if value.isEmpty { break }
            result = inserting(value, into: result, atFront: false, caseSensitive: caseSensitive, maxItems: maxItems)
        }
        return result
    }
    static func save(_ value: String, entries: [String], preferences: UserDefaults, key: String, caseSensitive: Bool, maxItems: Int = 25) -> [String] {
        let result = inserting(value, into: entries, atFront: true, caseSensitive: caseSensitive, maxItems: maxItems)
        preferences.set(Array(result.prefix(maxItems + 1)), forKey: key)
        return result
    }
}

/// Scoped local event handling; only an open, enabled history popup owns deletion.
final class EditableHistoryCombo: NSComboBox {
    let lifetime=TransportControlLifetime()
    var historyPopupOpen = false
    var deleteHistory: ((Int) -> Void)?
    private var eventMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow();lifetime.observe(self)
        lifetime.onRetire = { [weak self] in
            guard let self else{return};self.historyPopupOpen=false;self.deleteHistory=nil
            if let eventMonitor=self.eventMonitor {NSEvent.removeMonitor(eventMonitor);self.eventMonitor=nil}
        }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        historyPopupOpen = false
        guard window != nil, !lifetime.retired else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            return self.handleHistoryKey(event) ? nil : event
        }
    }
    func replaceHistory(_ entries: [String]) {
        let previous = (0..<numberOfItems).compactMap { itemObjectValue(at: $0) as? String }
        if previous.count == entries.count + 1,
           let removed = previous.indices.first(where: { index in
               var candidate = previous; candidate.remove(at: index)
               return candidate.elementsEqual(entries, by: { $0.utf16.elementsEqual($1.utf16) })
           }) { removeItem(at: removed) }
        else { removeAllItems(); addItems(withObjectValues: entries) }
    }
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
    /// Testable native event receiver; does not send synthetic events to the app.
    func handleHistoryKey(_ event: NSEvent) -> Bool {
        guard !lifetime.retired, window != nil, isEnabled, historyPopupOpen, event.type == .keyDown, event.modifierFlags.contains(.shift), [UInt16(51), 117].contains(event.keyCode) else { return false }
        if indexOfSelectedItem >= 0 { deleteHistory?(indexOfSelectedItem) }
        return true
    }
}

struct PullFollowUp: Sendable { var showPush = false; var showStashPop = false }
extension PullFollowUp {
    init(stashSave request: StashSaveFollowUp) { self.init(showPush: request.pullShowPush, showStashPop: true) }
}
struct PullProgressContext {
    let oldHead: String
    let newHead: String
    let resetRevision: String
    let followUp: PullFollowUp
}
enum PullPostAction: String, CaseIterable, Hashable {
    case resolve, commit, mergeUnrelated, pull, stash, reset, stashPop, diff, log, push, submoduleUpdate
    var title: String {
        switch self {
        case .resolve: return "Resolve…"; case .commit: return "Commit…"; case .mergeUnrelated: return "Merge unrelated history"
        case .pull: return "Pull…"; case .stash: return "Stash save…"; case .reset: return "Reset…"; case .stashPop: return "Stash pop"
        case .diff: return "Pulled Diff"; case .log: return "Pulled Log"; case .push: return "Push…"; case .submoduleUpdate: return "Submodule Update…"
        }
    }
    var icon: MenuIcon {
        switch self {
        case .resolve: return .resolve; case .commit: return .commit; case .mergeUnrelated: return .merge; case .pull: return .pull
        case .stash: return .stash; case .reset: return .reset; case .stashPop: return .stashPop; case .diff: return .compare
        case .log: return .log; case .push: return .push; case .submoduleUpdate: return .fetch
        }
    }
}
@MainActor final class PullProgressWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    private(set) var pendingOperations=0
    @Published var confirmingQuit = false
    var presentationAvailable: () -> Bool = { true }
    var closeForHandoff: ((@escaping () -> Void) -> Void)?
    private func finishAndPerform(_ action: @escaping () -> Void) {
        if let closeForHandoff { closeForHandoff(action) } else { close(); action() }
    }
    let repository: GitRepository
    let options: PullOptions
    let followUp: PullFollowUp
    private let access: RepositoryAccessLease?
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private var cancellation = OperationCancellation()
    private var inspectionToken: OperationCancellation?
    private var started = false, invalidated = false, dispatched = false
    @Published private(set) var completionWarning:String?
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var confirmingConflictHint = false
    @Published private(set) var dispatchingAction = false
    @Published private(set) var output = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var currentWork = ""
    private(set) var rawOutput = ""
    private var outputState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { outputState.presentation }
    var outputLimit: Int { outputState.limit }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        guard !invalidated else { return }
        outputState.consume(emission, parser: parser)
        output = outputState.output; percentage = outputState.percentage; currentWork = outputState.currentWork
    }
    private func resetOutput() {
        outputState.reset(); output = ""; rawOutput = ""; percentage = nil; currentWork = ""
    }
    private func displayFailure(_ error: Error) {
        if let failure = error as? GitCommandCancellationFailure { rawOutput = failure.result.text + "\n" + failure.localizedDescription }
        else { rawOutput += (rawOutput.isEmpty ? "" : "\n") + error.localizedDescription }
        if let failure=error as? FetchRebaseExecutionFailure,let command=failure.commandFailure {
            output=GitProgressFailureOutput.render(command,existing:output,limit:outputState.limit,context:"Preparing Rebase failed.")
        } else {output=GitProgressFailureOutput.render(error,existing:output,limit:outputState.limit)}
    }
    @Published private(set) var postActions: [PullPostAction] = []
    @Published private(set) var oldHead = ""
    @Published private(set) var newHead = ""
    var canCancel: Bool { !confirmingQuit && !confirmingConflictHint && !dispatchingAction && (!busy || !cancelling && !confirmingCancellation) }
    var close: () -> Void = {}
    var onCompleted: () -> Void = {}
    var onPostAction: ((PullPostAction, PullProgressContext) -> Void)?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    var presentConflictHint: (() async -> Bool)?
    var closeAfterCancellation = false
    private func finishCompletion() {
        guard !invalidated, !busy, !confirmingCancellation, !confirmingConflictHint, !dispatchingAction else { return }
        if completionWarning==nil && autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) || cancelled && closeAfterCancellation { close() }
    }
    private func completed() { guard !invalidated else { return }; busy = false; cancelling = false; onCompleted(); finishCompletion() }
    init(repository: GitRepository, access: RepositoryAccessLease?, options: PullOptions, followUp: PullFollowUp, preferences: UserDefaults = .standard) {
        self.repository = repository.libgit2Configuration == nil ? repository.capturingDiffBackend(preferences:preferences):repository; self.access = access; self.options = options; self.followUp = followUp; self.preferences = preferences; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences); self.outputState = GitProgressOutputState(preferences: preferences)
    }
    func invalidate() { invalidated = true; cancellation.cancel(); inspectionToken?.cancel(); inspectionToken = nil; busy = false; confirmingCancellation = false; confirmingConflictHint = false; dispatchingAction = false }
    func start() { Task { await run() } }
    func run() async { guard !started, !invalidated else { return }; started = true; await execute(options) }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func execute(_ snapshot: PullOptions) async {
        let repository=self.repository
        guard !invalidated else { return }
        Self.activeOperations += 1; pendingOperations += 1
        defer { Self.activeOperations -= 1; pendingOperations -= 1; withExtendedLifetime(access) {} }
        busy = true; success = false; cancelled = false; cancelling = false;completionWarning=nil; resetOutput(); postActions = []; newHead = ""
        do { try validateAccess(); if cancellation.isCancelled { throw OperationCancellationFailure.cancelled } }
        catch { guard !invalidated else { return }; output = error.localizedDescription; cancelled = cancellation.isCancelled; completed(); return }
        var beganPull = false
        do {
            guard let head=try await repository.revisionLookup("HEAD",requirement:.commit,cancellation:cancellation).objectID else{throw SynchronizationFailure.invalidInput}
            guard !invalidated else { return }; oldHead = head; beganPull = true
            let result = try await streamPull(snapshot,repository:repository)
            guard !invalidated else { return }; rawOutput = result
            if !outputState.hasOutput { output = rawOutput }
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }; success = true
        } catch { guard !invalidated else { return }; displayFailure(error); cancelled = cancellation.isCancelled }
        guard !invalidated else { return }; guard beganPull else { completed(); return }
        // Normal Cancel inspects recovery with a fresh token; forced closure stops it.
        let token = OperationCancellation(); inspectionToken = token
        defer { if inspectionToken === token { inspectionToken = nil } }
        var actions: [PullPostAction] = []
        if success {
            if followUp.showStashPop { actions.append(.stashPop) }
            do {
                guard let head=try await repository.revisionLookup("HEAD",requirement:.commit,cancellation:token).objectID else{throw SynchronizationFailure.invalidInput}
                guard !invalidated else{return};newHead=head;actions += [.diff,.log]
            } catch {
                guard !invalidated else{return};completionWarning=error.localizedDescription;output += "\n"+error.localizedDescription
            }
            if followUp.showPush { actions.append(.push) }
            let modules = try? await repository.submoduleUpdatePaths(cancellation: token)
            guard !invalidated else { return }; if modules?.isEmpty == false { actions.append(.submoduleUpdate) }
        } else {
            var conflicts:Bool?
            do {conflicts=try await repository.hasWorkingTreeConflicts(cancellation:token)}
            catch {if !invalidated,!token.isCancelled {output += "\nChecking for conflicts failed.\n"+error.localizedDescription}}
            guard !invalidated else { return }
            if conflicts == true {
                if !preferences.bool(forKey: MergeProgressWindowModel.conflictHintPreference), let presentConflictHint {
                    confirmingConflictHint = true
                    let suppress = await presentConflictHint()
                    guard !invalidated else { return }; confirmingConflictHint = false
                    if suppress { preferences.set(true, forKey: MergeProgressWindowModel.conflictHintPreference) }
                }
                actions = [.resolve, .commit]
            } else if conflicts == false {
                let known:Bool
                do {known=try await repository.remoteNames(cancellation:token).contains{GitReferenceName.equal($0,options.fetch.remote)}}
                catch {completionWarning=error.localizedDescription;output += "\n"+error.localizedDescription;known=false}
                guard !invalidated else { return }
                if !options.fetch.arbitraryURL, known {
                    var branch = options.fetch.branch, remote = options.fetch.remote
                    if branch.isEmpty, (try? await repository.branch(cancellation: token).isEmpty) == false, let defaults = try? await repository.pullDefaults(cancellation: token), !defaults.trackedRemote.isEmpty, !defaults.trackedBranch.isEmpty { branch = defaults.trackedBranch; remote = defaults.trackedRemote }
                    guard !invalidated else { return }
                    let shortBranch = branch.hasPrefix("refs/heads/") ? String(branch.dropFirst(11)) : branch
                    let ref = "refs/remotes/" + remote + "/" + shortBranch
                    do {
                        let relationship=try await repository.replayMergeBase(from:oldHead,to:ref,cancellation:token)
                        guard !invalidated else{return};if relationship.base == nil {actions.append(.mergeUnrelated)}
                    } catch {if !invalidated,!token.isCancelled {output += "\nReading merge bases failed.\n"+error.localizedDescription}}
                }
                actions += [.pull, .stash, .reset]
            }
        }
        guard !invalidated else { return }; postActions = actions; completed()
    }
    var makeSSHCoordinator: SSHTransportFactory?
    private func streamPull(_ snapshot: PullOptions,repository:GitRepository) async throws -> String {
        let coordinator = makeSSHCoordinator?(); defer { coordinator?.close() }; let preparation = coordinator?.preparation
        let parser = GitCliOutputParser(limit: outputState.limit)
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let operation = Task {
            defer { continuation.finish() }
            let observer:@Sendable(GitOutputChunk)->Void={chunk in parser.appendChunk(chunk.data);continuation.yield(())}
            return try await repository.pull(snapshot, cancellation: cancellation, onOutput:observer, prepareTransport: preparation,onCommand:{observer(GitOutputChunk(stream:.stdout,data:$0.preamble))})
        }
        for await _ in updates { consume(parser.processPending(), parser: parser) }
        consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser)
        return try await operation.value
    }
    func cancel() {
        guard !invalidated, busy, canCancel else { return }
        let token = cancellation
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, !self.invalidated, self.confirmingCancellation, self.cancellation === token else { return }
                self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; token.cancel() }; self.finishCompletion()
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: PullPostAction) {
        guard !invalidated, !confirmingQuit, presentationAvailable(), !dispatched, !busy, !confirmingCancellation, !dispatchingAction, !confirmingConflictHint, postActions.contains(action) else { return }
        if action == .mergeUnrelated {
            ProgressActionLog.nextAttempt(self);
            var snapshot = options; snapshot.allowUnrelatedHistories = true
            cancellation = OperationCancellation(); busy = true
            Task { await execute(snapshot) }; return
        }
        guard let onPostAction else { return }
        if action == .reset {
            dispatchingAction = true; let token = OperationCancellation(); inspectionToken = token
            Self.activeOperations += 1; pendingOperations += 1
            Task {
                defer { Self.activeOperations -= 1; pendingOperations -= 1; withExtendedLifetime(access) {}; if inspectionToken === token { inspectionToken = nil } }
                var revision = ""
                do {
                    try validateAccess()
                    let defaults = try await repository.pullDefaults(cancellation: token)
                    guard !invalidated, inspectionToken === token, !token.isCancelled else { return }
                    if !defaults.trackedRemote.isEmpty && !defaults.trackedBranch.isEmpty { revision = "refs/remotes/" + defaults.trackedRemote + "/" + defaults.trackedBranch }
                } catch { guard !invalidated, inspectionToken === token, !token.isCancelled else { return }; output += "\n" + error.localizedDescription; dispatchingAction = false; return }
                dispatchingAction = false
                guard !invalidated else { return }; dispatched = true
                let context = PullProgressContext(oldHead: oldHead, newHead: newHead, resetRevision: revision, followUp: followUp)
                finishAndPerform { onPostAction(action, context) }
            }
        } else {
            dispatched = true
            let context = PullProgressContext(oldHead: oldHead, newHead: newHead, resetRevision: "", followUp: followUp)
            finishAndPerform { onPostAction(action, context) }
        }
    }
}
@MainActor final class PullProgressWindowController: NSWindowController, NSWindowDelegate {
    private var pendingHandoff: (() -> Void)?
    private var presentationParent: NSWindow?
    private var release: TransportProgressRelease?
    private var finished = false
    let model: PullProgressWindowModel
    var onClosed: () -> Void = {}
    init(model: PullProgressWindowModel) {
        self.model = model; model.closeAfterCancellation = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: model.repository.root, dialog: "Pull progress", preferences: model.presentationPreferences); window.minSize = NSSize(width: 620, height: 340); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PullProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in
            guard let self, !self.model.confirmingQuit, !self.model.busy, !self.model.confirmingCancellation, !self.model.dispatchingAction, !self.model.confirmingConflictHint, self.window?.attachedSheet == nil else { return }
            if let window = self.window { self.presentationParent = window.sheetParent; window.close() }
        }
        model.presentationAvailable = { [weak window] in window != nil && window?.attachedSheet == nil }
        model.closeForHandoff = { [weak self] action in
            guard let self, !self.finished, self.pendingHandoff == nil else { return }
            self.pendingHandoff = action; self.model.close()
        }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.window.alphaValue = window.alphaValue; alert.window.appearance = window.appearance
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
        model.presentConflictHint = { [weak window] in
            guard let window, window.attachedSheet == nil else { return false }
            return await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "TurtleGit"; alert.informativeText = MergeProgressWindowModel.conflictHint
                let okay = alert.addButton(withTitle: "OK"); okay.keyEquivalent = "\r"; alert.window.defaultButtonCell = okay.cell as? NSButtonCell
                alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Don't show this message again"
                alert.window.alphaValue = window.alphaValue; alert.window.appearance = window.appearance
                alert.beginSheetModal(for: window) { _ in continuation.resume(returning: alert.suppressionButton?.state == .on) }
            }
        }

        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.confirmingQuit else { return false }
        if model.busy { model.cancel(); return false }
        guard !model.confirmingCancellation, !model.confirmingConflictHint, !model.dispatchingAction, sender.attachedSheet == nil else { return false }
        presentationParent = sender.sheetParent; return true
    }
    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }; finished = true
        model.saveActionLog(); model.invalidate(); model.closeForHandoff = nil
        guard let window else { pendingHandoff = nil; onClosed(); return }
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }
        let action = pendingHandoff; pendingHandoff = nil
        let release = TransportProgressRelease(window: window, parent: presentationParent ?? window.sheetParent) { [self] in
            self.release = nil; self.presentationParent = nil; onClosed(); action?()
        }
        self.release = release; release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
struct PullProgressDialog: View {
    @ObservedObject var model: PullProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { reader in
                ScrollView { VStack(alignment: .leading, spacing: 0) { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading); Color.clear.frame(height: 1).id("transport-output-end") } }
                    .onChange(of: model.output) { _ in reader.scrollTo("transport-output-end", anchor: .bottom) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor))
            if model.busy, let percentage = model.percentage { ProgressView(value: Double(percentage), total: 100).tint(.green) }
            if !model.currentWork.isEmpty { Text(model.currentWork).font(.caption).lineLimit(2) }
            HStack { if model.busy && model.percentage == nil { GitCommandActivity(animate: model.progressPresentation.animateActivity) }; Text(model.busy ? model.cancelling ? "Cancelling…" : "Pulling…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Pull failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red); Spacer() }
            HStack {
                if let first = model.postActions.first {
                    Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                    Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Pull post-actions") }.menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else {
                    if !model.success { Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction) }
                    Button("Close") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.dispatchingAction)
                }
            }.disabled(model.confirmingQuit || model.confirmingConflictHint || model.dispatchingAction)
        }.padding(12)
        .gitDockProgress(.command(busy: model.busy, success: model.success, waiting: model.confirmingCancellation || model.confirmingConflictHint, percentage: model.percentage))
    }
}

// Command-line DoFetch result and its manual/automatic Rebase post-execution choices.
enum FetchPostAction: String, CaseIterable, Hashable {
    case retry, log, reset, fetch, rebase, switchBranch, resolve
    var title: String {
        switch self { case .retry: return "Retry"; case .log: return "Show log"; case .reset: return "Reset…"; case .fetch: return "Fetch…"; case .rebase: return "Rebase…"; case .switchBranch: return "Switch/Checkout…"; case .resolve: return "Resolve" }
    }
    var icon: MenuIcon {
        switch self { case .retry: return .refresh; case .log: return .log; case .reset: return .reset; case .fetch: return .fetch; case .rebase: return .rebase; case .switchBranch: return .checkout; case .resolve: return .resolve }
    }
}
enum FetchRebaseMode { case none, manual, automatic }
enum FetchRebasePrompt: String, CaseIterable {
    case upToDate = "OpenRebaseRemoteBranchEqualsHEAD"
    case unchanged = "OpenRebaseRemoteBranchUnchanged"
    case fastForward = "OpenRebaseRemoteBranchFastForwards"
    var message: String {
        switch self {
        case .upToDate: return "Current branch is up to date or newer than the fetched branch. Open rebase anyway?"
        case .unchanged: return "The remote branch has not changed.\n\nOpen the rebase dialog anyway?"
        case .fastForward: return "The fetched branch fast-forwards upon the current branch.\n\nMerge or open the rebase dialog anyway?"
        }
    }
    var buttons: [String] { self == .fastForward ? ["Merge", "Rebase", "Abort"] : ["Yes", "No"] }
    var answers: [Int] { self == .fastForward ? [1, 2, 3] : [6, 7] }
    var defaultIndex: Int { 1 }
}
struct FetchRebaseAnswer { let value: Int; let suppress: Bool }
@MainActor final class FetchProgressWindowModel: ObservableObject {
    let notifications:FileOperationProgressState
    let backend:GitLibGit2Configuration
    var showsNotifications:Bool {backend.requests(.fetch)}
    var actionLogOutput:String {showsNotifications ? notifications.output+"\n\n"+output:output}
    var onNotificationLog:RemoteProgressLogHandler = {_,_,_,_,_ in}
    @Published var fileActionBusy=false
    @Published private(set) var notificationWarnings:[String]=[]
    var notificationOwnerAvailable:Bool {showsNotifications && !invalidated && !confirmingQuit && !busy && !confirmingCancellation && !dispatchingAction && !confirmingRebaseDecision && presentationAvailable()}
    var notificationActionsAvailable:Bool {notificationOwnerAvailable && !fileActionBusy}
    var notificationKeyboardAvailable:Bool {showsNotifications && !invalidated && !confirmingQuit && !fileActionBusy && presentationAvailable()}
    var onNotificationFileAction:(FileOperationProgressAction,FileOperationProgressRow)->Void = {_,_ in}
    var notificationAccess:RepositoryAccessLease? {access}
    func notificationFailure(_ text:String){output=GitProgressFailureOutput.renderDetails(text,existing:output,limit:outputLimit)}
    private(set) static var activeOperations = 0
    private(set) var pendingOperations=0
    @Published var confirmingQuit = false
    var presentationAvailable: () -> Bool = { true }
    var closeForHandoff: ((@escaping () -> Void) -> Void)?
    private func finishAndPerform(_ action: @escaping () -> Void) {
        if let closeForHandoff { closeForHandoff(action) } else { close(); action() }
    }
    let repository: GitRepository
    let options: FetchOptions
    let rebaseMode: FetchRebaseMode
    let preserveMerges: Bool
    /// PullFetchDlg omits a named-all Pull field only for its configured pair;
    /// ordinary Fetch omits it unconditionally. Retry retains this origin.
    let isPull:Bool
    private let access: RepositoryAccessLease?
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private var cancellation = OperationCancellation()
    private var inspectionToken: OperationCancellation?
    private var started = false, invalidated = false, dispatched = false
    private var explicitCloseRequested = false
    private var deferredRebase: (() -> Void)?
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var dispatchingAction = false
    @Published private(set) var output = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var currentWork = ""
    private(set) var rawOutput = ""
    private var outputState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { outputState.presentation }
    var outputLimit: Int { outputState.limit }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser, prefix: String = "") {
        guard !invalidated else { return }
        outputState.consume(emission, parser: parser)
        output = prefix + outputState.output; percentage = outputState.percentage; currentWork = outputState.currentWork
    }
    private func resetOutput() {
        outputState.reset(); output = ""; rawOutput = ""; percentage = nil; currentWork = ""
    }
    private func displayFailure(_ error: Error) {
        if let failure = error as? GitCommandCancellationFailure { rawOutput += (rawOutput.isEmpty ? "" : "\n") + failure.result.text + "\n" + failure.localizedDescription }
        else { rawOutput += (rawOutput.isEmpty ? "" : "\n") + error.localizedDescription }
        if let failure=error as? FetchRebaseExecutionFailure,let command=failure.commandFailure {
            output=GitProgressFailureOutput.render(command,existing:output,limit:outputState.limit,context:"Preparing Rebase failed.")
        } else {output=GitProgressFailureOutput.render(error,existing:output,limit:outputState.limit)}
    }
    @Published private(set) var postActions: [FetchPostAction] = []
    @Published private(set) var confirmingRebaseDecision = false
    @Published private(set) var merging = false
    var canCancel: Bool { !confirmingQuit && !dispatchingAction && !confirmingRebaseDecision && (!busy || !cancelling && !confirmingCancellation) }
    var closeAfterCancellation = false
    var close: () -> Void = {}
    var onCompleted: () -> Void = {}
    var onPostAction: ((FetchPostAction, String) -> Void)?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    var onRebase: (String, Bool, Bool) -> Void = { _, _, _ in }
    var onOwnedRebase: ((String, Bool, Bool) async throws -> Void)?
    var presentRebasePrompt: (FetchRebasePrompt) async -> FetchRebaseAnswer = { prompt in FetchRebaseAnswer(value: prompt.answers[prompt.defaultIndex], suppress: false) }
    init(repository: GitRepository, access: RepositoryAccessLease?, options: FetchOptions, preferences: UserDefaults = .standard, rebaseMode: FetchRebaseMode = .none, preserveMerges: Bool = false,isPull:Bool=false,backend:GitLibGit2Configuration?=nil) {
        notifications=FileOperationProgressState(preferences:preferences)
        let capturedBackend = backend ?? .load(from:preferences,helperURL:repository.libgit2Configuration?.helperURL)
        self.backend = capturedBackend
        self.repository = repository.capturingBackend(capturedBackend); self.access = access; self.options = options; self.preferences = preferences; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences); self.outputState = GitProgressOutputState(preferences: preferences)
        self.rebaseMode = rebaseMode; self.preserveMerges = preserveMerges;self.isPull=isPull
    }
    private func answer(_ prompt: FetchRebasePrompt) async -> Int {
        guard !invalidated else { return prompt.answers[prompt.defaultIndex] }
        if let saved = preferences.object(forKey: prompt.rawValue) as? Int, prompt.answers.contains(saved) { return saved }
        confirmingRebaseDecision = true
        let result = await presentRebasePrompt(prompt)
        guard !invalidated else { return prompt.answers[prompt.defaultIndex] }
        confirmingRebaseDecision = false
        let value = prompt.answers.contains(result.value) ? result.value : prompt.answers[prompt.defaultIndex]
        if result.suppress { preferences.set(value, forKey: prompt.rawValue) }
        return value
    }
    private var pendingRebase: FetchRebaseResult?
    private func openOwnedRebase(_ fetched: FetchRebaseResult) async -> Bool {
        guard !invalidated, let onOwnedRebase else { return false }
        pendingRebase = fetched; dispatchingAction = true
        do { try await onOwnedRebase(fetched.upstream, rebaseMode == .automatic, preserveMerges) }
        catch {
            guard !invalidated else { return false }
            dispatchingAction = false; success = false; explicitCloseRequested = false
            output = GitProgressFailureOutput.render(error, existing: output, limit: outputState.limit, context: "Opening Rebase failed.")
            postActions = [.rebase]; return false
        }
        guard !invalidated else { return false }
        pendingRebase = nil; dispatchingAction = false; success = true; explicitCloseRequested = true
        return true
    }
    private func finishCompletion() {
        guard !fileActionBusy,!busy, !invalidated, !confirmingCancellation else { return }
        if let deferredRebase { self.deferredRebase = nil; deferredRebase(); return }
        if explicitCloseRequested || notificationWarnings.isEmpty && autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) || cancelled && closeAfterCancellation { close() }
    }
    func invalidate() { notifications.retire();invalidated = true; cancellation.cancel(); inspectionToken?.cancel(); inspectionToken = nil; deferredRebase = nil; pendingRebase = nil; busy = false; confirmingCancellation = false; confirmingRebaseDecision = false; dispatchingAction = false }
    func start() { Task { await run() } }
    func run() async { guard !started, !invalidated else { return }; started = true; await execute() }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func execute() async {
        guard !invalidated else { return }
        Self.activeOperations += 1; pendingOperations += 1
        defer { Self.activeOperations -= 1; pendingOperations -= 1; withExtendedLifetime(access) {} }
        notifications.begin("Fetch");notificationWarnings=[]
        busy = true; success = false; cancelled = false; cancelling = false; merging = false; explicitCloseRequested = false; deferredRebase = nil; resetOutput(); postActions = []
        do {
            try validateAccess()
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            let transport = try await streamFetch()
            guard !invalidated else { return }
            let fetched = transport.1; rawOutput = transport.0
            if !outputState.hasOutput { output = rawOutput }
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            if let fetched {
                var openRebase = true
                if rebaseMode == .manual {
                    if fetched.currentIsUpToDate { if await answer(.upToDate) == 7 { openRebase = false }; guard !invalidated else { return } }
                    if openRebase && fetched.unchangedAtHEAD { if await answer(.unchanged) == 7 { openRebase = false }; guard !invalidated else { return } }
                    if openRebase && fetched.canFastForward {
                        let choice = await answer(.fastForward)
                        guard !invalidated else { return }
                        if choice == 3 { openRebase = false }
                        if choice == 1 {
                            merging = true; percentage = nil; currentWork = ""
                            var merge = MergeOptions(); merge.revision = fetched.upstream; merge.fastForwardOnly = true
                            let mergeOutput = try await streamMerge(merge)
                            guard !invalidated else { return }
                            rawOutput += "\n" + mergeOutput
                            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                            success = true; busy = false; explicitCloseRequested = true; onCompleted(); finishCompletion(); return
                        }
                    }
                }
                if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                if openRebase {
                    success = true; busy = false
                    if onOwnedRebase != nil {
                        _ = await openOwnedRebase(fetched)
                        guard !invalidated else { return }
                        onCompleted(); finishCompletion(); return
                    }
                    deferredRebase = { [weak self] in
                        guard let self else { return }
                        let callback = self.onRebase, automatic = self.rebaseMode == .automatic, preserve = self.preserveMerges
                        self.finishAndPerform { callback(fetched.upstream, automatic, preserve) }
                    }
                    onCompleted(); finishCompletion(); return
                }
            }
            success = true
            postActions = [.log, .reset, .fetch]
            if rebaseMode == .none { if (try? await repository.isBare(cancellation: cancellation)) == false { postActions.append(.rebase) } }
            if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
            postActions.append(.switchBranch)
        } catch {
            guard !invalidated else { return }
            displayFailure(error); cancelled = cancellation.isCancelled; success = false
            if merging {
                let token = OperationCancellation(); inspectionToken = token
                do {let conflicts=try await repository.hasWorkingTreeConflicts(cancellation:token);guard !invalidated else{return};postActions=conflicts ? [.resolve]:[]}
                catch {if !invalidated,!token.isCancelled {output += "\nChecking for conflicts failed.\n"+error.localizedDescription};postActions=[]}
                guard !invalidated else { return }; inspectionToken = nil
            }
            else { postActions = [.retry]; if options.allRemotes { postActions.append(.log) } }
        }
        guard !invalidated else { return }
        busy = false; cancelling = false; onCompleted(); finishCompletion()
    }
    var makeSSHCoordinator: SSHTransportFactory?
    private func streamFetch() async throws -> (String, FetchRebaseResult?) {
        let coordinator = makeSSHCoordinator?(); defer { coordinator?.close() }; let preparation = coordinator?.preparation
        let parser = GitCliOutputParser(limit: outputState.limit)
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let typed=RemoteProgressNotificationBuffer(),notificationStarted=Date()
        var fetchSucceeded=false
        func drainNotifications() {
            let values=typed.take();guard !invalidated else{return}
            for value in values {
                notifications.appendTransfer(value)
                if case .issue(let issue)=value {notificationWarnings.append(issue.message)}
            }
        }
        defer {drainNotifications();if showsNotifications,!invalidated {notifications.finish(success:fetchSucceeded,cancelled:cancellation.isCancelled,started:notificationStarted)}}
        let operation = Task<(String, FetchRebaseResult?), Error> {
            defer { continuation.finish() }
            let observer: @Sendable (GitOutputChunk) -> Void = { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }
            let command:@Sendable(GitCommandInvocation)->Void={observer(GitOutputChunk(stream:.stdout,data:$0.preamble))}
            if rebaseMode == .none { return (try await repository.fetch(options, cancellation: cancellation, onOutput: observer, prepareTransport: preparation,onCommand:command,backend:backend,onNotification:{value in typed.append(value);continuation.yield(())}), nil) }
            let result = try await repository.fetchForRebase(options, cancellation: cancellation, onOutput: observer, prepareTransport: preparation,onCommand:command,backend:backend,onNotification:{value in typed.append(value);continuation.yield(())},isPull:isPull)
            return (result.output, result)
        }
        for await _ in updates { drainNotifications();consume(parser.processPending(), parser: parser) }
        consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser)
        do {let result=try await operation.value;fetchSucceeded=true;return result}
        catch {
            drainNotifications()
            if showsNotifications,!invalidated {notifications.append("Error",GitProgressFailureOutput.render(error,existing:"",limit:outputLimit),kind:.error)}
            throw error
        }
    }
    private func streamMerge(_ options: MergeOptions) async throws -> String {
        // Upstream creates a new Merge progress dialog. Keep the retained Fetch
        // log here, but start an independent captured-limit presentation phase.
        let prefix = output + "\n"; outputState.reset(); percentage = nil; currentWork = ""
        let parser = GitCliOutputParser(limit: outputState.limit)
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let operation = Task {
            defer { continuation.finish() }
            return try await repository.merge(options, cancellation: cancellation, onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) })
        }
        for await _ in updates { consume(parser.processPending(), parser: parser, prefix: prefix) }
        consume(parser.processPending(), parser: parser, prefix: prefix); consume(parser.finish(), parser: parser, prefix: prefix)
        return try await operation.value
    }
    func cancel() {
        guard !invalidated, busy, canCancel else { return }
        let token = cancellation
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, !self.invalidated, self.confirmingCancellation, self.cancellation === token else { return }
                self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; token.cancel() }
                self.finishCompletion()
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ action: FetchPostAction) {
        guard !fileActionBusy,!invalidated, !confirmingQuit, presentationAvailable(), !dispatched, !busy, !confirmingCancellation, !confirmingRebaseDecision, !dispatchingAction, postActions.contains(action) else { return }
        if action == .rebase, let fetched = pendingRebase, onOwnedRebase != nil {
            dispatchingAction = true; Self.activeOperations += 1; pendingOperations += 1
            Task {
                defer { Self.activeOperations -= 1; pendingOperations -= 1; withExtendedLifetime(access) {} }
                _ = await openOwnedRebase(fetched)
                guard !invalidated else { return }; onCompleted(); finishCompletion()
            }
            return
        }
        if action == .retry {
            ProgressActionLog.nextAttempt(self); cancellation = OperationCancellation(); busy = true; Task { await execute() }; return }
        guard let onPostAction else { return }
        if action == .reset {
            dispatchingAction = true; let token = OperationCancellation(); inspectionToken = token
            Self.activeOperations += 1; pendingOperations += 1
            Task {
                defer { Self.activeOperations -= 1; pendingOperations -= 1; withExtendedLifetime(access) {}; if inspectionToken === token { inspectionToken = nil } }
                var revision = ""
                do {
                    try validateAccess(); let defaults = try await repository.pullDefaults(cancellation: token)
                    guard !invalidated, inspectionToken === token, !token.isCancelled else { return }
                    if !defaults.trackedRemote.isEmpty && !defaults.trackedBranch.isEmpty { revision = "refs/remotes/" + defaults.trackedRemote + "/" + defaults.trackedBranch }
                } catch { guard !invalidated, inspectionToken === token, !token.isCancelled else { return }; output += "\n" + error.localizedDescription; dispatchingAction = false; return }
                dispatchingAction = false; guard !invalidated else { return }; dispatched = true
                finishAndPerform { onPostAction(action, revision) }
            }
        } else { dispatched = true; finishAndPerform { onPostAction(action, "") } }
    }
}
@MainActor final class FetchProgressWindowController: NSWindowController, NSWindowDelegate {
    private var pendingHandoff: (() -> Void)?
    private var presentationParent: NSWindow?
    private var release: TransportProgressRelease?
    private var finished = false
    let model: FetchProgressWindowModel
    let notificationFiles:RemoteProgressFileActions
    var onClosed: () -> Void = {}
    init(model: FetchProgressWindowModel) {
        self.model = model; model.closeAfterCancellation = true
        notificationFiles=RemoteProgressFileActions(repository:model.repository,access:model.notificationAccess)
        let initialSize=model.showsNotifications ? NSSize(width:920,height:560):NSSize(width:760,height:430)
        let window = NSWindow(contentRect: NSRect(origin:.zero,size:initialSize), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: model.repository.root, dialog: "Fetch progress", preferences: model.presentationPreferences); window.minSize = NSSize(width: 620, height: 340); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FetchProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        if model.showsNotifications {window.contentMinSize=NSSize(width:780,height:480);window.setContentSize(initialSize)}
        notificationFiles.window=window;notificationFiles.available={ [weak model] in model?.notificationOwnerAvailable==true }
        notificationFiles.onBusy={ [weak model] in model?.fileActionBusy=$0 }
        notificationFiles.onError={ [weak model] in model?.notificationFailure($0) }
        notificationFiles.onLog={ [weak model] repository,access,paths,old,new in model?.onNotificationLog(repository,access,paths,old,new) }
        model.onNotificationFileAction={ [weak self] in self?.notificationFiles.perform($0,$1) }
        model.close = { [weak self] in
            guard let self, !self.model.confirmingQuit,!self.model.fileActionBusy, !self.model.busy, !self.model.confirmingCancellation, !self.model.dispatchingAction, !self.model.confirmingRebaseDecision, self.window?.attachedSheet == nil else { return }
            if let window = self.window { self.presentationParent = window.sheetParent; window.close() }
        }
        model.presentationAvailable = { [weak window] in window != nil && window?.attachedSheet == nil }
        model.closeForHandoff = { [weak self] action in
            guard let self, !self.finished, self.pendingHandoff == nil else { return }
            self.pendingHandoff = action; self.model.close()
        }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.window.alphaValue = window.alphaValue; alert.window.appearance = window.appearance
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
        model.presentRebasePrompt = { [weak window] prompt in
            guard let window, window.attachedSheet == nil else { return FetchRebaseAnswer(value: prompt.answers[prompt.defaultIndex], suppress: false) }
            return await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "TurtleGit"; alert.informativeText = prompt.message
                for (index, title) in prompt.buttons.enumerated() {
                    let button = alert.addButton(withTitle: title)
                    button.keyEquivalent = index == prompt.defaultIndex ? "\r" : ""
                    if index == prompt.defaultIndex { alert.window.defaultButtonCell = button.cell as? NSButtonCell }
                }
                if prompt == .fastForward { alert.buttons.last?.keyEquivalent = "\u{1b}" }
                alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Don't show this message again"
                alert.window.alphaValue = window.alphaValue; alert.window.appearance = window.appearance
                alert.beginSheetModal(for: window) { response in
                    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    let value = prompt.answers.indices.contains(index) ? prompt.answers[index] : prompt.answers[prompt.defaultIndex]
                    continuation.resume(returning: FetchRebaseAnswer(value: value, suppress: alert.suppressionButton?.state == .on))
                }
            }
        }


        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.confirmingQuit else { return false }
        if model.busy { model.cancel(); return false }
        guard !model.fileActionBusy,!model.confirmingCancellation, !model.dispatchingAction, !model.confirmingRebaseDecision, sender.attachedSheet == nil else { return false }
        presentationParent = sender.sheetParent; return true
    }
    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }; finished = true
        notificationFiles.retire();model.saveActionLog(); model.invalidate(); model.closeForHandoff = nil
        guard let window else { pendingHandoff = nil; onClosed(); return }
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }
        let action = pendingHandoff; pendingHandoff = nil
        let release = TransportProgressRelease(window: window, parent: presentationParent ?? window.sheetParent,ready:{ [self] in !notificationFiles.busy }) { [self] in
            self.release = nil; self.presentationParent = nil; onClosed(); action?()
        }
        self.release = release; release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
struct FetchProgressDialog: View {
    @ObservedObject var model: FetchProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.showsNotifications {
                FileOperationProgressTable(state:model.notifications,icon:.fetch,available:model.notificationActionsAvailable,repository:model.repository.root,keyboardAvailable:model.notificationKeyboardAvailable,fileRowIcons:true,actionAvailability:{model.notificationActionsAvailable},keyboardAvailability:{model.notificationKeyboardAvailable},performRow:model.onNotificationFileAction)
                    .frame(minHeight:180,maxHeight:.infinity).layoutPriority(1)
                if !model.output.isEmpty {SubmoduleProgressOutputView(text:model.output,completed:!model.busy,success:model.success,preferences:model.presentationPreferences).frame(height:90)}
                ForEach(Array(model.notificationWarnings.enumerated()),id:\.offset){_,warning in Label(warning,systemImage:"exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)}
            } else {
            ScrollViewReader { reader in
                ScrollView { VStack(alignment: .leading, spacing: 0) { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading); Color.clear.frame(height: 1).id("transport-output-end") } }
                    .onChange(of: model.output) { _ in reader.scrollTo("transport-output-end", anchor: .bottom) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor))
            }
            if model.busy, let percentage = model.percentage { ProgressView(value: Double(percentage), total: 100).tint(.green) }
            if !model.currentWork.isEmpty { Text(model.currentWork).font(.caption).lineLimit(2) }
            HStack { if model.busy && model.percentage == nil { GitCommandActivity(animate: model.progressPresentation.animateActivity) }; Text(model.busy ? model.cancelling ? "Cancelling…" : model.confirmingRebaseDecision ? "Waiting for your choice…" : model.merging ? "Merging…" : "Fetching…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : model.merging ? "Merge failed" : "Fetch failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red); Spacer() }
            HStack {
                if let first = model.postActions.first {
                    Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                    Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Fetch post-actions") }.menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { if !model.success { Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction) }; Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.fileActionBusy || model.confirmingQuit || model.dispatchingAction)
        }.padding(12)
        .gitDockProgress(.command(busy: model.busy, success: model.success, waiting: model.confirmingCancellation || model.confirmingRebaseDecision, percentage: model.percentage))
    }
}

/// CProgressDlg's constructor mapping and successful END-message close condition.
enum GitProgressAutoClose: Int, CaseIterable, Sendable {
    case manual = 0, noOptions = 1, noErrors = 2
    init(preferences: UserDefaults = .standard) { self = Self(rawValue: preferences.integer(forKey: "AutoCloseGitProgress")) ?? .manual }
    var title: String {
        switch self {
        case .manual: return "Close manually"
        case .noOptions: return "Auto-close if no further options are available"
        case .noErrors: return "Auto-close if no errors"
        }
    }
    func shouldClose(success: Bool, postActionCount: Int) -> Bool {
        success && (self == .noErrors || self == .noOptions && postActionCount == 0)
    }
}


/// Native equivalent of returning from CProgressDlg::DoModal before executing a
/// post-command. Retains the closed progress window and grant owner until AppKit
/// detaches its sheet, including when its outer controller is forcibly retired.
@MainActor private final class TransportProgressRelease {
    static private(set) var activeCount = 0
    private let window: NSWindow
    private let parent: NSWindow?
    private var completion: () -> Void
    private var observer: NSObjectProtocol?
    private var started = false, finished = false
    private let ready:()->Bool
    private var waiter:Task<Void,Never>?
    init(window: NSWindow, parent: NSWindow?, ready:@escaping()->Bool={true}, completion: @escaping () -> Void) {
        self.window = window; self.parent = parent; self.ready=ready;self.completion = completion
    }
    func start() {
        guard !started else { return }; started = true; Self.activeCount += 1
        waiter=Task { @MainActor [self] in while !finished {try? await Task.sleep(nanoseconds:5_000_000);drain()} }
        if window.sheetParent == nil && parent?.attachedSheet !== window { drain(); return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: parent, queue: .main) { [self] _ in
            DispatchQueue.main.async { self.drain() }
        }
        window.sheetParent?.endSheet(window); window.orderOut(nil)
        DispatchQueue.main.async { [self] in drain() }
    }
    private func drain() {
        guard !finished,ready(), window.sheetParent == nil, parent?.attachedSheet !== window else { return }
        finished = true;waiter?.cancel();waiter=nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        Self.activeCount -= 1; let done = completion; completion = {}; done()
    }
}
