import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

private final class AddNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    var accept: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.specialKey == .f5 { refresh(); return true }
        if event.charactersIgnoringModifiers == "\r", !event.modifierFlags.intersection([.command, .control]).isEmpty { accept(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class AddWindowController: NSWindowController, NSWindowDelegate {
    let model: AddWindowModel
    private let access: RepositoryAccessLease?
    private var ignoreController: IgnoreWindowController?
    private(set) var lfsOperation: LFSFileOperationController?
    private var columnAlert: NSAlert?
    private var closing = false
    private(set) lazy var filePanels = OwnedFilePanelSession(window:window)
    var onPullAfterLFSLock: () -> Void = {}
    var makeLFSOperation: (GitRepository, RepositoryAccessLease?) -> LFSFileOperationController = { LFSFileOperationController(repository: $0, access: $1) }
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        makeLFSOperation = { LFSFileOperationController(repository: $0, access: $1, defaults: defaults) }
        model = AddWindowModel(repository: repository, access: access, defaults: defaults); self.access = access
        let window = AddNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Add", preferences: defaults)
        window.contentMinSize = NSSize(width: 580, height: 320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AddDialogView(model: model))
        window.setContentSize(NSSize(width: 760, height: 480))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.close() }
        model.onOpen = { [weak model] path,action in _ = model?.requestOpen(path,action:action) }
        model.chooseSaveFile = { [weak self] path in await self?.chooseSave(path) }
        model.chooseExportFolder = { [weak self] in await self?.chooseExportFolder() }
        model.chooseApplication = { [weak self] in await self?.chooseApplication() }
        model.cancelFileChoice = { [weak self] in self?.filePanels.cancel() }
        model.onIgnore = { [weak self] paths, mask in self?.ignore(paths, mask: mask) }
        model.onIndexFlags = { [weak self] action, paths, mark in self?.confirmFlags(action, paths: paths, mark: mark) }
        model.onRevertRequest = { [weak self] rows in self?.confirmRevert(rows) }
        model.onRestore = { [weak self] paths in self?.confirmRestore(paths) }
        model.onDelete = { [weak self] selected, permanently in self?.confirmDelete(selected, permanently: permanently) }
        model.onSave = { [weak model] path in _ = model?.requestSave(path) }
        model.onExport = { [weak model] paths in _ = model?.requestExport(paths) }
        model.onResetColumns = { [weak self] in self?.confirmColumnReset() }
        model.onLFSOperation = { [weak self, weak window] paths, locked in
            guard let self, !self.closing, let window, window.attachedSheet == nil, self.lfsOperation == nil else { return false }
            let progress = self.makeLFSOperation(repository, access)
            progress.model.onProgressLog = { [weak self] path in self?.model.onLog(path) }
            progress.model.onPullAfterLock = { [weak self] in guard let self, !self.closing else { return }; self.onPullAfterLFSLock() }
            progress.onClosed = { [weak self, weak progress] in
                guard let self, !self.closing, self.lfsOperation === progress else { return }
                self.lfsOperation = nil; self.model.finishLFSOperation()
            }
            self.lfsOperation = progress
            guard progress.present(owner: window, paths: paths, locked: locked) else { self.lfsOperation = nil; return false }
            return true
        }
        window.refresh = { [weak model] in model?.reload() }; window.accept = { [weak model] in model?.apply() }

        DialogGeometry.attach(window, identifier: "AddDialog", legacyName: "AddDialog")
    }
    private func confirmColumnReset() {
        guard !closing, let window, window.attachedSheet == nil, model.beginColumnReset() else { return }
        let alert = NSAlert(); alert.messageText = "Are you sure to reset columns?"
        alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); columnAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.closing, self.columnAlert === alert else { return }
            self.columnAlert = nil; self.model.finishColumnReset(accepted: response == .alertFirstButtonReturn)
        }
    }
    private func chooseSave(_ path:String) async -> URL? {
        guard !closing,!model.retired,let window,window.attachedSheet == nil else {return nil}
        let panel = NSSavePanel();panel.title = "Save As";panel.canCreateDirectories = true
        let file = model.repository.root.appendingPathComponent(path),ext = StatusListClipboard.fileExtension(path)
        panel.nameFieldStringValue = String(file.lastPathComponent.dropLast(ext.count)) + "-" + ext
        panel.directoryURL = file.deletingLastPathComponent()
        return await filePanels.choose(panel)
    }
    private func chooseExportFolder() async -> URL? {
        guard !closing,!model.retired,let window,window.attachedSheet == nil else {return nil}
        let panel = NSOpenPanel();panel.title = "Export";panel.prompt = "Export"
        panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false;panel.directoryURL = model.repository.root
        return await filePanels.choose(panel)
    }
    private func chooseApplication() async -> URL? {
        guard !closing,!model.retired,let window,window.attachedSheet == nil else {return nil}
        let panel = NSOpenPanel();panel.title = "Open With";panel.prompt = "Open"
        panel.allowedContentTypes = [.applicationBundle];panel.canChooseDirectories = false;panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath:"/Applications",isDirectory:true)
        return await filePanels.choose(panel)
    }
    private func confirmDelete(_ selected: [StatusEntry], permanently: Bool) {
        guard let window, window.attachedSheet == nil, model.beginDeleteConfirmation(selected, permanently: permanently) else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = permanently ? "Permanently delete the selected paths?" : "Move the selected paths to Trash?"
        alert.informativeText = "\(selected.count) selected item(s). Any exact index entries will also be removed." + (permanently ? " This cannot be undone." : " Files moved to Trash can be recovered in Finder.")
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: permanently ? "Delete Permanently" : "Move to Trash")
        alert.beginSheetModal(for: window) { [weak model] response in _ = model?.finishDeleteConfirmation(accepted: response == .alertSecondButtonReturn) }
    }
    private func ignore(_ paths: [String], mask: Bool) {
        guard let window, window.attachedSheet == nil, ignoreController == nil, !model.busy, !model.confirmingQuit else { return }
        do {
            let controller = try IgnoreWindowController(repository: model.repository, access: access, paths: paths, mask: mask, delete: false)
            guard let child = controller.window, model.beginIgnore() else { return }
            var changed = false
            controller.onChanged = { [weak model] output in changed = true; model?.onIgnoreChanged(output) }
            controller.onClosed = { [weak self, weak child] in
                guard let self else { return }
                if let child, let parent = child.sheetParent { parent.endSheet(child) }
                self.ignoreController = nil; self.model.finishIgnore(changed: changed)
            }
            ignoreController = controller; window.beginSheet(child)
        } catch { model.error = error.localizedDescription }
    }
    private func confirmFlags(_ action: IndexFlagAction, paths: [String], mark: String) {
        guard let window, window.attachedSheet == nil, model.beginFlagConfirmation(action, paths: paths, mark: mark) else { return }
        let alert = NSAlert(); alert.messageText = action.confirmation
        alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
        alert.beginSheetModal(for: window) { [weak model] response in _ = model?.finishFlagConfirmation(accepted: response == .alertSecondButtonReturn) }
    }
    private func confirmRevert(_ rows: [AddDialogEntry]) {
        guard let window, window.attachedSheet == nil, model.beginRevertConfirmation(rows) else { return }
        guard model.revertNeedsConfirmation else { model.finishRevertConfirmation(accepted: true); return }
        let alert = NSAlert(); alert.messageText = "Are you sure you want to revert \(rows.count) item(s)?"
        alert.informativeText = "You will lose ALL changes since the last update! "+WorkingFileRevertPresentation.confirmation(model.pendingRevertPolicy ?? .load(from:model.presentationPreferences))
        alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
        alert.beginSheetModal(for: window) { [weak model] response in model?.finishRevertConfirmation(accepted: response == .alertSecondButtonReturn) }
    }
    private func confirmRestore(_ paths: [String]) {
        guard let window, window.attachedSheet == nil, model.beginRestoreConfirmation(paths) else { return }
        let alert = NSAlert(); alert.messageText = "Do you really want to restore the copy?"
        alert.informativeText = "You will lose all changes that you have done after creating the copy."
        alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Restore")
        alert.beginSheetModal(for: window) { [weak model] response in _ = model?.finishRestoreConfirmation(accepted: response == .alertSecondButtonReturn) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if sender.attachedSheet != nil { return false }; if model.busy { model.cancel(); return false }; return !model.confirmingQuit }
    func windowWillClose(_ notification: Notification) {
        closing = true;filePanels.retire();model.invalidate();columnAlert = nil
        lfsOperation?.model.retire(); lfsOperation?.close(); lfsOperation = nil
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }
        ignoreController?.close();ignoreController = nil;window?.contentViewController = nil;onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class AddWindowModel: ObservableObject {
    static private(set) var activeOperations = 0
    private(set) var retired = false
    private var readTask: Task<Void, Never>?
    var queryDroppedItems: (([URL], OperationCancellation) async throws -> [WorkingFileDropItem])?
    var querySelection: (([String], Bool, OperationCancellation) async throws -> AddDialogSelection)?
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    var presentationPreferences: UserDefaults { defaults }
    let workingDragOrigin = UUID().uuidString
    func captureWorkingDrag(_ orderedPaths:[String])->WorkingFileListDrag? {
        guard !retired,!accepted,!busy,!confirmingQuit,!orderedPaths.isEmpty,
              GitPathSet(orderedPaths).count==orderedPaths.count else{return nil}
        let lookup=GitPathMap(uniqueKeysWithValues:entries.map{($0.path,$0)})
        let selected=orderedPaths.compactMap{lookup[$0]}
        guard selected.count==orderedPaths.count,orderedPaths.allSatisfy({highlighted.contains($0)}) else{return nil}
        return FileListDrag.workingSelection(repository:repository,access:access,entries:selected.map(\.status),
            directories:GitPathSet(selected.filter(\.isDirectory).map(\.path)),backend:GitLibGit2Configuration.load(from:defaults),origin:workingDragOrigin)
    }
    private let defaults: UserDefaults
    private static let columnKey = "Add.FileColumns"
    static let columns: [StatusListColumn] = [.path, .fileExtension, .lastModified, .fileSize]
    static var defaultColumns: StatusListColumnSettings { StatusListColumnSettings(visible: [.path,.fileExtension], order: columns) }
    @Published private(set) var fileColumns: StatusListColumnSettings {didSet {fileMenuGeneration = UUID()}}
    @Published private(set) var columnResetGeneration = 0
    private(set) var resettingColumns = false
    var onResetColumns: () -> Void = {}
    @Published private(set) var hasLFS = false
    private(set) var lockingFiles = false
    var onLFSOperation: ([String], Bool) -> Bool = { _, _ in false }
    var onLFSChanged: () -> Void = {}
    func lfsActions(_ selected: [AddDialogEntry], marked: String?) -> [LFSLockMenuAction] {
        guard !retired, hasLFS, !selected.isEmpty,
              selected.allSatisfy({ candidate in entries.contains { GitReferenceName.equal($0.path,candidate.path) && $0.status == candidate.status } }),
              let mark = selected.first(where: { GitReferenceName.equal($0.path,marked) }) ?? selected.first,
              mark.status.canCompareWithBaseFromStatusList, mark.state != .conflicted,
              selected.allSatisfy({ row in
                  guard !row.isDirectory else { return false }
                  var directory: ObjCBool = false
                  _ = FileManager.default.fileExists(atPath: repository.root.appendingPathComponent(row.path).path, isDirectory: &directory)
                  return !directory.boolValue
              }) else { return [] }
        // AddDlg does not permit the owner column, so upstream offers both commands.
        return [.lock, .unlock]
    }
    func setLFSLocked(_ selected: [AddDialogEntry], marked: String?, locked: Bool) {
        guard !busy, !confirmingQuit, lfsActions(selected, marked: marked).contains(locked ? .lock : .unlock) else { return }
        busy = true; lockingFiles = true
        if !onLFSOperation(selected.map(\.path), locked) { lockingFiles = false; busy = false }
    }
    func finishLFSOperation() {
        guard !retired, lockingFiles else { return }; lockingFiles = false; busy = false
        reload(); onLFSChanged()
    }
    var columnCommandsAvailable: Bool { !retired && !busy && !confirmingQuit }
    func setColumn(_ column: StatusListColumn, visible: Bool) {
        guard columnCommandsAvailable, column != .path, Self.columns.contains(column) else { return }
        if visible { fileColumns.visible.insert(column) } else { fileColumns.visible.remove(column) }
        fileColumns.save(to: defaults, key: Self.columnKey)
    }
    func saveColumnLayout(order: [StatusListColumn], widths: [StatusListColumn: Double]) {
        guard columnCommandsAvailable else { return }
        let next = StatusListColumnSettings(visible: fileColumns.visible, order: order, widths: widths)
        if next != fileColumns { fileColumns = next; fileColumns.save(to: defaults, key: Self.columnKey) }
    }
    func beginColumnReset() -> Bool {
        guard columnCommandsAvailable else { return false }; resettingColumns = true; busy = true; return true
    }
    func finishColumnReset(accepted: Bool) {
        guard !retired, resettingColumns else { return }; resettingColumns = false; busy = false
        if accepted { fileColumns = Self.defaultColumns; fileColumns.save(to: defaults, key: Self.columnKey); columnResetGeneration += 1 }
    }
    private(set) var fileMenuGeneration = UUID()
    @Published var entries: [AddDialogEntry] = [] {didSet {fileMenuGeneration = UUID()}}
    @Published var checked = GitPathSet()
    @Published var highlighted = GitPathSet() {didSet {if highlighted != oldValue {fileMenuGeneration = UUID()}}}
    @Published var selectionMark: String? {didSet {if selectionMark.map({GitReferenceName($0)}) != oldValue.map({GitReferenceName($0)}) {fileMenuGeneration = UUID()}}}
    @Published private(set) var hasHead = false
    @Published var includeIgnored = false
    @Published var busy = false {didSet {if busy != oldValue {fileMenuGeneration = UUID()}}}
    @Published var confirmingQuit = false {didSet {if confirmingQuit != oldValue {fileMenuGeneration = UUID()}}}
    @Published var error: String?
    @Published var sortOrder = [KeyPathComparator(\AddDialogEntry.path)]
    private var paths: [String] = ["."]
    var scopePaths: [String] { paths }
    private var loaded = false
    private(set) var ignoring = false
    @Published var restoreCopies: GitPathMap<WorkingFileRestoreCopy> = [:] {didSet {fileMenuGeneration = UUID()}}
    @Published private(set) var indexFlagFiles: [WorkingTreeFile] = []
    private var pendingFlags: (IndexFlagAction, [String], String)?
    var onIndexFlags: (IndexFlagAction, [String], String) -> Void = { _, _, _ in }
    func beginFlagConfirmation(_ action: IndexFlagAction, paths: [String], mark: String) -> Bool {
        guard !retired, !busy, !confirmingQuit, !paths.isEmpty, GitPathSet(paths).contains(mark),
              paths.allSatisfy({ path in entries.contains { GitReferenceName.equal($0.path,path) } }),
              let marked = indexFlagFiles.first(where: { GitReferenceName.equal($0.id,mark) }), action.isAvailable(for: [marked]) else { return false }
        pendingFlags = (action, paths, mark); busy = true; return true
    }
    @discardableResult func finishFlagConfirmation(accepted: Bool) -> Task<Void, Never>? {
        guard !retired else { return nil }
        guard let (action, paths, mark) = pendingFlags else { return nil }; pendingFlags = nil
        guard accepted else { busy = false; return nil }
        cancellation = OperationCancellation(); let operationCancellation = cancellation
        return performOperation { [self] in
            defer { busy = false; if !retired && (operationCancellation.isCancelled || cancellation.isCancelled) { close() }; cancellation = OperationCancellation() }
            do {
                try validateAccess()
                if operationCancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                // The shared locked index transaction finishes atomically once started.
                try await repository.setIndexFlags(action, paths: paths, markedPath: mark)
                if !retired { onIgnoreChanged(action.rawValue + ": " + paths.joined(separator: ", ")) }
            } catch {
                if let failure = error as? IndexFlagPartialFailure, !failure.updatedPaths.isEmpty { onIgnoreChanged(failure.localizedDescription) }
                if !(error is OperationCancellationFailure) { self.error = error.localizedDescription }
            }
            cancellation = OperationCancellation()
            do { try await read() } catch { if !retired && !cancellation.isCancelled { self.error = [self.error, error.localizedDescription].compactMap { $0 }.joined(separator: "\n") } }
        }
    }
    private var pendingRevert: [AddDialogEntry]?
    private(set) var pendingRevertPolicy:WorkingFileRevertPolicy?
    private(set) var reverting = false
    private var closeAfterRevert = false
    private var cancelRevert: (() -> Void)?
    var onRevertRequest: ([AddDialogEntry]) -> Void = { _ in }
    var onRevert: ([StatusEntry], @escaping (Bool) -> Void) -> (() -> Void) = { _, done in done(false); return {} }
    var revertNeedsConfirmation: Bool { pendingRevert?.contains { !$0.isDirectory && [$0.status.index, $0.status.worktree].contains { $0 == "M" || $0 == "T" } } == true }
    func beginRevertConfirmation(_ rows: [AddDialogEntry]) -> Bool {
        let marked = rows.first { GitReferenceName.equal($0.path,selectionMark) } ?? rows.first
        guard !retired, !busy, !confirmingQuit, !rows.isEmpty, marked?.status.canCompareWithBaseFromStatusList == true else { return false }
        pendingRevertPolicy = .load(from:defaults)
        pendingRevert = rows; busy = true; return true
    }
    func finishRevertConfirmation(accepted: Bool) {
        guard !retired else { return }
        guard let selected = pendingRevert else { return }; pendingRevert = nil
        guard accepted else { pendingRevertPolicy=nil;busy = false; return }
        reverting = true; closeAfterRevert = false
        let cancel = onRevert(selected.map(\.status)) { [weak self] succeeded in self?.finishRevert(selected, succeeded: succeeded) }
        if reverting { cancelRevert = cancel }
    }
    private func finishRevert(_ selected: [AddDialogEntry], succeeded: Bool) {
        guard !retired, reverting else { return }; pendingRevertPolicy=nil;reverting = false; cancelRevert = nil; cancellation = OperationCancellation()
        performOperation { [self] in
            defer { busy = false; if !retired && (closeAfterRevert || cancellation.isCancelled) { close() }; closeAfterRevert = false; cancellation = OperationCancellation() }
            if succeeded { checked.subtract(selected.map(\.path)); highlighted.subtract(selected.map(\.path)) }
            do {
                try await read()
                if succeeded {
                    let clean = GitPathSet(selected.filter { !$0.isDirectory && $0.state != .added }.map(\.path))
                    entries.removeAll { clean.contains($0.path) && $0.state == .normal }
                }
            } catch { if !retired && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private var pendingRestore: [String]?
    var onRestore: ([String]) -> Void = { _ in }
    var onRestoreChanged: () -> Void = {}
    private var pendingDelete: (selected: [StatusEntry], permanently: Bool)?
    private(set) var lastDeleteResult: WorkingFileDeleteResult?
    private var cancellation = OperationCancellation()
    var close: () -> Void = {}
    var onAccepted: ([String]) -> Void = { _ in }
    private(set) var acceptedBackend: GitLibGit2Configuration?
    private var accepted = false
    var onPreview: (String) -> Void = { _ in }
    var onCompare: ([String]) -> Void = { _ in }
    var onCompareTwo: ([String]) -> Void = { _ in }
    var unifiedViewerBusy: () -> Bool = { false }
    var onUnifiedPatch: (Data, Bool) async throws -> Void = { _, _ in }
    var onLog: (String) -> Void = { _ in }
    var onBlame: (String) -> Void = { _ in }
    var onOpen: (String, AddFileOpenAction) -> Void = { _, _ in }
    var onIgnore: ([String], Bool) -> Void = { _, _ in }
    var onIgnoreChanged: (String) -> Void = { _ in }
    func beginIgnore() -> Bool {
        guard !retired, !busy, !confirmingQuit else { return false }
        ignoring = true; busy = true; return true
    }
    func finishIgnore(changed: Bool) {
        guard !retired, ignoring else { return }
        ignoring = false; busy = false
        if changed { reload() }
    }
    var onSave: (String) -> Void = { _ in }
    var onExport: ([String]) -> Void = { _ in }
    @Published var information = ""
    func saveFile(_ path: String, to target: URL) async { await startSave(path, to: target)?.value }
    func exportFiles(_ paths: [String], to folder: URL) async { await startExport(paths, to: folder)?.value }
    @discardableResult func startSave(_ path: String, to target: URL) -> Task<Void, Never>? { startCopy([path], to: target, save: true) }
    @discardableResult func startExport(_ paths: [String], to folder: URL) -> Task<Void, Never>? { startCopy(paths, to: folder, save: false) }
    var chooseSaveFile:(String) async -> URL? = {_ in nil}
    var chooseExportFolder:() async -> URL? = {nil}
    var chooseApplication:() async -> URL? = {nil}
    var cancelFileChoice:()->Void = {}
    private var fileIOActive = false
    var openWorkingFile:(URL,URL?) async throws -> Void = {file,application in
        if let application {
            try await withCheckedThrowingContinuation { (reply:CheckedContinuation<Void,Error>) in
                NSWorkspace.shared.open([file],withApplicationAt:application,configuration:NSWorkspace.OpenConfiguration()) {_,error in
                    if let error {reply.resume(throwing:error)} else {reply.resume()}
                }
            }
        } else if !NSWorkspace.shared.open(file) {throw StatusFileActionFailure(message:"Could not open the file. Choose an application using Open With.")}
    }
    lazy var openAlternativeEditor:(URL) async throws -> Void = { [weak self] file in
        guard let self else {throw OperationCancellationFailure.cancelled}
        try await withCheckedThrowingContinuation { (reply:CheckedContinuation<Void,Error>) in
            AlternativeEditor.open(file,preferences:self.defaults,permissions:self.access.map {[$0]} ?? []) {failure in
                if let failure {reply.resume(throwing:StatusFileActionFailure(message:failure))} else {reply.resume()}
            }
        }
    }
    private func fileRequestIsLive(_ token:OperationCancellation)->Bool {!retired && !confirmingQuit && cancellation === token && !token.isCancelled}
    @discardableResult private func fileRequest(_ paths:[String],operation:@escaping (OperationCancellation) async throws -> Void)->Task<Void,Never>? {
        guard !retired,!accepted,!busy,!confirmingQuit,!paths.isEmpty,GitPathSet(paths).count == paths.count else {return nil}
        let token = OperationCancellation();cancellation = token;fileIOActive = true;busy = true
        return performOperation { [self] in
            defer {
                withExtendedLifetime(access) {}
                if cancellation === token {
                    fileIOActive = false;busy = false;cancellation = OperationCancellation()
                    if !retired,token.isCancelled {close()}
                }
            }
            do {try validateAccess();try await operation(token)}
            catch {if fileRequestIsLive(token) {self.error = error.localizedDescription}}
        }
    }
    @discardableResult func requestOpen(_ path:String,action:AddFileOpenAction)->Task<Void,Never>? {
        guard entries.contains(where:{GitReferenceName.equal($0.path,path) && !$0.isDirectory}) else {return nil}
        return fileRequest([path]) { [self] token in
            let application = action == .openWith ? await chooseApplication():nil
            guard fileRequestIsLive(token),action != .openWith || application != nil else {return}
            let file = repository.root.appendingPathComponent(path)
            let scoped = application?.startAccessingSecurityScopedResource() ?? false
            defer {if scoped {application?.stopAccessingSecurityScopedResource()}}
            if action == .editor {try await openAlternativeEditor(file)} else {try await openWorkingFile(file,application)}
        }
    }
    @discardableResult func requestSave(_ path:String)->Task<Void,Never>? {
        guard entries.contains(where:{GitReferenceName.equal($0.path,path) && !$0.isDirectory}) else {return nil}
        return fileRequest([path]) { [self] token in
            guard let target = await chooseSaveFile(path),fileRequestIsLive(token) else {return}
            try await copy([path],to:target,save:true,token:token)
        }
    }
    @discardableResult func requestExport(_ paths:[String])->Task<Void,Never>? {
        guard paths.allSatisfy({path in entries.contains(where:{GitReferenceName.equal($0.path,path)})}) else {return nil}
        return fileRequest(paths) { [self] token in
            guard let target = await chooseExportFolder(),fileRequestIsLive(token) else {return}
            try await copy(paths,to:target,save:false,token:token)
        }
    }
    private func startCopy(_ paths:[String],to target:URL,save:Bool)->Task<Void,Never>? {
        fileRequest(paths) { [self] token in try await copy(paths,to:target,save:save,token:token) }
    }
    private func copy(_ paths:[String],to target:URL,save:Bool,token:OperationCancellation) async throws {
        guard fileRequestIsLive(token) else {throw OperationCancellationFailure.cancelled}
        let scoped = target.startAccessingSecurityScopedResource();defer {if scoped {target.stopAccessingSecurityScopedResource()}}
        if GitRuntime.isAppStoreBuild && !scoped {throw RepositoryAccessFailure.securityScopeUnavailable}
        if save {
            try await repository.saveWorkingFile(path:paths[0],to:target,cancellation:token)
            if fileRequestIsLive(token) {information = "Saved " + target.path}
        } else {
            let count = try await repository.exportWorkingFiles(paths:paths,to:target,cancellation:token)
            if fileRequestIsLive(token) {information = "\(count) file(s) exported."}
        }
    }
    var onDelete: ([StatusEntry], Bool) -> Void = { _, _ in }
    var onDeleteChanged: (String) -> Void = { _ in }
    func beginDeleteConfirmation(_ selected: [StatusEntry], permanently: Bool) -> Bool {
        guard !retired, !busy, !confirmingQuit, !selected.isEmpty, selected.contains(where: \.canDeleteFromStatusList) else { return false }
        pendingDelete = (selected, permanently); lastDeleteResult = nil; busy = true; return true
    }
    @discardableResult func finishDeleteConfirmation(accepted: Bool) -> Task<Void, Never>? {
        guard !retired else { return nil }
        guard let pendingDelete else { return nil }; self.pendingDelete = nil
        guard accepted else { busy = false; return nil }
        cancellation = OperationCancellation()
        return performOperation { [self] in
            do {
                try validateAccess()
                let result = try await repository.deleteWorkingFiles(pendingDelete.selected, permanently: pendingDelete.permanently, cancellation: cancellation)
                guard !retired else { return }
                lastDeleteResult = result
                checked.subtract(pendingDelete.selected.map(\.path)); highlighted.subtract(pendingDelete.selected.map(\.path))
                onDeleteChanged("\(pendingDelete.selected.count) item(s) deleted." + (result.trashedFiles.isEmpty ? "" : "\n" + result.trashedFiles.map { "Moved to Trash: " + $0.path }.joined(separator: "\n")))
            } catch {
                guard !retired else { return }
                self.error = error.localizedDescription
                if let failure = error as? WorkingFileDeleteFailure, !failure.removedPaths.isEmpty { onDeleteChanged(failure.localizedDescription) }
            }
            guard !retired else { return }
            cancellation = OperationCancellation()
            do { try await read() } catch { if !retired { self.error = [self.error, error.localizedDescription].compactMap { $0 }.joined(separator: "\n") } }
            busy = false
        }
    }
    @discardableResult func startMarkForRestore(_ paths: [String]) -> Task<Void, Never>? {
        let files = paths.filter { path in entries.contains { GitReferenceName.equal($0.path,path) && !$0.isDirectory } && restoreCopies[path] == nil }
        guard !retired, !busy, !confirmingQuit, !files.isEmpty else { return nil }
        busy = true; cancellation = OperationCancellation()
        return performOperation { [self] in
            defer { busy = false; if !retired && cancellation.isCancelled { close() }; cancellation = OperationCancellation() }
            do {
                try validateAccess()
                var failures: [String] = []
                for path in files {
                    if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                    do {
                        let copy = try await repository.captureWorkingFileRestoreCopy(path: path, allowUnversioned: true)
                        guard !retired else { return }; restoreCopies[path] = copy
                    }
                    catch { failures.append(path + ": " + error.localizedDescription) }
                }
                if !retired && !failures.isEmpty { self.error = failures.joined(separator: "\n") }
            } catch { if !retired && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func beginRestoreConfirmation(_ paths: [String]) -> Bool {
        guard !retired, !busy, !confirmingQuit, paths.contains(where: { restoreCopies[$0] != nil }) else { return false }
        pendingRestore = paths; busy = true; return true
    }
    @discardableResult func finishRestoreConfirmation(accepted: Bool) -> Task<Void, Never>? {
        guard !retired else { return nil }
        guard let paths = pendingRestore else { return nil }; pendingRestore = nil
        guard accepted else { busy = false; return nil }
        cancellation = OperationCancellation()
        return performOperation { [self] in
            var changed = false
            defer { busy = false; if !retired && cancellation.isCancelled { close() }; cancellation = OperationCancellation() }
            do {
                try validateAccess()
                var failures: [String] = []
                for path in paths {
                    if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                    guard let copy = restoreCopies[path] else { continue }
                    do { try await repository.restoreWorkingFile(copy); guard !retired else { return }; restoreCopies.removeValue(forKey: path); changed = true }
                    catch { failures.append(path + ": " + error.localizedDescription) }
                }
                if !retired && !failures.isEmpty { self.error = failures.joined(separator: "\n") }
            } catch { if !retired && !cancellation.isCancelled { self.error = error.localizedDescription } }
            if changed, !retired {
                onRestoreChanged()
                do { try await read() } catch { if !retired && !cancellation.isCancelled { self.error = error.localizedDescription } }
            }
        }
    }
    @discardableResult func startUnifiedDiff(paths: [String], alternate: Bool = false) -> Task<Void, Never>? {
        let marked = entries.first { GitReferenceName.equal($0.path,selectionMark) && GitPathSet(paths).contains($0.path) } ?? entries.first { GitReferenceName.equal($0.path,paths.first) }
        guard !retired, !busy, !confirmingQuit, !unifiedViewerBusy(), hasHead, !paths.isEmpty,
              GitPathSet(paths).count == paths.count, paths.allSatisfy({ path in entries.contains { GitReferenceName.equal($0.path,path) } }),
              marked?.status.canCompareWithBaseFromStatusList == true else { return nil }
        busy = true; cancellation = OperationCancellation()
        return performOperation { [self] in
            defer {
                busy = false
                if !retired && cancellation.isCancelled { close() }
                cancellation = OperationCancellation()
            }
            do {
                try validateAccess(); if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                var bytes = Data()
                for path in paths {
                    bytes.append(try await repository.run(["-c","core.precomposeunicode=false","diff", "--no-ext-diff", "--no-color", "--stat", "-p", "--end-of-options", "HEAD", "--", path], cancellation: cancellation).stdout)
                }
                if retired || cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                if unifiedViewerBusy() { throw NSError(domain: "TurtleGit.Add", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finish the open unified diff operation before showing another comparison."]) }
                try await onUnifiedPatch(bytes, alternate)
            } catch { if !retired && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func performOperation(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Self.activeOperations += 1
        return Task { @MainActor in
            defer { Self.activeOperations -= 1 }
            guard !retired else { return }
            await work()
        }
    }
    var canApply: Bool { !retired && !accepted && !busy && !confirmingQuit && entries.contains {checked.contains($0.path)} }
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.defaults = defaults
        if defaults.integer(forKey: Self.columnKey + ".Version") == 1 { fileColumns = .load(from: defaults, key: Self.columnKey) }
        else {
            var value = Self.defaultColumns
            if defaults.bool(forKey: "Add.ShowSize") { value.visible.insert(.fileSize) }
            if defaults.bool(forKey: "Add.ShowModifiedDate") { value.visible.insert(.lastModified) }
            fileColumns = value
        }
    }
    func invalidateFileMenus() {fileMenuGeneration = UUID()}
    func setScope(_ paths: [String]) { guard !retired, !busy else { return }; self.paths = paths.isEmpty ? ["."] : paths; loaded = false;accepted = false; checked = []; highlighted = []; selectionMark = nil; hasHead = false }
    private func validateAccess() throws {
        guard !retired, !cancellation.isCancelled else { throw OperationCancellationFailure.cancelled }
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func invalidate() {
        guard !retired else { return }; retired = true; cancellation.cancel();cancelFileChoice(); readTask?.cancel(); readTask = nil
        cancelRevert?(); cancelRevert = nil; reverting = false
        pendingFlags = nil; pendingDelete = nil; pendingRestore = nil; pendingRevert = nil;pendingRevertPolicy=nil; ignoring = false
        restoreCopies.removeAll(); lockingFiles = false; resettingColumns = false; busy = false
    }
    func read() async throws {
        try validateAccess()
        let token = cancellation
        let selection: AddDialogSelection
        if let querySelection { selection = try await querySelection(paths, includeIgnored, token) }
        else { selection = try await repository.addDialogSelection(paths: paths, includeIgnored: includeIgnored, cancellation: token) }
        guard !retired, cancellation === token, !token.isCancelled else { throw OperationCancellationFailure.cancelled }
        let head = try? await repository.run(["rev-parse", "--verify", "HEAD^{commit}"], cancellation: cancellation)
        if retired || cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
        let flags = try await repository.workingTreeStatus(refreshIndex: false, cancellation: token)
        if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
        guard !retired, cancellation === token, !token.isCancelled else { throw OperationCancellationFailure.cancelled }
        let lfs = try await repository.hasLFS(cancellation: token)
        guard !retired, cancellation === token, !token.isCancelled else { throw OperationCancellationFailure.cancelled }
        hasHead = head != nil; indexFlagFiles = flags; hasLFS = lfs
        let previous = GitPathSet(entries.map(\.path))
        entries = selection.entries
        if loaded { checked.formIntersection(GitPathSet(entries.map(\.path))); checked.formUnion(selection.initiallyChecked.subtracting(previous)) }
        else { checked = selection.initiallyChecked; loaded = true }
        highlighted.formIntersection(GitPathSet(entries.map(\.path)))
    }
    func reload() {
        guard !retired, !busy, !confirmingQuit else { return }; busy = true; cancellation = OperationCancellation()
        let token = cancellation
        readTask = performOperation { [self] in
            defer { self.readTask = nil; self.busy = false; if !self.retired && token.isCancelled { self.close() } }
            do { try await self.read() }
            catch { if !self.retired && !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func cancel() {
        guard !retired, !confirmingQuit, !ignoring, !lockingFiles, !resettingColumns, pendingDelete == nil, pendingRestore == nil, pendingRevert == nil, pendingFlags == nil else { return }
        if fileIOActive {cancellation.cancel();cancelFileChoice()}
        else if reverting { closeAfterRevert = true; cancelRevert?() }
        else if busy { cancellation.cancel() }
        else { close() }
    }
    func apply() {
        guard canApply else {return}
        let paths = GitPathOperationOrder.sorted(entries.filter {checked.contains($0.path)}.map(\.path))
        guard !paths.isEmpty else {return};acceptedBackend = .load(from: defaults);accepted = true;onAccepted(paths);close()
    }
    var canReceiveFileDrop: Bool { !retired && !busy && !confirmingQuit && loaded }
    @discardableResult func addDropped(_ urls: [URL]) -> Bool {
        guard canReceiveFileDrop, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        busy = true; cancellation = OperationCancellation(); let token = cancellation
        readTask = performOperation { [self] in
            defer { self.readTask = nil; self.busy = false; if !self.retired && token.isCancelled { self.close() } }
            do {
                try self.validateAccess()
                let items: [WorkingFileDropItem]
                if let query = self.queryDroppedItems { items = try await query(urls, token) }
                else { items = try await self.repository.resolveWorkingFileDrops(urls, cancellation: token) }
                guard !self.retired, self.cancellation === token, !token.isCancelled, !Task.isCancelled else { throw OperationCancellationFailure.cancelled }
                guard !items.isEmpty else { return }
                if items.contains(where: { $0.path == "." }) { self.paths = ["."] }
                else if !self.paths.contains(".") {
                    for item in items where !self.entries.contains(where: { $0.path.utf8.elementsEqual(item.path.utf8) }) && !self.paths.contains(where: { $0.utf8.elementsEqual(item.path.utf8) || item.path.utf8.starts(with:($0 + "/").utf8) }) { self.paths.append(item.path) }
                }
                try await self.read()
                guard !self.retired, !token.isCancelled else { throw OperationCancellationFailure.cancelled }
                for item in items {
                    for row in self.entries where item.path == "." || row.path.utf8.elementsEqual(item.path.utf8) || item.directory && row.path.utf8.starts(with:(item.path + "/").utf8) {
                        if row.state == .untracked || row.status.hasUnversionedCopy || self.paths.contains(where:{GitReferenceName.equal($0,row.path)}) { self.checked.insert(row.path) }
                        else { self.checked.remove(row.path) }
                    }
                }
            } catch { if !self.retired && !token.isCancelled { self.error = error.localizedDescription } }
        }
        return true
    }
}
enum AddFileOpenAction { case open, openWith, editor }

struct AddDialogView: View {
    @ObservedObject var model: AddWindowModel
    var body: some View {
        VStack(spacing: 10) {
            AddFileTable(model: model).frame(minHeight: 220)
            HStack {
                SelectionAllCheckbox(checked: model.checked.count, total: model.entries.count, checkedCount: { model.checked.count }) { model.checked = $0 ? GitPathSet(model.entries.map(\.path)) : [] }.frame(width: 180, height: 22)
                Toggle("Include ignored files", isOn: $model.includeIgnored).toggleStyle(.checkbox).onChange(of: model.includeIgnored) { _ in model.reload() }
                Spacer()
            }.disabled(model.busy)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                if !model.busy && !model.information.isEmpty { Text(model.information).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                if !model.busy && model.entries.isEmpty { Text("There is nothing to add.").foregroundStyle(.secondary) }
                Spacer()
                Button("OK") { model.apply() }.keyboardShortcut(.defaultAction).disabled(!model.canApply)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("Help") { TurtleGitHelp.show(.add) }
            }
        }.padding(12).disabled(model.confirmingQuit)
        .alert("Add failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
