import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import TurtleGitCore

private final class RevertNativeWindow:NSWindow {
    var commandKeyWindow:()->NSWindow? = {NSApp.keyWindow}
    var refresh:()->Void = {},accept:()->Void = {}
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        guard commandKeyWindow() === self,event.window === self,attachedSheet == nil else {return super.performKeyEquivalent(with:event)}
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.keyCode == 96,flags.isEmpty {refresh();return true}
        if [36,76].contains(event.keyCode),flags == .command || flags == .control {accept();return true}
        return super.performKeyEquivalent(with:event)
    }
}

@MainActor final class RevertWindowController:NSWindowController,NSWindowDelegate {
    let model:RevertWindowModel
    var onClosed:()->Void = {}
    var commandKeyWindow:()->NSWindow? = {NSApp.keyWindow}
    private var question:(NSAlert,CheckedContinuation<Bool,Never>)?
    private var panel:(NSSavePanel,CheckedContinuation<URL?,Never>)?
    private var lfsOperation:LFSFileOperationController?
    private var sheetObserver:NSObjectProtocol?
    private(set) var revertProgress:RevertProgressWindowController?
    init(repository:GitRepository,access:RepositoryAccessLease?,preferences:UserDefaults = .standard) {
        model = RevertWindowModel(repository:repository,access:access,preferences:preferences)
        let window = RevertNativeWindow(contentRect:.init(x:0,y:0,width:1000,height:520),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        RepositoryWindowTitles.set(window,repository:repository.root,dialog:"Revert",preferences:preferences)
        window.contentMinSize = .init(width:900,height:360);window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:RevertDialog(model:model).defaultAppStorage(preferences))
        super.init(window:window);window.delegate = self;window.setContentSize(.init(width:1000,height:520));window.center()
        model.window = window;model.commands.comparisonWindow = window
        sheetObserver = NotificationCenter.default.addObserver(forName:NSWindow.didEndSheetNotification,object:window,queue:.main) { [weak model] _ in
            DispatchQueue.main.async {model?.resumePendingRefresh()}
        }
        model.updateTitle = { [weak window] location in RepositoryWindowTitles.set(window,repository:repository.root,location:location,dialog:"Revert",preferences:preferences) }
        model.close = { [weak window] in window?.performClose(nil) }
        window.commandKeyWindow = { [weak self] in self?.commandKeyWindow() }
        window.refresh = { [weak model] in model?.reload() };window.accept = { [weak model] in model?.apply() }
        model.chooseSaveFile = { [weak self] path in await self?.chooseSave(path:path) }
        model.commands.chooseApplication = { [weak self] in await self?.choose(application:true) }
        model.commands.chooseExportFolder = { [weak self] in await self?.choose(application:false) }
        model.commands.confirmDeletion = { [weak self] paths,permanent in
            await self?.ask(title:permanent ? "Permanently delete the selected paths?":"Move the selected paths to Trash?",detail:"\(paths.count) selected item(s). Their index entries will also be removed." + (permanent ? " This cannot be undone.":" Files moved to Trash can be recovered in Finder."),yesDefault:false) ?? false
        }
        model.commands.onLFSOperation = { [weak self] paths,locked in
            guard let self,!self.model.retired,!self.model.busy,!self.model.confirmingQuit,let window=self.window,window.attachedSheet == nil,self.lfsOperation == nil else {return false}
            let operation = LFSFileOperationController(repository:repository,access:access,defaults:preferences)
            operation.model.onPullAfterLock = { [weak model=self.model] in model?.onAction(.pull,[]) }
            operation.model.onProgressLog = { [weak model=self.model] path in model?.onFileLog(path) }
            operation.onClosed = { [weak self,weak operation] in
                guard let self,!self.model.retired,self.lfsOperation === operation else {return};self.lfsOperation = nil
                self.model.commands.busy = false;self.model.reload();self.model.onChanged()
            }
            self.lfsOperation = operation
            guard operation.present(owner:window,paths:paths,locked:locked) else {self.lfsOperation = nil;return false};return true
        }
        model.confirmRevert = { [weak self] rows in
            await self?.ask(title:"Revert the selected paths?",detail:"Working changes to \(rows.count) selected item(s) will be reverted. Displaced working files use the existing Revert recovery flow.",yesDefault:true) ?? false
        }
        model.onRevert = { [weak self] rows in
            guard let self,!self.model.retired,self.revertProgress == nil else {return}
            let progress = RevertProgressWindowController(repository:repository,access:access,entries:rows,amend:false,againstHead:false,autoCloseSuccess:false,preferences:preferences)
            self.revertProgress = progress;self.model.hasChild = true
            progress.model.onFinished = { [weak model=self.model] _,_ in if model?.retired == false {model?.onChanged()} }
            progress.model.onHandleSubmodules = { [weak model=self.model] revision,paths in if model?.retired == false {model?.onHandleSubmodules(revision,paths)} }
            progress.onClosed = { [weak self,weak progress] in
                guard let self,self.revertProgress === progress else {return};self.revertProgress = nil
                guard !self.model.retired else {return};self.model.hasChild = false;self.model.reload()
            }
            progress.window?.alphaValue = window.alphaValue;progress.window?.appearance = window.appearance
            progress.showWindow(nil);progress.model.start()
        }
        DialogGeometry.attach(window,identifier:"RevertDialog",legacyName:"RevertDialog")
    }
    private func choose(application:Bool) async -> URL? {
        guard !model.retired,panel == nil,question == nil,let window,window.attachedSheet == nil else {return nil}
        let picker = NSOpenPanel();picker.allowsMultipleSelection = false
        picker.title = application ? "Open With":"Export working files";picker.prompt = application ? "Open":"Export"
        picker.canChooseFiles = application;picker.canChooseDirectories = !application;picker.canCreateDirectories = !application
        if application {picker.allowedContentTypes = [.applicationBundle];picker.directoryURL = URL(fileURLWithPath:"/Applications")}
        return await withCheckedContinuation { continuation in
            panel = (picker,continuation)
            picker.beginSheetModal(for:window) { [weak self] response in self?.finishPanel(picker,response:response) }
        }
    }
    private func chooseSave(path:String) async -> URL? {
        guard !model.retired,panel == nil,question == nil,let window,window.attachedSheet == nil else {return nil}
        let picker = NSSavePanel(),file = URL(fileURLWithPath:path)
        picker.title = "Save As";picker.canCreateDirectories = true
        picker.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + "-" + (file.pathExtension.isEmpty ? "":"." + file.pathExtension)
        picker.directoryURL = model.repository.root.appendingPathComponent(path).deletingLastPathComponent()
        return await withCheckedContinuation {continuation in
            panel = (picker,continuation)
            picker.beginSheetModal(for:window) { [weak self] response in self?.finishPanel(picker,response:response) }
        }
    }
    private func finishPanel(_ picker:NSSavePanel,response:NSApplication.ModalResponse) {
        guard let pending = panel,pending.0 === picker else {return};panel = nil
        if picker.sheetParent === window {window?.endSheet(picker)};picker.orderOut(nil)
        pending.1.resume(returning:!model.retired && response == .OK ? picker.url:nil)
    }
    private func ask(title:String,detail:String,yesDefault:Bool) async -> Bool {
        guard !model.retired,question == nil,panel == nil,let window,window.attachedSheet == nil else {return false}
        let alert = NSAlert();alert.messageText = title;alert.informativeText = detail
        alert.addButton(withTitle:yesDefault ? "Yes":"No");alert.addButton(withTitle:yesDefault ? "No":"Yes")
        return await withCheckedContinuation { continuation in
            question = (alert,continuation)
            alert.beginSheetModal(for:window) { [weak self] response in
                self?.finishQuestion(alert,accepted:response == (yesDefault ? .alertFirstButtonReturn:.alertSecondButtonReturn))
            }
        }
    }
    private func finishQuestion(_ alert:NSAlert,accepted:Bool) {
        guard let pending = question,pending.0 === alert else {return};question = nil
        if alert.window.sheetParent === window {window?.endSheet(alert.window)};alert.window.orderOut(nil)
        pending.1.resume(returning:!model.retired && accepted)
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard sender.attachedSheet == nil,!model.confirmingQuit,!model.hasChild else {return false}
        if model.cancel(closeAfter:true) {return false};return !model.commands.busy && !model.commands.unifiedViewerBusy
    }
    func windowWillClose(_ notification:Notification) {
        model.invalidate()
        if let sheetObserver {NotificationCenter.default.removeObserver(sheetObserver);self.sheetObserver = nil}
        if let pending = panel {finishPanel(pending.0,response:.cancel)}
        if let pending = question {finishQuestion(pending.0,accepted:false)}
        lfsOperation?.close();lfsOperation = nil;revertProgress?.close();revertProgress = nil
        window?.contentViewController = nil;onClosed()
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
}

@MainActor final class RevertWindowModel:ObservableObject {
    static private(set) var activeOperations = 0
    let repository:GitRepository
    private let access:RepositoryAccessLease?
    let preferences:UserDefaults
    let commands:StatusWindowModel
    let fileListRefresh = FileListRefreshCoordinator()
    weak var window:NSWindow?
    @Published private(set) var entries:[StatusEntry] = []
    @Published private(set) var statistics:GitPathMap<CommitFile> = [:]
    @Published var checked = Set<String>()
    @Published var highlighted = Set<String>() {didSet {commands.selection = highlighted}}
    @Published private(set) var busy = false
    @Published var confirmingQuit = false {didSet {commands.confirmingQuit = confirmingQuit;if !confirmingQuit {resumePendingRefresh()}}}
    @Published var error:String?
    @Published private(set) var hasUnversionedItems = false
    @Published private(set) var cancelling = false
    @Published var hasChild = false
    private var exclusiveAction = false
    private var pendingDrops:[URL] = []
    @Published private(set) var fileColumns:StatusListColumnSettings
    @Published var sortOrder = [StatusFileSort(column:.path)] {didSet {commands.sortOrder = sortOrder}}
    private var paths = ["."],hasLoaded = false,closeAfterRead = false
    private var request:OperationCancellation?
    private var generation = UUID()
    private var queuedForce = Set<String>()
    private var refreshRequested = false
    private var observer:AnyCancellable?
    private(set) var retired = false
    var readStatus:(OperationCancellation) async throws -> [WorkingTreeFile]
    var readStatistics:(OperationCancellation) async throws -> [CommitFile]
    var validateDrop:(URL,OperationCancellation) async throws -> Void
    var close:()->Void = {}
    var updateTitle:(URL)->Void = {_ in}
    var onAccepted:([StatusEntry])->Void = {_ in}
    var onFileLog:(String)->Void = {_ in}
    var onAction:(RepositoryAction,[String])->Void = {_,_ in}
    var onChanged:()->Void = {}
    var onHandleSubmodules:(String,[String])->Void = {_,_ in}
    var confirmRevert:([StatusEntry]) async -> Bool = {_ in false}
    var onRevert:([StatusEntry])->Void = {_ in}
    var onCompare:(([String])->Void)?
    @Published private(set) var comparisonMark:PreparedFileComparisonMark?
    private var comparisonGeneration = UUID()
    private var lastImportedWorkingMark:UUID?
    var onPreparedFileCompare:((PreparedFileComparisonMark,PreparedFileComparisonMark)->Void)?
    var chooseSaveFile:(String) async -> URL? = {_ in nil}
    var saveWorkingFile:(String,URL,OperationCancellation) async throws -> Void

