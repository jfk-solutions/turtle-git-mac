// SPDX-License-Identifier: GPL-2.0-or-later
// Adapts ChangedDlg/GitStatusListCtrl; Copyright (C) 2008-2026 TortoiseGit; 2003-2008, 2013-2015 TortoiseSVN.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

/// Both spellings remain selectable; clarify visually identical source names.
func changelistNameHelp(_ name: GitReferenceName, names: [GitReferenceName]) -> String {
    guard names.contains(where: { $0 != name && $0.rawValue == name.rawValue }) else { return name.rawValue }
    return name.rawValue + "\nUTF-8: " + name.rawValue.utf8.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func changelistGroupHelp(_ group: StatusListGroup, lists: GitChangelists) -> String {
    if case .changelist(let name) = group { return changelistNameHelp(GitReferenceName(name), names: lists.nameIdentities) }
    return FileListLabels.groupTitle(group)
}

struct StatusRow: Identifiable {
    let file: WorkingTreeFile
    let statistics: CommitFile?
    var id: String { file.id }
    var path: String { file.id }
    var fileExtension: String { StatusListClipboard.fileExtension(path, isDirectory: statistics?.isSubmodule == true || metadata?.isDirectory == true) }
    var status: String { file.status + (file.entry.staged ? " (staged)" : "") }
    var added: Int? { statistics?.added }
    var removed: Int? { statistics?.removed }
    var sortAdded: Int { added ?? -1 }
    var sortRemoved: Int { removed ?? -1 }
    var addedText: String { added.map { String($0) } ?? "–" }
    var removedText: String { removed.map { String($0) } ?? "–" }
    var modificationDate: Date? { file.modificationDate }
    var sortDate: Date { modificationDate ?? .distantPast }
    var lfsOwner = ""
    var metadata: StatusListMetadata? = nil
    var fileName: String { (path as NSString).lastPathComponent }
    var sizeText: String { metadata?.sizeText ?? "–" }
}

struct StatusGroupedRow: Identifiable {
    let row: StatusListRow
    let contents: StatusRow?
    var id: String { GitPathRowIdentity.encode(row.id) }
}
struct StatusGroupedSort: SortComparator {
    var column: StatusListColumn
    var order: SortOrder = .forward
    func compare(_ lhs: StatusGroupedRow, _ rhs: StatusGroupedRow) -> ComparisonResult {
        if let a = lhs.contents, let b = rhs.contents { return StatusFileSort(column: column, order: order).compare(a, b) }
        return lhs.id.compare(rhs.id)
    }
}

enum StatusFileCommand: String, CaseIterable {
    case compareTwo = "Compare two files", log = "Show log", submoduleLog = "Show submodule log", oldNameLog = "Show log of old name", blame = "Blame"
    case export = "Export…", editor = "View revision in alternative editor", open = "Open", openWith = "Open With…", reveal = "Reveal in Finder", delete = "Delete"
    var icon: MenuIcon {
        switch self {
        case .compareTwo: return .compare
        case .log, .oldNameLog, .submoduleLog: return .log
        case .blame: return .blame
        case .export: return .export
        case .editor: return .editor
        case .open, .openWith: return .open
        case .reveal: return .explore
        case .delete: return .remove
        }
    }
}
struct StatusFileMenuSnapshot {
    let generation: UUID
    let entries: [StatusEntry]
    let mark: StatusEntry?
    let commands: [StatusFileCommand]
    var markIsDirectory = false
    // GitStatusListCtrl gates these commands by the selection mark, then
    // dispatches to the complete captured selection, including mixed states.
    var offersAdd: Bool { !entries.isEmpty && mark.map { [FileState.untracked, .ignored].contains($0.state) } == true }
    var offersCompare: Bool { !entries.isEmpty && mark?.canCompareWithBaseFromStatusList == true }
    var offersRevert: Bool { !entries.isEmpty && mark.map { ![FileState.untracked, .ignored].contains($0.state) } == true }
    var offersResolve: Bool { !entries.isEmpty && mark?.state == .conflicted }
    var offersIgnore: Bool { !entries.isEmpty && mark.map { [FileState.untracked, .deleted].contains($0.state) } == true }
    func addModes(extended: Bool) -> [WorkingFileAddMode] {
        guard offersAdd else { return [] }
        return extended && !markIsDirectory ? [.normal, .executable, .symlink] : [.normal]
    }
}
struct StatusFileActionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class StatusNativeWindow: NSWindow {
    var refresh: () -> Void = {}, cancel: () -> Void = {}
    var commandKeyWindow: () -> NSWindow? = {NSApp.keyWindow}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.window === self,commandKeyWindow() === self,attachedSheet == nil else {return super.performKeyEquivalent(with:event)}
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.type == .keyDown,event.keyCode == 96,flags.isEmpty {refresh();return true}
        if event.type == .keyDown,event.keyCode == 53,flags.isEmpty {cancel();return true}
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class StatusWindowController: NSWindowController, NSWindowDelegate {
    let model: StatusWindowModel
    var onClosed: () -> Void = {}
    var commandKeyWindow: () -> NSWindow? = {NSApp.keyWindow}
    var onPullAfterLFSLock: () -> Void = {}
    private var lfsOperation: LFSFileOperationController?
    private var closingStatus = false
    var makeLFSOperation: (GitRepository, RepositoryAccessLease?) -> LFSFileOperationController = { LFSFileOperationController(repository: $0, access: $1) }
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        makeLFSOperation = { LFSFileOperationController(repository: $0, access: $1, defaults: defaults) }
        model = StatusWindowModel(repository: repository, access: access, defaults: defaults)
        let window = StatusNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 630),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Working Tree", preferences: defaults)
        window.minSize = NSSize(width: 960, height: 540); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StatusDialog(model: model).defaultAppStorage(defaults))
        super.init(window: window); model.comparisonWindow = window; window.delegate = self
        model.updateTitle = { [weak window] location in RepositoryWindowTitles.set(window, repository: repository.root, location: location, dialog: "Working Tree", preferences: defaults) }
        window.refresh = { [weak model] in model?.reload() }
        window.cancel = { [weak model] in guard let model else {return};if !model.cancelOperation() {model.close()} }
        window.commandKeyWindow = { [weak self] in self?.commandKeyWindow() }
        window.setContentSize(NSSize(width: 1100, height: 630)); window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.savePatch = { [weak self] text in self?.savePatch(text) }
        model.onLFSOperation = { [weak self, weak window] paths, locked in
            guard let self, !self.closingStatus, let window, window.attachedSheet == nil, self.lfsOperation == nil else { return false }
            let progress = self.makeLFSOperation(repository, access)
            progress.model.onProgressLog = { [weak self] path in self?.model.onAction(.log, [path]) }
            progress.model.onPullAfterLock = { [weak self] in guard let self, !self.closingStatus else { return }; self.onPullAfterLFSLock() }
            progress.onClosed = { [weak self, weak progress] in
                guard let self, !self.closingStatus, self.lfsOperation === progress else { return }
                self.lfsOperation = nil; self.model.busy = false; self.model.reload(); self.model.onChanged()
            }
            self.lfsOperation = progress
            guard progress.present(owner: window, paths: paths, locked: locked) else { self.lfsOperation = nil; return false }
            return true
        }


        model.chooseChangelistName = { [weak window] in
            guard let window, window.attachedSheet == nil else { return nil }
            let alert = NSAlert(); alert.messageText = "Create changelist"; alert.informativeText = "Enter a name for the new changelist:"
            let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); name.setAccessibilityLabel("Changelist name")
            alert.accessoryView = name; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
            return await withCheckedContinuation { reply in
                alert.beginSheetModal(for: window) { reply.resume(returning: $0 == .alertFirstButtonReturn && !name.stringValue.isEmpty ? name.stringValue : nil) }
                alert.window.makeFirstResponder(name)
            }
        }
        model.chooseApplication = { [weak window] in
            guard let window, window.attachedSheet == nil else { return nil }
            let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"
            panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            return await withCheckedContinuation { reply in panel.beginSheetModal(for: window) { reply.resume(returning: $0 == .OK ? panel.url : nil) } }
        }
        model.chooseExportFolder = { [weak window] in
            guard let window, window.attachedSheet == nil else { return nil }
            let panel = NSOpenPanel(); panel.title = "Export working files"; panel.prompt = "Export"
            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
            return await withCheckedContinuation { reply in panel.beginSheetModal(for: window) { reply.resume(returning: $0 == .OK ? panel.url : nil) } }
        }
        model.confirmDeletion = { [weak window] paths, permanently in
            guard let window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = permanently ? "Permanently delete the selected paths?" : "Move the selected paths to Trash?"
            alert.informativeText = "\(paths.count) selected item(s). Their index entries will also be removed." + (permanently ? " This cannot be undone." : " Files moved to Trash can be recovered in Finder.")
            alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
            return await withCheckedContinuation { reply in alert.beginSheetModal(for: window) { reply.resume(returning: $0 == .alertSecondButtonReturn) } }
        }

        DialogGeometry.attach(window, identifier: "StatusWindowController")
    }
    private func savePatch(_ bytes: Data) {
        guard let window, !model.retired, window.attachedSheet == nil else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "working-tree.patch"
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak model] response in
            guard response == .OK, let model, !model.retired, let url = panel.url else { return }
            do { try bytes.write(to: url, options: .atomic) }
            catch { model.error = error.localizedDescription }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.cancelOperation() { return false }
        return !model.busy && !model.confirmingQuit && !model.unifiedViewerBusy && sender.attachedSheet == nil
    }
    func windowWillClose(_ notification: Notification) {
        guard !closingStatus else { return }; closingStatus = true
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        model.invalidate(); lfsOperation?.close(); lfsOperation = nil
        model.unifiedWindow?.close(); onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class StatusWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    let fileListRefresh = FileListRefreshCoordinator()
    private(set) var retired = false
    private var operationCancellation: OperationCancellation?
    private var refreshRequested = false
    private var pendingScope: [String]?
    private var resetPositionOnReload = true
    @Published private(set) var invocation = WorkingTreeInvocation()
    @Published private(set) var hasStash = false
    var updateTitle: (URL) -> Void = { _ in }
    @Published private(set) var currentOperation = ""
    @Published private(set) var cancelling = false
    var readStatus: (OperationCancellation) async throws -> [WorkingTreeFile]
    var embeddedReload: (() -> Void)?
    var actionOwnerAvailable: () -> Bool = {true}
    var groupsEnabled = true
    var showsStagedStatus = true
    var clipboard = NSPasteboard.general
    func installEmbeddedFiles(_ rows:[WorkingTreeFile],statistics:GitPathMap<CommitFile>,metadata:GitPathMap<StatusListMetadata>,submodules: some Sequence<String>,hasHead:Bool,rebase:Bool,hasLFS:Bool) { let submodules = GitPathSet(submodules);
        guard !retired,!busy else {return};menuGeneration = UUID()
        files = rows;self.statistics = statistics;fileMetadata = metadata;self.submodules = submodules
        self.hasHead = hasHead;conflictRebase = rebase;self.hasLFS = hasLFS
        selection.formIntersection(GitPathSet(rows.map(\.id)))
    }
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var changelists = GitChangelists()
    @Published private(set) var keepChangelists = false
    var chooseChangelistName: () async -> String? = { nil }
    @Published var conflictRebase = false
    @Published var submodules = GitPathSet()
    @Published var hasLFS = false
    @Published var fileColumns: StatusListColumnSettings
    @Published var fileMetadata: GitPathMap<StatusListMetadata> = [:]
    var showLFSOwners: Bool { fileColumns.visible.contains(.lfsOwner) }
    private let columnKey: String
    private let initialColumns: StatusListColumnSettings
    static var defaultColumns: StatusListColumnSettings { StatusListColumnSettings(visible: Set(StatusListColumn.defaultColumns + [.lastModified])) }
    var visibleColumns: [StatusListColumn] { fileColumns.order.filter { fileColumns.visible.contains($0) && ($0 != .lfsOwner || hasLFS) } }
    var availableColumns: Set<StatusListColumn> { Set(StatusListColumn.allCases.filter { $0 != .lfsOwner || hasLFS }) }
    @Published var lfsOwners: [String: String] = [:]
    @Published var lfsLockedPaths = GitPathSet()
    @Published var lfsOwnershipKnown = false
    private let defaults: UserDefaults
    var colorPreferences: UserDefaults { defaults }
    private var ownerCancellation: OperationCancellation?
    var queryLFSOwners: (OperationCancellation) async throws -> [LFSLock]
    var ownersVisible: Bool { hasLFS && showLFSOwners }
    var onLFSOperation: ([String], Bool) -> Bool = { _, _ in false }
    @Published var files: [WorkingTreeFile] = []
    @Published var statistics: GitPathMap<CommitFile> = [:]
    private var menuGeneration = UUID()
    func invalidateFileMenus() {menuGeneration = UUID()}
    private var selectedPaths = GitPathSet()
    @Published var nativeFileSelection = Set<String>() {
        didSet {
            guard nativeFileSelection != oldValue else {return}
            selectedPaths = GitPathRowIdentity.paths(nativeFileSelection)
            menuGeneration = UUID()
        }
    }
    var selection: GitPathSet {
        get {selectedPaths}
        set {
            let ids = Set(newValue.map(GitPathRowIdentity.encode))
            if nativeFileSelection != ids {nativeFileSelection = ids}
        }
    }

    @Published var sortOrder = [StatusFileSort(column: .path)]
    @Published var filter = WorkingTreeFilter()
    @Published var branch = ""
    @Published private(set) var hasHead = false
    @Published var busy = false
    @Published var confirmingQuit = false { didSet { if oldValue && !confirmingQuit && refreshRequested && !busy && !retired { reload() } } }
    @Published var error: String?
    var onUnifiedDiff: ((Data, Bool) async throws -> Void)?
    weak var comparisonWindow: NSWindow?
    var unifiedWindow: PatchWindowController?
    var unifiedViewerBusy: Bool { unifiedWindow?.model.busy == true || unifiedWindow?.window?.attachedSheet != nil }
    var close: () -> Void = {}
    var savePatch: (Data) -> Void = { _ in }
    lazy var submoduleLog = SubmoduleWorkingLogSession(repository: repository, access: access)
    var onSubmoduleLog: (GitRepository) -> Void = { _ in }
    var onBlame: (String) -> Void = { _ in }
    var onCompareTwoFiles: ([String]) -> Void = { _ in }
    var onAddFiles: ([String], WorkingFileAddMode) -> Void = { _, _ in }
    var confirmFlags: (IndexFlagAction) -> Bool = confirmIndexFlags
    var chooseApplication: () async -> URL? = { nil }
    var chooseExportFolder: () async -> URL? = { nil }
    var confirmDeletion: ([String], Bool) async -> Bool = { _, _ in false }
    var openWorkingFile: (URL, URL?) async throws -> Void = { url, application in
        if let application {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { reply.resume(throwing: error) } else { reply.resume() }
                }
            }
        } else if !NSWorkspace.shared.open(url) { throw StatusFileActionFailure(message: "Could not open " + url.lastPathComponent + ".") }
    }
    lazy var openAlternativeEditor: (URL) async throws -> Void = { [weak self] url in
        guard let self else { throw OperationCancellationFailure.cancelled }
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            AlternativeEditor.open(url, preferences: self.defaults, permissions: self.access.map { [$0] } ?? []) { error in
                if let error { reply.resume(throwing: StatusFileActionFailure(message: error)) } else { reply.resume() }
            }
        }
    }
    var onTransferDrop: ([NSItemProvider]) -> Bool = { _ in false }
    var onCopyAdd: ([String]) -> Void = { _ in }
    var onPasteFiles: (Bool, [URL]) -> Void = { _, _ in }
    var onAction: (RepositoryAction, [String]) -> Void = { _, _ in }
    var onChanged: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard, columnKey: String = "WorkingTree.FileColumns", initialColumns: StatusListColumnSettings? = nil) {
        self.repository = repository; self.access = access; self.defaults = defaults
        self.columnKey = columnKey; self.initialColumns = initialColumns ?? Self.defaultColumns
        readStatus = { try await repository.workingTreeStatus(cancellation: $0) }
        if defaults.integer(forKey: columnKey + ".Version") == 1 {
            fileColumns = .load(from: defaults, key: columnKey)
        } else {
            var columns = self.initialColumns
            if initialColumns == nil && defaults.bool(forKey: "WorkingTree.LFSOwnerVisible") { columns.visible.insert(.lfsOwner) }
            fileColumns = columns
        }
        queryLFSOwners = { try await repository.lfsLocks(cancellation: $0) }
        keepChangelists = defaults.bool(forKey: "Commit.KeepChangelists")
        filter.showUnversioned = defaults.object(forKey: "AddBeforeCommit") == nil || defaults.bool(forKey: "AddBeforeCommit")
        filter.showAllStaged = defaults.object(forKey: "ChangedFilesIncludeStaged") == nil || defaults.bool(forKey: "ChangedFilesIncludeStaged")
    }
    func setSortOrder(_ order: [StatusFileSort]) {
        guard !retired, !busy, !confirmingQuit else { return }
        sortOrder = Array(order.prefix(1))
    }
    func setShowLFSOwners(_ visible: Bool) {
        guard !retired, hasLFS, !busy, !confirmingQuit else { return }
        if visible { fileColumns.visible.insert(.lfsOwner) } else { fileColumns.visible.remove(.lfsOwner) }
        fileColumns.save(to: defaults, key: columnKey)
        if visible { reload() } else { lfsOwners = [:]; lfsLockedPaths = []; lfsOwnershipKnown = false }
    }
    func setColumn(_ column: StatusListColumn, visible: Bool) {
        guard column != .path, availableColumns.contains(column), !busy, !confirmingQuit else { return }
        if column == .lfsOwner { setShowLFSOwners(visible); return }
        if visible { fileColumns.visible.insert(column) } else { fileColumns.visible.remove(column) }
        fileColumns.save(to: defaults, key: columnKey)
    }
    @discardableResult func saveColumnLayout(order: [StatusListColumn], widths: [StatusListColumn: Double]) -> Bool {
        guard !retired, !busy, !confirmingQuit else { return false }
        let next = StatusListColumnSettings(visible: fileColumns.visible, order: order, widths: widths)
        if fileColumns != next { fileColumns = next; fileColumns.save(to: defaults, key: columnKey) }
        return true
    }
    func requestResetColumns(choose: @escaping () async -> Bool, onAccepted: @escaping () -> Void) {
        runOperation("Reset columns…", operation: { [self] token in
            guard await choose(), isLive(token), !confirmingQuit else { return }
            fileColumns = initialColumns; fileColumns.save(to: defaults, key: columnKey)
            lfsOwners = [:]; lfsLockedPaths = []; lfsOwnershipKnown = false
            onAccepted()
        })
    }
    @discardableResult func cancelLFSOwnerQuery() -> Bool {
        guard let ownerCancellation else { return false }
        ownerCancellation.cancel(); return true
    }

    var visibleFiles: [WorkingTreeFile] { files.filter { filter.includes($0) } }
    private var ungroupedSortedRows: [StatusRow] { visibleFiles.map { StatusRow(file: $0, statistics: statistics[$0.id], lfsOwner: lfsOwners[$0.id] ?? "", metadata: fileMetadata[$0.id]) }.sorted(using: sortOrder) }
    var tableRows: [StatusGroupedRow] {
        let rows = ungroupedSortedRows, lookup = GitPathMap(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let flagged = GitPathSet(rows.filter { $0.file.assumeUnchanged || $0.file.skipWorktree }.map(\.id))
        return StatusListGroups.rows(entries: rows.map { $0.file.entry }, changelists: changelists, locallyIgnored: flagged).map {
            StatusGroupedRow(row: $0, contents: $0.entry.flatMap { lookup[$0.path] })
        }
    }
    var sortedRows: [StatusRow] { groupsEnabled ? tableRows.compactMap(\.contents):ungroupedSortedRows }
    var summary:String {StatusFooterStatistics(files:files,statistics:statistics,filter:filter).text}
    var nativeSummary: String {
        let rows = visibleFiles
        return FileListLabels.counts("{shown} files shown, {staged} staged, {modified} modified, {unversioned} unversioned",values:["shown":rows.count,"staged":rows.filter {$0.entry.staged}.count,"modified":rows.filter {$0.state == .modified}.count,"unversioned":rows.filter {$0.state == .untracked}.count])
    }
    var folderFiltersEnabled: Bool { invocation.singleDirectory }
    var stashActions: [RepositoryAction] { hasStash ? [.stash, .stashPop, .stashApply, .stashList] : [.stash] }
    func stashMenuSnapshot()->StatusStashMenuSnapshot? {
        guard !retired,!busy,!confirmingQuit,actionOwnerAvailable() else {return nil}
        return StatusStashMenuSnapshot(owner:ObjectIdentifier(self),generation:menuGeneration,actions:stashActions)
    }
    func performStashAction(_ action:RepositoryAction,snapshot:StatusStashMenuSnapshot) {
        guard snapshot.owner==ObjectIdentifier(self),snapshot.generation==menuGeneration,snapshot.actions.contains(action),stashActions.contains(action),stashMenuSnapshot() != nil else {return}
        performDialogAction(action)
    }

    private func updateScopeTitle() {
        let path = invocation.titlePath(wholeProject: filter.wholeProject)
        let location = path.isEmpty ? repository.root : repository.root.appendingPathComponent(path)
        updateTitle(location)
    }
    /// Related dialogs may finish while a status operation is still settling.
    /// Coalesce their refresh requests instead of losing the new repository state.
    func requestReload() {
        guard !retired else { return }
        if busy || confirmingQuit { refreshRequested = true; return }
        reload()
    }
    func performDialogAction(_ action: RepositoryAction) {
        guard !retired, !busy, !confirmingQuit else { return }
        if [.stash, .stashPop, .stashApply, .stashList].contains(action) {
            guard stashActions.contains(action) else { return }
            var available = false
            runOperation("Checking stash…", operation: { [self] token in
                let exists = try await repository.workingTreeHasStash(cancellation: token)
                guard isLive(token) else { return }
                hasStash = exists; available = action == .stash || exists
            }, completed: { [self] in if available { onAction(action, []) } })
        } else if action == .commit { onAction(action, commitPaths()) }
        else if action == .switchBranch { onAction(action, []) }
    }
    private var wholeProjectKey: String { "WorkingTree.ShowWholeProject." + repository.root.path }
    func setScope(_ paths: [String]) {
        guard !retired else { return }
        let normalized = paths.contains(".") ? [] : paths
        if busy || confirmingQuit { pendingScope = normalized; refreshRequested = true; return }
        applyScope(normalized); reload()
    }
    private func applyScope(_ paths: [String]) {
        resetPositionOnReload = true
        filter.paths = paths
        filter.wholeProject = paths.isEmpty || defaults.bool(forKey: wholeProjectKey)
        selection = []
    }
    func setFilter(_ value: WorkingTreeFilter) {
        guard !retired, !busy, !confirmingQuit else { return }
        let position = fileListRefresh.begin(preferences:defaults,selectedIDs:selection)
        menuGeneration = UUID(); filter = value
        defaults.set(value.showUnversioned, forKey: "AddBeforeCommit")
        defaults.set(value.showAllStaged, forKey: "ChangedFilesIncludeStaged")
        if !value.paths.isEmpty { defaults.set(value.wholeProject, forKey: wholeProjectKey) }
        selection.formIntersection(GitPathSet(visibleFiles.map(\.id)));if !position.remember {selection = []};updateScopeTitle()
        Task { [self] in await fileListRefresh.restore(position,ids:tableRows.map { $0.row.id });fileListRefresh.finish(position) }
    }
    @discardableResult func cancelOperation() -> Bool {
        guard let token = operationCancellation else { return cancelLFSOwnerQuery() }
        cancelling = true; token.cancel();fileListRefresh.cancel(); ownerCancellation?.cancel(); submoduleLog.cancel(); return true
    }
    func invalidate() {
        guard !retired else { return }; retired = true;fileListRefresh.retire(); refreshRequested = false; pendingScope = nil
        operationCancellation?.cancel(); ownerCancellation?.cancel(); submoduleLog.retire()
        unifiedWindow?.close(); unifiedWindow = nil
    }
    private func isLive(_ token: OperationCancellation) -> Bool {
        !retired && operationCancellation === token && !token.isCancelled
    }
    private func runOperation(_ title: String, reportCancellation:Bool = true, operation: @escaping (OperationCancellation) async throws -> Void, completed: @escaping () -> Void = {}, failed: @escaping () -> Void = {}) {
        guard !retired, !busy, !confirmingQuit,actionOwnerAvailable() else { return }
        let token = OperationCancellation(); operationCancellation = token
        busy = true; cancelling = false; currentOperation = title; Self.activeOperations += 1
        Task {
            defer {
                Self.activeOperations -= 1
                if operationCancellation === token { operationCancellation = nil; busy = false; cancelling = false; currentOperation = "" }
                withExtendedLifetime(access) {}
                if refreshRequested && !retired && !busy && !confirmingQuit { refreshRequested = false; reload() }
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await operation(token)
                guard isLive(token) else { return }
                operationCancellation = nil; busy = false; cancelling = false; currentOperation = ""; completed()
            } catch {
                guard !retired else { return }
                let diagnostic = token.isCancelled ? "Operation cancelled. Any completed changes are retained; refresh to inspect the working tree." : error.localizedDescription
                operationCancellation = nil; busy = false; cancelling = false; currentOperation = ""; failed()
                if !token.isCancelled || reportCancellation {self.error = diagnostic}
            }
        }
    }
    func reload() {
        guard !retired, !busy, !confirmingQuit else { return }
        if let embeddedReload {embeddedReload();return}
        menuGeneration = UUID(); refreshRequested = false
        let resetPosition = resetPositionOnReload || pendingScope != nil
        if let pendingScope { self.pendingScope = nil; applyScope(pendingScope) }
        let position = fileListRefresh.begin(preferences:defaults,reset:resetPosition,selectedIDs:selection)
        let scopePaths = filter.paths
        runOperation("Refreshing working tree…",reportCancellation:false,operation: { [self] token in
            defer {fileListRefresh.finish(position)}
            // Publish one complete snapshot. A failed/cancelled read retains the prior table.
            let nextInvocation = try await repository.workingTreeInvocation(paths: scopePaths, cancellation: token)
            let nextStash = try await repository.workingTreeHasStash(cancellation: token)
            let nextFiles = try await readStatus(token)
            let nextChangelists = try await repository.changelists(cancellation: token)
            let nextBranch = try await repository.branch(cancellation: token)
            let nextHasHead = try await repository.run(["rev-parse", "--verify", "--quiet", "HEAD"], successfulExitCodes:0...1, cancellation:token).exitCode == 0
            let nextRebase = try await repository.conflictIsRebase(cancellation: token)
            let nextSubmodules = try await repository.submodulePathNames(cancellation: token).map(\.rawValue)
            let nextLFS = try await repository.hasLFS(cancellation: token)
            let nextMetadata = await repository.statusListMetadata(paths: nextFiles.map(\.id))
            let nextStatistics = try await repository.workingTreeFiles(cancellation: token)
            let nextLocks:[LFSLock]
            if nextLFS && showLFSOwners {nextLocks = try await queryLFSOwners(token)} else {nextLocks = []}
            guard isLive(token) else { return }
            resetPositionOnReload = false
            invocation = nextInvocation; hasStash = nextStash; hasHead = nextHasHead; updateScopeTitle()
            changelists = nextChangelists; files = nextFiles; branch = nextBranch; conflictRebase = nextRebase; submodules = GitPathSet(nextSubmodules)
            hasLFS = nextLFS; fileMetadata = nextMetadata
            statistics = GitPathMap(nextStatistics.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
            selection.formIntersection(GitPathSet(visibleFiles.map(\.id)))
            lfsOwners = [:]; lfsLockedPaths = []; lfsOwnershipKnown = false
            if ownersVisible {
                lfsOwners = Dictionary(nextLocks.map {($0.path,$0.owner)},uniquingKeysWith:{first,_ in first})
                lfsLockedPaths = GitPathSet(nextLocks.map(\.path));lfsOwnershipKnown = true
            }
            if !position.remember {selection = []}
            await fileListRefresh.restore(position,ids:tableRows.map { $0.row.id });try token.check()
        })
    }
    func canLockLFS(_ selected: [WorkingTreeFile]) -> Bool {
        LFSLockingSelection.isAvailable(selected.map(\.entry), hasLFS: hasLFS, root: repository.root, directories: submodules)
    }
    func lfsActions(_ selected: [WorkingTreeFile]) -> [LFSLockMenuAction] {
        guard canLockLFS(selected) else { return [] }
        return LFSLockMenu.actions(paths: selected.map(\.id), ownersVisible: ownersVisible, lockedPaths: lfsLockedPaths, ownershipKnown: lfsOwnershipKnown)
    }
    func setLFSLocked(_ ids: some Sequence<String>, locked: Bool) { let ids = GitPathSet(ids);
        guard !retired, !busy, !confirmingQuit,actionOwnerAvailable() else { return }
        let selected = sortedRows.map(\.file).filter { ids.contains($0.id) }
        guard selected.count == ids.count, lfsActions(selected).contains(locked ? .lock : .unlock) else { return }
        busy = true
        if !onLFSOperation(selected.map(\.id), locked) { busy = false }
    }
    func stage(_ ids: some Sequence<String>, staged: Bool) { let ids = GitPathSet(ids);
        let paths = sortedRows.map(\.file).filter { ids.contains($0.id) && $0.state != .conflicted }.map(\.id)
        guard !paths.isEmpty else { return }
        runOperation(staged ? "Staging files…" : "Unstaging files…", operation: { [self] token in
            if staged { try await repository.stage(paths, cancellation: token) }
            else { try await repository.unstage(paths, cancellation: token) }
        }, completed: { [self] in reload(); onChanged() })
    }
    func setFlags(_ action: IndexFlagAction, files: [WorkingTreeFile], selectionMark: WorkingTreeFile? = nil) {
        guard !retired, !busy, !confirmingQuit, actionOwnerAvailable(), !files.isEmpty, action.isAvailable(for: selectionMark.map { [$0] } ?? files), confirmFlags(action), !retired else { return }
        runOperation("Updating index flags…", operation: { [self] token in
            try await repository.setIndexFlags(action, paths: files.map(\.id), markedPath: selectionMark?.id, cancellation: token)
        }, completed: { [self] in reload(); onChanged() }, failed: { [self] in reload(); onChanged() })
    }
    func diff(_ ids: some Sequence<String>, saving: Bool = false) { let ids = GitPathSet(ids);
        guard !retired, !busy, !confirmingQuit else { return }
        if !saving {
            let paths = sortedRows.filter { ids.contains($0.id) }.map(\.id)
            guard !paths.isEmpty else { return }; onAction(.diff, paths); return
        }
        let paths = filter.wholeProject ? [] : filter.paths
        runOperation("Preparing unified diff…", operation: { [self] token in
            let bytes = try await repository.workingTreeDiffData(paths: paths, cancellation: token)
            guard isLive(token) else { return }; savePatch(bytes)
        })
    }
    func scopeUnifiedDiff(alternate: Bool) {
        presentUnifiedDiff(paths: invocation.comparisonPaths(wholeProject: filter.wholeProject), alternate: alternate)
    }
    func unifiedDiff(_ ids: some Sequence<String>, alternate: Bool) { let ids = GitPathSet(ids);
        let paths = sortedRows.filter { ids.contains($0.id) }.map(\.id)
        guard !paths.isEmpty else { return }
        presentUnifiedDiff(paths: paths, alternate: alternate)
    }
    private func presentUnifiedDiff(paths: [String], alternate: Bool) {
        guard !unifiedViewerBusy else { return }
        let owner = comparisonWindow
        runOperation("Preparing unified diff…", operation: { [self] token in
            let session = FileListComparisonSession(window: owner, preferences: defaults, cancellation: token)
            try await session.run(selectedCount: 0) { [self] token in
                let bytes = try await repository.workingTreeDiffData(paths: paths, cancellation: token)
                guard isLive(token) else { return }
                if let onUnifiedDiff { try await onUnifiedDiff(bytes, alternate) }
                else if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: defaults, title: "HEAD → Working tree", permissions: access.map { [$0] } ?? [], cancellation: token) {
                    guard isLive(token) else { return }
                    unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: "HEAD → Working tree", onClosed: { [weak self] in self?.unifiedWindow = nil })
            }
            }
        })
    }
    func fileMenu(_ ids: some Sequence<String>, mark: String? = nil) -> StatusFileMenuSnapshot { let ids = GitPathSet(ids);
        let rows = sortedRows.filter { ids.contains($0.id) }, entries = rows.map { $0.file.entry }
        let focused = files.first { GitReferenceName.equal($0.id,mark) }?.entry ?? entries.first
        func directory(_ row: StatusRow) -> Bool { submodules.contains(row.id) || row.metadata?.isDirectory == true }
        var commands: [StatusFileCommand] = []
        if rows.count == 2 && rows.allSatisfy({ !directory($0) }) { commands.append(.compareTwo) }
        if let row = rows.first, rows.count == 1 {
            let entry = row.file.entry
            if ![FileState.untracked, .ignored].contains(entry.state) {
                commands.append(.log)
                if directory(row) { commands.append(.submoduleLog) }
                if entry.originalPath != nil { commands.append(.oldNameLog) }
                if !directory(row), entry.index != "A", entry.worktree != "A", entry.index != "D" { commands.append(.blame) }
            }
        }
        if !rows.isEmpty, let focused, focused.state != .deleted,
           focused.worktree != "D" { commands.append(.export) }
        if let row = rows.first, rows.count == 1, row.file.state != .deleted, row.file.entry.worktree != "D" {
            if !directory(row) { commands += [.editor, .open, .openWith] }
        }
        if let row = rows.first, rows.count == 1, row.file.entry.index != "D" { commands.append(.reveal) }
        if focused?.canDeleteFromStatusList == true { commands.append(.delete) }
        return StatusFileMenuSnapshot(generation: menuGeneration, entries: entries, mark: focused, commands: commands, markIsDirectory: focused.map { submodules.contains($0.path) || fileMetadata[$0.path]?.isDirectory == true } ?? false)
    }
    func canCommit(_ snapshot: StatusFileMenuSnapshot) -> Bool {
        guard !snapshot.entries.isEmpty, let mark = snapshot.mark else { return false }
        if snapshot.offersAdd { return true }
        guard let file = files.first(where: { GitReferenceName.equal($0.id,mark.path) }) else { return false }
        return !file.assumeUnchanged && !file.skipWorktree
    }
    func commitSelection(_ snapshot: StatusFileMenuSnapshot) {
        guard accepts(snapshot), canCommit(snapshot) else { return }
        onAction(.commit, snapshot.entries.map(\.path))
    }
    func addSelection(_ snapshot: StatusFileMenuSnapshot, mode: WorkingFileAddMode) {
        guard accepts(snapshot), snapshot.addModes(extended:true).contains(mode) else { return }
        onAddFiles(snapshot.entries.map(\.path), mode)
    }
    private func accepts(_ snapshot: StatusFileMenuSnapshot, duringOperation: Bool = false) -> Bool {
        guard !retired, !confirmingQuit, actionOwnerAvailable(), (duringOperation || !busy), snapshot.generation == menuGeneration,
              !snapshot.entries.isEmpty else { return false }
        let current = GitPathMap(files.map { ($0.id, $0.entry) }, uniquingKeysWith: { _, last in last })
        return snapshot.entries.allSatisfy { current[$0.path] == $0 } && (snapshot.mark.map { current[$0.path] == $0 } ?? true)
    }
    func withFileMenu(_ snapshot: StatusFileMenuSnapshot, perform: () -> Void) {
        guard accepts(snapshot) else { return }; perform()
    }
    func fileAction(_ command: StatusFileCommand, snapshot: StatusFileMenuSnapshot, permanently: Bool = false) {
        guard accepts(snapshot), snapshot.commands.contains(command) else { return }
        let paths = snapshot.entries.map(\.path)
        switch command {
        case .compareTwo: onCompareTwoFiles(paths)
        case .log: onAction(.log, paths)
        case .submoduleLog:
            runOperation("Reading submodule checkout…", operation: { [self] token in
                let child = try await submoduleLog.load(paths[0], cancellation: token)
                guard isLive(token), accepts(snapshot, duringOperation: true) else { return }; onSubmoduleLog(child)
            })
        case .oldNameLog: if let old = snapshot.entries.first?.originalPath { onAction(.log, [old]) }
        case .blame: onBlame(paths[0])
        case .reveal:
            var location = repository.root.appendingPathComponent(paths[0])
            while !FileManager.default.fileExists(atPath: location.path), location.path != repository.root.path { location.deleteLastPathComponent() }
            NSWorkspace.shared.activateFileViewerSelecting([location])
        case .export:
            runOperation("Exporting working files…", operation: { [self] token in
                guard let folder = await chooseExportFolder(), isLive(token), accepts(snapshot, duringOperation: true) else { return }
                let scoped = folder.startAccessingSecurityScopedResource(); defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                _ = try await repository.exportWorkingFiles(paths: paths, to: folder, cancellation: token)
            })
        case .delete:
            var changed = false
            runOperation(permanently ? "Deleting working files…" : "Moving working files to Trash…", operation: { [self] token in
                guard await confirmDeletion(paths, permanently), isLive(token), accepts(snapshot, duringOperation: true) else { return }
                _ = try await repository.deleteWorkingFiles(snapshot.entries, selectionMark: snapshot.mark, permanently: permanently, cancellation: token)
                changed = true
                guard isLive(token) else { return }; selection.subtract(paths)
            }, completed: { [self] in if changed { reload(); onChanged() } }, failed: { [self] in reload(); onChanged() })
        case .editor, .open, .openWith:
            runOperation(command.rawValue, operation: { [self] token in
                let application = command == .openWith ? await chooseApplication() : nil
                guard command != .openWith || application != nil, isLive(token), accepts(snapshot, duringOperation: true) else { return }
                let url = repository.root.appendingPathComponent(paths[0])
                if command == .editor { try await openAlternativeEditor(url) }
                else { try await openWorkingFile(url, application) }
            })
        }
    }
    func canAssignChangelist(_ snapshot: StatusFileMenuSnapshot) -> Bool {
        // Pinned source compares wcStatus with enum values 0/1, excluding a pure
        // Added action, rather than masking all unversioned rows.
        guard let mark = snapshot.mark else { return false }
        return !snapshot.entries.isEmpty && !(mark.index == "A" && mark.worktree == " ")
    }
    func setKeepChangelists(_ value: Bool, snapshot: StatusFileMenuSnapshot) {
        guard accepts(snapshot), canAssignChangelist(snapshot) else { return }
        keepChangelists = value; defaults.set(value, forKey: "Commit.KeepChangelists")
    }
    func assignChangelist(_ snapshot: StatusFileMenuSnapshot, name: String?, creating: Bool = false) {
        guard accepts(snapshot), canAssignChangelist(snapshot) else { return }
        runOperation(creating ? "New changelist…" : "Moving to changelist…", operation: { [self] token in
            let chosen: String?
            if creating { guard let value = await chooseChangelistName(), !value.isEmpty else { return }; chosen = value }
            else { chosen = name }
            guard isLive(token), accepts(snapshot, duringOperation: true) else { return }
            let next = try await repository.assignChangelist(paths: snapshot.entries.map(\.path), name: chosen, cancellation: token)
            guard isLive(token) else { return }; changelists = next; menuGeneration = UUID()
        })
    }
    func groupMenu(_ group: StatusListGroup) -> StatusFileMenuSnapshot {
        fileMenu(GitPathSet(StatusListGroups.files(in: group, rows: tableRows.map(\.row)).map(\.path)))
    }
    func selectGroup(_ group: StatusListGroup, snapshot: StatusFileMenuSnapshot? = nil) {
        let captured = snapshot ?? groupMenu(group)
        guard accepts(captured) else { return }
        selection = GitPathSet(captured.entries.map(\.path))
    }
    func commitPaths() -> [String] { invocation.commitPaths(wholeProject: filter.wholeProject) }
    func didRename(_ source: String, to destination: String) {
        func moved(_ path: String) -> String { GitReferenceName.equal(path,source) ? destination : path.utf8.starts(with:(source + "/").utf8) ? destination + path.dropFirst(source.count) : path }
        selection = GitPathSet(selection.map(moved)); filter.paths = filter.paths.map(moved); reload()
    }
    func reveal(_ ids: some Sequence<String>) { let ids = GitPathSet(ids); guard !retired, !busy, !confirmingQuit else { return }; NSWorkspace.shared.activateFileViewerSelecting(files.filter { ids.contains($0.id) }.map { repository.root.appendingPathComponent($0.id) }) }
    func columnText(_ row: StatusRow, _ column: StatusListColumn) -> String {
        switch column {
        case .path: return StatusListClipboard.displayedPath(row.file.entry)
        case .fileName: return row.fileName
        case .fileExtension: return row.fileExtension
        case .status: return FileListLabels.caption(showsStagedStatus ? row.status : row.file.status)
        case .added: return row.addedText
        case .removed: return row.removedText
        case .lastModified: return row.metadata?.dateText ?? "–"
        case .fileSize: return row.sizeText
        case .lfsOwner: return row.lfsOwner
        }
    }
    func clipboardText(_ ids: some Sequence<String>, copy: StatusListCopy) -> String { let ids = GitPathSet(ids);
        let rows = sortedRows.filter { ids.contains($0.id) }
        guard !rows.isEmpty else { return "" }
        let columns: [StatusListColumn]
        switch copy {
        case .all: columns = visibleColumns
        case .column(let column): columns = [column]
        case .pathsAndStatus: columns = [.path,.status]
        default: columns = []
        }
        let heading = StatusListClipboard.heading(copy: copy, columns: columns, label:FileListLabels.caption)
        return heading + rows.map { row in
            switch copy {
            case .fullPaths: return repository.root.appendingPathComponent(row.path).path
            case .relativePaths: return row.path
            case .names: return row.fileName
            case .pathsAndStatus: return [row.path,FileListLabels.caption(row.status)].joined(separator: "\t")
            default: return columns.map { columnText(row,$0) }.joined(separator: "\t")
            }
        }.joined(separator: "\n") + "\n"
    }
    func copy(_ ids: some Sequence<String>, information: StatusListCopy = .relativePaths) { let ids = GitPathSet(ids);
        guard !retired, !busy, !confirmingQuit,actionOwnerAvailable() else { return }
        let text = clipboardText(ids, copy: information)
        guard !text.isEmpty else { return }
        clipboard.clearContents(); clipboard.setString(text, forType: .string)
    }
}

