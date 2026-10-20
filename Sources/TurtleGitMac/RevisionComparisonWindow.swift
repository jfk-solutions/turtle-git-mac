import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

private final class RevisionComparisonNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 96 { refresh(); return true }; return super.performKeyEquivalent(with: event)
    }
}
enum ComparisonSide: String, Identifiable { case base, destination; var id: String { rawValue } }

@MainActor final class RevisionComparisonWindowController: NSWindowController, NSWindowDelegate {
    let model: RevisionComparisonWindowModel
    var onClosed: () -> Void = {}
    private(set) var referencePicker: ReferenceBrowserWindowController?
    private var pickerRequest: UUID?
    private weak var pickerFocus: NSResponder?
    private var pendingPickerSelection: (String?, ComparisonSide)?
    private(set) var logPicker: LogWindowController?
    private(set) var reflogPicker: ReferenceLogWindowController?
    private(set) var fileActionPresenter:RevisionFileActionPresenter?
    private(set) var rangeLogs: [UUID:LogWindowController] = [:]
    private let revisionEditor = RevisionGraphCompletionEditor()
    private let historyRegexExecutable: URL?
    private let savesHistoryGeometry: Bool
    init(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision, paths: [String] = [], preferences: UserDefaults = .standard, historyRegexExecutable: URL? = nil, savesGeometry: Bool = true) {
        self.historyRegexExecutable = historyRegexExecutable; self.savesHistoryGeometry = savesGeometry
        model = RevisionComparisonWindowModel(repository: repository, access: access, from: from, to: to, paths: paths, preferences: preferences)
        let size = NSSize(width: 1000, height: 700)
        let window = RevisionComparisonNativeWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Changed Files", preferences: preferences); window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 530)
        window.contentViewController = NSHostingController(rootView: RevisionComparisonDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        revisionEditor.isFieldEditor = true; revisionEditor.isAutomaticTextCompletionEnabled = false
        revisionEditor.isAutomaticSpellingCorrectionEnabled = false; revisionEditor.isContinuousSpellCheckingEnabled = false
        window.setContentSize(size); window.center()
        model.pickReferences = { [weak self] side in self?.showReferencePicker(side: side) }
        model.pickHistory = { [weak self] side, reflog in self?.showHistoryPicker(side: side, reflog: reflog) }
        model.onLog = { [weak self] revision in self?.showRangeLog(nil,revision:revision) }
        model.onLogRange = { [weak self] range in self?.showRangeLog(range) }
        model.window = window; model.close={ [weak window] in window?.performClose(nil) };installFileActions(); window.refresh = { [weak model] in model?.load() }

        NotificationCenter.default.addObserver(self, selector: #selector(pickerSheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        if savesGeometry { DialogGeometry.attach(window, identifier: "FileDiffDialog", legacyName: "FileDiffDialog") }
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is ComparisonRevisionNativeField ? revisionEditor : nil
    }
    private func showRangeLog(_ range: HistoryRevisionRange?, revision: String? = nil) {
        guard !model.closed, !model.busy, !model.confirmingQuit, window?.attachedSheet == nil else { return }
        let id = UUID(), child = LogWindowController(repository:model.repository,access:model.access,labelDefaults:model.preferences,savesGeometry:savesHistoryGeometry,initialRevision:revision,historyRegexExecutable:historyRegexExecutable)
        child.window?.alphaValue = window?.alphaValue ?? 1
        model.configureLogPicker(child.model); if let range { child.model.revisionRange = range; child.model.reload() }
        child.onClosed = { [weak self] in self?.rangeLogs.removeValue(forKey:id) }
        rangeLogs[id] = child; child.showWindow(nil); child.window?.makeKeyAndOrderFront(nil)
    }
    private func installFileActions() {
        fileActionPresenter = RevisionFileActionPresenter(model:model,window:window)
    }
    private func beginPicker() -> UUID? {
        guard let window, window.attachedSheet == nil, !model.closed, !model.busy,
              !model.confirmingQuit, pickerRequest == nil else { return nil }
        model.cancelPendingInput(); pickerFocus = (window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSResponder : $0 } ?? window.firstResponder
        let request = UUID(); pickerRequest = request; return request
    }
    private func finishPicker(_ request: UUID, revision: String?, side: ComparisonSide) {
        guard pickerRequest == request else { return }
        pickerRequest = nil; referencePicker = nil; logPicker = nil; reflogPicker = nil
        guard !model.closed else { pickerFocus = nil; return }
        pendingPickerSelection = (revision, side); pickerSheetEnded()
    }
    @objc private func pickerSheetEnded() {
        guard !model.closed, pickerRequest == nil, let window, window.attachedSheet == nil,
              let (revision, side) = pendingPickerSelection else { return }
        pendingPickerSelection = nil
        if let focus = pickerFocus { window.makeFirstResponder(focus) }; pickerFocus = nil
        if let revision { model.choose(revision, side: side) }
        else if model.snapshot == nil { model.load(inlineErrors: true) }
    }
    func showReferencePicker(side: ComparisonSide) {
        guard let request = beginPicker(), let window else { return }
        let picker = ReferenceBrowserWindowController(repository: model.repository, access: model.access,
            initial: side == .base ? model.from : model.to, preferences: model.preferences) { [weak self] value in
                self?.finishPicker(request, revision: value, side: side)
            }
        referencePicker = picker; model.configureReferencePicker(picker.model)
        if let child = picker.window { child.alphaValue = window.alphaValue; window.beginSheet(child) }
        picker.model.load()
    }
    func showHistoryPicker(side: ComparisonSide, reflog: Bool) {
        guard let request = beginPicker(), let window else { return }
        if reflog {
            let picker = ReferenceLogWindowController(repository: model.repository, access: model.access, reference: "HEAD", onChoose: { [weak self] entry in
                self?.finishPicker(request, revision: entry?.hash, side: side)
            }, preferences: model.preferences)
            reflogPicker = picker
            if let child = picker.window { child.alphaValue = window.alphaValue; window.beginSheet(child) }
        } else {
            let revision = side == .base ? model.from : model.to
            let initial = ["working tree", "empty tree"].contains(revision.lowercased()) ? "HEAD" : revision
            let picker = LogWindowController(repository: model.repository, access: model.access, onChoose: { [weak self] entry in
                self?.finishPicker(request, revision: entry?.hash, side: side)
            }, labelDefaults: model.preferences, initialRevision: initial, historyRegexExecutable: historyRegexExecutable)
            logPicker = picker; model.configureLogPicker(picker.model)
            if let child = picker.window { child.alphaValue = window.alphaValue; window.beginSheet(child) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender.attachedSheet==nil,model.cancelFileAction(closeAfter:true) { return false }
        guard sender.attachedSheet == nil, !model.busy, model.patchWindow?.model.busy != true, model.patchWindow?.window?.attachedSheet == nil, !model.unifiedWindows.values.contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }), !model.comparisonWindows.values.contains(where: { $0.model.busy }) else { return false }
        guard PatchDocumentSession.permitOwnerClose(Array(model.unifiedWindows.values)) else { return false }
        if let child = model.comparisonWindows.values.first(where: { $0.model.dirty }) {
            child.window?.makeKeyAndOrderFront(nil); child.window?.performClose(nil); return false
        }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        pickerRequest = nil; pickerFocus = nil; pendingPickerSelection = nil; fileActionPresenter?.retire(); model.invalidate()
        let history = Array(rangeLogs.values); rangeLogs.removeAll(); history.forEach { $0.close() }
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        referencePicker?.abandonPresentation(); referencePicker = nil
        logPicker?.close(); logPicker = nil; reflogPicker?.close(); reflogPicker = nil
        model.patchWindow?.close(); Array(model.unifiedWindows.values).forEach { $0.close() }
        Array(model.comparisonWindows.values).forEach { $0.close() }; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// File commands attach their panels to the owning dialog, including embedded lists.
@MainActor final class RevisionFileActionPresenter {
    let model:RevisionComparisonWindowModel
    weak var window:NSWindow?
    private(set) lazy var filePanels = OwnedFilePanelSession(window:window)
    private var messageAlert:NSAlert?
    init(model:RevisionComparisonWindowModel,window:NSWindow?) {
        self.model=model;self.window=window
        model.chooseExportFolder={ [weak self] in
            guard let self, !self.model.closed else { return nil }
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            panel.prompt = "Export"; panel.message = "Export selected changed files to a folder."; panel.alphaValue = self.window?.alphaValue ?? 1
            return await self.filePanels.choose(panel)
        }
        model.cancelFilePicker={ [weak self] in self?.cancelOwnedSheets() }
        model.chooseHistoricalApplication={ [weak self] in
            guard let self, !self.model.closed else { return nil }
            let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"; panel.allowedContentTypes = [.applicationBundle]
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath:"/Applications")
            panel.alphaValue = self.window?.alphaValue ?? 1
            return await self.filePanels.choose(panel)
        }
        model.chooseHistoricalSave={ [weak self] content in
            guard let self, !self.model.closed else { return nil }
            let panel = NSSavePanel(); panel.title = "Save file at revision"; panel.canCreateDirectories = true; panel.allowsOtherFileTypes = true
            let name = (content.path as NSString).lastPathComponent as NSString, ext = name.pathExtension
            panel.nameFieldStringValue = name.deletingPathExtension + "-" + String(content.revision.label.prefix(8)) + (ext.isEmpty ? "":"."+ext)
            panel.alphaValue = self.window?.alphaValue ?? 1
            return await self.filePanels.choose(panel)
        }
        model.chooseFileList={ [weak self] in
            guard let self, !self.model.closed else { return nil }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "changed-files.txt"; panel.allowedContentTypes = [.plainText]; panel.canCreateDirectories = true
            panel.alphaValue = self.window?.alphaValue ?? 1
            return await self.filePanels.choose(panel)
        }
        model.openHistoricalContent={ [weak self] content,action,application in
            guard let self,!self.model.closed else {return}
            let model=self.model
            let preview=try HistoricalFilePreview.create(content);HistoricalPreviewFiles.retain(preview)
            do {
                if action == .alternativeEditor {
                    guard let token=model.historicalFileCancellation else {throw OperationCancellationFailure.cancelled}
                    try await AlternativeEditor.openDocument(preview.file,settings:model.historicalEditorSettings ?? .load(from:model.preferences),permissions:model.access.map {[$0]} ?? [],cancellation:token)
                } else if let application {
                    let scoped=application.startAccessingSecurityScopedResource();defer {if scoped{application.stopAccessingSecurityScopedResource()}}
                    let message:String?=await withCheckedContinuation {reply in NSWorkspace.shared.open([preview.file],withApplicationAt:application,configuration:NSWorkspace.OpenConfiguration()){_,error in reply.resume(returning:error?.localizedDescription)}}
                    if let message {throw CocoaError(.fileReadUnknown,userInfo:[NSLocalizedDescriptionKey:message])}
                } else if !NSWorkspace.shared.open(preview.file) {throw CocoaError(.fileReadUnknown,userInfo:[NSLocalizedDescriptionKey:"Could not open the historical file. Choose an application using Open With."])}
            } catch {HistoricalPreviewFiles.discard(preview.file);throw error}
            withExtendedLifetime(self) {}
        }
        model.fileActionFailure={ [weak self] message in guard let self else{return false};return await self.fileActionMessage(message,question:true) }
        model.fileActionNotice={ [weak self] message in guard let self else{return};_ = await self.fileActionMessage(message,question:false) }
    }
    func retire() { filePanels.retire(); cancelOwnedSheets() }
    private func cancelOwnedSheets() {
        filePanels.cancel()
        if let alert=messageAlert,window?.attachedSheet===alert.window {window?.endSheet(alert.window,returnCode:.abort);alert.window.orderOut(nil)}
    }
    private func fileActionMessage(_ message:String,question:Bool) async -> Bool {
        guard let window,!model.closed,window.attachedSheet==nil else {return false}
        return await withCheckedContinuation { reply in
            let alert=NSAlert();alert.messageText=question ? "Could not complete file operation." : "TurtleGit";alert.informativeText=message;alert.alertStyle=question ? .warning : .informational
            for title in question ? ["Ignore","Abort"] : ["OK"] {alert.addButton(withTitle:title).keyEquivalent=""}
            alert.window.alphaValue=window.alphaValue
            messageAlert=alert
            alert.beginSheetModal(for:window) { [weak self] response in self?.messageAlert=nil;reply.resume(returning:response == .alertFirstButtonReturn)}
            let primary=alert.buttons.last!;primary.keyEquivalent="\r";alert.window.defaultButtonCell=primary.cell as? NSButtonCell
        }
    }
 }

@MainActor final class RevisionComparisonWindowModel: ObservableObject {
    let scopePaths: [String]
    let repository: GitRepository
    let access: RepositoryAccessLease?
    weak var window: NSWindow?
    @Published var from: String { didSet { invalidateFileMenus(); cancelSelectionPreparations() } }
    @Published var to: String { didSet { invalidateFileMenus(); cancelSelectionPreparations() } }
    @Published var references: [CheckoutReference] = []
    @Published var basePickerAction = ComparisonPickerAction.browse { didSet { invalidateFileMenus() } }
    @Published var destinationPickerAction = ComparisonPickerAction.browse { didSet { invalidateFileMenus() } }
    func pickerAction(_ side: ComparisonSide) -> ComparisonPickerAction { side == .base ? basePickerAction:destinationPickerAction }
    func performPickerAction(_ side: ComparisonSide) {
        guard canChangeColumns else { return }
        switch pickerAction(side) {
        case .browse: pickReferences(side)
        case .log: pickHistory(side,false)
        case .reflog: pickHistory(side,true)
        }
    }
    var pickReferences: (ComparisonSide) -> Void = { _ in }
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    @Published private(set) var inputMessage = ""
    private var inputTask: Task<Void, Never>?
    private var inputGeneration = UUID()
    var pickHistory: (ComparisonSide, Bool) -> Void = { _, _ in }
    @Published var snapshot: RevisionComparisonSnapshot? { didSet { invalidateFileMenus() } }
    private var selectedPaths = GitPathSet()
    @Published var nativeSelection = Set<String>() {
        didSet {
            guard nativeSelection != oldValue else { return }
            selectedPaths = GitPathRowIdentity.paths(nativeSelection).intersection(visibleFiles.map(\.path))
            let valid = Set(selectedPaths.map(GitPathRowIdentity.encode))
            if nativeSelection != valid { nativeSelection = valid }
            invalidateFileMenus(); cancelSelectionPreparations(); updatePatch()
        }
    }
    var selection: GitPathSet {
        get { selectedPaths }
        set { let ids = Set(newValue.map(GitPathRowIdentity.encode)); if nativeSelection != ids { nativeSelection = ids } }
    }
    @Published var filter = "" { didSet { invalidateFileMenus(); selection.formIntersection(visibleFiles.map(\.path)); updatePatch() } }
    @Published var sortOrder = [KeyPathComparator(\CommitFile.sortPath)] { didSet { invalidateFileMenus() } }
    @Published var options = RevisionDiffOptions() { didSet { invalidateFileMenus(); cancelSelectionPreparations() } }
    @Published var busy = false { didSet { if busy != oldValue { invalidateFileMenus() } } }
    @Published var confirmingQuit = false { didSet { if confirmingQuit != oldValue { invalidateFileMenus() } } }
    private(set) var fileMenuEpoch = UUID()
    private func invalidateFileMenus() { fileMenuEpoch = UUID() }
    private func cancelSelectionPreparations() {
        if let token = fileActionToken { token.cancel(); cancelFilePicker() }
        comparisonSessions.values.forEach { $0.cancel() }; patchTokens.values.forEach { $0.cancel() }
    }
    @Published var error: String?
    @Published var showingPatch = false
    var patchWindow: PatchWindowController?
    var unifiedWindows = GitPathMap<PatchWindowController>()
    private var patchGeneration = 0
    private(set) static var activeFileOperations = 0
    let preferences: UserDefaults
    var captureMaterializationBackend:(()->GitLibGit2Configuration)?
    private func materializationBackend()->GitLibGit2Configuration {captureMaterializationBackend?() ?? .load(from:preferences)}
    var confirmManyDiffs: ((Int) async -> Bool)?
    var openComparedFile: ((RevisionComparisonSnapshot, CommitFile) -> Void)?
    private var comparisonSessions: [UUID: FileListComparisonSession] = [:]
    private var patchTokens: [UUID: OperationCancellation] = [:]
    private var loadToken: OperationCancellation?
    @Published private(set) var bare=false
    @Published private(set) var fileActionTitle=""
    private var fileActionToken:OperationCancellation?
    var historicalFileCancellation:OperationCancellation? {fileActionToken}
    private(set) var historicalEditorSettings:AlternativeEditorPreferences?
    private var closeAfterFileAction=false
    private var actionGeneration=UUID()
    private let menuOwner=UUID()
    var close:()->Void = {}
    var cancelFilePicker:()->Void = {}
    var chooseExportFolder:() async -> URL? = { nil }
    var chooseHistoricalApplication:() async -> URL? = {nil}
    var chooseFileList: () async -> URL? = { nil }
    var chooseHistoricalSave:(ComparisonFileContent) async -> URL? = {_ in nil}
    var openHistoricalContent:(ComparisonFileContent,HistoricalOpenAction,URL?) async throws -> Void = {_,_,_ in}
    var fileActionFailure:(String) async -> Bool = { _ in false }
    var fileActionNotice:(String) async -> Void = { _ in }
    var onBlame:(String,String)->Void = { _,_ in }
    var onSubmoduleLog:(URL,String?)->Void = { _,_ in }
    var onFilesChanged:()->Void = {}
    private(set) var actionTrash:[URL]=[]
    private(set) var closed = false
    func invalidate() { closed = true; cancelPendingInput();actionGeneration=UUID();fileActionToken?.cancel();cancelFilePicker();closeAfterFileAction=false; comparisonSessions.values.forEach { $0.cancel() }; patchTokens.values.forEach { $0.cancel() }; patchTokens.removeAll(); loadToken?.cancel(); loadToken = nil; patchGeneration += 1; busy = false }
    var onLog: (String?) -> Void = { _ in }
    var onLogRange: ((HistoryRevisionRange) -> Void)?
    var onFileLog: (String, String?) -> Void = { _, _ in }
    var onSubmoduleCompare: (String, String?, ComparisonRevision, ComparisonRevision) -> Void = { _, _, _, _ in }
    var comparisonWindows = GitPathMap<FileComparisonWindowController>()
    @Published var fileColumns: StatusListColumnSettings { didSet { invalidateFileMenus() } }
    @Published var focusedFile: String? {
        didSet { if oldValue.map({GitReferenceName($0)}) != focusedFile.map({GitReferenceName($0)}) { invalidateFileMenus() } }
    }
    @Published private(set) var resettingColumns = false
    private var columnsRequest = UUID()
    static let columnsKey = "FileDiff.Columns"
    let fileColumnsKey:String
    var clipboard:NSPasteboard = .general
    var canChangeColumns: Bool { !closed && !busy && !confirmingQuit && !resettingColumns && window?.attachedSheet == nil }
    @discardableResult func saveFileLayout(order: [StatusListColumn], widths: [StatusListColumn: Double]) -> Bool {
        guard canChangeColumns else { return false }
        let allowed = Set(StatusListColumn.defaultColumns)
        let next = StatusListColumnSettings(visible: fileColumns.visible.intersection(allowed), order: order, widths: widths.filter { allowed.contains($0.key) })
        if next != fileColumns { fileColumns = next; next.save(to: preferences, key: fileColumnsKey) }
        return true
    }
    func setFileColumn(_ column: StatusListColumn, visible: Bool) {
        guard canChangeColumns, StatusListColumn.defaultColumns.contains(column), column != .path else { return }
        if visible { fileColumns.visible.insert(column) } else { fileColumns.visible.remove(column) }
        fileColumns.save(to: preferences, key: fileColumnsKey)
    }
    func resetFileColumns(choose: @escaping () async -> Bool, accepted: @escaping () -> Void) {
        guard canChangeColumns else { return }
        let request = UUID(); columnsRequest = request; resettingColumns = true
        Task { [weak self] in
            guard let self else { return }; let yes = await choose()
            guard !closed, columnsRequest == request else { return }; resettingColumns = false
            guard yes, !busy else { return }
            fileColumns = StatusListColumnSettings(); fileColumns.save(to: preferences, key: fileColumnsKey); accepted()
        }
    }
    func fileText(_ file: CommitFile, column: StatusListColumn) -> String {
        switch column {
        case .path: return StatusListClipboard.displayedPath(file, abbreviate: preferences.bool(forKey: "AbbreviateRenamings"))
        case .fileExtension: return StatusListClipboard.fileExtension(file.path, isDirectory: file.isSubmodule)
        case .status: return FileListLabels.caption(file.status)
        case .added: return file.addedText
        case .removed: return file.removedText
        default: return ""
        }
    }
    var completionNames: [String] {
        GitPathSet(["HEAD"] + references.map { ref in
            if ref.name.hasPrefix("refs/heads/") { return String(ref.name.dropFirst(11)) }
            if ref.name.hasPrefix("refs/tags/") { return String(ref.name.dropFirst(10)) }
            if ref.name.hasPrefix("refs/remotes/") { return String(ref.name.dropFirst(13)) }
            return ref.name
        }).sorted { $0 == $1 ? $0.utf8.lexicographicallyPrecedes($1.utf8):$0 < $1 }
    }
    var visibleFiles: [CommitFile] {
        let query = ComparisonPathFilter(filter)
        return snapshot?.files.filter { query.matches(path: $0.path, oldPath: $0.oldPath) }.sorted { a,b in
            for comparator in sortOrder { let result = comparator.compare(a,b); if result != .orderedSame { return result == .orderedAscending } }
            let ascending = a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
            return sortOrder.first?.order == .reverse ? !GitReferenceName.equal(a.path,b.path) && !ascending:ascending
        } ?? []
    }
    let alternateTool = ComparisonToolInvocation.alternate
    init(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision, paths: [String] = [], preferences: UserDefaults = .standard, columnsKey:String = RevisionComparisonWindowModel.columnsKey) {
        fileColumnsKey=columnsKey;self.preferences = preferences; self.repository = repository; self.access = access
        self.from = from.label; self.to = to.label; scopePaths = paths
        fileColumns = StatusListColumnSettings.load(from: preferences, key: fileColumnsKey)
    }
    /// Replace an embedded commit atomically; old popup payloads and preparations
    /// cannot act on the newly selected commit, even if it has identical paths.
    func clearEmbeddedSnapshot() {
        cancelPendingInput();loadToken?.cancel();actionGeneration=UUID();snapshot=nil;selection=[]
        comparisonSessions.values.forEach { $0.cancel() };patchTokens.values.forEach { $0.cancel() }
        fileActionToken?.cancel();cancelFilePicker();patchGeneration += 1
    }
    func installEmbeddedSnapshot(_ value:RevisionComparisonSnapshot,bare:Bool) {
        guard !closed else {return}
        actionGeneration=UUID();from=value.from.label;to=value.to.label;options=value.options
        self.bare=bare;snapshot=value;selection=[]
    }
    var hasOwnedPreparation:Bool { fileActionToken != nil || !comparisonSessions.isEmpty || !patchTokens.isEmpty || loadToken != nil }
    @discardableResult func cancelEmbeddedPreparation() -> Bool {
        guard hasOwnedPreparation else {return false}
        fileActionToken?.cancel();cancelFilePicker();comparisonSessions.values.forEach {$0.cancel()};patchTokens.values.forEach {$0.cancel()};loadToken?.cancel();return true
    }
    func closeOwnedViewers() {
        patchWindow?.close();Array(unifiedWindows.values).forEach {$0.close()};Array(comparisonWindows.values).forEach {$0.close()}
    }
    func cancelPendingInput() { inputGeneration = UUID(); inputTask?.cancel(); inputTask = nil }
    func editRevision(_ value: String, side: ComparisonSide) {
        guard !closed, !confirmingQuit, !busy || loadToken != nil, window?.attachedSheet == nil else { return }
        if side == .base { from = value } else { to = value }
        cancelPendingInput(); loadToken?.cancel()
        if loadToken != nil { loadToken = nil; busy = false }
        actionGeneration = UUID(); snapshot = nil; selection = []; patchGeneration += 1
        patchWindow?.model.document = GitPatch(text: ""); patchWindow?.model.busy = false
        inputMessage = "Wait for input to validate version…"
        let request = inputGeneration
        inputTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self, !closed, inputGeneration == request else { return }
            inputTask = nil; load(inlineErrors: true)
        }
    }
    func canReuseForComparison(from requestedFrom: ComparisonRevision, to requestedTo: ComparisonRevision, paths: [String] = []) -> Bool {
        !closed && inputTask == nil && !resettingColumns && !busy && !confirmingQuit && scopePaths.map({GitReferenceName($0)}) == paths.map({GitReferenceName($0)}) && GitReferenceName.equal(from,requestedFrom.label) && GitReferenceName.equal(to,requestedTo.label) &&
        patchWindow?.model.busy != true && patchWindow?.window?.attachedSheet == nil &&
        !unifiedWindows.values.contains { $0.model.busy || $0.window?.attachedSheet != nil } &&
        !comparisonWindows.values.contains { $0.model.busy || $0.model.dirty }
    }
    private func side(_ input: String) -> ComparisonRevision {
        switch input.lowercased() { case "working tree": return .workingTree; case "empty tree": return .emptyTree; default: return .revision(input) }
    }
    func load(inlineErrors: Bool = false) {
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        guard !closed, !busy, !confirmingQuit else { return }; cancelPendingInput(); busy = true; inputMessage = ""; error = nil
        let token = OperationCancellation(); loadToken = token;actionGeneration=UUID()
        let old = side(from), new = side(to), settings = options
        snapshot = nil; selection = []; patchGeneration += 1; patchWindow?.model.document = GitPatch(text: ""); patchWindow?.model.busy = false
        Self.activeFileOperations += 1
        Task {
            defer { Self.activeFileOperations -= 1; if loadToken === token { loadToken = nil; busy = false }; withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let catalog = try await repository.checkoutReferences(includeAll: true, includeFetchHead: preferences.includesFetchHead, localBranchesFirst: AdvancedListBehavior(defaults: preferences).localBranchesFirst, cancellation: token)
                guard !closed, loadToken === token, !token.isCancelled else { return }; references = catalog
                let isBare=try await repository.isBare(cancellation:token)
                let result = try await repository.revisionComparison(from: old, to: new, options: settings, cancellation: token, paths: scopePaths)
                guard !closed, loadToken === token, !token.isCancelled else { return }
                bare=isBare;references = catalog; snapshot = result
                if showingPatch { updatePatch() }
            }
            catch { if !closed, loadToken === token, !token.isCancelled { if inlineErrors { inputMessage = "Invalid reference: " + error.localizedDescription } else { self.error = error.localizedDescription } } }
        }
    }
    func choose(_ revision: String, side: ComparisonSide) {
        guard !closed, !busy, !confirmingQuit else { return }
        cancelPendingInput()
        if side == .base { from = revision } else { to = revision }
        load()
    }
    func revisionDescription(base: Bool) -> String {
        guard let snapshot else { return "" }
        if let detail = base ? snapshot.fromDetails : snapshot.toDetails { return detail.shortHash + ": " + detail.subject }
        return (base ? snapshot.from : snapshot.to).label
    }
    func revisionTooltip(base: Bool) -> String {
        guard let snapshot, let detail = base ? snapshot.fromDetails : snapshot.toDetails else { return "" }
        if detail.isTree { return "Tree object — no commit metadata" }
        return (detail.authorDate?.formatted(date: .numeric, time: .standard) ?? "") + "  " + detail.author
    }
    func revisionTitle(base: Bool) -> String {
        let title = base ? "Version 1 (Base)" : "Version 2"
        guard let a = snapshot?.fromDetails?.committerDate, let b = snapshot?.toDetails?.committerDate else { return title }
        return (base ? a > b : b > a) ? title + " (newer)" : title
    }
    func swap() { guard !closed, !busy, !confirmingQuit, side(to) != .workingTree else { return }; (from, to) = (to, from); load() }
    func log() {
        guard !closed, !busy, !confirmingQuit, let snapshot else { return }
        guard snapshot.fromDetails?.isTree != true, snapshot.toDetails?.isTree != true, snapshot.to != .emptyTree else {
            error = "Tree objects have no commit history. Choose a commit or tag to view history."; return
        }
        let destination = snapshot.to == .workingTree ? "HEAD":snapshot.to.label
        if snapshot.from == .emptyTree { onLog(snapshot.to == .workingTree ? nil:destination); return }
        let base = snapshot.from == .workingTree ? "HEAD":snapshot.from.label
        let range = HistoryRevisionRange(from:base,to:destination)
        onLogRange?(range)
    }
    func logFiles(_ ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard !closed, !busy, !confirmingQuit, let snapshot else { return }
        guard snapshot.toDetails?.isTree != true else { error = "Tree objects have no commit history. Choose a commit or tag to view history."; return }
        let revision: String? = { if case .revision(let value) = snapshot.to { return value }; return nil }()
        for file in visibleFiles where ids.contains(file.path) { onFileLog(file.path, revision) }
    }
    private func runFiles(_ files: [CommitFile], operation: @escaping (OperationCancellation) async -> Void) {
        guard !closed, !busy, !confirmingQuit, !files.isEmpty else { return }
        let request = UUID(), session = FileListComparisonSession(window: window, preferences: preferences, alternateTool: alternateTool)
        session.confirmation = confirmManyDiffs; comparisonSessions[request] = session
        patchTokens[request] = session.cancellation; busy = true; Self.activeFileOperations += 1
        Task {
            defer { Self.activeFileOperations -= 1; comparisonSessions.removeValue(forKey: request); patchTokens.removeValue(forKey: request); if !closed { busy = false }; withExtendedLifetime(access) {} }
            do {
                try await session.run(selectedCount: files.count) { [self] token in
                    guard !closed, !confirmingQuit, !token.isCancelled else { return }; await operation(token)
                }
            } catch { if !closed, !session.cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }

    func compare(_ ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard !closed, !busy, !confirmingQuit, let snapshot else { return }
        let files = visibleFiles.filter { ids.contains($0.path) }
        runFiles(files) { [self] token in
        for file in files {
            guard !closed, !token.isCancelled else { return }
            if let openComparedFile { openComparedFile(snapshot, file); continue }
            if file.isSubmodule { onSubmoduleCompare(file.path, file.oldPath, snapshot.from, snapshot.to); continue }
            let key = file.path + "\0" + snapshot.from.label + "\0" + snapshot.to.label + "\0" + ComparisonToolInvocation.cacheKey
            let controller = comparisonWindows[key] ?? FileComparisonWindowController(repository: repository, access: access, snapshot: snapshot, path: file.path)
            controller.onClosed = { [weak self] in self?.comparisonWindows.removeValue(forKey: key) }
            comparisonWindows[key] = controller
            controller.model.comparisonDefaults = preferences
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
        }
    }
    func copyPaths(_ ids: some Sequence<String>, extended: Bool = false) {
        let ids = GitPathSet(ids)
        guard !closed, !busy, !confirmingQuit else { return }
        let files = visibleFiles.filter { ids.contains($0.path) }; guard !files.isEmpty else { return }
        clipboard.clearContents(); clipboard.setString(ComparisonFileList.clipboard(files, extended: extended,label:FileListLabels.caption), forType: .string)
    }
    func copyColumn(_ ids: some Sequence<String>, column: StatusListColumn) {
        let ids = GitPathSet(ids)
        guard !closed, !busy, !confirmingQuit else { return }
        let files = visibleFiles.filter { ids.contains($0.path) }; guard !files.isEmpty else { return }
        clipboard.clearContents(); clipboard.setString(files.map { fileText($0, column: column) }.joined(separator: "\r\n"), forType: .string)
    }
    func saveList(_ ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        runFileAction(ids,title:"Save list of selected files") { [self] snapshot,files,token in
            let text = ComparisonFileList.savedList(files,from:snapshot.from,to:snapshot.to)
            guard let destination = await chooseFileList(), !closed, !token.isCancelled else { return }
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            if GitRuntime.isAppStoreBuild && !scoped { throw RepositoryAccessFailure.securityScopeUnavailable }
            try text.write(to:destination,atomically:true,encoding:.utf8)
        }
    }
    func togglePatch() {
        guard !closed, !busy, !confirmingQuit, patchWindow?.model.busy != true, patchWindow?.window?.attachedSheet == nil else { return }
        if showingPatch { patchWindow?.close(); return }
        let controller = PatchWindowController(repository: repository, access: access, preferences:preferences)
        RepositoryWindowTitles.set(controller.window, repository: repository.root, dialog: "Unified Diff", preferences: preferences)
        controller.model.readOnly = true
        controller.model.readOnlyInformation = "Read-only comparison. Select files in Changed Files to inspect their patch."
        controller.model.customRefresh = { [weak self] in self?.updatePatch() }
        controller.onClosed = { [weak self] in self?.patchGeneration += 1; self?.showingPatch = false; self?.patchWindow = nil }
        patchWindow = controller; showingPatch = true
        if let window, let patch = controller.window, let screen = window.screen {
            let visible = screen.visibleFrame
            let x = max(visible.minX, min(window.frame.maxX + 8, visible.maxX - patch.frame.width))
            let y = max(visible.minY, min(window.frame.maxY - patch.frame.height, visible.maxY - patch.frame.height))
            patch.setFrameOrigin(NSPoint(x: x, y: y))
        }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); updatePatch()
    }
    func showPatch(_ ids: some Sequence<String>, alternate: Bool) {
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        let ids = GitPathSet(ids)
        guard !closed, !busy, !confirmingQuit, let snapshot, !unifiedWindows.values.contains(where: { $0.model.busy }) else { return }
        let files = visibleFiles.filter { ids.contains($0.path) }
        guard !files.isEmpty else { return }
        runFiles(files) { [self] token in
            var failures: [String] = []
            for file in files {
                guard !closed, !token.isCancelled else { return }
                do {
                    try checkPatchAccess()
                    let bytes = try await repository.revisionComparisonPatchData(snapshot, paths: [file.path], cancellation: token)
                    guard !closed, !token.isCancelled else { return }
                    if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: preferences, title: "\(snapshot.from.label.prefix(12)) → \(snapshot.to.label.prefix(12))", permissions: access.map { [$0] } ?? [], cancellation: token), !closed, !token.isCancelled {
                        let controller = unifiedWindows[file.path] ?? PatchWindowController(repository: repository, access: access, preferences:preferences)
                        controller.presentDocument(bytes, title: "\(file.path) – Unified Diff – TurtleGit",
                            comparison: "\(snapshot.from.label.prefix(12)) → \(snapshot.to.label.prefix(12))",
                            information: "Unified diff for \(file.path). Right-click to save the patch.", paths: [file.path], refreshAvailable: true, refresh: { [weak self, weak controller] in
                                guard let self, let controller, !self.closed, !controller.model.busy, !controller.model.confirmingQuit else { return }
                                let identity = controller.documentSession.documentIdentity
                                controller.model.busy = true
                                let refresh = UUID(), token = OperationCancellation(); self.patchTokens[refresh] = token
                                let repository=self.repository.capturingDiffBackend(preferences:self.preferences)
                                Task {
                                    defer { self.patchTokens.removeValue(forKey: refresh); if !self.closed { controller.model.busy = false } }
                                    do {
                                        try self.checkPatchAccess()
                                        let bytes = try await repository.revisionComparisonPatchData(snapshot, paths: [file.path], cancellation: token)
                                        guard !self.closed, !token.isCancelled, controller.documentSession.documentIdentity == identity else { return }
                                        controller.documentSession.replace(bytes)
                                    } catch { if !self.closed, !token.isCancelled { controller.model.error = error.localizedDescription } }
                                }
                            })
                        controller.onClosed = { [weak self] in self?.unifiedWindows.removeValue(forKey: file.path) }
                        unifiedWindows[file.path] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
                    }
                } catch { failures.append(file.path + ": " + error.localizedDescription) }
            }
            if !closed, !token.isCancelled, !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }
    private func checkPatchAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func updatePatch() {
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        guard !closed, showingPatch, let controller = patchWindow, let snapshot else { return }
        patchGeneration += 1; let request = patchGeneration
        let paths = visibleFiles.filter { selection.contains($0.path) }.map(\.path)
        controller.model.busy = true; controller.model.comparisonTitle = "\(snapshot.from.label.prefix(12)) → \(snapshot.to.label.prefix(12))"
        controller.model.paths = paths
        let id = UUID(), token = OperationCancellation(); patchTokens[id] = token
        Task {
            defer { patchTokens.removeValue(forKey: id) }
            do {
                let bytes = paths.isEmpty ? Data() : try await repository.revisionComparisonPatchData(snapshot, paths: paths, cancellation: token)
                guard !closed, request == patchGeneration else { return }
                controller.model.setReadOnlyDiff(bytes); controller.model.busy = false
            } catch { if !closed, request == patchGeneration { controller.model.error = error.localizedDescription; controller.model.busy = false } }
        }
    }
    final class FileMenuContext {
        fileprivate var consumed=false
        fileprivate let generation:UUID,epoch:UUID,owner:UUID,from:String,to:String,options:RevisionDiffOptions,files:[CommitFile]
        fileprivate init(generation:UUID,epoch:UUID,owner:UUID,from:String,to:String,options:RevisionDiffOptions,files:[CommitFile]) {self.generation=generation;self.epoch=epoch;self.owner=owner;self.from=from;self.to=to;self.options=options;self.files=files}
    }
    func captureFileMenu(_ ids:some Sequence<String>)->FileMenuContext? {
        let ids = GitPathSet(ids)
        let files=visibleFiles.filter{ids.contains($0.path)}
        guard !closed,!busy,!files.isEmpty,snapshot != nil else{return nil}
        return FileMenuContext(generation:actionGeneration,epoch:fileMenuEpoch,owner:menuOwner,from:from,to:to,options:options,files:files)
    }
    func claimFileMenu(_ context:FileMenuContext?)->Bool {
        guard let context,!context.consumed,!closed,!busy,!confirmingQuit,window?.attachedSheet==nil,
              context.owner==menuOwner,context.epoch==fileMenuEpoch,!resettingColumns,context.generation==actionGeneration,context.from.utf8.elementsEqual(from.utf8),context.to.utf8.elementsEqual(to.utf8),context.options==options,
              visibleFiles.filter({file in context.files.contains{GitReferenceName.equal($0.path,file.path)}})==context.files else{return false}
        context.consumed=true;return true
    }
    var fileActionActive:Bool { fileActionToken != nil }
    @discardableResult func cancelFileAction(closeAfter:Bool=false)->Bool {
        guard let token=fileActionToken else { return false };closeAfterFileAction = closeAfterFileAction || closeAfter
        token.cancel();cancelFilePicker();return true
    }
    func canRevertFiles(_ ids:some Sequence<String>,base:Bool)->Bool {
        let ids = GitPathSet(ids)
        guard !closed,!busy,!bare,let snapshot,let first=visibleFiles.first(where:{ids.contains($0.path)}),(base ? snapshot.from : snapshot.to) != .workingTree else { return false }
        return base || snapshot.from == .workingTree || !first.action.hasPrefix("D")
    }
    func revertTitle(base:Bool)->String {
        guard let snapshot else { return "Revert" }
        let side = base ? snapshot.from : snapshot.to
        return side == .emptyTree ? "Revert to empty tree" : "Revert to revision "+String(side.label.prefix(8))
    }
    func canBlameFiles(_ ids:some Sequence<String>)->Bool {
        let ids = GitPathSet(ids)
        guard !closed,!busy,!bare,let snapshot,visibleFiles.first(where:{ids.contains($0.path)})?.isSubmodule==false else {return false}
        return visibleFiles.filter{ids.contains($0.path) && !$0.isSubmodule}.contains { file in
            if file.action.hasPrefix("D") {return snapshot.fromDetails?.isTree != true && snapshot.from != .workingTree && snapshot.from != .emptyTree}
            if snapshot.to == .workingTree {return !file.action.hasPrefix("A") && (!file.action.hasPrefix("R") || snapshot.fromDetails?.isTree != true)}
            return snapshot.to != .emptyTree && snapshot.toDetails?.isTree != true
        }
    }
    func blameFiles(_ ids:some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard canBlameFiles(ids),let snapshot else { return }
        let files=visibleFiles.filter{ids.contains($0.path)}
        runFiles(files) { [self] token in
            for file in files where !file.isSubmodule {
                guard !closed,!token.isCancelled else { return }
                if file.action.hasPrefix("D") {
                    if case .revision(let hash)=snapshot.from,snapshot.fromDetails?.isTree != true { onBlame(file.path,hash) }
                } else if snapshot.to == .workingTree {
                    if file.action.hasPrefix("A") { continue }
                    if file.action.hasPrefix("R") {
                        if snapshot.fromDetails?.isTree != true,case .revision(let hash)=snapshot.from {onBlame(file.oldPath ?? file.path,hash)}
                    } else {onBlame(file.path,"HEAD")}
                } else if snapshot.toDetails?.isTree != true,case .revision(let hash)=snapshot.to {onBlame(file.path,hash)}
            }
        }
    }
    func logSubmodules(_ ids:some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard !closed,!busy,let snapshot else { return }
        let files=visibleFiles.filter{ids.contains($0.path) && $0.isSubmodule}
        let repository = self.repository.capturingDiffBackend(preferences:preferences)
        let pin=preferences.object(forKey:"LogSubmoduleShowRevision")==nil || preferences.bool(forKey:"LogSubmoduleShowRevision")
        runFiles(files) { [self] token in
            for file in files {
                guard !closed,!token.isCancelled else { return }
                do {
                    let child=try await repository.submoduleWorkingRepository(path:file.path,cancellation:token)
                    let comparison=try await repository.submoduleComparison(path:file.path,from:snapshot.from == .emptyTree ? "" : snapshot.from == .workingTree ? "HEAD" : snapshot.from.label,to:snapshot.to == .workingTree ? nil : snapshot.to == .emptyTree ? "" : snapshot.to.label,cancellation:token)
                    guard !closed,!token.isCancelled else { continue }
                    onSubmoduleLog(child.root,pin && snapshot.to != .workingTree && !file.action.hasPrefix("D") ? comparison.to.revision : nil)
                } catch {if !closed,!token.isCancelled {self.error=error.localizedDescription;return}}
            }
        }
    }
    func revertFiles(_ ids:some Sequence<String>,base:Bool) {
        let ids = GitPathSet(ids)
        guard canRevertFiles(ids,base:base) else { return }
        runFileAction(ids,title:revertTitle(base:base)) { [self] snapshot,files,token in
            let batch=try await repository.prepareComparisonRevertBatch(snapshot,files:files,base:base,cancellation:token)
            let recycle=preferences.object(forKey:"RevertWithRecycleBin")==nil || preferences.bool(forKey:"RevertWithRecycleBin")
            var count=0,changed=false
            for file in batch.files {
                guard !closed,!token.isCancelled else { break }
                do {
                    let target=try await repository.prepareComparisonRevertFile(batch,file:file,cancellation:token)
                    guard !closed,!token.isCancelled else { break }
                    actionTrash += try await repository.revertComparisonFile(target,recycle:recycle,cancellation:token);count += 1;changed=true
                }
                catch {
                    if let failure=error as? WorkingFileRevertFailure {actionTrash += failure.trashedFiles;changed=true}
                    guard !closed,!token.isCancelled else { break }
                    if !(await fileActionFailure(file.path+"\n"+error.localizedDescription)) {break}
                }
            }
            if changed {onFilesChanged()}
            if !closed,!token.isCancelled {await fileActionNotice("\(count) file(s) reverted to \(batch.revision).")}
        }
    }
    func exportFiles(_ ids:some Sequence<String>) {
        let ids = GitPathSet(ids)
        let backend=materializationBackend()
        runFileAction(ids,title:"Export selected files") { [self] snapshot,files,token in
            guard let folder=await chooseExportFolder(),!closed,!token.isCancelled else {return}
            let scoped=folder.startAccessingSecurityScopedResource();defer{if scoped{folder.stopAccessingSecurityScopedResource()}}
            guard !GitRuntime.isAppStoreBuild || scoped || access?.permits(folder)==true else {throw RepositoryAccessFailure.securityScopeUnavailable}
            let plan=try await repository.prepareComparisonExport(snapshot,files:files,to:folder,cancellation:token,backend:backend)
            for path in plan.paths {
                guard !closed,!token.isCancelled else {break}
                do {try await repository.exportComparisonFile(plan,path:path,cancellation:token)}
                catch {guard !closed,!token.isCancelled else {break};if !(await fileActionFailure(path+"\n"+error.localizedDescription)){break}}
            }
        }
    }
    func canOpenRevisionFile(_ ids:some Sequence<String>)->Bool {
        let ids = GitPathSet(ids)
        guard !closed,!busy,ids.count==1,let snapshot,case .revision=snapshot.to,
              let file=visibleFiles.first(where:{ids.contains($0.path)}) else{return false}
        return !file.isSubmodule && !file.action.hasPrefix("D")
    }
    func openRevisionFile(_ ids:some Sequence<String>,action:HistoricalOpenAction) {
        let ids = GitPathSet(ids)
        guard canOpenRevisionFile(ids) else{return}
        let backend=materializationBackend();historicalEditorSettings = .load(from:preferences)
        runFileAction(ids,title:"Opening file at revision…") { [self] snapshot,files,token in
            let application:URL?
            if action == .openWith {application=await chooseHistoricalApplication();guard application != nil else{return}} else {application=nil}
            try token.check();guard !closed,let file=files.first,case .revision(let hash)=snapshot.to else{return}
            let content=try await repository.materializedHistoricalFile(revision:hash,path:file.path,cancellation:token,backend:backend)
            try token.check();guard !closed else{return}
            try await openHistoricalContent(content,action,application)
        }
    }
    func saveRevisionFile(_ ids:some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard canOpenRevisionFile(ids) else{return}
        let backend=materializationBackend()
        runFileAction(ids,title:"Saving file at revision…") { [self] snapshot,files,token in
            guard let file=files.first,case .revision(let hash)=snapshot.to else{return}
            let content=try await repository.materializedHistoricalFile(revision:hash,path:file.path,cancellation:token,backend:backend)
            try token.check();guard !closed,let destination=await chooseHistoricalSave(content) else{return}
            try token.check();guard !closed else{return}
            let scoped=destination.startAccessingSecurityScopedResource();defer{if scoped{destination.stopAccessingSecurityScopedResource()}}
            if GitRuntime.isAppStoreBuild && !scoped {throw RepositoryAccessFailure.securityScopeUnavailable}
            try content.bytes.write(to:destination,options:.atomic)
        }
    }
    private func runFileAction(_ ids:some Sequence<String>,title:String,operation:@escaping (RevisionComparisonSnapshot,[CommitFile],OperationCancellation) async throws -> Void) {
        let ids = GitPathSet(ids)
        guard !closed,!busy,!confirmingQuit,window?.attachedSheet==nil,let snapshot else {return}
        let files=visibleFiles.filter{ids.contains($0.path)};guard !files.isEmpty else {return}
        let token=OperationCancellation(),generation=actionGeneration
        fileActionToken=token;closeAfterFileAction=false;fileActionTitle=title;actionTrash=[];busy=true;error=nil;Self.activeFileOperations += 1
        Task {
            defer {
                Self.activeFileOperations -= 1;withExtendedLifetime(access) {}
                if fileActionToken === token {fileActionToken=nil;fileActionTitle="";busy=false;let end=closeAfterFileAction;closeAfterFileAction=false;if end,!closed{close()}}
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) {throw RepositoryAccessFailure.securityScopeUnavailable}
                guard !closed,generation==actionGeneration,!token.isCancelled else {return}
                try await operation(snapshot,files,token)
            } catch {if !closed,generation==actionGeneration,!token.isCancelled{self.error=error.localizedDescription}}
        }
    }

}
private struct RevisionComparisonDialog: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: RevisionComparisonWindowModel
    private func revisionGroup(_ title: String, value: Binding<String>, base: Bool) -> some View {
        GroupBox(model.revisionTitle(base: base)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ComparisonRevisionField(value: value.wrappedValue, completions: model.completionNames, changed: { model.editRevision($0, side: base ? .base : .destination) }, submitted: { model.load(inlineErrors: true) })
                    ComparisonRevisionPicker(model:model,side:base ? .base:.destination).frame(width:125)
                }
                Text(model.revisionDescription(base: base)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).help(model.revisionTooltip(base: base))
            }.padding(5)
        }
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Difference between"); Spacer()
                ComparisonDiffOptionsControl(model:model).frame(width:155)
                Button { model.log() } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(model.snapshot == nil)
                Button { model.swap() } label: { Image(nsImage: MenuIcon.reverse.image() ?? NSImage()) }.help("Swap revisions").accessibilityLabel("Swap revisions").disabled(model.to.lowercased() == "working tree")
            }
            revisionGroup("Version 1 (Base)", value: $model.from, base: true)
            revisionGroup("Version 2", value: $model.to, base: false)
            HStack { TextField("Filter paths", text: $model.filter).textFieldStyle(.roundedBorder); if !model.filter.isEmpty { Button("Clear") { model.filter = "" } } }
            RevisionComparisonFileList(model:model)
                .overlay { if !model.inputMessage.isEmpty { Text(model.inputMessage).foregroundStyle(.secondary).padding().textSelection(.enabled) } }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text("\(model.visibleFiles.count) changed file(s)").font(.caption).foregroundStyle(.secondary); Spacer(); Button(model.showingPatch ? "Hide Patch<<" : "View Patch>>") { model.togglePatch() }.buttonStyle(.link).disabled(model.snapshot == nil) }
        }.padding(12).disabled(model.busy || model.confirmingQuit)
        .overlay(alignment:.bottom) {
            if model.fileActionActive {HStack{ProgressView().controlSize(.small);Text(model.fileActionTitle).font(.caption);Spacer();Button("Cancel"){model.cancelFileAction()}}.padding(12).background(.regularMaterial)}
        }.onAppear { model.load() }
        .alert("Comparison failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}


/// Keep Git revision completion in a native text field, including slashes in
/// branch names; accepting a completion goes through the same delayed validation.
private final class ComparisonRevisionNativeField: NSTextField {}
private struct ComparisonRevisionField: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    let value: String
    let completions: [String]
    let changed: (String) -> Void
    let submitted: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = ComparisonRevisionNativeField(string: value)
        field.placeholderString = "Revision"; field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator; field.setAccessibilityLabel("Revision")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self; field.isEnabled = enabled
        if field.stringValue != value { field.stringValue = value }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComparisonRevisionField
        private var completing = false
        init(_ parent: ComparisonRevisionField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field.isEnabled else { return }
            parent.changed(field.stringValue)
            guard !completing, let editor = field.currentEditor() as? NSTextView,
                  !editor.hasMarkedText(), let event = NSApp.currentEvent, event.type == .keyDown,
                  ![51, 117, 53].contains(event.keyCode) else { return }
            completing = true; editor.complete(nil); completing = false
        }
        func control(_ control: NSControl, textView: NSTextView, completions words: [String], forPartialWordRange range: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            let text = textView.string as NSString
            guard range.location <= text.length, range.length <= text.length - range.location else { return [] }
            let prefix = text.substring(with: range); index.pointee = -1
            guard !prefix.isEmpty else { return [] }
            return parent.completions.filter { $0.range(of: prefix, options: [.anchored, .caseInsensitive, .literal]) != nil }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.submitted(); return true }
            return false
        }
    }
}

