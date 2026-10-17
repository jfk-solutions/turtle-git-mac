import AppKit
import SwiftUI
import TurtleGitCore

struct ReferenceBrowserColumnLayout: Codable, Equatable {
    static let key = "TurtleGit.BrowseRefs.Columns.v7"
    static let definitions: [(String,String,Double)] = [("name","Branch Name",210),("upstream","Tracked branch",150),("authorDate","Last Author Date",140),("subject","Last Commit",280),("author","Last Author",130),("committerDate","Date Last Commit",140),("committer","Last Committer",130),("hash","SHA-1",170),("description","Description",180)]
    static var ids: [String] { definitions.map { $0.0 } }
    var order = ids
    var visible = Set(ids)
    var widths: [String:Double] = [:]
    var divider = 190.0
    func normalized() -> Self {
        var next = self, used = Set<String>()
        next.order = (order + Self.ids).filter { Self.ids.contains($0) && used.insert($0).inserted }
        next.visible = visible.intersection(Self.ids);next.visible.insert("name")
        next.widths = widths.filter { Self.ids.contains($0.key) && $0.value.isFinite && (40...10000).contains($0.value) }
        if !divider.isFinite || !(120...2000).contains(divider) { next.divider = 190 }
        return next
    }
    static func load(_ preferences:UserDefaults) -> Self {
        guard let data = preferences.data(forKey:key),let value = try? JSONDecoder().decode(Self.self,from:data) else { return .init() }
        return value.normalized()
    }
}