/// Native adaptation of ChangedDlg::UpdateStatistics and status-list action flags.
struct StatusFooterStatistics {
    var addedLines=0,removedLines=0,unversioned=0,modified=0,added=0,deleted=0,conflicted=0
    init(files:[WorkingTreeFile],statistics:GitPathMap<CommitFile>,filter:WorkingTreeFilter) {
        var acquired=filter;acquired.showUnmodified=true
        for file in files where acquired.includes(file) {
            let counts=statistics[file.id];addedLines += counts?.added ?? 0;removedLines += counts?.removed ?? 0
            if [.untracked,.ignored].contains(file.state) {unversioned += 1;continue}
            let codes=Set([file.entry.index,file.entry.worktree])
            if !codes.isDisjoint(with:Set("AC")) {added += 1}
            if codes.contains("D") {deleted += 1}
            if !codes.isDisjoint(with:Set("MRT")) {modified += 1}
            if file.state == .conflicted {conflicted += 1}
        }
    }
    var text:String {
        // Pinned BuildStatistics resets normal but never increments it. The
        // hidden Show unmodified control is not exposed as a new native option.
        FileListLabels.counts("line: {added_lines}(+) {removed_lines}(-) files: normal=0, unversioned={unversioned}, modified={modified}, added={added}, deleted={deleted}, conflicted={conflicted}",values:["added_lines":addedLines,"removed_lines":removedLines,"unversioned":unversioned,"modified":modified,"added":added,"deleted":deleted,"conflicted":conflicted])
    }
}
struct StatusStatisticsField:NSViewRepresentable {
    @ObservedObject var model:StatusWindowModel
    func makeNSView(context:Context)->NSTextField {
        let field=NSTextField(wrappingLabelWithString:"");field.isEditable=false;field.isSelectable=true;field.isBezeled=false;field.drawsBackground=false
        field.font = .systemFont(ofSize:NSFont.smallSystemFontSize);field.lineBreakMode = .byWordWrapping;field.maximumNumberOfLines=0
        field.setAccessibilityLabel(NSLocalizedString("Working Tree statistics",comment:""));return field
    }
    func updateNSView(_ field:NSTextField,context:Context) {
        if field.stringValue != model.summary {if field.currentEditor() != nil {field.window?.makeFirstResponder(nil)};field.stringValue=model.summary}
        field.toolTip=model.nativeSummary;field.preferredMaxLayoutWidth=440
    }
    static func dismantleNSView(_ field:NSTextField,coordinator:()) {field.isSelectable=false}
}
struct StatusStashMenuSnapshot {
    let owner:ObjectIdentifier,generation:UUID
    let actions:[RepositoryAction]
}
struct StatusStashMenu:NSViewRepresentable {
    @ObservedObject var model:StatusWindowModel
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator()->Coordinator {Coordinator(model:model)}
    func makeNSView(context:Context)->NSPopUpButton {
        let button=NSPopUpButton(frame:.zero,pullsDown:true);button.bezelStyle = .rounded;button.addItem(withTitle:"Stash");button.menu?.autoenablesItems=false;button.menu?.delegate=context.coordinator
        button.setAccessibilityLabel("Stash");context.coordinator.button=button;return button
    }
    func updateNSView(_ button:NSPopUpButton,context:Context) {context.coordinator.model=model;button.isEnabled=enabled && model.stashMenuSnapshot() != nil}
    static func dismantleNSView(_ button:NSPopUpButton,coordinator:Coordinator) {coordinator.retired=true;button.menu?.delegate=nil;button.menu?.items.forEach {$0.target=nil}}
    @MainActor final class Coordinator:NSObject,NSMenuDelegate {
        var model:StatusWindowModel
        weak var button:NSPopUpButton?
        var retired=false
        init(model:StatusWindowModel) {self.model=model}
        final class Invocation:NSObject {let snapshot:StatusStashMenuSnapshot,action:RepositoryAction;var used=false;init(_ snapshot:StatusStashMenuSnapshot,_ action:RepositoryAction) {self.snapshot=snapshot;self.action=action}}
        func menuNeedsUpdate(_ menu:NSMenu) {
            menu.removeAllItems();let title=NSMenuItem(title:"Stash",action:nil,keyEquivalent:"");title.isHidden=true;menu.addItem(title)
            guard !retired,button?.window != nil,button?.window?.attachedSheet==nil,let snapshot=model.stashMenuSnapshot() else {return}
            for action in snapshot.actions {
                let name:String,icon:MenuIcon
                switch action {case .stash:name="Stash save…";icon = .stash;case .stashPop:name="Stash pop";icon = .stashPop;case .stashApply:name="Stash apply";icon = .stashPop;default:name="Stash list";icon = .log}
                let item=NSMenuItem(title:name,action:#selector(invoke(_:)),keyEquivalent:"");item.target=self;item.image=icon.contextImage(defaults:model.colorPreferences);item.representedObject=Invocation(snapshot,action);menu.addItem(item)
            }
        }
        @objc func invoke(_ item:NSMenuItem) {
            guard !retired,button?.window != nil,button?.window?.attachedSheet==nil,let invocation=item.representedObject as? Invocation,!invocation.used else {return}
            invocation.used=true;model.performStashAction(invocation.action,snapshot:invocation.snapshot)
        }
    }
}

struct StatusDialog: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: StatusWindowModel
    @State private var focusedIdentity: GitReferenceName?
    private var focusedPath: String? { focusedIdentity?.rawValue }
    private var focusBinding: Binding<String?> {
        Binding(get:{ focusedIdentity?.rawValue },set:{ focusedIdentity = $0.map { GitReferenceName($0) } })
    }
    var body: some View {
        let rows = model.sortedRows
        let rowsByID = GitPathMap(uniqueKeysWithValues: rows.map { ($0.id,$0) })
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.branch.isEmpty ? "Unborn / detached HEAD" : model.branch) { model.performDialogAction(.switchBranch) }.buttonStyle(.link)
                Spacer(); if model.busy { Text(model.currentOperation).font(.caption); ProgressView().controlSize(.small) }
            }
            Table(model.tableRows, selection: $model.nativeFileSelection, sortOrder: Binding(get: { model.sortOrder.map { StatusGroupedSort(column: $0.column, order: $0.order) } }, set: { model.setSortOrder($0.map { StatusFileSort(column: $0.column, order: $0.order) }) })) {
                TableColumn("Path", sortUsing: StatusGroupedSort(column: .path)) { item in
                    if let row = item.contents {
                        HStack(spacing: 6) { if let icon = row.file.state.icon.image() { Image(nsImage: icon) }; Text(StatusListClipboard.displayedPath(row.file.entry)).foregroundStyle(row.file.entry.statusTextColor(selected: model.selection.contains(row.id), preferences: model.colorPreferences)).lineLimit(1) }
                            .repositoryFileHelp(repository: model.repository.root, path: row.path, detail: row.file.entry.originalPath.map { "Renamed from " + $0 } ?? "", preferences: model.colorPreferences)
                    } else if let group = item.row.group { Text(verbatim:FileListLabels.groupTitle(group)).font(.headline).foregroundStyle(Color.accentColor).help(changelistGroupHelp(group, lists: model.changelists)).accessibilityLabel(changelistGroupHelp(group, lists: model.changelists)) }
                }.width(min: 250, ideal: 380)
                TableColumn("Filename", sortUsing: StatusGroupedSort(column: .fileName)) { item in groupCell(item, column: .fileName) }.width(min: 100, ideal: 180)
                TableColumn("Extension", sortUsing: StatusGroupedSort(column: .fileExtension)) { item in groupCell(item, column: .fileExtension) }.width(min: 45, ideal: 65)
                TableColumn("Status", sortUsing: StatusGroupedSort(column: .status)) { item in groupCell(item, column: .status) }.width(min: 110, ideal: 155)
                TableColumn("Lines added", sortUsing: StatusGroupedSort(column: .added)) { item in groupCell(item, column: .added) }.width(min: 60, ideal: 80)
                TableColumn("Lines removed", sortUsing: StatusGroupedSort(column: .removed)) { item in groupCell(item, column: .removed) }.width(min: 60, ideal: 90)
                TableColumn("Last modified", sortUsing: StatusGroupedSort(column: .lastModified)) { item in groupCell(item, column: .lastModified) }.width(min: 150, ideal: 170)
                TableColumn("File size", sortUsing: StatusGroupedSort(column: .fileSize)) { item in groupCell(item, column: .fileSize) }.width(min: 70, ideal: 100)
                TableColumn("LFS Lock", sortUsing: StatusGroupedSort(column: .lfsOwner)) { item in groupCell(item, column: .lfsOwner) }.width(min: 100, ideal: 160)
            }.fileListFont()
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                guard !model.busy, !model.confirmingQuit, !model.retired else { return false }; return model.onTransferDrop(providers)
            }
            .background(CommitFileInteraction(rows: model.tableRows.map(\.row), leadingColumnCount: 0, keyboardDeleteEnabled: true,configureRefresh:{model.fileListRefresh.attach($0)},preferences:model.colorPreferences,
                visibleColumns: Set(model.visibleColumns), availableColumns: model.availableColumns, columnText: { entry, column in
                    rowsByID[entry.path].map { model.columnText($0,column) } ?? ""
                }, savedOrder: model.fileColumns.order, savedWidths: model.fileColumns.widths,
                saveLayout: { model.saveColumnLayout(order: $0, widths: $1) }, setColumnVisible: { model.setColumn($0, visible: $1) },
                resetColumns: { choose, accepted in model.requestResetColumns(choose: choose, onAccepted: accepted) }, focusedPath: focusBinding,
                enabled: !model.busy && !model.confirmingQuit && !model.retired, delete: { entries, mark, permanently in
                    guard mark.canDeleteWithKeyboard else { return }
                    model.fileAction(.delete, snapshot: model.fileMenu(GitPathSet(entries.map(\.path)), mark: mark.path), permanently: permanently)
                },
                copy: { entries, status in model.copy(GitPathSet(entries.map(\.path)), information: status ? .pathsAndStatus : .relativePaths) },
                copyColumn: { entries, column in model.copy(GitPathSet(entries.map(\.path)), information: .column(column)) }, toggleCheck: { _,_ in }))
            .contextMenu(forSelectionType: String.self) { nativeIDs in
                let ids = GitPathRowIdentity.paths(nativeIDs)
                let snapshot = model.fileMenu(ids, mark: focusedPath)
                TurtleGitContextMenu {
                    if ids.count == 1, let group = model.tableRows.first(where: { ids.contains($0.row.id) })?.row.group {
                        let groupedSelection = model.groupMenu(group)
                        Button("Select group") { model.selectGroup(group, snapshot: groupedSelection) }.disabled(model.busy || model.confirmingQuit)
                    }
                    if !snapshot.entries.isEmpty {
                    if snapshot.offersResolve {
                        ResolveSelectionMenu(paths: snapshot.entries.map(\.path), rebase: model.conflictRebase, canEdit: snapshot.entries.count == 1, action: { action, paths in model.withFileMenu(snapshot) { model.onAction(action, paths) } })
                        Divider()
                    }
                    ForEach(snapshot.addModes(extended:NSEvent.modifierFlags.contains(.shift)), id: \.self) { mode in
                        Button { model.addSelection(snapshot, mode:mode) } label: { CommandLabel(title:mode.rawValue, icon:.add) }
                    }
                    if snapshot.offersCompare {
                        Button { model.withFileMenu(snapshot) { model.diff(ids) } } label: { CommandLabel(title: "Compare with base", icon: .compare) }
                        if model.hasHead {
                            Button { model.withFileMenu(snapshot) { model.unifiedDiff(ids, alternate: NSEvent.modifierFlags.contains(.shift)) } } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }
                        }
                    }
                    if model.canCommit(snapshot) {
                        Button { model.commitSelection(snapshot) } label: { CommandLabel(title:"Commit…", icon:.commit) }
                    }
                    if !snapshot.offersAdd {
                        Button { model.withFileMenu(snapshot) { model.stage(ids, staged:true) } } label: { CommandLabel(title:"Stage", icon:.add) }
                    }
                    if snapshot.entries.contains(where: \.staged) {
                        Button { model.withFileMenu(snapshot) { model.stage(ids, staged:false) } } label: { CommandLabel(title:"Unstage", icon:.revert) }
                    }
                    if ids.count == 1, let path = ids.first, let row = model.files.first(where: { GitReferenceName.equal($0.id,path) }), ![FileState.untracked, .ignored, .deleted].contains(row.state) {
                        Button { model.withFileMenu(snapshot) { model.onAction(.rename, [path]) } } label: { CommandLabel(title: "Rename…", icon: .rename) }
                    }
                    let selected = model.files.filter { ids.contains($0.id) }
                    if !selected.isEmpty, selected.allSatisfy({ $0.state != .deleted }) {
                        Button { model.withFileMenu(snapshot) { FileTransferClipboard.copy(selected.map { model.repository.root.appendingPathComponent($0.id) }) } } label: { CommandLabel(title: "Copy files", icon: .copy) }
                        Button { model.withFileMenu(snapshot) { model.onCopyAdd(selected.map(\.id)) } } label: { CommandLabel(title: "Copy and Add…", icon: .add) }
                    }
                    Button { let urls = FileTransferClipboard.urls(); model.withFileMenu(snapshot) { model.onPasteFiles(true, urls) } } label: { CommandLabel(title: "Paste Copy and Add…", icon: .copy) }
                    Button { let urls = FileTransferClipboard.urls(); model.withFileMenu(snapshot) { model.onPasteFiles(false, urls) } } label: { CommandLabel(title: "Paste Move…", icon: .rename) }
                    if !selected.isEmpty, selected.allSatisfy({ ![FileState.untracked, .ignored, .deleted].contains($0.state) }) {
                        Button { model.withFileMenu(snapshot) { model.onAction(.move, selected.map(\.id)) } } label: { CommandLabel(title: "Move…", icon: .rename) }
                    }
                    if snapshot.offersRevert {
                        Button { model.withFileMenu(snapshot) { model.onAction(.revert, selected.map(\.id)) } } label: { CommandLabel(title: "Revert…", icon: .revert) }
                    }
                    ForEach(model.lfsActions(selected), id: \.self) { action in
                        Button { model.withFileMenu(snapshot) { model.setLFSLocked(ids, locked: action == .lock) } } label: { CommandLabel(title: action.rawValue, icon: action == .lock ? .lock : .unlock) }.disabled(model.busy || model.confirmingQuit)
                    }
                    if let mark = model.files.first(where: { GitReferenceName.equal($0.id,snapshot.mark?.path) }) {
                        IndexFlagsMenu(files:selected, selectionMark:mark) { action in model.withFileMenu(snapshot) { model.setFlags(action, files:selected, selectionMark:mark) } }
                    }
                    if snapshot.offersIgnore {
                        IgnoreSelectionMenu(paths: selected.map(\.id), action: { action, paths in model.withFileMenu(snapshot) { model.onAction(action, paths) } })
                    }
                    if model.canAssignChangelist(snapshot) {
                        Divider()
                        if snapshot.entries.contains(where: { model.changelists.name(for: $0.path) != nil }) {
                            Button("Remove from changelist") { model.assignChangelist(snapshot, name: nil) }
                        }
                        Menu("Move to changelist") {
                            Button("<new changelist>") { model.assignChangelist(snapshot, name: nil, creating: true) }
                            Divider()
                            Button(GitChangelists.ignored) { model.assignChangelist(snapshot, name: GitChangelists.ignored) }
                            ForEach(model.changelists.nameIdentities.filter { $0.rawValue != GitChangelists.ignored }, id: \.self) { name in
                                Button(name.rawValue) { model.assignChangelist(snapshot, name: name.rawValue) }.help(changelistNameHelp(name, names: model.changelists.nameIdentities)).accessibilityLabel(changelistNameHelp(name, names: model.changelists.nameIdentities))
                            }
                        }
                        Toggle("Keep changelists", isOn: Binding(get: { model.keepChangelists }, set: { model.setKeepChangelists($0, snapshot: snapshot) }))
                    }
                    Divider()
                    ForEach(snapshot.commands, id: \.self) { command in
                        Button { model.fileAction(command, snapshot: snapshot, permanently: NSEvent.modifierFlags.contains(.shift)) } label: {
                            CommandLabel(title: command.rawValue, icon: command.icon)
                        }
                    }
                    Menu {
                        Button { model.withFileMenu(snapshot) { model.copy(ids, information: .fullPaths) } } label: { CommandLabel(title: "Full paths", icon: .copy) }
                        Button { model.withFileMenu(snapshot) { model.copy(ids) } } label: { CommandLabel(title: "Relative paths", icon: .copy) }
                        Button { model.withFileMenu(snapshot) { model.copy(ids, information: .names) } } label: { CommandLabel(title: "File/folder names", icon: .copy) }
                        Button { model.withFileMenu(snapshot) { model.copy(ids, information: .all) } } label: { CommandLabel(title: "Copy all information to clipboard", icon: .copy) }
                    } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }.disabled(ids.isEmpty)
                    }
                }
            } primaryAction: { nativeIDs in
                let ids = GitPathRowIdentity.paths(nativeIDs)
                if ids.count == 1, let group = model.tableRows.first(where: { ids.contains($0.row.id) })?.row.group { model.selectGroup(group); return }
                if ids.count == 1, let entry = model.files.first(where: { ids.contains($0.id) }), entry.state == .conflicted { model.onAction(.editConflict, [entry.id]) }
                else { model.diff(ids) }
            }
            .frame(minHeight: 300)
            .overlay { if rows.isEmpty && !model.busy { Text("No files to show with the current setting.\nCheck one or more settings below to see unversioned, ignored and/or unmodified files.").foregroundStyle(.secondary).allowsHitTesting(false) } }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show unversioned files", isOn: Binding(get: { model.filter.showUnversioned }, set: { var value = model.filter; value.showUnversioned = $0; model.setFilter(value) })).disabled(!model.folderFiltersEnabled)
                    Toggle("Show ignore local changes flagged files", isOn: Binding(get: { model.filter.showLocalChangesIgnored }, set: { var value = model.filter; value.showLocalChangesIgnored = $0; model.setFilter(value) }))
                    Toggle("Show ignored files", isOn: Binding(get: { model.filter.showIgnored }, set: { var value = model.filter; value.showIgnored = $0; model.setFilter(value) })).disabled(!model.folderFiltersEnabled)
                    Toggle("Show all staged files", isOn: Binding(get: { model.filter.showAllStaged }, set: { var value = model.filter; value.showAllStaged = $0; model.setFilter(value) }))
                    Toggle("Show Whole Project", isOn: Binding(get: { model.filter.wholeProject }, set: { var value = model.filter; value.wholeProject = $0; model.setFilter(value) })).disabled(model.filter.paths.isEmpty)
                }.toggleStyle(.checkbox)
                Spacer()
                StatusStatisticsField(model:model).frame(width:440,height:48,alignment:.topLeading)
            }
            HStack {
                Spacer()
                Button("Save unified diff") { model.scopeUnifiedDiff(alternate: NSEvent.modifierFlags.contains(.shift)) }
                    .help("Open the invocation scope as a unified diff. Hold Shift to use the alternative viewer; save from the viewer.")
                StatusStashMenu(model:model).frame(width:100,height:24)
                Button("Commit") { model.performDialogAction(.commit) }
                Button("Refresh") { model.reload() }.keyboardShortcut("r")
                Button("OK") { model.close() }.keyboardShortcut(.defaultAction)
            }
        }.padding(12).disabled(model.busy || model.confirmingQuit || model.retired)
        .overlay(alignment: .bottomLeading) {
            if model.busy && !model.currentOperation.isEmpty {
                Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancelOperation() }
                    .disabled(model.cancelling || model.retired).padding(12)
            }
        }
        .onChange(of: model.filter) { _ in model.selection.formIntersection(GitPathSet(model.visibleFiles.map(\.id))) }
        .alert("Git operation failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }

    }
    @ViewBuilder private func groupCell(_ item: StatusGroupedRow, column: StatusListColumn) -> some View {
        if let row = item.contents { Text(model.columnText(row, column)).foregroundStyle(row.file.entry.statusTextColor(selected: model.selection.contains(row.id), preferences: model.colorPreferences)) }
        else { Rectangle().fill(Color.accentColor.opacity(0.35)).frame(height: 1).padding(.vertical, 8) }
    }

}