    var canInteract:Bool {!retired && !busy && !commands.busy && !confirmingQuit && !hasChild && !commands.unifiedViewerBusy && window?.attachedSheet == nil}
    var canApply:Bool {canInteract && entries.contains{checked.contains($0.path)}}
    var rows:[StatusRow] {commands.sortedRows}
    static let columnKey = "RevertDlg.FileColumns"
    static var defaultColumns:StatusListColumnSettings {.init(visible:Set(StatusListColumn.defaultColumns))}
    var availableColumns:Set<StatusListColumn> {Set(StatusListColumn.allCases.filter{$0 != .lfsOwner})}
    init(repository:GitRepository,access:RepositoryAccessLease?,preferences:UserDefaults = .standard) {
        self.repository = repository;self.access = access;self.preferences = preferences
        commands = StatusWindowModel(repository:repository,access:access,defaults:preferences)
        fileColumns = preferences.integer(forKey:Self.columnKey + ".Version") == 1 ? .load(from:preferences,key:Self.columnKey):Self.defaultColumns
        readStatus = {try await repository.workingTreeStatus(refreshIndex:false,cancellation:$0)}
        readStatistics = {try await repository.workingTreeFiles(cancellation:$0)}
        saveWorkingFile = {try await repository.saveWorkingFile(path:$0,to:$1,cancellation:$2)}
        validateDrop = {url,token in
            let attributes = try? FileManager.default.attributesOfItem(atPath:url.path)
            let folder = attributes?[.type] as? FileAttributeType == .typeDirectory ? url:url.deletingLastPathComponent()
            let owner = try await GitRepository(root:folder,executable:repository.executable).discoverSelectionRoot(for:.revert,selected:url,cancellation:token)
            guard owner.standardizedFileURL.path == repository.root.standardizedFileURL.path else {throw RevertDropFailure.outsideRepository}
        }
        commands.groupsEnabled = false;commands.fileColumns = fileColumns
        commands.filter.showUnversioned = true;commands.filter.showIgnored = true;commands.filter.showUnmodified = true;commands.filter.showLocalChangesIgnored = true
        commands.embeddedReload = { [weak self] in self?.reload() }
        commands.actionOwnerAvailable = { [weak self] in guard let self else {return false};return !self.retired && !self.busy && !self.confirmingQuit && !self.hasChild && self.window?.attachedSheet == nil && !self.commands.unifiedViewerBusy }
        commands.onAction = { [weak self] action,paths in
            guard let self else {return};if action == .log,let path = paths.first {self.onFileLog(path)} else {self.onAction(action,paths)}
        }
        commands.onChanged = { [weak self] in self?.onChanged() }
        observer = commands.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async { [weak self] in
                guard let self,!self.retired,!self.commands.busy,!self.busy else {return}
                if self.closeAfterRead {self.closeAfterRead = false;self.close();return}
                if self.refreshRequested {self.refreshRequested = false;self.reload()}
            }
        }
    }
    func setScope(_ paths:[String]) {
        guard !retired,!confirmingQuit,!commands.busy,!hasChild,!exclusiveAction,!closeAfterRead,window?.attachedSheet == nil else {return}
        pendingDrops = [];self.paths = paths.isEmpty ? ["."]:paths;hasLoaded = false;checked = [];highlighted = [];reload()
    }
    func didRename(_ old:String,to new:String) {
        guard !retired else {return}
        func moved(_ path:String)->String {path == old ? new:path.hasPrefix(old + "/") ? new + path.dropFirst(old.count):path}
        paths = paths.map(moved);checked = Set(checked.map(moved));highlighted = Set(highlighted.map(moved))
        if busy && !exclusiveAction {reload()} else {requestReload()}
    }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) {throw RepositoryAccessFailure.securityScopeUnavailable}
    }
    func resumePendingRefresh() {if refreshRequested && canInteract {reload()}}
    func requestReload() {
        guard !retired else {return}
        if busy || commands.busy || confirmingQuit || hasChild || window?.attachedSheet != nil {refreshRequested = true;return}
        reload()
    }
    func reload(forceChecked:Set<String> = []) {start(forceChecked:forceChecked,drops:pendingDrops)}
    private func start(forceChecked:Set<String>,drops:[URL]) {
        guard !retired,!confirmingQuit,!hasChild,!exclusiveAction,!closeAfterRead else {return}
        if commands.busy {refreshRequested = true;queuedForce.formUnion(forceChecked);return}
        let position = fileListRefresh.begin(preferences:preferences,reset:!hasLoaded,selectedIDs:highlighted)
        refreshRequested = false;request?.cancel();let token = OperationCancellation(),identity = UUID(),scope = paths
        request = token;generation = identity;busy = true;cancelling = false;error = nil
        let forced = queuedForce.union(forceChecked);queuedForce = [];Self.activeOperations += 1
        Task { [self] in
            defer {
                Self.activeOperations -= 1;fileListRefresh.finish(position);withExtendedLifetime(access) {}
                if request === token {
                    request = nil;busy = false;cancelling = false
                    if closeAfterRead {closeAfterRead = false;if !retired {close()}} else {resumePendingRefresh()}
                }
            }
            do {
                try validateAccess();var nextScope = scope,dropPaths = Set<String>()
                if !drops.isEmpty {try await Task.sleep(nanoseconds:200_000_000);try token.check()}
                for url in drops {try token.check();try await validateDrop(url,token)}
                if !drops.isEmpty {
                    let added = FinderRequest(action:.revert,paths:drops).relativePaths(root:repository.root)
                    if !nextScope.contains(".") {nextScope = Array(Set(nextScope + added)).sorted()}
                    dropPaths = Set(added)
                }
                let invocation = try await repository.workingTreeInvocation(paths:nextScope,cancellation:token)
                let files = try await readStatus(token);try token.check()
                let direct = Set(nextScope.filter {path in path != "." && (try? FileManager.default.attributesOfItem(atPath:repository.root.appendingPathComponent(path).path)[.type]) as? FileAttributeType != .typeDirectory})
                let status = files.filter{$0.state != .normal || direct.contains($0.id)}.map(\.entry)
                let selection = RevertDialogSelection(status:status,paths:nextScope,directFiles:direct)
                let ids = Set(selection.entries.map(\.path)),selectedFiles = files.filter{ids.contains($0.id)}
                let stats = GitPathMap(try await readStatistics(token).map{($0.path,$0)},uniquingKeysWith:{_,last in last})
                let metadata = await repository.statusListMetadata(paths:selection.entries.map(\.path));try token.check()
                let modules = try await repository.submodulePaths(cancellation:token),rebase = try await repository.conflictIsRebase(cancellation:token)
                let hasHead = try await repository.run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1,cancellation:token).exitCode == 0
                let hasLFS = try await repository.hasLFS(cancellation:token)
                guard !retired,request === token,generation == identity,!token.isCancelled else {return}
                let oldPaths = Set(entries.map(\.path));paths = nextScope;pendingDrops = []
                entries = selection.entries;statistics = stats;hasUnversionedItems = selection.hasUnversionedItems
                let location = invocation.titlePath(wholeProject:false);updateTitle(location.isEmpty ? repository.root:repository.root.appendingPathComponent(location))
                if !hasLoaded {checked = selection.initiallyChecked;hasLoaded = true}
                else {checked.formIntersection(ids);checked.formUnion(selection.initiallyChecked.subtracting(oldPaths))}
                checked.formUnion(forced.union(dropPaths).intersection(ids));highlighted.formIntersection(ids)
                commands.installEmbeddedFiles(selectedFiles,statistics:stats,metadata:metadata,submodules:modules,hasHead:hasHead,rebase:rebase,hasLFS:hasLFS)
                if !position.remember {highlighted = []}
                await fileListRefresh.restore(position,ids:rows.map(\.id));try token.check()
            } catch {if !retired,request === token,!token.isCancelled {pendingDrops = [];self.error = error.localizedDescription}}
        }
    }
    @discardableResult func cancel(closeAfter:Bool = false)->Bool {
        if let request {closeAfterRead = closeAfterRead || closeAfter;request.cancel();fileListRefresh.cancel();cancelling = true;return true}
        if commands.cancelOperation() {closeAfterRead = closeAfterRead || closeAfter;return true};return false
    }
    func invalidate() {guard !retired else {return};retired = true;fileListRefresh.retire();generation = UUID();request?.cancel();refreshRequested = false;commands.invalidate()}
    func apply() {
        guard canApply else {return};onAccepted(entries.filter{checked.contains($0.path)});close()
    }
    func diff(_ ids:Set<String>) {
        guard canInteract,!ids.isEmpty else {return}
        let snapshot = commands.fileMenu(ids)
        guard !snapshot.entries.isEmpty else {return}
        if let onCompare {onCompare(snapshot.entries.map(\.path))} else {commands.unifiedDiff(ids,alternate:ComparisonToolInvocation.capture)}
    }
    @discardableResult func addDropped(_ urls:[URL])->Bool {
        guard !retired,!commands.busy,!confirmingQuit,!hasChild,!exclusiveAction,!closeAfterRead,window?.attachedSheet == nil,!urls.isEmpty else {return false}
        let values = FinderRequest(action:.revert,paths:urls).paths
        guard values.count > 0,values.allSatisfy({$0.isFileURL && RepositoryAccessLease.pathIsContained($0,by:repository.root)}) else {return false}
        var seen = Set<String>();pendingDrops = (pendingDrops + values).filter{seen.insert($0.path).inserted}
        start(forceChecked:[],drops:pendingDrops);return true
    }
    func requestRevert(_ snapshot:StatusFileMenuSnapshot) {
        guard canInteract,snapshot.offersRevert else {return}
        var valid = false;commands.withFileMenu(snapshot){valid = true};guard valid else {return}
        let rows = snapshot.entries,token = OperationCancellation(),identity = generation
        request = token;busy = true;exclusiveAction = true;Self.activeOperations += 1
        Task { [self] in
            defer {Self.activeOperations -= 1;exclusiveAction = false;if request === token {request = nil;busy = false;cancelling = false;if closeAfterRead {closeAfterRead = false;if !retired {close()}} else {resumePendingRefresh()}}}
            let needsQuestion = rows.contains{entry in commands.files.contains{$0.id == entry.path && $0.state == .modified} && commands.fileMetadata[entry.path]?.isDirectory != true && !commands.submodules.contains(entry.path)}
            let accepted = needsQuestion ? await confirmRevert(rows):true
            guard accepted,!retired,request === token,!token.isCancelled,generation == identity,rows.allSatisfy({entries.contains($0)}) else {return}
            request = nil;busy = false;exclusiveAction = false;onRevert(rows)
        }
    }
    struct PreparedMenu {
        fileprivate let file:StatusFileMenuSnapshot
        fileprivate let generation:UUID
        let marked:PreparedFileComparisonMark?
    }
    func preparedMenu(_ snapshot:StatusFileMenuSnapshot)->PreparedMenu {
        PreparedMenu(file:snapshot,generation:comparisonGeneration,marked:comparisonMark)
    }
    // These commands use the source selection mark, independently of the highlighted set.
    func canPrepareFile(_ snapshot:StatusFileMenuSnapshot)->Bool {
        !snapshot.entries.isEmpty && !snapshot.markIsDirectory && snapshot.mark.map{$0.index != "D"} == true
    }
    func canMarkForComparison(_ snapshot:StatusFileMenuSnapshot)->Bool {
        guard !snapshot.entries.isEmpty,let mark = snapshot.mark,mark.index != "D" else {return false}
        return !snapshot.markIsDirectory || commands.submodules.contains(mark.path)
    }
    func importWorkingComparisonMark(_ access:WorkingComparisonAccess?) {
        guard !retired,let access,access.mark.id != lastImportedWorkingMark else {return}
        lastImportedWorkingMark = access.mark.id;comparisonGeneration = UUID()
        comparisonMark = PreparedFileComparisonMark(path:access.file.path,revision:"",workingAccess:access)
    }
    func markForComparison(_ snapshot:StatusFileMenuSnapshot) {
        guard canInteract,canMarkForComparison(snapshot),let path = snapshot.mark?.path else {return}
        commands.withFileMenu(snapshot) {
            comparisonGeneration = UUID();comparisonMark = PreparedFileComparisonMark(path:path,revision:"",isDirectory:snapshot.markIsDirectory)
        }
    }
    func compareWithMarkedFile(_ menu:PreparedMenu) {
        guard canInteract,canMarkForComparison(menu.file),comparisonGeneration == menu.generation,
              let marked = menu.marked,let current = menu.file.mark,let onPreparedFileCompare else {return}
        commands.withFileMenu(menu.file) {onPreparedFileCompare(marked,PreparedFileComparisonMark(path:current.path,revision:"",isDirectory:menu.file.markIsDirectory))}
    }
    func captureColumnCopy(_ ids:[String],column:StatusListColumn)->(() -> Void)? {
        guard canInteract else {return nil};let snapshot = commands.fileMenu(Set(ids))
        guard !snapshot.entries.isEmpty else {return nil}
        let value = commands.clipboardText(Set(ids),copy:.column(column))
        return { [weak self] in
            guard let self,self.canInteract else {return}
            self.commands.withFileMenu(snapshot) {self.commands.clipboard.clearContents();self.commands.clipboard.setString(value,forType:.string)}
        }
    }
    func saveAs(_ snapshot:StatusFileMenuSnapshot) {
        guard canInteract,canPrepareFile(snapshot),let path = snapshot.mark?.path else {return}
        var valid = false;commands.withFileMenu(snapshot){valid = true};guard valid else {return}
        let token = OperationCancellation();request = token;busy = true;exclusiveAction = true;Self.activeOperations += 1
        Task { [self] in
            defer {
                Self.activeOperations -= 1;withExtendedLifetime(access) {}
                if request === token {request = nil;exclusiveAction = false;busy = false;cancelling = false
                    if closeAfterRead {closeAfterRead = false;if !retired {close()}} else {resumePendingRefresh()}
                }
            }
            do {
                try validateAccess()
                guard let target = await chooseSaveFile(path),!retired,request === token,!token.isCancelled else {return}
                // Busy input fences preserve this captured mark through destination selection.
                let scoped = target.startAccessingSecurityScopedResource();defer {if scoped {target.stopAccessingSecurityScopedResource()}}
                try await saveWorkingFile(path,target,token)
            } catch {if !retired,request === token,!token.isCancelled {self.error = error.localizedDescription}}
        }
    }
    func setChecked(_ ids:Set<String>,value:Bool) {guard canInteract else {return};if value {checked.formUnion(ids.intersection(Set(entries.map(\.path))))} else {checked.subtract(ids)}}
    @discardableResult func saveColumns(order:[StatusListColumn],widths:[StatusListColumn:Double])->Bool {
        guard canInteract else {return false};fileColumns = .init(visible:fileColumns.visible,order:order,widths:widths);persistColumns();return true
    }
    func setColumn(_ column:StatusListColumn,visible:Bool) {
        guard canInteract,column != .path,availableColumns.contains(column) else {return}
        if visible {fileColumns.visible.insert(column)} else {fileColumns.visible.remove(column)};persistColumns()
    }
    private func persistColumns() {fileColumns.save(to:preferences,key:Self.columnKey);commands.fileColumns = fileColumns}
    func resetColumns(choose:@escaping () async -> Bool,accepted:@escaping ()->Void) {
        guard canInteract else {return};let token = OperationCancellation();request = token;busy = true;exclusiveAction = true;Self.activeOperations += 1
        Task { [self] in
            defer {Self.activeOperations -= 1;exclusiveAction = false;if request === token {request = nil;busy = false;cancelling = false;if closeAfterRead {closeAfterRead = false;if !retired {close()}} else {resumePendingRefresh()}}}
            guard await choose(),!retired,request === token,!token.isCancelled else {return}
            fileColumns = Self.defaultColumns;persistColumns();accepted()
        }
    }
}

