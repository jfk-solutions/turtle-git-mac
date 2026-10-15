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
    private var exportFolderPanel:NSOpenPanel?
    private let revisionEditor = RevisionGraphCompletionEditor()
    private let historyRegexExecutable: URL?
    init(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision, paths: [String] = [], preferences: UserDefaults = .standard, historyRegexExecutable: URL? = nil) {
        self.historyRegexExecutable = historyRegexExecutable
        model = RevisionComparisonWindowModel(repository: repository, access: access, from: from, to: to, paths: paths, preferences: preferences)
        let size = NSSize(width: 1000, height: 700)
        let window = RevisionComparisonNativeWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(paths.isEmpty ? repository.root.lastPathComponent : paths.joined(separator: ", ")) – Changed Files – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 530)
        window.contentViewController = NSHostingController(rootView: RevisionComparisonDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        revisionEditor.isFieldEditor = true; revisionEditor.isAutomaticTextCompletionEnabled = false
        revisionEditor.isAutomaticSpellingCorrectionEnabled = false; revisionEditor.isContinuousSpellCheckingEnabled = false
        window.setContentSize(size); window.center()
        model.pickReferences = { [weak self] side in self?.showReferencePicker(side: side) }
        model.pickHistory = { [weak self] side, reflog in self?.showHistoryPicker(side: side, reflog: reflog) }
        model.window = window; model.close={ [weak window] in window?.performClose(nil) };installFileActions(); window.refresh = { [weak model] in model?.load() }

        NotificationCenter.default.addObserver(self, selector: #selector(pickerSheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        DialogGeometry.attach(window, identifier: "FileDiffDialog", legacyName: "FileDiffDialog")
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is ComparisonRevisionNativeField ? revisionEditor : nil
    }
    private func installFileActions() {
        model.chooseExportFolder={ [weak self] in
            guard let self,let window=self.window,window.attachedSheet==nil,!self.model.closed else {return nil}
            return await withCheckedContinuation { reply in
                let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false;panel.prompt="Export";panel.message="Export selected changed files to a folder.";panel.alphaValue=window.alphaValue
                self.exportFolderPanel=panel
                panel.beginSheetModal(for:window) { [weak self] response in self?.exportFolderPanel=nil;reply.resume(returning:response == .OK ? panel.url : nil) }
            }
        }
        model.cancelFilePicker={ [weak self] in guard let self,let panel=self.exportFolderPanel,self.window?.attachedSheet===panel else{return};self.window?.endSheet(panel,returnCode:.cancel);panel.orderOut(nil) }
        model.fileActionFailure={ [weak self] message in guard let self else{return false};return await self.fileActionMessage(message,question:true) }
        model.fileActionNotice={ [weak self] message in guard let self else{return};_ = await self.fileActionMessage(message,question:false) }
    }
    private func fileActionMessage(_ message:String,question:Bool) async -> Bool {
        guard let window,!model.closed,window.attachedSheet==nil else {return false}
        return await withCheckedContinuation { reply in
            let alert=NSAlert();alert.messageText=question ? "Could not complete file operation." : "TurtleGit";alert.informativeText=message;alert.alertStyle=question ? .warning : .informational
            for title in question ? ["Ignore","Abort"] : ["OK"] {alert.addButton(withTitle:title).keyEquivalent=""}
            alert.window.alphaValue=window.alphaValue
            alert.beginSheetModal(for:window) {response in reply.resume(returning:response == .alertFirstButtonReturn)}
            let primary=alert.buttons.last!;primary.keyEquivalent="\r";alert.window.defaultButtonCell=primary.cell as? NSButtonCell
        }
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
        pickerRequest = nil; pickerFocus = nil; pendingPickerSelection = nil; model.invalidate()
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        referencePicker?.abandonPresentation(); referencePicker = nil
        logPicker?.close(); logPicker = nil; reflogPicker?.close(); reflogPicker = nil
        model.patchWindow?.close(); Array(model.unifiedWindows.values).forEach { $0.close() }
        Array(model.comparisonWindows.values).forEach { $0.close() }; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class RevisionComparisonWindowModel: ObservableObject {
    let scopePaths: [String]
    let repository: GitRepository
    let access: RepositoryAccessLease?
    weak var window: NSWindow?
    @Published var from: String
    @Published var to: String
    @Published var references: [CheckoutReference] = []
    var pickReferences: (ComparisonSide) -> Void = { _ in }
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    @Published private(set) var inputMessage = ""
    private var inputTask: Task<Void, Never>?
    private var inputGeneration = UUID()
    var pickHistory: (ComparisonSide, Bool) -> Void = { _, _ in }
    @Published var snapshot: RevisionComparisonSnapshot?
    @Published var selection = Set<String>()
    @Published var filter = ""
    @Published var sortOrder = [KeyPathComparator(\CommitFile.sortPath)]
    @Published var options = RevisionDiffOptions()
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var showingPatch = false
    var patchWindow: PatchWindowController?
    var unifiedWindows: [String: PatchWindowController] = [:]
    private var patchGeneration = 0
    private(set) static var activeFileOperations = 0
    let preferences: UserDefaults
    var confirmManyDiffs: ((Int) async -> Bool)?
    var openComparedFile: ((RevisionComparisonSnapshot, CommitFile) -> Void)?
    private var comparisonSessions: [UUID: FileListComparisonSession] = [:]
    private var patchTokens: [UUID: OperationCancellation] = [:]
    private var loadToken: OperationCancellation?
    @Published private(set) var bare=false
    @Published private(set) var fileActionTitle=""
    private var fileActionToken:OperationCancellation?
    private var closeAfterFileAction=false
    private var actionGeneration=UUID()
    var close:()->Void = {}
    var cancelFilePicker:()->Void = {}
    var chooseExportFolder:() async -> URL? = { nil }
    var fileActionFailure:(String) async -> Bool = { _ in false }
    var fileActionNotice:(String) async -> Void = { _ in }
    var onBlame:(String,String)->Void = { _,_ in }
    var onSubmoduleLog:(URL,String?)->Void = { _,_ in }
    var onFilesChanged:()->Void = {}
    private(set) var actionTrash:[URL]=[]
    private(set) var closed = false
    func invalidate() { closed = true; cancelPendingInput();actionGeneration=UUID();fileActionToken?.cancel();cancelFilePicker();closeAfterFileAction=false; comparisonSessions.values.forEach { $0.cancel() }; patchTokens.values.forEach { $0.cancel() }; patchTokens.removeAll(); loadToken?.cancel(); loadToken = nil; patchGeneration += 1; busy = false }
    var onLog: (String?) -> Void = { _ in }
    var onFileLog: (String, String?) -> Void = { _, _ in }
    var onSubmoduleCompare: (String, ComparisonRevision, ComparisonRevision) -> Void = { _, _, _ in }
    var comparisonWindows: [String: FileComparisonWindowController] = [:]
    @Published var fileColumns: StatusListColumnSettings
    @Published var focusedFile: String?
    @Published private(set) var resettingColumns = false
    private var columnsRequest = UUID()
    static let columnsKey = "FileDiff.Columns"
    var canChangeColumns: Bool { !closed && !busy && !confirmingQuit && !resettingColumns && window?.attachedSheet == nil }
    @discardableResult func saveFileLayout(order: [StatusListColumn], widths: [StatusListColumn: Double]) -> Bool {
        guard canChangeColumns else { return false }
        let allowed = Set(StatusListColumn.defaultColumns)
        let next = StatusListColumnSettings(visible: fileColumns.visible.intersection(allowed), order: order, widths: widths.filter { allowed.contains($0.key) })
        if next != fileColumns { fileColumns = next; next.save(to: preferences, key: Self.columnsKey) }
        return true
    }
    func setFileColumn(_ column: StatusListColumn, visible: Bool) {
        guard canChangeColumns, StatusListColumn.defaultColumns.contains(column), column != .path else { return }
        if visible { fileColumns.visible.insert(column) } else { fileColumns.visible.remove(column) }
        fileColumns.save(to: preferences, key: Self.columnsKey)
    }
    func resetFileColumns(choose: @escaping () async -> Bool, accepted: @escaping () -> Void) {
        guard canChangeColumns else { return }
        let request = UUID(); columnsRequest = request; resettingColumns = true
        Task { [weak self] in
            guard let self else { return }; let yes = await choose()
            guard !closed, columnsRequest == request else { return }; resettingColumns = false
            guard yes, !busy else { return }
            fileColumns = StatusListColumnSettings(); fileColumns.save(to: preferences, key: Self.columnsKey); accepted()
        }
    }
    func fileText(_ file: CommitFile, column: StatusListColumn) -> String {
        switch column {
        case .path: return StatusListClipboard.displayedPath(file, abbreviate: preferences.bool(forKey: "AbbreviateRenamings"))
        case .fileExtension: return StatusListClipboard.fileExtension(file.path, isDirectory: file.isSubmodule)
        case .status: return file.status
        case .added: return file.addedText
        case .removed: return file.removedText
        default: return ""
        }
    }
    var completionNames: [String] {
        Array(Set(["HEAD"] + references.map { ref in
            if ref.name.hasPrefix("refs/heads/") { return String(ref.name.dropFirst(11)) }
            if ref.name.hasPrefix("refs/tags/") { return String(ref.name.dropFirst(10)) }
            if ref.name.hasPrefix("refs/remotes/") { return String(ref.name.dropFirst(13)) }
            return ref.name
        })).sorted()
    }
    var visibleFiles: [CommitFile] {
        let query = ComparisonPathFilter(filter)
        return snapshot?.files.filter { query.matches(path: $0.path, oldPath: $0.oldPath) }.sorted(using: sortOrder) ?? []
    }
    let alternateTool = ComparisonToolInvocation.alternate
    init(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision, paths: [String] = [], preferences: UserDefaults = .standard) {
        self.preferences = preferences; self.repository = repository; self.access = access
        self.from = from.label; self.to = to.label; scopePaths = paths
        fileColumns = StatusListColumnSettings.load(from: preferences, key: Self.columnsKey)
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
        !closed && inputTask == nil && !resettingColumns && !busy && !confirmingQuit && scopePaths == paths && from == requestedFrom.label && to == requestedTo.label &&
        patchWindow?.model.busy != true && patchWindow?.window?.attachedSheet == nil &&
        !unifiedWindows.values.contains { $0.model.busy || $0.window?.attachedSheet != nil } &&
        !comparisonWindows.values.contains { $0.model.busy || $0.model.dirty }
    }
    private func side(_ input: String) -> ComparisonRevision {
        switch input.lowercased() { case "working tree": return .workingTree; case "empty tree": return .emptyTree; default: return .revision(input) }
    }
    func load(inlineErrors: Bool = false) {
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
        guard snapshot.toDetails?.isTree != true else { error = "Tree objects have no commit history. Choose a commit or tag to view history."; return }
        if case .revision(let value) = snapshot.to { onLog(value) } else { onLog(nil) }
    }
    func logFiles(_ ids: Set<String>) {
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

    func compare(_ ids: Set<String>) {
        guard !closed, !busy, !confirmingQuit, let snapshot else { return }
        let files = visibleFiles.filter { ids.contains($0.path) }
        runFiles(files) { [self] token in
        for file in files {
            guard !closed, !token.isCancelled else { return }
            if let openComparedFile { openComparedFile(snapshot, file); continue }
            if file.isSubmodule { onSubmoduleCompare(file.path, snapshot.from, snapshot.to); continue }
            let key = file.path + "\0" + snapshot.from.label + "\0" + snapshot.to.label + "\0" + ComparisonToolInvocation.cacheKey
            let controller = comparisonWindows[key] ?? FileComparisonWindowController(repository: repository, access: access, snapshot: snapshot, path: file.path)
            controller.onClosed = { [weak self] in self?.comparisonWindows.removeValue(forKey: key) }
            comparisonWindows[key] = controller
            controller.model.comparisonDefaults = preferences
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
        }
    }
    func copyPaths(_ ids: Set<String>, extended: Bool = false) {
        guard !closed, !busy, !confirmingQuit else { return }
        let files = visibleFiles.filter { ids.contains($0.path) }; guard !files.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ComparisonFileList.clipboard(files, extended: extended), forType: .string)
    }
    func copyColumn(_ ids: Set<String>, column: StatusListColumn) {
        guard !closed, !busy, !confirmingQuit else { return }
        let files = visibleFiles.filter { ids.contains($0.path) }; guard !files.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(files.map { fileText($0, column: column) }.joined(separator: "\r\n"), forType: .string)
    }
    func saveList(_ ids: Set<String>) {
        guard !closed, !busy, !confirmingQuit, let snapshot, let window else { return }
        let files = visibleFiles.filter { ids.contains($0.path) }; guard !files.isEmpty else { return }
        let text = ComparisonFileList.savedList(files, from: snapshot.from, to: snapshot.to)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "changed-files.txt"; panel.allowedContentTypes = [.plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self?.error = error.localizedDescription }
        }
    }
    func togglePatch() {
        guard !closed, !busy, !confirmingQuit, patchWindow?.model.busy != true, patchWindow?.window?.attachedSheet == nil else { return }
        if showingPatch { patchWindow?.close(); return }
        let controller = PatchWindowController(repository: repository, access: access)
        controller.window?.title = "\(repository.root.lastPathComponent) – Unified Diff – TurtleGit"
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
    func showPatch(_ ids: Set<String>, alternate: Bool) {
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
                    if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: preferences), !closed, !token.isCancelled {
                        let controller = unifiedWindows[file.path] ?? PatchWindowController(repository: repository, access: access)
                        controller.presentDocument(bytes, title: "\(file.path) – Unified Diff – TurtleGit",
                            comparison: "\(snapshot.from.label.prefix(12)) → \(snapshot.to.label.prefix(12))",
                            information: "Unified diff for \(file.path). Right-click to save the patch.", paths: [file.path], refreshAvailable: true, refresh: { [weak self, weak controller] in
                                guard let self, let controller, !self.closed, !controller.model.busy, !controller.model.confirmingQuit else { return }
                                let identity = controller.documentSession.documentIdentity
                                controller.model.busy = true
                                let refresh = UUID(), token = OperationCancellation(); self.patchTokens[refresh] = token
                                Task {
                                    defer { self.patchTokens.removeValue(forKey: refresh); if !self.closed { controller.model.busy = false } }
                                    do {
                                        try self.checkPatchAccess()
                                        let bytes = try await self.repository.revisionComparisonPatchData(snapshot, paths: [file.path], cancellation: token)
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
        fileprivate let generation:UUID,from:String,to:String,options:RevisionDiffOptions,files:[CommitFile]
        fileprivate init(generation:UUID,from:String,to:String,options:RevisionDiffOptions,files:[CommitFile]) {self.generation=generation;self.from=from;self.to=to;self.options=options;self.files=files}
    }
    func captureFileMenu(_ ids:Set<String>)->FileMenuContext? {
        let files=visibleFiles.filter{ids.contains($0.path)}
        guard !closed,!busy,!files.isEmpty,snapshot != nil else{return nil}
        return FileMenuContext(generation:actionGeneration,from:from,to:to,options:options,files:files)
    }
    func claimFileMenu(_ context:FileMenuContext?)->Bool {
        guard let context,!context.consumed,!closed,!busy,!confirmingQuit,window?.attachedSheet==nil,
              context.generation==actionGeneration,context.from.utf8.elementsEqual(from.utf8),context.to.utf8.elementsEqual(to.utf8),context.options==options,
              visibleFiles.filter({file in context.files.contains{$0.path==file.path}})==context.files else{return false}
        context.consumed=true;return true
    }
    var fileActionActive:Bool { fileActionToken != nil }
    @discardableResult func cancelFileAction(closeAfter:Bool=false)->Bool {
        guard let token=fileActionToken else { return false };closeAfterFileAction = closeAfterFileAction || closeAfter
        token.cancel();cancelFilePicker();return true
    }
    func canRevertFiles(_ ids:Set<String>,base:Bool)->Bool {
        guard !closed,!busy,!bare,let snapshot,let first=visibleFiles.first(where:{ids.contains($0.path)}),case .revision = base ? snapshot.from : snapshot.to else { return false }
        return base || snapshot.from == .workingTree || !first.action.hasPrefix("D")
    }
    func revertTitle(base:Bool)->String {
        guard let snapshot else { return "Revert" }
        return "Revert to revision "+String((base ? snapshot.from : snapshot.to).label.prefix(8))
    }
    func canBlameFiles(_ ids:Set<String>)->Bool {
        guard !closed,!busy,!bare,let snapshot,visibleFiles.first(where:{ids.contains($0.path)})?.isSubmodule==false else {return false}
        return visibleFiles.filter{ids.contains($0.path) && !$0.isSubmodule}.contains { file in
            if file.action.hasPrefix("D") {return snapshot.fromDetails?.isTree != true && snapshot.from != .workingTree && snapshot.from != .emptyTree}
            if snapshot.to == .workingTree {return !file.action.hasPrefix("A") && (!file.action.hasPrefix("R") || snapshot.fromDetails?.isTree != true)}
            return snapshot.to != .emptyTree && snapshot.toDetails?.isTree != true
        }
    }
    func blameFiles(_ ids:Set<String>) {
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
    func logSubmodules(_ ids:Set<String>) {
        guard !closed,!busy,let snapshot else { return }
        let files=visibleFiles.filter{ids.contains($0.path) && $0.isSubmodule}
        runFiles(files) { [self] token in
            for file in files {
                guard !closed,!token.isCancelled else { return }
                do {
                    let child=try await repository.submoduleWorkingRepository(path:file.path,cancellation:token)
                    let comparison=try await repository.submoduleComparison(path:file.path,from:snapshot.from == .emptyTree ? "" : snapshot.from == .workingTree ? "HEAD" : snapshot.from.label,to:snapshot.to == .workingTree ? nil : snapshot.to == .emptyTree ? "" : snapshot.to.label,cancellation:token)
                    guard !closed,!token.isCancelled else { continue }
                    let pin=preferences.object(forKey:"LogSubmoduleShowRevision")==nil || preferences.bool(forKey:"LogSubmoduleShowRevision")
                    onSubmoduleLog(child.root,pin && snapshot.to != .workingTree && !file.action.hasPrefix("D") ? comparison.to.revision : nil)
                } catch {if !closed,!token.isCancelled {self.error=error.localizedDescription;return}}
            }
        }
    }
    func revertFiles(_ ids:Set<String>,base:Bool) {
        guard canRevertFiles(ids,base:base) else { return }
        runFileAction(ids,title:revertTitle(base:base)) { [self] snapshot,files,token in
            let targets=try await repository.prepareComparisonRevert(snapshot,files:files,base:base,cancellation:token)
            let recycle=preferences.object(forKey:"RevertWithRecycleBin")==nil || preferences.bool(forKey:"RevertWithRecycleBin")
            var count=0,changed=false
            for target in targets {
                guard !closed,!token.isCancelled else { break }
                do { actionTrash += try await repository.revertComparisonFile(target,recycle:recycle,cancellation:token);count += 1;changed=true }
                catch {
                    if let failure=error as? WorkingFileRevertFailure {actionTrash += failure.trashedFiles;changed=true}
                    guard !closed,!token.isCancelled else { break }
                    if !(await fileActionFailure(target.path+"\n"+error.localizedDescription)) {break}
                }
            }
            if changed {onFilesChanged()}
            if !closed,!token.isCancelled {await fileActionNotice("\(count) file(s) reverted to \(targets.first?.revision ?? "").")}
        }
    }
    func exportFiles(_ ids:Set<String>) {
        runFileAction(ids,title:"Export selected files") { [self] snapshot,files,token in
            guard let folder=await chooseExportFolder(),!closed,!token.isCancelled else {return}
            let scoped=folder.startAccessingSecurityScopedResource();defer{if scoped{folder.stopAccessingSecurityScopedResource()}}
            guard !GitRuntime.isAppStoreBuild || scoped || access?.permits(folder)==true else {throw RepositoryAccessFailure.securityScopeUnavailable}
            let plan=try await repository.prepareComparisonExport(snapshot,files:files,to:folder,cancellation:token)
            for path in plan.paths {
                guard !closed,!token.isCancelled else {break}
                do {try await repository.exportComparisonFile(plan,path:path,cancellation:token)}
                catch {guard !closed,!token.isCancelled else {break};if !(await fileActionFailure(path+"\n"+error.localizedDescription)){break}}
            }
        }
    }
    private func runFileAction(_ ids:Set<String>,title:String,operation:@escaping (RevisionComparisonSnapshot,[CommitFile],OperationCancellation) async throws -> Void) {
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
                    Menu("HEAD") {
                        Button { model.pickReferences(base ? .base : .destination) } label: { CommandLabel(title: "Browse references…", icon: .branch) }
                        Button { model.pickHistory(base ? .base : .destination, false) } label: { CommandLabel(title: "Log…", icon: .log) }
                        Button { model.pickHistory(base ? .base : .destination, true) } label: { CommandLabel(title: "RefLog…", icon: .log) }
                    }.frame(width: 100)
                }
                Text(model.revisionDescription(base: base)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).help(model.revisionTooltip(base: base))
            }.padding(5)
        }
    }
    private func state(_ file: CommitFile) -> FileState {
        switch file.action.first { case "A": return .added; case "D": return .deleted; default: return .modified }
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Difference between"); Spacer()
                Menu("Diff Options") {
                    Toggle("Ignore space at end of line", isOn: $model.options.ignoreSpaceAtEnd)
                    Toggle("Ignore space changes", isOn: $model.options.ignoreSpaceChange)
                    Toggle("Ignore all spaces", isOn: $model.options.ignoreAllSpace)
                    Toggle("Ignore blank lines", isOn: $model.options.ignoreBlankLines)
                    Toggle("Common ancestor", isOn: $model.options.commonAncestor)
                }.frame(width: 130)
                Button { model.log() } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(model.snapshot == nil)
                Button { model.swap() } label: { Image(nsImage: MenuIcon.reverse.image() ?? NSImage()) }.help("Swap revisions").accessibilityLabel("Swap revisions").disabled(model.to.lowercased() == "working tree")
            }
            revisionGroup("Version 1 (Base)", value: $model.from, base: true)
            revisionGroup("Version 2", value: $model.to, base: false)
            HStack { TextField("Filter paths", text: $model.filter).textFieldStyle(.roundedBorder); if !model.filter.isEmpty { Button("Clear") { model.filter = "" } } }
            Table(model.visibleFiles, selection: $model.selection, sortOrder: $model.sortOrder) {
                TableColumn("File", value: \.sortPath) { file in HStack { Image(nsImage: state(file).icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(model.fileText(file, column: .path)).foregroundStyle(model.selection.contains(file.path) ? Color.primary : state(file).textColor) }.help(file.oldPath.map { "Renamed from \($0)" } ?? file.path) }.width(min: 350, ideal: 500)
                TableColumn("Extension", value: \.sortExtension) { file in Text(model.fileText(file, column: .fileExtension)) }.width(min: 45, ideal: 75, max: 320)
                TableColumn("Action", value: \.sortAction) { file in Text(file.status) }.width(min: 65, ideal: 100, max: 320)
                TableColumn("Lines added", value: \.sortAdded) { file in Text(file.addedText) }.width(min: 65, ideal: 85, max: 320)
                TableColumn("Lines deleted", value: \.sortRemoved) { file in Text(file.removedText) }.width(min: 65, ideal: 95, max: 320)
            }.fileListFont()
            .background(CommitFileInteraction(rows: model.visibleFiles.compactMap { StatusEntry.parse(Data((" M " + $0.path + "\0").utf8)).first.map(StatusListRow.file) },
                leadingColumnCount: 0, keyboardDeleteEnabled: false, nativeColumns: StatusListColumn.defaultColumns,
                rowTexts: model.visibleFiles.map { file in Dictionary(uniqueKeysWithValues: StatusListColumn.defaultColumns.map { ($0, model.fileText(file, column: $0)) }) },
                itemIDs: model.visibleFiles.map(\.path), copyIDs: { model.copyPaths(Set($0), extended: $1) },
                copyColumnIDs: { model.copyColumn(Set($0), column: $1) }, preferences: model.preferences,
                visibleColumns: model.fileColumns.visible, availableColumns: Set(StatusListColumn.defaultColumns), columnText: { _, _ in "" },
                savedOrder: model.fileColumns.order, savedWidths: model.fileColumns.widths,
                saveLayout: { model.saveFileLayout(order: $0, widths: $1) }, setColumnVisible: model.setFileColumn,
                resetColumns: { model.resetFileColumns(choose: $0, accepted: $1) }, focusedPath: $model.focusedFile,
                enabled: model.canChangeColumns, delete: { _, _, _ in }, copy: { _, _ in }, copyColumn: { _, _ in }, toggleCheck: { _, _ in }))
            .overlay { if !model.inputMessage.isEmpty { Text(model.inputMessage).foregroundStyle(.secondary).padding().textSelection(.enabled) } }
            .contextMenu(forSelectionType: String.self) { ids in
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
                    Button { if model.claimFileMenu(context) {model.saveList(ids)} } label: { CommandLabel(title: "Save list of selected files…", icon: .saveAs) }.disabled(ids.isEmpty)
                    Button { if model.claimFileMenu(context) {model.copyPaths(ids)} } label: { CommandLabel(title: "Copy paths to clipboard", icon: .copy) }.disabled(ids.isEmpty)
                    Button { if model.claimFileMenu(context) {model.copyPaths(ids, extended: true)} } label: { CommandLabel(title: "Copy all columns to clipboard", icon: .copy) }.disabled(ids.isEmpty)
                }
            } primaryAction: { model.compare($0) }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text("\(model.visibleFiles.count) changed file(s)").font(.caption).foregroundStyle(.secondary); Spacer(); Button(model.showingPatch ? "Hide Patch<<" : "View Patch>>") { model.togglePatch() }.buttonStyle(.link).disabled(model.snapshot == nil) }
        }.padding(12).disabled(model.busy || model.confirmingQuit)
        .overlay(alignment:.bottom) {
            if model.fileActionActive {HStack{ProgressView().controlSize(.small);Text(model.fileActionTitle).font(.caption);Spacer();Button("Cancel"){model.cancelFileAction()}}.padding(12).background(.regularMaterial)}
        }.onAppear { model.load() }
        .onChange(of: model.options) { _ in model.load() }
        .onChange(of: model.selection) { _ in model.updatePatch() }
        .onChange(of: model.filter) { _ in model.selection.formIntersection(model.visibleFiles.map(\.path)); model.updatePatch() }
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