private final class ReferenceBrowserNativeWindow: NSWindow {
    var handleCommand: (NSEvent) -> Bool = { _ in false }
    var commandKeyWindow: () -> NSWindow? = { NSApp.keyWindow }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if commandKeyWindow() === self, event.window === self, handleCommand(event) { return true }
        return super.performKeyEquivalent(with:event)
    }
}
@MainActor final class ReferenceBrowserWindowController: NSWindowController, NSWindowDelegate {
    var commandKeyWindow: () -> NSWindow? = { NSApp.keyWindow }
    let model: ReferenceBrowserWindowModel
    var onClosed: () -> Void = {}
    private(set) var remoteSettingsDialog: RemoteSettingsWindowController?
    var configureRemoteSettings: (RemoteSettingsWindowController) -> Void = { _ in }
    var presentRemoteSettings: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    private(set) var addRemoteDialog: AddRemoteWindowController?
    private(set) var remoteTagDialog: RemoteTagWindowController?
    var configureRemoteTags: (RemoteTagWindowController) -> Void = { _ in }
    var presentRemoteTags: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    private(set) var comparisonDialog: RevisionComparisonWindowController?
    var presentComparison: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    private var unifiedViewer: PatchWindowController?
    var presentUnified: ((Data, Bool, String) async throws -> Void)?
    private(set) var fetchDialog: FetchWindowController?
    var presentFetch: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    private(set) var branchDialog: BranchTagWindowController?
    var presentBranch: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    private(set) var mergeDialog: MergeWindowController?
    var presentMerge: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    private(set) var switchDialog: SwitchWindowController?
    var presentSwitch: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    private(set) var trackingPicker: ReferenceBrowserWindowController?
    private var trackingRequest: UUID?
    var configureTrackingPicker: (ReferenceBrowserWindowController) -> Void = { _ in }
    var presentTrackingPicker: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    private(set) var reflog: ReferenceLogWindowController?
    private(set) var descriptionEditor: ReferenceDescriptionWindowController?
    var presentDescription: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    var presentReflog: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    private var completion: ((String?) -> Void)?
    private var question: (UUID, NSAlert, (Bool) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, initial: String, preferences: UserDefaults = .standard, scope: ReferenceBrowserScope = .all, picking: Bool = true, pickMultiple: Bool = false, allowsRangeSelection: Bool = false, onChoose: @escaping (String?) -> Void) {
        model = ReferenceBrowserWindowModel(repository: repository, access: access, initial: initial, preferences: preferences, scope: scope, picking: picking, pickMultiple: pickMultiple, allowsRangeSelection: allowsRangeSelection); completion = onChoose
        let window = ReferenceBrowserNativeWindow(contentRect: .init(x: 0, y: 0, width: 1130, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Browse references", preferences: preferences); window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 940, height: 450)
        let host = NSHostingController(rootView: ReferenceBrowserDialog(model: model).defaultAppStorage(preferences))
        host.sizingOptions = []; window.contentViewController = host
        window.setContentSize(NSSize(width:1130,height:660))
        super.init(window: window); window.delegate = self; window.center()
        window.commandKeyWindow = { [weak self] in self?.commandKeyWindow() }
        window.handleCommand = { [weak self] event in self?.handleCommand(event) ?? false }
        model.confirmResetColumns = { [weak self] in await self?.ask(message:"Reset column order?",detail:"Restore the default column order, widths and visibility?",warning:false) ?? false }
        model.confirmDeletion = { [weak self] confirmation in
            await self?.ask(message: "TurtleGit", detail: confirmation.message, warning: confirmation.warning) ?? false
        }
        model.confirmCancellation = { [weak self] in
            await self?.ask(message: "The process is still running.", detail: "Stop the current reference operation? Review the resulting references and configuration before retrying.", warning: true) ?? false
        }
        model.sshSettings.present = { [weak window] prompt in
            guard let window, window.attachedSheet == nil, let child = prompt.window else { return false }
            window.makeFirstResponder(nil); window.beginSheet(child); return true
        }
        model.onComparePair = { [weak self] pair in self?.showComparison(pair) }
        model.onUnifiedPair = { [weak self] pair, alternate in self?.showUnified(pair, alternate: alternate) }
        model.onReflog = { [weak self] name in self?.showReflog(name) }
        model.onEditDescription = { [weak self] in self?.editDescription() }
        model.onSelectTracking = { [weak self] in self?.selectTracking() }
        model.onFetch = { [weak self] in self?.showFetch() }
        model.onDeleteRemoteTags = { [weak self] remote in self?.showRemoteTags(remote) }
        model.onAddRemote = { [weak self] in self?.showAddRemote() }
        model.onManageRemotes = { [weak self] in self?.showRemoteSettings() }
        model.onFetchFolder = { [weak self] remote in self?.showFetch(remote: remote) }
        model.onCreateFolder = { [weak self] isTag in self?.showCreateFolder(isTag: isTag) }
        model.onCreateBranch = { [weak self] in self?.showCreateBranch() }
        model.onMerge = { [weak self] in self?.showMerge() }
        model.onSwitch = { [weak self] in self?.showSwitch() }
        model.finish = { [weak self] reference in self?.finish(reference) }
        DialogGeometry.attach(window, identifier: "BrowseRefs", legacyName: "BrowseRefs")
    }
    private func ask(message: String, detail: String, warning: Bool) async -> Bool {
        guard !model.closed, question == nil, let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = message; alert.informativeText = detail; alert.alertStyle = warning ? .warning : .informational
        let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
        yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
        let id = UUID()
        return await withCheckedContinuation { continuation in
            question = (id, alert, { continuation.resume(returning: $0) })
            alert.beginSheetModal(for: window) { [weak self] response in self?.finishQuestion(id, accepted: response == .alertFirstButtonReturn) }
        }
    }
    private func finishQuestion(_ id: UUID, accepted: Bool) {
        guard let pending = question, pending.0 == id else { return }; question = nil
        if pending.1.window.sheetParent === window { window?.endSheet(pending.1.window) }; pending.1.window.orderOut(nil); pending.2(accepted)
    }
    private func handleCommand(_ event:NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command,.control,.option,.shift])
        let modified = modifiers == .command || modifiers == .control
        func find<T:NSView>(_ type:T.Type,_ id:String,in root:NSView?) -> T? {
            guard let root else { return nil }
            if let view = root as? T,view.identifier?.rawValue == id { return view }
            return root.subviews.compactMap { find(type,id,in:$0) }.first
        }
        if event.keyCode == 96, modifiers.isEmpty { if model.canEditPresentation,window?.attachedSheet == nil { model.load() };return true }
        if event.keyCode == 14, modified {
            if model.canEditPresentation,window?.attachedSheet == nil,let field = find(NSSearchField.self,"BrowseRefs.Filter",in:window?.contentView),field.isEnabled { window?.makeFirstResponder(field);field.currentEditor()?.selectAll(nil) }
            return true
        }
        if event.keyCode == 0, modified,let table = window?.firstResponder as? NSTableView,table.identifier?.rawValue == "BrowseRefs.References" {
            if model.canEditPresentation,window?.attachedSheet == nil,table.allowsMultipleSelection { table.selectAll(nil) };return true
        }
        if event.keyCode == 53,modifiers.isEmpty,!model.query.isEmpty,
           let field = find(NSSearchField.self,"BrowseRefs.Filter",in:window?.contentView),field.currentEditor() === window?.firstResponder {
            if model.canEditPresentation,window?.attachedSheet == nil { field.stringValue = "";model.query = "";model.refilter() };return true
        }
        return false
    }
    func showComparison(_ pair: ReferenceBrowserComparison) {
        guard let owner = window, owner.attachedSheet == nil, model.canComparePair else { return }
        owner.makeFirstResponder(nil); model.hasChild = true
        let child = RevisionComparisonWindowController(repository: model.repository, access: model.access, from: .revision(pair.from.rawValue), to: .revision(pair.to.rawValue))
        comparisonDialog = child; model.configureComparison(child.model)
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.comparisonDialog === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.comparisonDialog = nil; self.model.hasChild = false
        }
        guard let window = child.window, presentComparison(owner, window) else { child.close(); return }
        child.model.load()
    }
    func showUnified(_ pair: ReferenceBrowserComparison, alternate: Bool) {
        guard model.canComparePair, unifiedViewer?.model.busy != true, unifiedViewer?.window?.attachedSheet == nil else { return }
        model.generateUnified(pair, alternate: alternate) { [weak self] bytes, alternate in
            guard let self, !self.model.closed else { return }
            let title = pair.from.rawValue + ":" + pair.to.rawValue
            if let present = self.presentUnified { try await present(bytes, alternate, title); return }
            if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: self.model.preferences, title: title, permissions: self.model.access.map { [$0] } ?? []), !self.model.closed {
                self.unifiedViewer = UnifiedDiffApplication.presentBuiltin(bytes, repository: self.model.repository, access: self.model.access, existing: self.unifiedViewer, title: title, onClosed: { [weak self] in self?.unifiedViewer = nil })
            }
        }
    }
    private func showReflog(_ reference: String) {
        guard let owner = window, owner.attachedSheet == nil, !model.busy, !model.hasChild, model.renameReference == nil, !model.closed else { return }
        model.hasChild = true
        let child = ReferenceLogWindowController(repository: model.repository, access: model.access, reference: reference, preferences: model.preferences)
        reflog = child
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.reflog === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.reflog = nil; self.model.hasChild = false
        }
        guard let window = child.window, presentReflog(owner, window) else { child.close(); reflog = nil; model.hasChild = false; return }
    }
    func editDescription() {
        guard let owner = window, owner.attachedSheet == nil, model.canEditDescription,
              let chosen = model.chosen,
              let branch = GitReferenceName.removingPrefix("refs/heads/", from: chosen.name.rawValue) else { return }
        model.hasChild = true
        let repository = model.repository, access = model.access
        let child = ReferenceDescriptionWindowController(text: chosen.description, preferences: model.preferences) { text, cancellation in
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            try await repository.updateBranchDescription(branch, message: text, cancellation: cancellation, expectedHash: chosen.hash)
        }
        descriptionEditor = child
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.descriptionEditor === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.descriptionEditor = nil; self.model.hasChild = false
            if child.saved && !self.model.closed { self.model.onReferencesChanged(); self.model.load() }
        }
        guard let window = child.window, presentDescription(owner, window) else { child.close(); return }
        child.focusEditor()
    }
    func selectTracking() {
        guard let owner = window, owner.attachedSheet == nil, model.canChangeTracking, let reference = model.chosen?.name else { return }
        let request = UUID(); trackingRequest = request; model.hasChild = true
        let child = ReferenceBrowserWindowController(repository: model.repository, access: model.access, initial: "HEAD", preferences: model.preferences, scope: .remotes) { [weak self] upstream in
            guard let self, self.trackingRequest == request, !self.model.closed else { return }
            self.trackingRequest = nil
            if let upstream, GitReferenceName.removingPrefix("refs/remotes/", from: upstream) != nil { self.model.changeTracking(reference, upstream: GitReferenceName(upstream)) }
        }
        child.model.configureComparison = model.configureComparison; child.model.onLogRange = model.onLogRange; child.model.onLog = model.onLog; child.model.onBrowse = model.onBrowse; child.model.onCompare = model.onCompare; child.model.configureSwitch = model.configureSwitch; child.model.configureMerge = model.configureMerge; child.model.configureBranch = model.configureBranch; child.model.configureFetch = model.configureFetch
        trackingPicker = child; configureTrackingPicker(child)
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.trackingPicker === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.trackingPicker = nil; self.model.hasChild = false
        }
        guard let window = child.window, presentTrackingPicker(owner, window) else { child.abandonPresentation(); trackingRequest = nil; return }
        child.model.load()
    }
    func showSwitch() {
        guard let owner = window, owner.attachedSheet == nil, model.canSwitch, let reference = model.chosen?.name.rawValue else { return }
        model.hasChild = true
        let child = SwitchWindowController(repository: model.repository, access: model.access, revision: reference, preferences: model.preferences)
        switchDialog = child; model.configureSwitch(child)
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.switchDialog === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.switchDialog = nil; self.model.hasChild = false
        }
        guard let window = child.window, presentSwitch(owner, window) else { child.close(); return }
        child.model.load(revision: reference)
    }
    func showRemoteTags(_ remote: String) {
        guard let owner = window, owner.attachedSheet == nil, model.canUseFolder, model.snapshot?.remotes.contains(where: { GitReferenceName.equal($0, remote) }) == true else { return }
        owner.makeFirstResponder(nil); model.hasChild = true
        let child = RemoteTagWindowController(repository: model.repository, access: model.access, remote: remote, preferences: model.preferences)
        remoteTagDialog = child; configureRemoteTags(child)
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.remoteTagDialog === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.remoteTagDialog = nil; self.model.hasChild = false
        }
        guard let window = child.window, presentRemoteTags(owner, window) else { child.close(); return }
        child.model.load()
    }
    func showAddRemote() {
        guard let owner = window, owner.attachedSheet == nil, model.canUseFolder, model.folder.browserIsFrom("refs/remotes"), addRemoteDialog == nil else { return }
        model.hasChild = true
        let child = AddRemoteWindowController(repository: model.repository,access: model.access); addRemoteDialog = child
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.addRemoteDialog === child else { return }
            self.addRemoteDialog = nil; self.model.hasChild = false
            if !self.model.closed { self.model.load() }
        }
        if let window = child.window { owner.beginSheet(window) }
    }
    func showRemoteSettings() {
        guard let owner = window, owner.attachedSheet == nil, model.canUseFolder, model.folder.browserIsFrom("refs/remotes") else { return }
        owner.makeFirstResponder(nil); model.hasChild = true
        let child = RemoteSettingsWindowController(repository: model.repository, access: model.access, preferences: model.preferences)
        remoteSettingsDialog = child; child.configureFetch = model.configureFetch; configureRemoteSettings(child)
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.remoteSettingsDialog === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.remoteSettingsDialog = nil; self.model.hasChild = false; if !self.model.closed { self.model.load() }
        }
        guard let window = child.window, presentRemoteSettings(owner, window) else { child.close(); return }; child.model.load()
    }
    func showFetch() {
        guard model.canFetch, let remote = model.fetchRemote else { return }; showFetch(remote: remote)
    }
    private func showFetch(remote: String) {
        guard let owner = window, owner.attachedSheet == nil, !model.busy, !model.hasChild, !model.closed, model.renameReference == nil else { return }
        owner.makeFirstResponder(nil)
        model.hasChild = true
        let child = FetchWindowController(repository: model.repository, access: model.access, preferences: model.preferences)
        fetchDialog = child; model.configureFetch(child)
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.fetchDialog === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.fetchDialog = nil; self.model.hasChild = false; if !self.model.closed { self.model.load() }
        }
        guard let window = child.window, presentFetch(owner, window) else { child.close(); return }
        child.model.load(remote: remote)
    }
    func showCreateBranch() {
        guard model.canCreateBranch, let hash = model.chosen?.hash else { return }
        showCreation(isTag: false, revision: hash)
    }
    func showCreateFolder(isTag: Bool) {
        guard model.canCreateFolder(isTag: isTag) else { return }
        showCreation(isTag: isTag, revision: nil)
    }
    private func showCreation(isTag: Bool, revision: String?) {
        guard let owner = window, owner.attachedSheet == nil, !model.busy, !model.hasChild, !model.closed, model.renameReference == nil else { return }
        owner.makeFirstResponder(nil); model.hasChild = true
        let child = BranchTagWindowController(repository: model.repository, access: model.access, isTag: isTag, preferences: model.preferences)
        branchDialog = child; model.configureBranch(child)
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.branchDialog === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.branchDialog = nil; self.model.hasChild = false; if !self.model.closed { self.model.load() }
        }
        guard let window = child.window, presentBranch(owner, window) else { child.close(); return }
        child.model.load(revision: revision)
    }
    func showMerge() {
        guard let owner = window, owner.attachedSheet == nil, model.canMerge, let reference = model.chosen?.name.rawValue else { return }
        model.hasChild = true
        let child = MergeWindowController(repository: model.repository, access: model.access, preferences: model.preferences)
        mergeDialog = child; model.configureMerge(child)
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.mergeDialog === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.mergeDialog = nil; self.model.hasChild = false
        }
        guard let window = child.window, presentMerge(owner, window) else { child.close(); return }
        child.model.load(revision: reference)
    }
    func abandonPresentation() { completion = nil; close() }
    private func finish(_ reference: String?) {
        guard let completion, !model.busy, !model.hasChild, model.renameReference == nil, window?.attachedSheet == nil else { return }; self.completion = nil
        if let window { window.sheetParent?.endSheet(window); window.close() }; completion(reference)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.mutationActive { model.cancelRenameOperation(); return false }; guard !model.hasChild, model.renameReference == nil, !model.busy, sender.attachedSheet == nil else { return false }; finish(nil); return false }
    func windowWillClose(_ notification: Notification) { model.invalidate(); if let pending = question { finishQuestion(pending.0, accepted: false) }; addRemoteDialog?.close(); addRemoteDialog = nil; remoteSettingsDialog?.close(); remoteSettingsDialog = nil; remoteTagDialog?.close(); remoteTagDialog = nil; comparisonDialog?.close(); comparisonDialog = nil; unifiedViewer?.close(); unifiedViewer = nil; if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }; fetchDialog?.close(); fetchDialog = nil; branchDialog?.close(); branchDialog = nil; mergeDialog?.close(); mergeDialog = nil; switchDialog?.close(); switchDialog = nil; trackingRequest = nil; trackingPicker?.abandonPresentation(); trackingPicker = nil; descriptionEditor?.close(); descriptionEditor = nil; reflog?.close(); reflog = nil; model.hasChild = false; let completion = completion; self.completion = nil; completion?(nil); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class ReferenceBrowserWindowModel: ObservableObject, ActionLogProgress {
    private(set) static var activeReads = 0
    let repository: GitRepository
    let sshSettings: SSHTransportSettings
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    private let initial: String
    let scope: ReferenceBrowserScope
    let picking: Bool
    let pickMultiple: Bool
    let allowsRangeSelection: Bool
    private var token: OperationCancellation?
    private var invalidated = false
    @Published private(set) var deletingReference = false
    @Published private(set) var changingTracking = false
    private var generatingUnified = false
    private var resolvingCurrentBranch = false
    private(set) var initialFocusPending = true
    var closed: Bool { invalidated }
    @Published private(set) var renameReference: GitReferenceName? { didSet { if oldValue != renameReference { menuEpoch &+= 1; formRevision = UUID() } } }
    private var renameFolder: GitReferenceName?
    private var renameHash: String?
    static private(set) var activeRenames = 0
    static private(set) var activeMutations = 0
    @Published private(set) var confirmingCancellation = false { didSet { if oldValue != confirmingCancellation { formRevision = UUID() } } }
    @Published private(set) var awaitingConfirmation = false { didSet { if oldValue != awaitingConfirmation { formRevision = UUID() } } }
    @Published private(set) var mutationTitle = "Rename"
    @Published private(set) var mutationFailed = false
    @Published private(set) var mutationCancelled = false
    var mutationActive: Bool { renaming || deletingReference || changingTracking }
    var confirmCancellation: () async -> Bool = { false }
    @Published private(set) var renaming = false
    @Published var renameOutput = ""
    @Published private(set) var cancellingRename = false
    var onReferencesChanged: () -> Void = {}
    var output: String { renameOutput }
    var actionLogRepository: URL { repository.root }
    var actionLogFailed: Bool { mutationFailed }
    var actionLogCancelled: Bool { mutationCancelled }
    var actionLogEligible: Bool { !renameOutput.isEmpty }
    func dismissOutput() { guard !mutationActive else { return }; saveActionLog(); renameOutput = "" }


    @Published var hasChild = false { didSet { if oldValue != hasChild { menuEpoch &+= 1; formRevision = UUID() } } }
    @Published private(set) var bare = false
    private(set) var folders: [GitReferenceName] = ["refs"]
    @Published private(set) var snapshot: ReferenceBrowserSnapshot?
    @Published private(set) var busy = false { didSet { if oldValue != busy { menuEpoch &+= 1; formRevision = UUID() } } }
    @Published var error: String?
    @Published var folder: GitReferenceName = "refs" { didSet { if oldValue != folder { menuEpoch &+= 1;formRevision = UUID();refreshNamespaceColumns() } } }
    @Published private(set) var selection: Set<GitReferenceName> = []
    @Published private(set) var lastSelected: GitReferenceName?
    var selected: GitReferenceName? {
        get { selection.count == 1 ? selection.first : lastSelected }
        set { selection = newValue.map { [$0] } ?? []; lastSelected = newValue }
    }
    func select(_ references: Set<GitReferenceName>, last: GitReferenceName?) {
        guard !invalidated, !busy, !hasChild, renameReference == nil, !picking || pickMultiple || references.count <= 1 else { return }
        selection = references
        lastSelected = last.flatMap { selection.contains($0) ? $0 : nil } ?? rows.last(where: { selection.contains($0.reference.name) })?.reference.name
    }
    // A menu owns its displayed leaves, while the native selection remains free
    // to move. Only synchronous action dispatch reads this captured selection;
    // child controllers and asynchronous Git operations capture their own inputs.
    struct MenuContext {
        fileprivate let owner: ObjectIdentifier
        fileprivate let epoch: UInt64
        fileprivate let selectedRows: [ReferenceBrowserRow]
        fileprivate let lastSelected: GitReferenceName?
    }
    private var menuEpoch: UInt64 = 0
    private var dispatchingMenu: MenuContext?
    func menuContext() -> MenuContext? {
        guard !invalidated, !busy, !hasChild, !confirmingCancellation, !awaitingConfirmation, renameReference == nil, snapshot != nil else { return nil }
        return MenuContext(owner: ObjectIdentifier(self), epoch: menuEpoch, selectedRows: selectedRows, lastSelected: lastSelected)
    }
    func performMenu(_ context: MenuContext, action: () -> Void) {
        guard context.owner == ObjectIdentifier(self), context.epoch == menuEpoch,
              !invalidated, !busy, !hasChild, !confirmingCancellation, !awaitingConfirmation,
              renameReference == nil, dispatchingMenu == nil else { return }
        dispatchingMenu = context
        defer { dispatchingMenu = nil }
        action()
    }
    var selectedRows: [ReferenceBrowserRow] { dispatchingMenu?.selectedRows ?? rows.filter { selection.contains($0.reference.name) } }
    var range: ReferenceBrowserRange? { ReferenceBrowserRange(references: selectedRows.map { $0.reference.name }, lastSelected: dispatchingMenu == nil ? lastSelected : dispatchingMenu?.lastSelected) }
    var copyReferences: (String) -> Void = { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func copySelection() { guard !invalidated, !busy, !hasChild, renameReference == nil else { return }; copyReferences(selectedRows.map { $0.reference.name.browserShortName }.joined(separator: "\n")) }
    func logRange(symmetric: Bool) { guard !invalidated, !busy, !hasChild, renameReference == nil, let range else { return }; onLogRange?(range.history(symmetric: symmetric)) }
    func activateSelection() {
        if picking { accept(); return }
        guard !invalidated, !busy, !hasChild, renameReference == nil, let reference = selectedRows.first?.reference else { return }
        if reference.objectType == "tree" { onBrowse?(reference.name.rawValue) } else { onLog?(reference.name.rawValue) }
    }
    @Published var query = "" { didSet { if !GitReferenceName.equal(oldValue, query) { menuEpoch &+= 1 } } }
    static let allFields: HistorySearchFields = [.referenceNames, .subject, .authors, .revisions]
    @Published var fields: HistorySearchFields = allFields { didSet { if oldValue != fields { menuEpoch &+= 1 } } }
    @Published var mergeFilter = ReferenceBrowserMergeFilter.all { didSet { if oldValue != mergeFilter { menuEpoch &+= 1 } } }
    @Published var nested: Bool { didSet { if oldValue != nested { menuEpoch &+= 1 } } }
    @Published var sortColumn = "name" { didSet { if oldValue != sortColumn { menuEpoch &+= 1;saveSort() } } }
    @Published var descending = false { didSet { if oldValue != descending { menuEpoch &+= 1;saveSort() } } }
    @Published private(set) var columnLayout = ReferenceBrowserColumnLayout()
    @Published var displayedDivider = 190.0
    private(set) var layoutRevision = 0
    var confirmResetColumns: () async -> Bool = { false }
    private var formRevision = UUID()
    struct FormContext: Equatable { let owner: ObjectIdentifier; let revision: UUID }
    var formContext: FormContext { .init(owner:ObjectIdentifier(self),revision:formRevision) }
    private func accepts(_ context: FormContext) -> Bool { canEditPresentation && context == formContext }
    var filterCue: String {
        let names: [(HistorySearchFields,String)] = [(.referenceNames,"Refname"),(.subject,"Subject"),(.authors,"Authors"),(.revisions,"SHA-1")]
        return "Filter by " + names.filter { fields.contains($0.0) }.map { $0.1 }.joined(separator:", ")
    }
    func queryBinding(context: FormContext) -> Binding<String> {
        Binding(get:{self.query},set:{value in guard self.accepts(context) else {return};self.query=value;self.refilter()})
    }
    func searchField(_ field: HistorySearchFields, context: FormContext) -> Binding<Bool> {
        Binding(get:{self.fields.contains(field)},set:{value in
            guard self.accepts(context) else {return}
            if value {self.fields.insert(field)} else {self.fields.remove(field)};self.refilter()
        })
    }
    func toggleSearchFields(context: FormContext) { guard accepts(context) else {return};fields=Self.allFields.subtracting(fields);refilter() }
    func mergeFilterBinding(context: FormContext) -> Binding<ReferenceBrowserMergeFilter> {
        Binding(get:{self.mergeFilter},set:{value in
            guard self.accepts(context),self.mergeFilter != value else {return};self.mergeFilter=value;self.load()
        })
    }
    func nestedBinding(context: FormContext) -> Binding<Bool> {
        Binding(get:{self.nested},set:{value in
            guard self.accepts(context),self.nested != value else {return};self.nested=value;self.nestedChanged()
        })
    }
    func acceptRange(_ choice: Int, context: MenuContext) { performMenu(context) { acceptRange(choice) } }
    func accept(context: MenuContext) { performMenu(context) { accept() } }
    var canEditPresentation: Bool { !invalidated && !busy && !hasChild && !confirmingCancellation && !awaitingConfirmation && renameReference == nil }
    var isLocalNamespace: Bool { folder == "refs/heads" || GitReferenceName.removingPrefix("refs/heads/",from:folder.rawValue) != nil }
    private func saveSort() {
        guard !invalidated,let index = ReferenceBrowserColumnLayout.ids.firstIndex(of:sortColumn) else { return }
        preferences.set(index,forKey:"RefBrowserSortCol");preferences.set(descending,forKey:"RefBrowserSortDesc")
    }
    private func installColumns(_ value: ReferenceBrowserColumnLayout) {
        let value = value.normalized();guard !invalidated,value != columnLayout else { return }
        columnLayout = value;layoutRevision &+= 1;menuEpoch &+= 1
        if let data = try? JSONEncoder().encode(value) { preferences.set(data,forKey:ReferenceBrowserColumnLayout.key) }
    }
    func saveColumns(_ value:ReferenceBrowserColumnLayout) { guard canEditPresentation else { return };installColumns(value) }
    private func refreshNamespaceColumns() {
        var value = columnLayout
        for id in ["upstream","description"] { if isLocalNamespace { value.visible.insert(id) } else { value.visible.remove(id) } }
        installColumns(value)
    }
    func resetColumns() {
        guard canEditPresentation else { return }
        let revision = layoutRevision,folder = self.folder,divider = columnLayout.divider
        hasChild = true;Self.activeMutations += 1
        Task {
            defer {Self.activeMutations -= 1;if !invalidated {hasChild = false}}
            guard await confirmResetColumns(),!invalidated,layoutRevision == revision,self.folder == folder else { return }
            var value = ReferenceBrowserColumnLayout();value.divider = divider
            if !isLocalNamespace {value.visible.subtract(["upstream","description"])}
            installColumns(value)
        }
    }
    var finish: (String?) -> Void = { _ in }
    var confirmDeletion: ((ReferenceBrowserDeletionConfirmation) async -> Bool)?
    var deletionKind: ReferenceBrowserDeletionKind? {
        guard let first = selectedRows.first, let kind = ReferenceBrowserDeletionKind(reference: first.reference.name), selectedRows.allSatisfy({ ReferenceBrowserDeletionKind(reference: $0.reference.name) == kind }) else { return nil }
        return kind
    }
    var canDelete: Bool { !invalidated && !busy && !hasChild && renameReference == nil && deletionKind != nil }
    func deleteChosen() {
        guard canDelete else { return }
        deleteReferences(selectedRows.map { $0.reference.name })
    }
    var canUseFolder: Bool { !invalidated && !busy && !hasChild && renameReference == nil && folders.contains(folder) }
    var onDeleteRemoteTags: ((String) -> Void)?
    var onAddRemote: (() -> Void)?
    var onManageRemotes: (() -> Void)?
    var onFetchFolder: ((String) -> Void)?
    var folderRemote: String? { folder.browserIsFrom("refs/remotes") ? snapshot?.remote(for: folder) : nil }
    var onCreateFolder: ((Bool) -> Void)?
    func canCreateFolder(isTag: Bool) -> Bool { canUseFolder && folder.browserIsFrom(isTag ? "refs/tags" : "refs/heads") }
    var canDeleteAllTags: Bool { canUseFolder && folder.browserIsFrom("refs/tags") && !rows.isEmpty }
    func deleteAllTags() {
        guard canDeleteAllTags else { return }
        let references = rows.map { $0.reference.name }
        guard references.allSatisfy({ $0.browserIsFrom("refs/tags") }) else { return }
        // Source selects every currently displayed row, even in a single picker.
        selection = Set(references); lastSelected = references.last
        deleteReferences(references)
    }
    private func deleteReferences(_ references: [GitReferenceName]) {
        guard !invalidated, !busy, !hasChild, renameReference == nil, !references.isEmpty, let confirmDeletion else { return }
        let names = Set(references)
        let hashes = Dictionary(uniqueKeysWithValues: rows.filter { names.contains($0.reference.name) }.map { ($0.reference.name, $0.reference.hash) })
        let factory = sshSettings.capture()
        ProgressActionLog.nextAttempt(self); let request = OperationCancellation(); token = request; deletingReference = true; busy = true; error = nil; mutationTitle = "Delete references"; mutationFailed = false; mutationCancelled = false; renameOutput = ""; cancellingRename = false
        Self.activeMutations += 1; LocalGitCommandProgress.begin()
        Task {
            var attempted = false, failure: String?
            defer { Self.activeMutations -= 1; LocalGitCommandProgress.end(); withExtendedLifetime(access) {}; if token === request { token = nil; deletingReference = false; busy = false; awaitingConfirmation = false }; if !invalidated { cancellingRename = false; saveActionLog(); if attempted { onReferencesChanged() }; load(preservingError: failure) } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let confirmation = try await repository.browserDeletionConfirmation(references, cancellation: request)
                guard !invalidated, token === request, !request.isCancelled else { return }
                awaitingConfirmation = true; let accepted = await confirmDeletion(confirmation); awaitingConfirmation = false
                guard !invalidated, token === request, !request.isCancelled, accepted else { return }
                attempted = true
                let coordinator = factory?(); defer { coordinator?.close() }
                _ = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] progress in guard let self, !self.invalidated, self.token === request else { return }; self.renameOutput = progress.output }, resultText: { $0 }) { [self] emit in
                    try await repository.deleteBrowserReferences(references, cancellation: request, prepareTransport: coordinator?.preparation, expectedHashes: hashes, onOutput: emit)
                    return "Deleted \(references.count) reference(s).\n"
                }
            } catch {
                guard !invalidated, token === request else { return }
                mutationCancelled = request.isCancelled; mutationFailed = !mutationCancelled
                renameOutput = LocalGitCommandProgress.failure(error, existing: renameOutput, preferences: preferences)
                if !mutationCancelled { failure = error.localizedDescription }
            }
        }
    }
    var onFetch: (() -> Void)?
    var configureFetch: (FetchWindowController) -> Void = { _ in }
    var fetchRemote: String? { chosen.flatMap { snapshot?.remote(for: $0.name) } }
    var canFetch: Bool { canAccept && fetchRemote != nil }
    var onCreateBranch: (() -> Void)?
    var configureBranch: (BranchTagWindowController) -> Void = { _ in }
    var canCreateBranch: Bool { canAccept && chosen.map { GitReferenceName.removingPrefix("refs/remotes/", from: $0.name.rawValue) != nil } == true }
    var onMerge: (() -> Void)?
    var configureMerge: (MergeWindowController) -> Void = { _ in }
    var currentBranchName: String {
        guard let path = snapshot?.headFile, let head = try? String(contentsOf: path, encoding: .utf8),
              let branch = GitReferenceName.removingPrefix("ref: refs/heads/", from: head) else { return "(no branch)" }
        return branch.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var mergeTitle: String { "Merge to \"" + currentBranchName + "\"…" }
    var canMerge: Bool { canSwitch && chosen?.name != GitReferenceName("refs/heads/" + currentBranchName) }
    var onSwitch: (() -> Void)?
    var configureSwitch: (SwitchWindowController) -> Void = { _ in }
    var canSwitch: Bool { canAccept && !bare && chosen?.objectType == "commit" }
    var onSelectTracking: (() -> Void)?
    var canChangeTracking: Bool { canAccept && !bare && chosen?.objectType == "commit" && chosen.flatMap { GitReferenceName.removingPrefix("refs/heads/", from: $0.name.rawValue) } != nil }
    func unsetTracking() { guard canChangeTracking, let chosen, !chosen.upstream.isEmpty else { return }; changeTracking(chosen.name, upstream: nil) }
    func changeTracking(_ reference: GitReferenceName, upstream: GitReferenceName?) {
        guard !invalidated, !busy, !hasChild, renameReference == nil, !bare, let captured = snapshot?.references.first(where: { $0.name == reference }) else { return }
        ProgressActionLog.nextAttempt(self); let request = OperationCancellation(); token = request; changingTracking = true; busy = true; error = nil; mutationTitle = upstream == nil ? "Drop tracked branch" : "Set tracked branch"; mutationFailed = false; mutationCancelled = false; renameOutput = ""; cancellingRename = false
        Self.activeMutations += 1; LocalGitCommandProgress.begin()
        Task {
            var failure: String?
            defer { Self.activeMutations -= 1; LocalGitCommandProgress.end(); withExtendedLifetime(access) {}; if token === request { token = nil; changingTracking = false; busy = false }; if !invalidated { cancellingRename = false; saveActionLog(); onReferencesChanged(); load(preservingError: failure) } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                _ = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] progress in guard let self, !self.invalidated, self.token === request else { return }; self.renameOutput = progress.output }, resultText: { $0 }) { [self] emit in
                    try await repository.updateBrowserTracking(reference, upstream: upstream, cancellation: request, expectedHash: captured.hash, onOutput: emit)
                    return upstream.map { "Tracking “\($0.rawValue)”.\n" } ?? "Dropped tracked branch.\n"
                }
            } catch {
                guard !invalidated, token === request else { return }; mutationCancelled = request.isCancelled; mutationFailed = !mutationCancelled
                renameOutput = LocalGitCommandProgress.failure(error, existing: renameOutput, preferences: preferences)
                if !mutationCancelled { failure = error.localizedDescription }
            }
        }
    }
    var onEditDescription: (() -> Void)?
    var canEditDescription: Bool { canAccept && chosen?.objectType == "commit" && chosen.flatMap { GitReferenceName.removingPrefix("refs/heads/", from: $0.name.rawValue) } != nil }
    var comparisonPair: ReferenceBrowserComparison? { ReferenceBrowserComparison(references: selectedRows.map { $0.reference }) }
    var canComparePair: Bool { !invalidated && !busy && !hasChild && renameReference == nil && comparisonPair != nil }
    var onComparePair: ((ReferenceBrowserComparison) -> Void)?
    var onUnifiedPair: ((ReferenceBrowserComparison, Bool) -> Void)?
    var configureComparison: (RevisionComparisonWindowModel) -> Void = { _ in }
    func comparePair(unified: Bool, alternate: Bool = false) {
        guard canComparePair, let pair = comparisonPair else { return }
        if unified { onUnifiedPair?(pair, alternate) } else { onComparePair?(pair) }
    }
    func generateUnified(_ pair: ReferenceBrowserComparison, alternate: Bool, present: @escaping (Data, Bool) async throws -> Void) {
        guard canComparePair else { return }
        let request = OperationCancellation(); token = request; busy = true; generatingUnified = true
        Task {
            defer { if token === request { token = nil; busy = false; generatingUnified = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let bytes = try await repository.referenceBrowserUnifiedDiff(pair, cancellation: request)
                guard !invalidated, token === request, !request.isCancelled else { return }
                try await present(bytes, alternate)
            } catch { if !invalidated, token === request, !request.isCancelled { self.error = error.localizedDescription } }
        }
    }
    var onLogRange: ((HistoryRevisionRange) -> Void)?
    var onLog: ((String) -> Void)?
    var onReflog: ((String) -> Void)?
    var onBrowse: ((String) -> Void)?
    var onCompare: ((String) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, initial: String, preferences: UserDefaults = .standard, scope: ReferenceBrowserScope = .all, picking: Bool = true, pickMultiple: Bool = false, allowsRangeSelection: Bool = false) {
        self.picking = picking; self.pickMultiple = pickMultiple; self.allowsRangeSelection = allowsRangeSelection; sshSettings = SSHTransportSettings(repository: repository); sshSettings.enabled = sshSettings.available
        self.repository = repository; self.access = access; self.initial = initial; self.preferences = preferences; self.scope = scope
        nested = preferences.object(forKey: "RefBrowserIncludeNestedRefs") as? Bool ?? true
        columnLayout = .load(preferences)
        let sort = (preferences.object(forKey:"RefBrowserSortCol") as? NSNumber)?.intValue ?? 0
        let savedDescending = (preferences.object(forKey:"RefBrowserSortDesc") as? NSNumber)?.uint32Value == 1
        descending = savedDescending
        sortColumn = ReferenceBrowserColumnLayout.ids.indices.contains(sort) ? ReferenceBrowserColumnLayout.ids[sort]:"name"
    }
    var rows: [ReferenceBrowserRow] {
        (snapshot?.rows(folder: folder, nested: nested, query: query, fields: fields) ?? []).sorted { lhs, rhs in
            let comparison: ComparisonResult
            if sortColumn == "authorDate" || sortColumn == "committerDate" {
                let a = sortColumn == "authorDate" ? lhs.reference.authorDate ?? 0 : lhs.reference.committerDate ?? 0
                let b = sortColumn == "authorDate" ? rhs.reference.authorDate ?? 0 : rhs.reference.committerDate ?? 0
                comparison = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
            } else if sortColumn == "hash" { comparison = lhs.reference.hash.compare(rhs.reference.hash, options: .caseInsensitive) }
            else { comparison = text(lhs, column: sortColumn).localizedStandardCompare(text(rhs, column: sortColumn)) }
            if comparison == .orderedSame { return lhs.reference.name.rawValue.utf8.lexicographicallyPrecedes(rhs.reference.name.rawValue.utf8) }
            return descending ? comparison == .orderedDescending : comparison == .orderedAscending
        }
    }
    var chosen: BrowserReference? { (dispatchingMenu?.selectedRows.count ?? selection.count) == 1 ? selectedRows.first?.reference : nil }
    var canAccept: Bool { !confirmingCancellation && !awaitingConfirmation && !busy && !hasChild && !invalidated && renameReference == nil && (pickMultiple ? !selectedRows.isEmpty && selectedRows.count == (dispatchingMenu?.selectedRows.count ?? selection.count) : chosen != nil) }
    var canFinish: Bool { picking ? canAccept : !busy && !hasChild && !invalidated && renameReference == nil }
    var canRename: Bool { canAccept && chosen.flatMap { GitReferenceName.removingPrefix("refs/heads/", from: $0.name.rawValue) } != nil }
    func beginRename(keyboard:Bool = false) -> String? {
        guard canEditPresentation,keyboard || canRename,let chosen = keyboard ? selectedRows.first?.reference:self.chosen,
              GitReferenceName.removingPrefix("refs/heads/",from:chosen.name.rawValue) != nil,
              let row = rows.first(where: { $0.reference.name == chosen.name }) else { return nil }
        renameFolder = folder; renameHash = chosen.hash; renameReference = chosen.name; initialFocusPending = false; error = nil
        return row.name
    }
    func cancelRename() { guard !busy else { return }; renameReference = nil; renameFolder = nil; renameHash = nil }
    func cancelRenameOperation() {
        guard mutationActive, !invalidated, !awaitingConfirmation, !confirmingCancellation, !cancellingRename, let request = token else { return }
        if !preferences.bool(forKey: "ConfirmKillProcess") { cancellingRename = true; request.cancel(); return }
        confirmingCancellation = true; Self.activeMutations += 1
        Task {
            defer { Self.activeMutations -= 1; if !invalidated { confirmingCancellation = false } }
            let accepted = await confirmCancellation()
            if accepted && !invalidated && token === request { cancellingRename = true; request.cancel() }
        }
    }
    func commitRename(_ label: String) {
        guard !invalidated, !busy, !hasChild, let reference = renameReference, let folder = renameFolder, let hash = renameHash else { return }
        ProgressActionLog.nextAttempt(self); let request = OperationCancellation(); token = request; busy = true; error = nil; renaming = true; mutationTitle = "Rename"; mutationFailed = false; mutationCancelled = false; cancellingRename = false; renameOutput = ""; Self.activeRenames += 1; Self.activeMutations += 1; LocalGitCommandProgress.begin()
        Task {
            defer { Self.activeRenames -= 1; Self.activeMutations -= 1; LocalGitCommandProgress.end(); withExtendedLifetime(access) {}; renaming = false; cancellingRename = false; if !invalidated { saveActionLog() } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                _ = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] progress in guard let self, !self.invalidated, self.token === request else { return }; self.renameOutput = progress.output }, resultText: { $0 }) { [self] emit in
                    try await repository.renameBrowserBranch(reference, folder: folder, label: label, cancellation: request, expectedHash: hash, onOutput: emit)
                    return "Renamed “\(reference.rawValue)” to “\(folder.rawValue)/\(label)”.\n"
                }
                guard !invalidated, token === request else { return }
                token = nil; busy = false; renameReference = nil; renameFolder = nil; renameHash = nil; onReferencesChanged(); load()
            } catch {
                guard !invalidated, token === request else { return }
                mutationCancelled = request.isCancelled; mutationFailed = !mutationCancelled
                renameOutput = LocalGitCommandProgress.failure(error, existing: renameOutput, preferences: preferences)
                token = nil; busy = false; renameReference = nil; renameFolder = nil; renameHash = nil; onReferencesChanged(); load(preservingError: request.isCancelled ? nil : error.localizedDescription)
            }
        }
    }
    func text(_ row: ReferenceBrowserRow, column: String) -> String {
        let ref = row.reference
        switch column {
        case "name": return row.name
        case "upstream": return ref.upstream
        case "subject": return ref.subject
        case "author": return ref.author
        case "committer": return ref.committer
        case "hash": return ref.hash
        case "description": return ref.description.replacingOccurrences(of: "\n", with: " ")
        case "authorDate", "committerDate":
            guard let epoch = column == "authorDate" ? ref.authorDate : ref.committerDate else { return "" }
            let timestamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: epoch)); return HistoryDateSettings.load(defaults: preferences).format(timestamp)
        default: return ""
        }
    }
    func load(preservingError: String? = nil) {
        guard !invalidated, !confirmingCancellation, !awaitingConfirmation, !generatingUnified, !hasChild, !deletingReference, !changingTracking, !resolvingCurrentBranch, renameReference == nil else { return }
        let requested = selected?.rawValue ?? (snapshot == nil ? initial : folder.rawValue)
        token?.cancel(); let request = OperationCancellation(); token = request; busy = true; error = preservingError
        let filter = mergeFilter; Self.activeReads += 1
        Task {
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {}; if token === request { token = nil; busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result = try await repository.referenceBrowser(filter: filter, scope: scope, useMailmap: preferences.usesMailmap, cancellation: request)
                let bare = try await repository.isBare(cancellation: request)
                guard !invalidated, token === request, !request.isCancelled else { return }
                let choice = result.initialSelection(requested); folders = result.folders; self.bare = bare; snapshot = result; folder = choice.folder; selected = choice.reference; refilter()
            } catch { if !invalidated, token === request, !request.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func invalidate() { if mutationActive { mutationCancelled = true }; saveActionLog(); invalidated = true; confirmingCancellation = false; awaitingConfirmation = false; generatingUnified = false; deletingReference = false; changingTracking = false; resolvingCurrentBranch = false; renameReference = nil; renameFolder = nil; initialFocusPending = false; token?.cancel(); token = nil; busy = false }
    func setFolder(_ folder: GitReferenceName) { guard !invalidated, !busy, !hasChild, renameReference == nil, folders.contains(folder) else { return }; self.folder = folder; selected = nil }
    func refilter() {
        refreshNamespaceColumns()
        selection.formIntersection(Set(rows.map { $0.reference.name }))
        if let lastSelected, !selection.contains(lastSelected) { self.lastSelected = selectedRows.last?.reference.name }
    }
    func nestedChanged() { guard canEditPresentation else {return};preferences.set(nested, forKey: "RefBrowserIncludeNestedRefs"); load() }
    var canChooseCurrentBranch: Bool { !invalidated && !busy && !hasChild && renameReference == nil }
    func currentBranch() {
        guard canChooseCurrentBranch else { return }
        let request = OperationCancellation(); token = request; resolvingCurrentBranch = true; busy = true; error = nil; Self.activeReads += 1
        Task {
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let revision = try await repository.referenceBrowserCurrentBranch(cancellation: request)
                guard !invalidated, token === request, !request.isCancelled else { return }
                token = nil; resolvingCurrentBranch = false; busy = false; finish(revision)
            } catch {
                guard !invalidated, token === request else { return }
                token = nil; resolvingCurrentBranch = false; busy = false
                if !request.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    var pickRangeChoices: [HistoryRevisionRange] {
        guard picking, pickMultiple, allowsRangeSelection, let first = selectedRows.first, selectedRows.count == 2 else { return [] }
        let names = selectedRows.map { $0.reference.name }
        guard let a = ReferenceBrowserRange(references: names, lastSelected: first.reference.name),
              let b = ReferenceBrowserRange(references: names, lastSelected: names[1]) else { return [] }
        return [a.history(), b.history(), b.history(symmetric: true)]
    }
    func acceptRange(_ choice: Int) {
        guard canAccept, pickRangeChoices.indices.contains(choice) else { return }
        finish(pickRangeChoices[choice].expression)
    }
    func accept() {
        guard canFinish else { return }
        guard picking else { finish(nil); return }
        // GetSelectedRef returns the canonical name for one selection, and
        // space-separated browser short names for multiple selections.
        let selected = selectedRows
        finish(selected.count == 1 ? selected[0].reference.name.rawValue : selected.map { $0.reference.name.browserShortName }.joined(separator: " "))
    }
    func cancel() { finish(nil) }
    func focusIfReady(_ table: NSTableView) {
        guard initialFocusPending, !invalidated, !busy, !hasChild, snapshot != nil, let window = table.window, window.attachedSheet == nil else { return }
        if window.makeFirstResponder(table) { initialFocusPending = false }
    }
}
struct ReferenceBrowserDialog: View {
    @ObservedObject var model: ReferenceBrowserWindowModel
    var body: some View {
        let context = model.formContext
        let rangeContext = model.menuContext()
        VStack(spacing: 8) {
            HStack {
                Color.clear.frame(width:model.displayedDivider,height:1)
                Text("Filter:")
                ReferenceBrowserSearchField(text: model.queryBinding(context:context), cue:model.filterCue)
                Menu { ForEach([(HistorySearchFields.referenceNames, "Refname"), (.subject, "Subject"), (.authors, "Authors"), (.revisions, "SHA-1")], id: \.0.rawValue) { field, title in
                    Toggle(title, isOn: model.searchField(field,context:context))
                }; Divider(); Button("Toggle filters") { model.toggleSearchFields(context:context) }
                } label: { CommandLabel(title: "Filter by", icon: .log) }
                Picker("Branch filter", selection: model.mergeFilterBinding(context:context)) { ForEach(ReferenceBrowserMergeFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 170)
            }.disabled(!model.canEditPresentation)
            ReferenceBrowserNativeView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.mutationActive || !model.renameOutput.isEmpty {
                SubmoduleProgressOutputView(text: model.renameOutput, completed: !model.mutationActive, success: !model.mutationFailed && !model.mutationCancelled, preferences: model.preferences).frame(height: 100)
                HStack { Spacer(); if model.mutationActive { Button(model.cancellingRename ? "Cancelling…" : "Cancel " + model.mutationTitle) { model.cancelRenameOperation() }.disabled(model.cancellingRename || model.awaitingConfirmation || model.confirmingCancellation) } else { Button("Dismiss output") { model.dismissOutput() } } }
            }
            HStack {
                Toggle("Show nested refs", isOn: model.nestedBinding(context:context)).disabled(!model.canEditPresentation)
                Text("Showing \(model.rows.count) ref(s), \(model.selectedRows.count) ref(s) selected").font(.system(size: 11)).foregroundStyle(.secondary)
                if model.busy { ProgressView().controlSize(.small) }; Spacer()
                Button("Current Branch") { model.currentBranch() }.disabled(!model.canChooseCurrentBranch)
                if !model.pickRangeChoices.isEmpty {
                    Menu("OK") {
                        Button { if let rangeContext { model.accept(context:rangeContext) } } label: { CommandLabel(title: model.selectedRows.map { $0.reference.name.browserShortName }.joined(separator: " "), icon: .log, localized: false) }
                        ForEach(Array(model.pickRangeChoices.enumerated()), id: \.offset) { index, range in
                            Button { if let rangeContext { model.acceptRange(index,context:rangeContext) } } label: { CommandLabel(title: range.expression, icon: .log) }
                        }
                    }.disabled(!model.canAccept)
                } else { Button("OK") { model.accept() }.keyboardShortcut(.defaultAction).disabled(!model.canFinish) }
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(model.busy || model.renameReference != nil)
                Button { TurtleGitHelp.show(.references) } label: { CommandLabel(title: "Help", icon: .help) }
            }
        }.padding(10).disabled(model.hasChild).onAppear { model.load() }
        .alert("Browse references failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
@MainActor final class ReferenceBrowserOwnedSearchField: NSSearchField {
    let lifetime=TransportControlLifetime()
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();lifetime.observe(self)}
}
struct ReferenceBrowserSearchField: NSViewRepresentable {
    @Binding var text: String
    var cue = "Filter references"
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSSearchField {
        let field = ReferenceBrowserOwnedSearchField();field.identifier = .init("BrowseRefs.Filter"); field.placeholderString = "Filter references"; field.setAccessibilityLabel("Filter references")
        field.sendsSearchStringImmediately = true; field.sendsWholeSearchString = false
        field.target = context.coordinator; field.action = #selector(Coordinator.changed(_:)); return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        guard (field as? ReferenceBrowserOwnedSearchField)?.lifetime.retired != true else {field.isEnabled=false;return}
        field.placeholderString = cue
        if !field.stringValue.utf8.elementsEqual(text.utf8) { field.stringValue = text }
        field.isEnabled = enabled; context.coordinator.change = { text = $0 }
    }
    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) { coordinator.live=false;(field as? ReferenceBrowserOwnedSearchField)?.lifetime.retire();field.target = nil; coordinator.change = { _ in } }
    @MainActor final class Coordinator: NSObject { var live=true;var change: (String) -> Void = { _ in }; @objc func changed(_ sender: NSSearchField) { guard live,sender.isEnabled,sender.window != nil,(sender as? ReferenceBrowserOwnedSearchField)?.lifetime.retired != true else { return }; change(sender.stringValue) } }
}
struct ReferenceBrowserNativeView: NSViewRepresentable {
    @ObservedObject var model: ReferenceBrowserWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView(); split.delegate = context.coordinator; split.isVertical = true; split.dividerStyle = .thin
        let tree = NSOutlineView(); tree.headerView = nil; tree.setAccessibilityLabel("Reference namespaces")
        let folder = NSTableColumn(identifier: .init("folder")); folder.width = 185; tree.addTableColumn(folder); tree.outlineTableColumn = folder; tree.rowHeight = 22
        let table = ReferenceBrowserRenameTable(); table.rename = { [weak coordinator = context.coordinator] in coordinator?.beginRename(keyboard:true) }; table.rowHeight = 23; table.allowsMultipleSelection = !model.picking || model.pickMultiple; table.setAccessibilityLabel("References");table.identifier = .init("BrowseRefs.References")
        table.columnAutoresizingStyle = .noColumnAutoresizing;table.allowsColumnResizing = true;table.allowsColumnReordering = true
        for (id, title, width) in ReferenceBrowserColumnLayout.definitions {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; column.minWidth = 40;column.maxWidth = 10000; table.addTableColumn(column)
        }
        let header = RepositoryBrowserColumnHeader(frame:.init(x:0,y:0,width:0,height:24))
        header.buildMenu = { [weak coordinator = context.coordinator] in coordinator?.columnMenu() }
        header.fit = { [weak coordinator = context.coordinator] index,includeHeader in coordinator?.fit(index,includeHeader:includeHeader) };table.headerView = header
        tree.delegate = context.coordinator; tree.dataSource = context.coordinator; table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.activateSelection)
        let menu = NSMenu(); menu.delegate = context.coordinator; table.menu = menu
        let folderMenu = NSMenu(); folderMenu.delegate = context.coordinator; tree.menu = folderMenu
        for view in [tree, table] { let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = view; split.addArrangedSubview(scroll) }
        context.coordinator.tree = tree; context.coordinator.table = table
        split.setPosition(model.columnLayout.divider, ofDividerAt: 0)
        return split
    }
    func updateNSView(_ split: NSSplitView, context: Context) {
        let coordinator = context.coordinator; coordinator.model = model; coordinator.update()
        DispatchQueue.main.async { [weak coordinator, weak table = coordinator.table, weak split] in guard let coordinator,!coordinator.retired, let table else { return }; if let split, !coordinator.positioned, split.bounds.width > 0 { coordinator.updating = true;split.setPosition(min(coordinator.model.columnLayout.divider,max(120,split.bounds.width - 320)), ofDividerAt: 0);coordinator.updating = false; coordinator.positioned = true }; coordinator.model.focusIfReady(table) }
    }
    static func dismantleNSView(_ split: NSSplitView, coordinator: Coordinator) { coordinator.retired = true;split.delegate = nil; coordinator.tree?.delegate = nil; coordinator.tree?.dataSource = nil; coordinator.tree?.menu?.delegate = nil; coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil; coordinator.table?.menu?.delegate = nil;(coordinator.table?.headerView as? RepositoryBrowserColumnHeader)?.buildMenu = { nil };(coordinator.table?.headerView as? RepositoryBrowserColumnHeader)?.fit = {_,_ in} }
    @MainActor final class Folder: NSObject { let key: GitReferenceName; var children: [Folder] = []; weak var parent: Folder?; init(_ key: GitReferenceName) { self.key = key } }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate, NSSplitViewDelegate {
        private let wordCommands=GitInputWordCommands()
        var model: ReferenceBrowserWindowModel
        weak var tree: NSOutlineView?; weak var table: NSTableView?
        private var paths: [GitReferenceName] = [], folders: [GitReferenceName: Folder] = [:], visible: [ReferenceBrowserRow] = []
        var positioned = false,retired = false
        private var appliedLayout: ReferenceBrowserColumnLayout?
        private var rowSignature: [String] = []
        var updating = false
        private weak var renameField: NSTextField?
        init(model: ReferenceBrowserWindowModel) { self.model = model }
        func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view === splitView.subviews.last }
        var presentationAvailable: Bool { !retired && model.canEditPresentation && table?.window?.attachedSheet == nil }
        func splitView(_ splitView:NSSplitView,constrainMinCoordinate proposedMinimumPosition:CGFloat,ofSubviewAt dividerIndex:Int) -> CGFloat { 120 }
        func splitView(_ splitView:NSSplitView,constrainMaxCoordinate proposedMaximumPosition:CGFloat,ofSubviewAt dividerIndex:Int) -> CGFloat { max(120,splitView.bounds.width - 320) }
        func splitViewDidResizeSubviews(_ notification:Notification) {
            guard !retired,let split = notification.object as? NSSplitView,let first = split.arrangedSubviews.first,first.frame.width >= 120 else { return }
            let width = first.frame.width
            DispatchQueue.main.async { [weak self] in
                guard let self,!self.retired,!self.model.closed,abs(self.model.displayedDivider - width)>0.25 else { return }
                self.model.displayedDivider = width
            }
            guard positioned,!updating,presentationAvailable else { return }
            var value = model.columnLayout;value.divider = first.frame.width;model.saveColumns(value)
        }
        func tableViewColumnDidResize(_ notification:Notification) {saveColumns()}
        func tableViewColumnDidMove(_ notification:Notification) {saveColumns()}
        private func saveColumns() {
            guard !updating,presentationAvailable,let table else { return }
            var value = model.columnLayout
            value.order = table.tableColumns.map { $0.identifier.rawValue }
            value.widths = Dictionary(uniqueKeysWithValues:table.tableColumns.map { ($0.identifier.rawValue,Double($0.width)) })
            value.visible = Set(table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue })
            model.saveColumns(value)
        }
        func fit(_ index:Int,includeHeader:Bool) {
            guard presentationAvailable,let table,table.tableColumns.indices.contains(index) else { return }
            let column = table.tableColumns[index],font = NSFont.systemFont(ofSize:NSFont.systemFontSize)
            var width = visible.map { (model.text($0,column:column.identifier.rawValue) as NSString).size(withAttributes:[.font:font]).width + 18 }.max() ?? 40
            if includeHeader { width = max(width,(column.title as NSString).size(withAttributes:[.font:font]).width + 24) }
            updating = true;column.width = min(10000,max(40,width));updating = false;saveColumns()
        }
        func columnMenu() -> NSMenu {
            let menu = NSMenu();menu.autoenablesItems = false
            let revision = model.layoutRevision
            func add(_ title:String,enabled:Bool,state:NSControl.StateValue = .off,action:@escaping (Coordinator)->Void) {
                let command = ReferenceBrowserMenuCommand { [weak self] in guard let self,self.presentationAvailable,self.model.layoutRevision == revision else { return };action(self) }
                let item = NSMenuItem(title:title,action:#selector(ReferenceBrowserMenuCommand.invoke(_:)),keyEquivalent:"")
                item.target = command;item.representedObject = command;item.isEnabled = enabled && presentationAvailable;item.state = state;menu.addItem(item)
            }
            add("Reset column order",enabled:true) { $0.model.resetColumns() };menu.addItem(.separator())
            for (id,title,_) in ReferenceBrowserColumnLayout.definitions where id != "name" {
                add(title,enabled:true,state:model.columnLayout.visible.contains(id) ? .on:.off) { coordinator in
                    var value = coordinator.model.columnLayout
                    if value.visible.contains(id) {value.visible.remove(id)} else {value.visible.insert(id)}
                    coordinator.model.saveColumns(value)
                }
            }
            return menu
        }
        func update() {
            guard !retired,let tree, let table else { return }
            if model.renameReference != nil { tree.isEnabled = false; renameField?.isEditable = !model.busy; return }
            if renameField != nil { renameField?.delegate = nil; table.window?.makeFirstResponder(table); renameField = nil }
            updating = true; defer { updating = false }
            let paths = model.folders
            if paths != self.paths {
                self.paths = paths; folders = Dictionary(uniqueKeysWithValues: paths.map { ($0, Folder($0)) })
                for path in paths where path != "refs" {
                    let bytes = Array(path.rawValue.utf8), slash = bytes.lastIndex(of: 47)!
                    let parent = folders[GitReferenceName(String(decoding: bytes[..<slash], as: UTF8.self))]
                    let child = folders[path]!; child.parent = parent; parent?.children.append(child)
                }
                tree.reloadData(); if let root = folders["refs"] { tree.expandItem(root) }
            }
            if let chosen = folders[model.folder] {
                var ancestors: [Folder] = []; var parent = chosen.parent
                while let current = parent { ancestors.append(current); parent = current.parent }
                for ancestor in ancestors.reversed() { tree.expandItem(ancestor) }
                let row = tree.row(forItem: chosen); if row >= 0 { tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            }
            visible = model.rows
            let signature = visible.flatMap { row in
                [row.reference.name.rawValue,row.reference.hash,row.reference.objectType,row.reference.name == model.snapshot?.currentBranch ? "current":""] + ReferenceBrowserColumnLayout.ids.map { model.text(row,column:$0) }
            }
            let changed = signature.count != rowSignature.count || !zip(signature,rowSignature).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
            if changed {rowSignature = signature;table.reloadData()}
            let selected = IndexSet(visible.indices.filter { model.selection.contains(visible[$0].reference.name) })
            let selectionChanged = table.selectedRowIndexes != selected
            if selectionChanged {table.selectRowIndexes(selected, byExtendingSelection: false)}
            if changed || selectionChanged,let row = selected.first { table.scrollRowToVisible(row) }
            if appliedLayout != model.columnLayout {
                let value = model.columnLayout
                for (index,id) in value.order.enumerated() { let current = table.column(withIdentifier:.init(id));if current >= 0,current != index {table.moveColumn(current,toColumn:index)} }
                for column in table.tableColumns {
                    let id = column.identifier.rawValue;column.isHidden = !value.visible.contains(id)
                    column.width = value.widths[id] ?? ReferenceBrowserColumnLayout.definitions.first { $0.0 == id }!.2
                }
                appliedLayout = value
            }
            tree.isEnabled = !model.busy && !model.hasChild; table.isEnabled = !model.busy && !model.hasChild
            table.allowsColumnResizing = model.canEditPresentation;table.allowsColumnReordering = model.canEditPresentation
            for column in table.tableColumns { table.setIndicatorImage(nil, in: column) }
            if let column = table.tableColumn(withIdentifier: .init(model.sortColumn)) {
                table.highlightedTableColumn = column
                table.setIndicatorImage(NSImage(named: NSImage.Name(model.descending ? "NSDescendingSortIndicator" : "NSAscendingSortIndicator")), in: column)
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Folder)?.children.count ?? (folders["refs"] == nil ? 0 : 1) }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { if let folder = item as? Folder { return folder.children[index] }; return folders["refs"]! }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Folder).children.isEmpty }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            let folder = item as! Folder; let cell = NSTableCellView(); let text = NSTextField(labelWithString: String(decoding: folder.key.rawValue.utf8.split(separator: 47).last!, as: UTF8.self)); text.frame = .init(x: 22, y: 1, width: 165, height: 20); cell.addSubview(text); cell.textField = text
            let icon = NSImageView(frame: .init(x: 1, y: 3, width: 16, height: 16)); icon.image = NSImage(named: NSImage.folderName); cell.addSubview(icon); cell.imageView = icon; return cell
        }
        func outlineViewSelectionDidChange(_ notification: Notification) { guard !updating, let tree, let folder = tree.item(atRow: tree.selectedRow) as? Folder else { return }; model.setFolder(folder.key) }
        func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard visible.indices.contains(row), let column = tableColumn else { return nil }
            let item = visible[row]; let text = NSTextField(labelWithString: model.text(item, column: column.identifier.rawValue)); text.lineBreakMode = .byTruncatingTail
            text.toolTip = item.reference.name.rawValue
            if item.reference.name == model.snapshot?.currentBranch { text.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
            if column.identifier.rawValue == "name" {
                let cell = NSTableCellView(); text.frame = .init(x: 2, y: 2, width: column.width - 4, height: 19); text.autoresizingMask = [.width]
                cell.addSubview(text); cell.textField = text; return cell
            }
            return text
        }
        func beginRename(keyboard:Bool = false) {
            guard let table, let label = model.beginRename(keyboard:keyboard), let reference = model.renameReference,
                  let row = visible.firstIndex(where: { $0.reference.name == reference }) else { return }
            table.scrollRowToVisible(row);table.scrollColumnToVisible(table.column(withIdentifier:.init("name")))
            guard let cell = table.view(atColumn: table.column(withIdentifier: .init("name")), row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { model.cancelRename(); return }
            renameField = field; field.stringValue = label; field.isEditable = true; field.isSelectable = true; field.isBordered = true; field.drawsBackground = true; field.backgroundColor = .textBackgroundColor; field.delegate = self
            field.setAccessibilityLabel("Rename branch")
            if table.window?.makeFirstResponder(field) == true { field.currentEditor()?.selectAll(nil) }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard control === renameField else { return false }
            if commandSelector == NSSelectorFromString("cancelOperation:") {
                renameField?.delegate = nil; model.cancelRename(); update(); return true
            }
            if commandSelector == NSSelectorFromString("insertNewline:") {
                let label = renameField?.stringValue ?? ""; renameField?.delegate = nil; model.commitRename(label); return true
            }
            guard !retired,!model.busy else{return false}
            wordCommands.policy=GitInputWordBreak(defaults:model.preferences)
            return wordCommands.handle(control,text:textView,selector:commandSelector,combo:false,owner:self)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field === renameField, model.renameReference != nil, !model.busy else { return }
            field.delegate = nil; model.commitRename(field.stringValue)
        }
        func selectionShouldChange(in tableView: NSTableView) -> Bool { !model.busy && !model.hasChild && model.renameReference == nil }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !model.busy && !model.hasChild && model.renameReference == nil }
        func tableViewSelectionDidChange(_ notification: Notification) { guard !updating, model.renameReference == nil, let table else { return }; let names = Set(table.selectedRowIndexes.compactMap { visible.indices.contains($0) ? visible[$0].reference.name : nil })
            let added = table.selectedRowIndexes.last(where: { visible.indices.contains($0) && !model.selection.contains(visible[$0].reference.name) }).map { visible[$0].reference.name }
            model.select(names, last: added ?? model.lastSelected) }
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) { guard presentationAvailable else { return }; let id = tableColumn.identifier.rawValue; if model.sortColumn == id { model.descending.toggle() } else { model.sortColumn = id; model.descending = false } }
        @objc func activateSelection() { model.activateSelection() }
        @objc func accept() { model.accept() }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems(); guard !model.closed, !model.busy, !model.hasChild, model.renameReference == nil, let table else { return }
            let fromTree = menu === tree?.menu
            if fromTree, let tree, let clicked = tree.item(atRow: tree.clickedRow) as? Folder, clicked.key != model.folder { model.setFolder(clicked.key) }
            if !fromTree, visible.indices.contains(table.clickedRow), !table.selectedRowIndexes.contains(table.clickedRow) { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
            guard let context = model.menuContext() else { return }
            // Wrap every entry, including dynamically generated remote entries.
            // Keep NSMenuItem's weak target alive through representedObject.
            let owner = model
            defer {
                for entry in menu.items where !entry.isSeparatorItem {
                    guard let selector = entry.action else { continue }
                    let payload = entry.representedObject
                    let command = ReferenceBrowserMenuCommand { [weak self, weak owner, weak entry] in
                        guard let self, let owner, self.model === owner, let entry else { return }
                        owner.performMenu(context) {
                            let invocation = NSMenuItem(title: entry.title, action: selector, keyEquivalent: "")
                            invocation.representedObject = payload
                            if NSStringFromSelector(selector).contains(":") { _ = self.perform(selector, with: invocation) }
                            else { _ = self.perform(selector) }
                        }
                    }
                    entry.target = command; entry.action = #selector(ReferenceBrowserMenuCommand.invoke(_:)); entry.representedObject = command
                }
            }
            menu.autoenablesItems = false
            func item(_ title: String, _ action: Selector, _ icon: MenuIcon, _ enabled: Bool) { let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; entry.image = icon.contextImage(defaults: model.preferences); entry.isEnabled = enabled; menu.addItem(entry) }
            if fromTree || model.selectedRows.isEmpty {
                guard model.canUseFolder else { return }
                if model.canCreateFolder(isTag: false) { item("Create Branch…", #selector(createFolderBranch), .branch, model.onCreateFolder != nil) }
                if model.canCreateFolder(isTag: true) {
                    item("Create Tag…", #selector(createFolderTag), .tag, model.onCreateFolder != nil)
                    item("Delete all tags", #selector(deleteAllTags), .remove, model.canDeleteAllTags && model.confirmDeletion != nil)
                }
                if model.folder.browserIsFrom("refs/tags"), let remotes = model.snapshot?.remotes, !remotes.isEmpty {
                    menu.addItem(.separator())
                    for remote in remotes {
                        let entry = NSMenuItem(title: "Delete remote tags on \"" + remote + "\"…", action: #selector(deleteRemoteTags(_:)), keyEquivalent: "")
                        entry.target = self; entry.image = MenuIcon.remove.contextImage(defaults: model.preferences); entry.isEnabled = model.onDeleteRemoteTags != nil; entry.representedObject = remote; menu.addItem(entry)
                    }
                }
                if model.folder.browserIsFrom("refs/remotes") { item("Add Remote…", #selector(addRemote), .add, model.onAddRemote != nil); item("Manage Remotes", #selector(manageRemotes), .settings, model.onManageRemotes != nil) }
                if let remote = model.folderRemote {
                    let fetch = NSMenuItem(title: "Fetch from \"" + remote + "\"", action: #selector(fetchFolder(_:)), keyEquivalent: "")
                    fetch.target = self; fetch.image = MenuIcon.fetch.contextImage(defaults: model.preferences); fetch.representedObject = remote; fetch.isEnabled = model.onFetchFolder != nil; menu.addItem(fetch)
                    let tags = NSMenuItem(title: "Delete remote tags…", action: #selector(deleteRemoteTags(_:)), keyEquivalent: "")
                    tags.target = self; tags.image = MenuIcon.remove.contextImage(defaults: model.preferences); tags.representedObject = remote; tags.isEnabled = model.onDeleteRemoteTags != nil; menu.addItem(tags)
                }
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                item("Copy ref names", #selector(copyFolder), .copy, true); return
            }
            func deletion() {
                if model.canDelete, let kind = model.deletionKind { if !menu.items.isEmpty { menu.addItem(.separator()) }; item(kind.title(count: model.selectedRows.count), #selector(deleteReference), .remove, model.confirmDeletion != nil) }
            }
            if let range = model.range {
                item("Compare selected refs", #selector(comparePair), .unifiedDiff, model.onComparePair != nil)
                item("Show changes as unified diff", #selector(unifiedPair), .unifiedDiff, model.onUnifiedPair != nil)
                item("Show log of " + range.label(), #selector(logRange), .log, model.onLogRange != nil)
                item("Show log of " + range.label(symmetric: true), #selector(logSymmetricRange), .log, model.onLogRange != nil)
                deletion(); menu.addItem(.separator()); item("Copy ref names", #selector(copyName), .copy, true); return
            }
            guard let chosen = model.chosen else { deletion(); if !menu.items.isEmpty { menu.addItem(.separator()) }; item("Copy ref names", #selector(copyName), .copy, true); return }
            if model.picking { item("Select", #selector(accept), .checkout, model.canAccept); menu.addItem(.separator()) }
            if chosen.objectType == "commit" { item("Show log", #selector(log), .log, model.onLog != nil) }
            item("Browse repository", #selector(browse), .repositoryBrowser, model.onBrowse != nil)
            let branch = GitReferenceName.removingPrefix("refs/heads/", from: chosen.name.rawValue) != nil || GitReferenceName.removingPrefix("refs/remotes/", from: chosen.name.rawValue) != nil
            if branch { item("Show Reflog", #selector(reflog), .log, model.onReflog != nil) }
            if !model.bare && chosen.objectType == "commit" { menu.addItem(.separator()); item("Compare with working tree", #selector(compare), .compare, model.onCompare != nil) }
            menu.addItem(.separator())
            if model.canFetch, let remote = model.fetchRemote { item("Fetch from \"" + remote + "\"", #selector(fetch), .fetch, model.onFetch != nil); menu.addItem(.separator()) }
            if model.canMerge { item(model.mergeTitle, #selector(mergeRevision), .merge, model.onMerge != nil) }
            if model.canSwitch { item("Switch/Checkout to this…", #selector(switchRevision), .checkout, model.onSwitch != nil) }
            if model.canSwitch { menu.addItem(.separator()) }
            if model.canCreateBranch { item("Create Branch…", #selector(createBranch), .branch, model.onCreateBranch != nil) }
            if model.canEditDescription { item("Edit description", #selector(editDescription), .rename, model.onEditDescription != nil) }
            if model.canRename { item("Rename", #selector(rename), .rename, true) }
            if model.canChangeTracking {
                if !chosen.upstream.isEmpty { item("Unset tracked branch", #selector(unsetTracking), .remove, true) }
                item("Select tracked branch", #selector(selectTracking), .branch, model.onSelectTracking != nil)
            }
            deletion()
            menu.addItem(.separator()); item("Copy ref names", #selector(copyName), .copy, true)
        }
        @objc func deleteRemoteTags(_ sender: NSMenuItem) { guard model.canUseFolder, let remote = sender.representedObject as? String else { return }; model.onDeleteRemoteTags?(remote) }
        @objc func addRemote() { guard model.canUseFolder, model.folder.browserIsFrom("refs/remotes") else { return }; model.onAddRemote?() }
        @objc func manageRemotes() { guard model.canUseFolder, model.folder.browserIsFrom("refs/remotes") else { return }; model.onManageRemotes?() }
        @objc func fetchFolder(_ sender: NSMenuItem) { guard model.canUseFolder, let remote = sender.representedObject as? String, model.folderRemote.map({ GitReferenceName.equal($0, remote) }) == true else { return }; model.onFetchFolder?(remote) }
        @objc func createFolderBranch() { if model.canCreateFolder(isTag: false) { model.onCreateFolder?(false) } }
        @objc func createFolderTag() { if model.canCreateFolder(isTag: true) { model.onCreateFolder?(true) } }
        @objc func deleteAllTags() { model.deleteAllTags() }
        @objc func copyFolder() { if model.canUseFolder { model.copyReferences("") } }
        @objc func deleteReference() { model.deleteChosen() }
        @objc func logRange() { model.logRange(symmetric: false) }
        @objc func logSymmetricRange() { model.logRange(symmetric: true) }
        @objc func fetch() { if model.canFetch { model.onFetch?() } }
        @objc func createBranch() { if model.canCreateBranch { model.onCreateBranch?() } }
        @objc func mergeRevision() { if model.canMerge { model.onMerge?() } }
        @objc func switchRevision() { if model.canSwitch { model.onSwitch?() } }
        @objc func selectTracking() { if model.canChangeTracking { model.onSelectTracking?() } }
        @objc func unsetTracking() { model.unsetTracking() }
        @objc func rename() { beginRename() }
        @objc func editDescription() { if model.canEditDescription { model.onEditDescription?() } }
        @objc func log() { if let chosen = model.chosen { model.onLog?(chosen.name.rawValue) } }
        @objc func reflog() { if let chosen = model.chosen { model.onReflog?(chosen.name.rawValue) } }
        @objc func browse() { if let chosen = model.chosen { model.onBrowse?(chosen.name.rawValue) } }
        @objc func comparePair() { model.comparePair(unified: false) }
        @objc func unifiedPair() { model.comparePair(unified: true, alternate: NSEvent.modifierFlags.contains(.shift)) }
        @objc func compare() { if let chosen = model.chosen { model.onCompare?(chosen.name.rawValue) } }
        @objc func copyName() { model.copySelection() }
    }
}

private final class ReferenceBrowserRenameTable: NSTableView {
    var rename: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 120,event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty {
            if isEnabled,window?.firstResponder === self,let owner = window as? ReferenceBrowserNativeWindow,owner.commandKeyWindow() === owner { rename() };return
        }
        super.keyDown(with: event)
    }
}

// A retained command belongs to one displayed menu, rather than the coordinator's
// next selection. The coordinator and window model are deliberately weak owners.
@MainActor private final class ReferenceBrowserMenuCommand: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: NSMenuItem) { guard sender.isEnabled else { return }; action() }
}