private struct RevertDialog:View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model:RevertWindowModel
    @State private var focusedPath:String?
    private func fileCommand(_ command:StatusFileCommand,snapshot:StatusFileMenuSnapshot)->some View {
        Button {model.commands.fileAction(command,snapshot:snapshot,permanently:NSEvent.modifierFlags.contains(.shift))} label:{CommandLabel(title:command.rawValue,icon:command.icon)}
    }
    var body:some View {
        let rows = model.rows,byID = Dictionary(uniqueKeysWithValues:rows.map{($0.id,$0)})
        VStack(spacing:10) {
            Table(rows,selection:$model.highlighted,sortOrder:$model.sortOrder) {
                TableColumn("") {row in Toggle("Revert \(row.path)",isOn:Binding(get:{model.checked.contains(row.path)},set:{model.setChecked([row.path],value:$0)})).labelsHidden().toggleStyle(.checkbox)}.width(24)
                TableColumn("Path",sortUsing:StatusFileSort(column:.path)) {row in HStack {Image(nsImage:row.file.state.icon.image() ?? NSImage()).resizable().frame(width:16,height:16);Text(row.path).foregroundStyle(model.highlighted.contains(row.path) ? Color.primary:row.file.state.textColor)}.repositoryFileHelp(repository:model.repository.root,path:row.path,detail:row.file.entry.originalPath.map{"Renamed from " + $0} ?? "",preferences:model.preferences)}.width(min:250,ideal:390)
                TableColumn("Filename",sortUsing:StatusFileSort(column:.fileName)) {row in Text(row.fileName)}.width(min:70,ideal:120)
                TableColumn("Extension",sortUsing:StatusFileSort(column:.fileExtension)) {row in Text(row.fileExtension)}.width(min:45,ideal:70)
                TableColumn("Status",sortUsing:StatusFileSort(column:.status)) {row in Text(row.status)}.width(min:90,ideal:110)
                TableColumn("Lines added",sortUsing:StatusFileSort(column:.added)) {row in Text(row.addedText)}.width(min:65,ideal:80)
                TableColumn("Lines removed",sortUsing:StatusFileSort(column:.removed)) {row in Text(row.removedText)}.width(min:75,ideal:95)
                TableColumn("Modification date",sortUsing:StatusFileSort(column:.lastModified)) {row in Text(row.metadata?.dateText ?? "–")}.width(min:100,ideal:150)
                TableColumn("File size",sortUsing:StatusFileSort(column:.fileSize)) {row in Text(row.sizeText)}.width(min:70,ideal:100)
            }.fileListFont().disabled(!model.canInteract)
            .background(CommitFileInteraction(rows:rows.map{.file($0.file.entry)},nativeColumns:StatusListColumn.allCases.filter{$0 != .lfsOwner},captureColumnCopy:{model.captureColumnCopy($0,column:$1)},configureRefresh:{model.fileListRefresh.attach($0)},watermarkIcon:.revertBackdrop,preferences:model.preferences,
                visibleColumns:Set(model.fileColumns.order.filter{model.fileColumns.visible.contains($0)}),availableColumns:model.availableColumns,
                columnText:{entry,column in byID[entry.path].map{model.commands.columnText($0,column)} ?? ""},savedOrder:model.fileColumns.order,savedWidths:model.fileColumns.widths,
                saveLayout:{model.saveColumns(order:$0,widths:$1)},setColumnVisible:{model.setColumn($0,visible:$1)},resetColumns:{model.resetColumns(choose:$0,accepted:$1)},focusedPath:$focusedPath,
                enabled:model.canInteract,delete:{entries,mark,permanent in guard mark.canDeleteWithKeyboard else {return};model.commands.fileAction(.delete,snapshot:model.commands.fileMenu(Set(entries.map(\.path)),mark:mark.path),permanently:permanent)},
                copy:{entries,status in model.commands.copy(Set(entries.map(\.path)),information:status ? .pathsAndStatus:.relativePaths)},copyColumn:{entries,column in model.commands.copy(Set(entries.map(\.path)),information:.column(column))},
                toggleCheck:{entries,mark in model.setChecked(Set(entries.map(\.path)),value:!model.checked.contains(mark.path))}))
            .contextMenu(forSelectionType:String.self) {ids in
                let snapshot = model.commands.fileMenu(ids,mark:focusedPath)
                let prepared = model.preparedMenu(snapshot)
                TurtleGitContextMenu {
                    if !snapshot.entries.isEmpty {
                        if snapshot.offersResolve {ResolveSelectionMenu(paths:snapshot.entries.map(\.path),rebase:model.commands.conflictRebase,canEdit:snapshot.entries.count == 1,action:{action,paths in model.commands.withFileMenu(snapshot){model.onAction(action,paths)}});Divider()}
                        if snapshot.offersCompare {Button {model.commands.withFileMenu(snapshot){model.diff(ids)}} label:{CommandLabel(title:"Compare with base",icon:.compare)}}
                        if model.commands.hasHead {Button {model.commands.withFileMenu(snapshot){model.commands.unifiedDiff(ids,alternate:ComparisonToolInvocation.capture)}} label:{CommandLabel(title:"Show changes as unified diff",icon:.unifiedDiff)}}
                        Group {
                            Button {model.commands.withFileMenu(snapshot){model.setChecked(ids,value:true)}} label:{CommandLabel(title:"Check selected files",icon:.add)}
                            Button {model.commands.withFileMenu(snapshot){model.setChecked(ids,value:false)}} label:{CommandLabel(title:"Uncheck selected files",icon:.revert)}
                        }
                        if snapshot.offersRevert {Button {model.requestRevert(snapshot)} label:{CommandLabel(title:"Revert…",icon:.revert)}}
                        if let mark = model.commands.files.first(where:{$0.id == snapshot.mark?.path}) {IndexFlagsMenu(files:model.commands.files.filter{ids.contains($0.id)},selectionMark:mark){action in model.commands.withFileMenu(snapshot){model.commands.setFlags(action,files:model.commands.files.filter{ids.contains($0.id)},selectionMark:mark)}}}
                        Group {
                            if snapshot.offersIgnore {IgnoreSelectionMenu(paths:snapshot.entries.map(\.path),action:{action,paths in model.commands.withFileMenu(snapshot){model.onAction(action,paths)}})}
                            if snapshot.entries.count == 1,let entry = snapshot.entries.first,entry.state != .deleted,entry.worktree != "D" {Button {model.commands.withFileMenu(snapshot){model.onAction(.rename,[entry.path])}} label:{CommandLabel(title:"Rename…",icon:.rename)}}
                            if snapshot.entries.allSatisfy({![FileState.deleted,.untracked,.ignored].contains($0.state)}) {Button {model.commands.withFileMenu(snapshot){model.onAction(.move,snapshot.entries.map(\.path))}} label:{CommandLabel(title:"Move…",icon:.rename)}}
                            ForEach(model.commands.lfsActions(model.commands.files.filter{ids.contains($0.id)}),id:\.self) {action in Button {model.commands.withFileMenu(snapshot){model.commands.setLFSLocked(ids,locked:action == .lock)}} label:{CommandLabel(title:action.rawValue,icon:action == .lock ? .lock:.unlock)}}
                        }
                        ForEach(snapshot.commands.filter{![StatusFileCommand.editor,.open,.openWith,.reveal,.delete].contains($0)},id:\.self) {command in fileCommand(command,snapshot:snapshot)}
                        if model.canPrepareFile(snapshot) {Button {model.saveAs(snapshot)} label:{CommandLabel(title:"Save As…",icon:.saveAs)}}
                        ForEach(snapshot.commands.filter{[StatusFileCommand.editor,.open,.openWith,.reveal].contains($0)},id:\.self) {command in fileCommand(command,snapshot:snapshot)}
                        if model.canMarkForComparison(snapshot) {
                            Button {model.markForComparison(snapshot)} label:{CommandLabel(title:"Mark for comparison",icon:.compare)}
                            if let mark = prepared.marked {
                                Button {model.compareWithMarkedFile(prepared)} label:{CommandLabel(title:"Compare with " + mark.label(for:snapshot.mark?.path ?? ""),icon:.compare,localized:false)}.disabled(model.onPreparedFileCompare == nil)
                            }
                        }
                        if snapshot.commands.contains(.delete) {fileCommand(.delete,snapshot:snapshot)}
                        Menu {
                            Button {model.commands.withFileMenu(snapshot){model.commands.copy(ids,information:.fullPaths)}} label:{CommandLabel(title:"Full paths",icon:.copy)}
                            Button {model.commands.withFileMenu(snapshot){model.commands.copy(ids)}} label:{CommandLabel(title:"Relative paths",icon:.copy)}
                            Button {model.commands.withFileMenu(snapshot){model.commands.copy(ids,information:.names)}} label:{CommandLabel(title:"File/folder names",icon:.copy)}
                            Button {model.commands.withFileMenu(snapshot){model.commands.copy(ids,information:.all)}} label:{CommandLabel(title:"Copy all information to clipboard",icon:.copy)}
                        } label:{CommandLabel(title:"Copy to Clipboard",icon:.copy)}
                    }
                }.disabled(!model.canInteract)
            } primaryAction:{model.diff($0)}
            HStack {
                SelectionAllCheckbox(checked:model.checked.count,total:model.entries.count,checkedCount:{model.checked.count}) {model.setChecked(Set(model.entries.map(\.path)),value:$0)}.frame(width:190,height:22).disabled(!model.canInteract)
                Spacer()
                if model.hasUnversionedItems && (model.preferences.object(forKey:"UnversionedAsModified") as? NSNumber)?.boolValue == true {Text("Note: the folder contains unversioned items").font(.caption).foregroundStyle(.secondary)}
            }
            HStack {
                if model.busy || model.commands.busy {ProgressView().controlSize(.small);Text(model.cancelling ? "Cancelling…":model.commands.currentOperation).font(.caption)}
                if model.entries.isEmpty && !model.busy {Text("No files or folders were modified.").foregroundStyle(.secondary)}
                Spacer()
                Button("OK"){model.apply()}.keyboardShortcut(.defaultAction).disabled(!model.canApply)
                Button("Cancel"){if !model.cancel(closeAfter:true){model.close()}}.keyboardShortcut(.cancelAction).disabled(model.cancelling || model.hasChild)
                Button("Help"){TurtleGitHelp.show(.revert)}
            }
        }.padding(12).dropDestination(for:URL.self){urls,_ in model.addDropped(urls)}
        .alert("Revert",isPresented:Binding(get:{model.error != nil || model.commands.error != nil},set:{if !$0 {model.error = nil;model.commands.error = nil}})) {Button("OK"){model.error = nil;model.commands.error = nil}} message:{Text(model.error ?? model.commands.error ?? "")}
    }
}
private enum RevertDropFailure:LocalizedError {
    case outsideRepository
    var errorDescription:String? {"Only paths from this repository can be dropped here."}
}