/// The same native commands, source icons and column behavior in Changed Files
/// and Rebase's historical Revision Files tab.
struct RevisionComparisonFileList:View {
    @ObservedObject private var colorUpdates = StatusColorUpdates.shared
    @ObservedObject var model:RevisionComparisonWindowModel
    var pathTitle="File",statusTitle="Action"
    private func state(_ file: CommitFile) -> FileState {
        switch file.action.first { case "A": return .added; case "D": return .deleted; default: return .modified }
    }
    private func color(_ file: CommitFile) -> Color { model.selection.contains(file.path) ? .primary:state(file).textColor(preferences:model.preferences) }
    var body:some View {
            Table(model.visibleFiles.map(RevisionComparisonFileRow.init), selection: $model.nativeSelection, sortOrder: Binding(get:{model.sortOrder.map(RevisionComparisonFileSort.init)},set:{model.sortOrder=$0.map(\.comparator)})) {
                TableColumn(LocalizedStringKey(pathTitle), sortUsing: RevisionComparisonFileSort(column: .path)) { row in let file = row.file; HStack { Image(nsImage: state(file).icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(model.fileText(file, column: .path)).foregroundStyle(color(file)) }.repositoryFileHelp(repository: model.repository.root, path: file.path, detail: file.oldPath.map { "Renamed from " + $0 } ?? "", preferences: model.preferences) }.width(min: 260, ideal: 500)
                TableColumn("Extension", sortUsing: RevisionComparisonFileSort(column: .fileExtension)) { row in let file = row.file; Text(model.fileText(file, column: .fileExtension)).foregroundStyle(color(file)) }.width(min: 45, ideal: 75, max: 320)
                TableColumn(LocalizedStringKey(statusTitle), sortUsing: RevisionComparisonFileSort(column: .status)) { row in let file = row.file; Text(FileListLabels.caption(file.status)).foregroundStyle(color(file)) }.width(min: 65, ideal: 100, max: 320)
                TableColumn("Lines added", sortUsing: RevisionComparisonFileSort(column: .added)) { row in let file = row.file; Text(file.addedText).foregroundStyle(color(file)) }.width(min: 65, ideal: 85, max: 320)
                TableColumn("Lines removed", sortUsing: RevisionComparisonFileSort(column: .removed)) { row in let file = row.file; Text(file.removedText).foregroundStyle(color(file)) }.width(min: 65, ideal: 95, max: 320)
            }.fileListFont()
            .background(CommitFileInteraction(rows: model.visibleFiles.compactMap { StatusEntry.parse(Data((" M " + $0.path + "\0").utf8)).first.map(StatusListRow.file) },
                leadingColumnCount: 0, keyboardDeleteEnabled: false, nativeColumns: StatusListColumn.defaultColumns,
                rowTexts: model.visibleFiles.map { file in Dictionary(uniqueKeysWithValues: StatusListColumn.defaultColumns.map { ($0, model.fileText(file, column: $0)) }) },
                itemIDs: model.visibleFiles.map(\.path), copyIDs: { model.copyPaths(GitPathSet($0), extended: $1) },
                copyColumnIDs: { model.copyColumn(GitPathSet($0), column: $1) }, preferences: model.preferences,
                visibleColumns: model.fileColumns.visible, availableColumns: Set(StatusListColumn.defaultColumns), columnText: { _, _ in "" },
                savedOrder: model.fileColumns.order, savedWidths: model.fileColumns.widths,
                saveLayout: { model.saveFileLayout(order: $0, widths: $1) }, setColumnVisible: model.setFileColumn,
                resetColumns: { model.resetFileColumns(choose: $0, accepted: $1) }, focusedPath: $model.focusedFile,
                enabled: model.canChangeColumns, delete: { _, _, _ in }, copy: { _, _ in }, copyColumn: { _, _ in }, toggleCheck: { _, _ in }))
            .contextMenu(forSelectionType: String.self) { nativeIDs in
                let ids = GitPathRowIdentity.paths(nativeIDs)
                let context=model.captureFileMenu(ids)
                TurtleGitContextMenu {
                    Button { if model.claimFileMenu(context) {model.compare(ids)} } label: { CommandLabel(title: "Compare revisions", icon: .compare) }.disabled(ids.isEmpty)
                    Button { if model.claimFileMenu(context) {model.showPatch(ids, alternate: NSEvent.modifierFlags.contains(.shift))} } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(ids.isEmpty)
                    Divider()
                    ForEach([true,false],id:\.self) { base in
                        if model.canRevertFiles(ids,base:base) {
                            Button {if model.claimFileMenu(context) {model.revertFiles(ids,base:base)}} label: {CommandLabel(title:model.revertTitle(base:base),icon:.revert)}
                        }
                    }
                    Button { if model.claimFileMenu(context) {model.logFiles(ids)} } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(ids.isEmpty)
                    if model.visibleFiles.first(where:{ids.contains($0.path)})?.isSubmodule==true {
                        Button {if model.claimFileMenu(context) {model.logSubmodules(ids)}} label:{CommandLabel(title:"Show submodule log",icon:.log)}
                    } else if !ids.isEmpty {
                        if !model.bare {Button {if model.claimFileMenu(context) {model.blameFiles(ids)}} label:{CommandLabel(title:"Blame",icon:.blame)}.disabled(!model.canBlameFiles(ids))}
                        Divider()
                        Button {if model.claimFileMenu(context) {model.exportFiles(ids)}} label:{CommandLabel(title:"Export selection to…",icon:.export)}
                    }
                    Divider()
                    ForEach([HistoricalOpenAction.open,.openWith,.alternativeEditor],id:\.self) { action in
                        Button {if model.claimFileMenu(context){model.openRevisionFile(ids,action:action)}} label:{CommandLabel(title:action == .open ? "Open revision":action == .openWith ? "Open revision with…":"View revision in alternative editor",icon:action == .alternativeEditor ? .editor:.open)}.disabled(!model.canOpenRevisionFile(ids))
                    }
                    Button {if model.claimFileMenu(context){model.saveRevisionFile(ids)}} label:{CommandLabel(title:"Save revision to…",icon:.saveAs)}.disabled(!model.canOpenRevisionFile(ids))
                    Divider()
                    Button { if model.claimFileMenu(context) {model.saveList(ids)} } label: { CommandLabel(title: "Save list of selected files…", icon: .saveAs) }.disabled(ids.isEmpty)
                    Button { if model.claimFileMenu(context) {model.copyPaths(ids)} } label: { CommandLabel(title: "Copy paths to clipboard", icon: .copy) }.disabled(ids.isEmpty)
                    Button { if model.claimFileMenu(context) {model.copyPaths(ids, extended: true)} } label: { CommandLabel(title: "Copy all columns to clipboard", icon: .copy) }.disabled(ids.isEmpty)
                }
            } primaryAction: { model.compare(GitPathRowIdentity.paths($0)) }
    }
}

struct RevisionComparisonFileRow: Identifiable {
    let file: CommitFile
    var id: String { GitPathRowIdentity.encode(file.path) }
}
struct RevisionComparisonFileSort: SortComparator {
    var comparator: KeyPathComparator<CommitFile>
    var order: SortOrder { get { comparator.order } set { comparator.order = newValue } }
    init(_ comparator: KeyPathComparator<CommitFile>) { self.comparator = comparator }
    init(column: StatusListColumn) {
        switch column {
        case .fileExtension: comparator = KeyPathComparator(\CommitFile.sortExtension)
        case .status: comparator = KeyPathComparator(\CommitFile.sortAction)
        case .added: comparator = KeyPathComparator(\CommitFile.sortAdded)
        case .removed: comparator = KeyPathComparator(\CommitFile.sortRemoved)
        default: comparator = KeyPathComparator(\CommitFile.sortPath)
        }
    }
    func compare(_ lhs: RevisionComparisonFileRow, _ rhs: RevisionComparisonFileRow) -> ComparisonResult { comparator.compare(lhs.file,rhs.file) }
}

enum ComparisonDiffOption: String, CaseIterable {
    case spaceAtEnd = "Ignore space at end of line", spaceChange = "Ignore space changes", allSpace = "Ignore all spaces", blankLines = "Ignore blank lines", ancestor = "Common ancestor"
    func enabled(in value: RevisionDiffOptions) -> Bool {
        switch self { case .spaceAtEnd:return value.ignoreSpaceAtEnd;case .spaceChange:return value.ignoreSpaceChange;case .allSpace:return value.ignoreAllSpace;case .blankLines:return value.ignoreBlankLines;case .ancestor:return value.commonAncestor }
    }
    func toggle(_ value: inout RevisionDiffOptions) {
        switch self { case .spaceAtEnd:value.ignoreSpaceAtEnd.toggle();case .spaceChange:value.ignoreSpaceChange.toggle();case .allSpace:value.ignoreAllSpace.toggle();case .blankLines:value.ignoreBlankLines.toggle();case .ancestor:value.commonAncestor.toggle() }
    }
}
@MainActor final class ComparisonOptionMenuItem: NSMenuItem {
    weak var model: RevisionComparisonWindowModel?
    let option: ComparisonDiffOption, epoch: UUID
    private var used = false
    init(model:RevisionComparisonWindowModel,option:ComparisonDiffOption) {
        self.model = model; self.option = option; epoch = model.fileMenuEpoch
        super.init(title:NSLocalizedString(option.rawValue,comment:""),action:#selector(invokeCaptured),keyEquivalent:""); target = self
        image = MenuIcon.unifiedDiff.contextImage(defaults:model.preferences)
        state = option.enabled(in:model.options) ? .on:.off
        isEnabled = model.canChangeColumns
    }
    required init(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func invokeCaptured() {
        guard !used, isEnabled, let model, model.canChangeColumns, epoch == model.fileMenuEpoch else { return }
        used = true; option.toggle(&model.options); model.load()
    }
}
struct ComparisonDiffOptionsControl: NSViewRepresentable {
    @ObservedObject var model: RevisionComparisonWindowModel
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSButton {
        let button = NSButton(title:"Diff Options",target:context.coordinator,action:#selector(Coordinator.openMenu(_:)))
        button.bezelStyle = .rounded; button.image = NSImage(systemSymbolName:"chevron.down",accessibilityDescription:nil); button.imagePosition = .imageTrailing; button.imageHugsTitle = true
        button.identifier = .init("Comparison.DiffOptions"); return button
    }
    func updateNSView(_ button:NSButton,context:Context) {
        context.coordinator.model = model
        let active = ComparisonDiffOption.allCases.contains { $0.enabled(in:model.options) }
        button.title = (active ? "✓ ":"") + NSLocalizedString("Diff Options",comment:"")
        button.isEnabled = model.canChangeColumns
    }
    static func dismantleNSView(_ button:NSButton,coordinator:Coordinator) { button.target = nil; button.action = nil; button.isEnabled = false; coordinator.model = nil }
    @MainActor final class Coordinator: NSObject {
        weak var model: RevisionComparisonWindowModel?
        func makeMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            guard let model else { return menu }
            for option in ComparisonDiffOption.allCases {
                if option == .ancestor { menu.addItem(.separator()) }
                menu.addItem(ComparisonOptionMenuItem(model:model,option:option))
            }
            return menu
        }
        @objc func openMenu(_ sender:NSButton) { guard sender.isEnabled else { return }; makeMenu().popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.maxY+3),in:sender) }
    }
}

enum ComparisonPickerAction: String, CaseIterable { case browse = "RefBrowse", log = "Log", reflog = "RefLog" }
@MainActor final class ComparisonPickerMenuItem: NSMenuItem {
    weak var model: RevisionComparisonWindowModel?
    let side: ComparisonSide, choice: ComparisonPickerAction, epoch: UUID
    private var used = false
    init(model:RevisionComparisonWindowModel,side:ComparisonSide,choice:ComparisonPickerAction) {
        self.model = model; self.side = side; self.choice = choice; epoch = model.fileMenuEpoch
        super.init(title:NSLocalizedString(choice.rawValue,comment:""),action:#selector(invokeCaptured),keyEquivalent:"");target = self
        image = (choice == .browse ? MenuIcon.branch:.log).contextImage(defaults:model.preferences)
        state = model.pickerAction(side) == choice ? .on:.off;isEnabled = model.canChangeColumns
    }
    required init(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func invokeCaptured() {
        guard !used,isEnabled,let model,model.canChangeColumns,model.fileMenuEpoch == epoch else { return }
        used = true
        if side == .base { model.basePickerAction = choice } else { model.destinationPickerAction = choice }
        model.performPickerAction(side)
    }
}
struct ComparisonRevisionPicker: NSViewRepresentable {
    @ObservedObject var model: RevisionComparisonWindowModel
    let side: ComparisonSide
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels:["RefBrowse","▾"],trackingMode:.momentary,target:context.coordinator,action:#selector(Coordinator.activate(_:)))
        control.segmentStyle = .rounded; control.setWidth(99,forSegment:0); control.setWidth(20,forSegment:1)
        return control
    }
    func updateNSView(_ control:NSSegmentedControl,context:Context) {
        context.coordinator.model = model;context.coordinator.side = side
        control.setLabel(NSLocalizedString(model.pickerAction(side).rawValue,comment:""),forSegment:0)
        control.identifier = .init("Comparison.RevisionPicker."+side.rawValue)
        control.isEnabled = model.canChangeColumns;control.setAccessibilityLabel(side == .base ? "Version 1 revision chooser":"Version 2 revision chooser")
    }
    static func dismantleNSView(_ control:NSSegmentedControl,coordinator:Coordinator) { control.target = nil;control.action = nil;control.isEnabled = false;coordinator.model = nil }
    @MainActor final class Coordinator: NSObject {
        weak var model: RevisionComparisonWindowModel?
        var side = ComparisonSide.base
        func makeMenu() -> NSMenu {
            let menu = NSMenu();menu.autoenablesItems = false
            if let model { for choice in ComparisonPickerAction.allCases { menu.addItem(ComparisonPickerMenuItem(model:model,side:side,choice:choice)) } }
            return menu
        }
        @objc func activate(_ sender:NSSegmentedControl) { activateSegment(sender.selectedSegment,from:sender) }
        func activateSegment(_ segment:Int,from sender:NSSegmentedControl) {
            guard sender.isEnabled,let model,model.canChangeColumns else { return }
            switch segment {
            case 0: model.performPickerAction(side)
            case 1: makeMenu().popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.maxY+3),in:sender)
            default: return
            }
        }
    }
}