struct IndexFlagsMenu: View {
    let files: [WorkingTreeFile]
    var selectionMark: WorkingTreeFile? = nil
    let action: (IndexFlagAction) -> Void
    var body: some View {
        ForEach(IndexFlagAction.allCases.filter { $0.isAvailable(for: selectionMark.map { [$0] } ?? files) }, id: \.self) { item in
            Button { action(item) } label: { CommandLabel(title: item.rawValue, icon: .ignore) }
        }
    }
}
@MainActor func confirmIndexFlags(_ action: IndexFlagAction) -> Bool {
    let alert = NSAlert(); alert.messageText = action.confirmation
    alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
    return alert.runModal() == .alertSecondButtonReturn
}

struct StatusFileSort: SortComparator {
    var column: StatusListColumn
    var order: SortOrder = .forward
    func compare(_ lhs: StatusRow, _ rhs: StatusRow) -> ComparisonResult {
        var result: ComparisonResult
        if column == .status {
            result = lhs.status.compare(rhs.status, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if result == .orderedSame { result = StatusListSorting.compare(lhs.file.entry, rhs.file.entry, column: .path) }
        } else {
            result = StatusListSorting.compare(lhs.file.entry, rhs.file.entry, column: column,
                lhsStatistics: lhs.statistics, rhsStatistics: rhs.statistics,
                lhsMetadata: lhs.metadata,
                rhsMetadata: rhs.metadata,
                lhsLFSOwner: lhs.lfsOwner, rhsLFSOwner: rhs.lfsOwner)
        }
        return order == .forward ? result : result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
    }
}
