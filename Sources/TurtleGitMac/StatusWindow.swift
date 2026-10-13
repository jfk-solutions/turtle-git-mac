import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

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

enum StatusFileCommand: String, CaseIterable {
    case compareTwo = "Compare two files", log = "Show log", oldNameLog = "Show log of old name", blame = "Blame"
    case export = "Export…", editor = "View revision in alternative editor", open = "Open", openWith = "Open With…", reveal = "Reveal in Finder", delete = "Delete"
    var icon: MenuIcon {
        switch self {
        case .compareTwo: return .compare
        case .log, .oldNameLog: return .log
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
}
private struct StatusFileActionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class StatusNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 96 { refresh(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class StatusWindowController: NSWindowController, NSWindowDelegate {
    let model: StatusWindowModel
    var onClosed: () -> Void = {}
    var onPullAfterLFSLock: () -> Void = {}
    private var lfsOperation: LFSFileOperationController?
    private var closingStatus = false
    var makeLFSOperation: (GitRepository, RepositoryAccessLease?) -> LFSFileOperationController = { LFSFileOperationController(repository: $0, access: $1) }
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        model = StatusWindowModel(repository: repository, access: access, defaults: defaults)
        let window = StatusNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 630),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Working Tree – TurtleGit"
        window.minSize = NSSize(width: 960, height: 540); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StatusDialog(model: model))
        super.init(window: window); window.delegate = self
        window.refresh = { [weak model] in model?.reload() }
        window.setContentSize(NSSize(width: 1100, height: 630)); window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.savePatch = { [weak self] text in self?.savePatch(text) }
        model.onLFSOperation = { [weak self, weak window] paths, locked in
            guard let self, !self.closingStatus, let window, window.attachedSheet == nil, self.lfsOperation == nil else { return false }
            let progress = self.makeLFSOperation(repository, access)
            progress.model.onPullAfterLock = { [weak self] in guard let self, !self.closingStatus else { return }; self.onPullAfterLFSLock() }
            progress.onClosed = { [weak self, weak progress] in
                guard let self, !self.closingStatus, self.lfsOperation === progress else { return }
                self.lfsOperation = nil; self.model.busy = false; self.model.reload(); self.model.onChanged()
            }
            self.lfsOperation = progress
            guard progress.present(owner: window, paths: paths, locked: locked) else { self.lfsOperation = nil; return false }
            return true
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
    private(set) var retired = false
    private var operationCancellation: OperationCancellation?
    @Published private(set) var currentOperation = ""
    @Published private(set) var cancelling = false
    var readStatus: (OperationCancellation) async throws -> [WorkingTreeFile]
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var conflictRebase = false
    @Published var submodules = Set<String>()
    @Published var hasLFS = false
    @Published var fileColumns: StatusListColumnSettings
    @Published var fileMetadata: [String: StatusListMetadata] = [:]
    var showLFSOwners: Bool { fileColumns.visible.contains(.lfsOwner) }
    private static let columnKey = "WorkingTree.FileColumns"
    static var defaultColumns: StatusListColumnSettings { StatusListColumnSettings(visible: Set(StatusListColumn.defaultColumns + [.lastModified])) }
    var visibleColumns: [StatusListColumn] { fileColumns.order.filter { fileColumns.visible.contains($0) && ($0 != .lfsOwner || hasLFS) } }
    var availableColumns: Set<StatusListColumn> { Set(StatusListColumn.allCases.filter { $0 != .lfsOwner || hasLFS }) }
    @Published var lfsOwners: [String: String] = [:]
    @Published var lfsLockedPaths = Set<String>()
    @Published var lfsOwnershipKnown = false
    private let defaults: UserDefaults
    private var ownerCancellation: OperationCancellation?
    var queryLFSOwners: (OperationCancellation) async throws -> [LFSLock]
    var ownersVisible: Bool { hasLFS && showLFSOwners }
    var onLFSOperation: ([String], Bool) -> Bool = { _, _ in false }
    @Published var files: [WorkingTreeFile] = []
    @Published var statistics: [String: CommitFile] = [:]
    private var menuGeneration = UUID()
    @Published var selection = Set<String>() { didSet { if selection != oldValue { menuGeneration = UUID() } } }
    @Published var sortOrder = [StatusFileSort(column: .path)]
    @Published var filter = WorkingTreeFilter()
    @Published var branch = ""
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    var unifiedWindow: PatchWindowController?
    var unifiedViewerBusy: Bool { unifiedWindow?.model.busy == true || unifiedWindow?.window?.attachedSheet != nil }
    var close: () -> Void = {}
    var savePatch: (Data) -> Void = { _ in }
    var onBlame: (String) -> Void = { _ in }
    var onCompareTwoFiles: ([String]) -> Void = { _ in }
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
    var openAlternativeEditor: (URL) async throws -> Void = { url in
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            AlternativeEditor.open(url) { error in
                if let error { reply.resume(throwing: StatusFileActionFailure(message: error)) } else { reply.resume() }
            }
        }
    }
    var onAction: (RepositoryAction, [String]) -> Void = { _, _ in }
    var onChanged: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.defaults = defaults
        readStatus = { try await repository.workingTreeStatus(cancellation: $0) }
        if defaults.integer(forKey: Self.columnKey + ".Version") == 1 {
            fileColumns = .load(from: defaults, key: Self.columnKey)
        } else {
            var columns = Self.defaultColumns
            if defaults.bool(forKey: "WorkingTree.LFSOwnerVisible") { columns.visible.insert(.lfsOwner) }
            fileColumns = columns
        }
        queryLFSOwners = { try await repository.lfsLocks(cancellation: $0) }
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
        fileColumns.save(to: defaults, key: Self.columnKey)
        if visible { reload() } else { lfsOwners = [:]; lfsLockedPaths = []; lfsOwnershipKnown = false }
    }
    func setColumn(_ column: StatusListColumn, visible: Bool) {
        guard column != .path, availableColumns.contains(column), !busy, !confirmingQuit else { return }
        if column == .lfsOwner { setShowLFSOwners(visible); return }
        if visible { fileColumns.visible.insert(column) } else { fileColumns.visible.remove(column) }
        fileColumns.save(to: defaults, key: Self.columnKey)
    }
    @discardableResult func saveColumnLayout(order: [StatusListColumn], widths: [StatusListColumn: Double]) -> Bool {
        guard !retired, !busy, !confirmingQuit else { return false }
        let next = StatusListColumnSettings(visible: fileColumns.visible, order: order, widths: widths)
        if fileColumns != next { fileColumns = next; fileColumns.save(to: defaults, key: Self.columnKey) }
        return true
    }
    func requestResetColumns(choose: @escaping () async -> Bool, onAccepted: @escaping () -> Void) {
        runOperation("Reset columns…", operation: { [self] token in
            guard await choose(), isLive(token), !confirmingQuit else { return }
            fileColumns = Self.defaultColumns; fileColumns.save(to: defaults, key: Self.columnKey)
            lfsOwners = [:]; lfsLockedPaths = []; lfsOwnershipKnown = false
            onAccepted()
        })
    }
    @discardableResult func cancelLFSOwnerQuery() -> Bool {
        guard let ownerCancellation else { return false }
        ownerCancellation.cancel(); return true
    }

    var visibleFiles: [WorkingTreeFile] { files.filter { filter.includes($0) } }
    var sortedRows: [StatusRow] { visibleFiles.map { StatusRow(file: $0, statistics: statistics[$0.id], lfsOwner: lfsOwners[$0.id] ?? "", metadata: fileMetadata[$0.id]) }.sorted(using: sortOrder) }
    var summary: String {
        let rows = visibleFiles
        return "\(rows.count) files shown, \(rows.filter { $0.entry.staged }.count) staged, \(rows.filter { $0.state == .modified }.count) modified, \(rows.filter { $0.state == .untracked }.count) unversioned"
    }
    private var wholeProjectKey: String { "WorkingTree.ShowWholeProject." + repository.root.path }
    func setScope(_ paths: [String]) {
        guard !retired, !busy else { return }
        filter.paths = paths.contains(".") ? [] : paths
        filter.wholeProject = filter.paths.isEmpty || defaults.bool(forKey: wholeProjectKey)
        selection = []; reload()
    }
    func setFilter(_ value: WorkingTreeFilter) {
        guard !retired, !busy, !confirmingQuit else { return }
        menuGeneration = UUID(); filter = value
        defaults.set(value.showUnversioned, forKey: "AddBeforeCommit")
        defaults.set(value.showAllStaged, forKey: "ChangedFilesIncludeStaged")
        if !value.paths.isEmpty { defaults.set(value.wholeProject, forKey: wholeProjectKey) }
        selection.formIntersection(Set(visibleFiles.map(\.id)))
    }
    @discardableResult func cancelOperation() -> Bool {
        guard let token = operationCancellation else { return cancelLFSOwnerQuery() }
        cancelling = true; token.cancel(); ownerCancellation?.cancel(); return true
    }
    func invalidate() {
        guard !retired else { return }; retired = true
        operationCancellation?.cancel(); ownerCancellation?.cancel()
        unifiedWindow?.close(); unifiedWindow = nil
    }
    private func isLive(_ token: OperationCancellation) -> Bool {
        !retired && operationCancellation === token && !token.isCancelled
    }
    private func runOperation(_ title: String, operation: @escaping (OperationCancellation) async throws -> Void, completed: @escaping () -> Void = {}, failed: @escaping () -> Void = {}) {
        guard !retired, !busy, !confirmingQuit else { return }
        let token = OperationCancellation(); operationCancellation = token
        busy = true; cancelling = false; currentOperation = title; Self.activeOperations += 1
        Task {
            defer {
                Self.activeOperations -= 1
                if operationCancellation === token { operationCancellation = nil; busy = false; cancelling = false; currentOperation = "" }
                withExtendedLifetime(access) {}
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await operation(token)
                guard isLive(token) else { return }
                busy = false; completed()
            } catch {
                guard !retired else { return }
                if token.isCancelled { self.error = "Operation cancelled. Any completed changes are retained; refresh to inspect the working tree." }
                else { self.error = error.localizedDescription }
                busy = false; failed()
            }
        }
    }
    func reload() {
        guard !retired, !busy, !confirmingQuit else { return }; menuGeneration = UUID()
        runOperation("Refreshing working tree…", operation: { [self] token in
            // Publish one complete snapshot. A failed/cancelled read retains the prior table.
            let nextFiles = try await readStatus(token)
            let nextBranch = try await repository.branch(cancellation: token)
            let nextRebase = try await repository.conflictIsRebase(cancellation: token)
            let nextSubmodules = try await repository.submodulePaths(cancellation: token)
            let nextLFS = try await repository.hasLFS(cancellation: token)
            let nextMetadata = await repository.statusListMetadata(paths: nextFiles.map(\.id))
            let nextStatistics = try await repository.workingTreeFiles(cancellation: token)
            guard isLive(token) else { return }
            files = nextFiles; branch = nextBranch; conflictRebase = nextRebase; submodules = nextSubmodules
            hasLFS = nextLFS; fileMetadata = nextMetadata
            statistics = Dictionary(nextStatistics.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
            selection.formIntersection(Set(visibleFiles.map(\.id)))
            lfsOwners = [:]; lfsLockedPaths = []; lfsOwnershipKnown = false
            if ownersVisible {
                ownerCancellation = token; defer { if ownerCancellation === token { ownerCancellation = nil } }
                let locks = try await queryLFSOwners(token)
                guard isLive(token) else { return }
                lfsOwners = Dictionary(locks.map { ($0.path, $0.owner) }, uniquingKeysWith: { first, _ in first })
                lfsLockedPaths = Set(locks.map(\.path)); lfsOwnershipKnown = true
            }
        })
    }
    func canLockLFS(_ selected: [WorkingTreeFile]) -> Bool {
        LFSLockingSelection.isAvailable(selected.map(\.entry), hasLFS: hasLFS, root: repository.root, directories: submodules)
    }
    func lfsActions(_ selected: [WorkingTreeFile]) -> [LFSLockMenuAction] {
        guard canLockLFS(selected) else { return [] }
        return LFSLockMenu.actions(paths: selected.map(\.id), ownersVisible: ownersVisible, lockedPaths: lfsLockedPaths, ownershipKnown: lfsOwnershipKnown)
    }
    func setLFSLocked(_ ids: Set<String>, locked: Bool) {
        guard !retired, !busy, !confirmingQuit else { return }
        let selected = sortedRows.map(\.file).filter { ids.contains($0.id) }
        guard selected.count == ids.count, lfsActions(selected).contains(locked ? .lock : .unlock) else { return }
        busy = true
        if !onLFSOperation(selected.map(\.id), locked) { busy = false }
    }
    func stage(_ ids: Set<String>, staged: Bool) {
        let paths = sortedRows.map(\.file).filter { ids.contains($0.id) && $0.state != .conflicted }.map(\.id)
        guard !paths.isEmpty else { return }
        runOperation(staged ? "Staging files…" : "Unstaging files…", operation: { [self] token in
            if staged { try await repository.stage(paths, cancellation: token) }
            else { try await repository.unstage(paths, cancellation: token) }
        }, completed: { [self] in reload(); onChanged() })
    }
    func setFlags(_ action: IndexFlagAction, files: [WorkingTreeFile]) {
        guard !retired, !busy, !confirmingQuit, action.isAvailable(for: files), confirmIndexFlags(action), !retired else { return }
        runOperation("Updating index flags…", operation: { [self] token in
            try await repository.setIndexFlags(action, paths: files.map(\.id), cancellation: token)
        }, completed: { [self] in reload(); onChanged() })
    }
    func diff(_ ids: Set<String>, saving: Bool = false) {
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
    func unifiedDiff(_ ids: Set<String>, alternate: Bool) {
        guard !unifiedViewerBusy else { return }
        let paths = sortedRows.filter { ids.contains($0.id) }.map(\.id)
        guard !paths.isEmpty else { return }
        runOperation("Preparing unified diff…", operation: { [self] token in
            let bytes = try await repository.workingTreeDiffData(paths: paths, cancellation: token)
            guard isLive(token) else { return }
            if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate) {
                guard isLive(token) else { return }
                unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: "HEAD → Working tree", onClosed: { [weak self] in self?.unifiedWindow = nil })
            }
        })
    }
    func fileMenu(_ ids: Set<String>, mark: String? = nil) -> StatusFileMenuSnapshot {
        let rows = sortedRows.filter { ids.contains($0.id) }, entries = rows.map { $0.file.entry }
        let focused = files.first { $0.id == mark }?.entry ?? entries.first
        func directory(_ row: StatusRow) -> Bool { submodules.contains(row.id) || row.metadata?.isDirectory == true }
        var commands: [StatusFileCommand] = []
        if rows.count == 2 && rows.allSatisfy({ !directory($0) }) { commands.append(.compareTwo) }
        if let row = rows.first, rows.count == 1 {
            let entry = row.file.entry
            if ![FileState.untracked, .ignored].contains(entry.state) {
                commands.append(.log)
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
        return StatusFileMenuSnapshot(generation: menuGeneration, entries: entries, mark: focused, commands: commands)
    }
    private func accepts(_ snapshot: StatusFileMenuSnapshot, duringOperation: Bool = false) -> Bool {
        guard !retired, !confirmingQuit, (duringOperation || !busy), snapshot.generation == menuGeneration,
              !snapshot.entries.isEmpty else { return false }
        let current = Dictionary(files.map { ($0.id, $0.entry) }, uniquingKeysWith: { _, last in last })
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
    func commitPaths() -> [String] { filter.wholeProject ? [] : filter.paths }
    func didRename(_ source: String, to destination: String) {
        func moved(_ path: String) -> String { path == source ? destination : path.hasPrefix(source + "/") ? destination + path.dropFirst(source.count) : path }
        selection = Set(selection.map(moved)); filter.paths = filter.paths.map(moved); reload()
    }
    func reveal(_ ids: Set<String>) { guard !retired, !busy, !confirmingQuit else { return }; NSWorkspace.shared.activateFileViewerSelecting(files.filter { ids.contains($0.id) }.map { repository.root.appendingPathComponent($0.id) }) }
    func columnText(_ row: StatusRow, _ column: StatusListColumn) -> String {
        switch column {
        case .path: return StatusListClipboard.displayedPath(row.file.entry)
        case .fileName: return row.fileName
        case .fileExtension: return row.fileExtension
        case .status: return row.status
        case .added: return row.addedText
        case .removed: return row.removedText
        case .lastModified: return row.metadata?.dateText ?? "–"
        case .fileSize: return row.sizeText
        case .lfsOwner: return row.lfsOwner
        }
    }
    func clipboardText(_ ids: Set<String>, copy: StatusListCopy) -> String {
        let rows = sortedRows.filter { ids.contains($0.id) }
        guard !rows.isEmpty else { return "" }
        let columns: [StatusListColumn]
        switch copy {
        case .all: columns = visibleColumns
        case .column(let column): columns = [column]
        case .pathsAndStatus: columns = [.path,.status]
        default: columns = []
        }
        let heading = StatusListClipboard.heading(copy: copy, columns: columns)
        return heading + rows.map { row in
            switch copy {
            case .fullPaths: return repository.root.appendingPathComponent(row.path).path
            case .relativePaths: return row.path
            case .names: return row.fileName
            case .pathsAndStatus: return [row.path,row.status].joined(separator: "\t")
            default: return columns.map { columnText(row,$0) }.joined(separator: "\t")
            }
        }.joined(separator: "\n") + "\n"
    }
    func copy(_ ids: Set<String>, information: StatusListCopy = .relativePaths) {
        guard !retired, !busy, !confirmingQuit else { return }
        let text = clipboardText(ids, copy: information)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

struct StatusDialog: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: StatusWindowModel
    @State private var focusedPath: String?
    var body: some View {
        let rows = model.sortedRows
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id,$0) })
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.branch.isEmpty ? "Unborn / detached HEAD" : model.branch) { model.onAction(.switchBranch, []) }.buttonStyle(.link)
                Spacer(); if model.busy { Text(model.currentOperation).font(.caption); ProgressView().controlSize(.small) }
            }
            Table(rows, selection: $model.selection, sortOrder: Binding(get: { model.sortOrder }, set: { model.setSortOrder($0) })) {
                TableColumn("Path", sortUsing: StatusFileSort(column: .path)) { row in
                    HStack(spacing: 6) { if let icon = row.file.state.icon.image() { Image(nsImage: icon) }; Text(StatusListClipboard.displayedPath(row.file.entry)).foregroundStyle(row.file.entry.statusTextColor(selected: model.selection.contains(row.id))).lineLimit(1) }
                        .help(row.file.entry.originalPath.map { "Renamed from \($0)" } ?? row.path)
                }.width(min: 250, ideal: 380)
                TableColumn("Filename", sortUsing: StatusFileSort(column: .fileName)) { Text($0.fileName).foregroundStyle($0.file.entry.statusTextColor(selected: model.selection.contains($0.id))) }.width(min: 100, ideal: 180)
                TableColumn("Extension", sortUsing: StatusFileSort(column: .fileExtension)) { Text($0.fileExtension).foregroundStyle($0.file.entry.statusTextColor(selected: model.selection.contains($0.id))) }.width(min: 45, ideal: 65)
                TableColumn("Status", sortUsing: StatusFileSort(column: .status)) { row in Text(row.status).foregroundStyle(row.file.entry.statusTextColor(selected: model.selection.contains(row.id))) }.width(min: 110, ideal: 155)
                TableColumn("Lines added", sortUsing: StatusFileSort(column: .added)) { Text($0.addedText).foregroundStyle($0.file.entry.statusTextColor(selected: model.selection.contains($0.id))) }.width(min: 60, ideal: 80)
                TableColumn("Lines removed", sortUsing: StatusFileSort(column: .removed)) { Text($0.removedText).foregroundStyle($0.file.entry.statusTextColor(selected: model.selection.contains($0.id))) }.width(min: 60, ideal: 90)
                TableColumn("Last modified", sortUsing: StatusFileSort(column: .lastModified)) { row in
                    Text(row.metadata?.dateText ?? "–").foregroundStyle(row.file.entry.statusTextColor(selected: model.selection.contains(row.id)))
                }.width(min: 150, ideal: 170)
                TableColumn("File size", sortUsing: StatusFileSort(column: .fileSize)) { Text($0.sizeText).foregroundStyle($0.file.entry.statusTextColor(selected: model.selection.contains($0.id))) }.width(min: 70, ideal: 100)
                TableColumn("LFS Lock", sortUsing: StatusFileSort(column: .lfsOwner)) { Text($0.lfsOwner).foregroundStyle($0.file.entry.statusTextColor(selected: model.selection.contains($0.id))) }.width(min: 100, ideal: 160)
            }.fileListFont()
            .background(CommitFileInteraction(rows: rows.map { .file($0.file.entry) }, leadingColumnCount: 0, keyboardDeleteEnabled: true,
                visibleColumns: Set(model.visibleColumns), availableColumns: model.availableColumns, columnText: { entry, column in
                    rowsByID[entry.path].map { model.columnText($0,column) } ?? ""
                }, savedOrder: model.fileColumns.order, savedWidths: model.fileColumns.widths,
                saveLayout: { model.saveColumnLayout(order: $0, widths: $1) }, setColumnVisible: { model.setColumn($0, visible: $1) },
                resetColumns: { choose, accepted in model.requestResetColumns(choose: choose, onAccepted: accepted) }, focusedPath: $focusedPath,
                enabled: !model.busy && !model.confirmingQuit && !model.retired, delete: { entries, mark, permanently in
                    guard mark.canDeleteWithKeyboard else { return }
                    model.fileAction(.delete, snapshot: model.fileMenu(Set(entries.map(\.path)), mark: mark.path), permanently: permanently)
                },
                copy: { entries, status in model.copy(Set(entries.map(\.path)), information: status ? .pathsAndStatus : .relativePaths) },
                copyColumn: { entries, column in model.copy(Set(entries.map(\.path)), information: .column(column)) }, toggleCheck: { _,_ in }))
            .contextMenu(forSelectionType: String.self) { ids in
                let snapshot = model.fileMenu(ids, mark: focusedPath)
                TurtleGitContextMenu {
                    Button { model.withFileMenu(snapshot) { model.diff(ids) } } label: { CommandLabel(title: "Diff", icon: .compare) }.disabled(ids.isEmpty)
                    Button { model.withFileMenu(snapshot) { model.unifiedDiff(ids, alternate: NSEvent.modifierFlags.contains(.shift)) } } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(ids.isEmpty || model.busy)
                    Button { model.withFileMenu(snapshot) { model.stage(ids, staged: true) } } label: { CommandLabel(title: "Add / Stage", icon: .add) }.disabled(ids.isEmpty)
                    Button { model.withFileMenu(snapshot) { model.stage(ids, staged: false) } } label: { CommandLabel(title: "Unstage", icon: .revert) }.disabled(ids.isEmpty)
                    if ids.count == 1, let path = ids.first, let row = model.files.first(where: { $0.id == path }), ![FileState.untracked, .ignored, .deleted].contains(row.state) {
                        Button { model.withFileMenu(snapshot) { model.onAction(.rename, [path]) } } label: { CommandLabel(title: "Rename…", icon: .rename) }
                    }
                    let selected = model.files.filter { ids.contains($0.id) }
                    if !selected.isEmpty && selected.allSatisfy({ ![FileState.normal, .untracked, .ignored].contains($0.state) }) {
                        Button { model.withFileMenu(snapshot) { model.onAction(.revert, selected.map(\.id)) } } label: { CommandLabel(title: "Revert…", icon: .revert) }
                    }
                    ForEach(model.lfsActions(selected), id: \.self) { action in
                        Button { model.withFileMenu(snapshot) { model.setLFSLocked(ids, locked: action == .lock) } } label: { CommandLabel(title: action.rawValue, icon: action == .lock ? .lock : .unlock) }.disabled(model.busy || model.confirmingQuit)
                    }
                    IndexFlagsMenu(files: selected) { action in model.withFileMenu(snapshot) { model.setFlags(action, files: selected) } }
                    if !selected.isEmpty && selected.allSatisfy({ $0.state == .conflicted }) {
                        ResolveSelectionMenu(paths: selected.map(\.id), rebase: model.conflictRebase, canEdit: selected.count == 1, action: { action, paths in model.withFileMenu(snapshot) { model.onAction(action, paths) } })
                    }
                    if !selected.isEmpty && selected.allSatisfy({ [.untracked, .deleted].contains($0.state) }) {
                        IgnoreSelectionMenu(paths: selected.map(\.id), action: { action, paths in model.withFileMenu(snapshot) { model.onAction(action, paths) } })
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
            } primaryAction: { ids in
                if ids.count == 1, let entry = model.files.first(where: { ids.contains($0.id) }), entry.state == .conflicted { model.onAction(.editConflict, [entry.id]) }
                else { model.diff(ids) }
            }
            .frame(minHeight: 300)
            .overlay { if rows.isEmpty && !model.busy { Text("No files to show with the current setting.\nCheck one or more settings below to see unversioned, ignored and/or unmodified files.").foregroundStyle(.secondary).allowsHitTesting(false) } }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show unversioned files", isOn: Binding(get: { model.filter.showUnversioned }, set: { var value = model.filter; value.showUnversioned = $0; model.setFilter(value) }))
                    Toggle("Show ignore local changes flagged files", isOn: Binding(get: { model.filter.showLocalChangesIgnored }, set: { var value = model.filter; value.showLocalChangesIgnored = $0; model.setFilter(value) }))
                    Toggle("Show ignored files", isOn: Binding(get: { model.filter.showIgnored }, set: { var value = model.filter; value.showIgnored = $0; model.setFilter(value) }))
                    Toggle("Show all staged files", isOn: Binding(get: { model.filter.showAllStaged }, set: { var value = model.filter; value.showAllStaged = $0; model.setFilter(value) }))
                    Toggle("Show Whole Project", isOn: Binding(get: { model.filter.wholeProject }, set: { var value = model.filter; value.wholeProject = $0; model.setFilter(value) })).disabled(model.filter.paths.isEmpty)
                }.toggleStyle(.checkbox)
                Spacer()
                Text(model.summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            HStack {
                Spacer()
                Button("Save unified diff") { model.diff([], saving: true) }.disabled(model.visibleFiles.isEmpty)
                Menu("Stash") {
                    Button { model.onAction(.stash, []) } label: { CommandLabel(title: "Stash save…", icon: .stash) }
                    Button { model.onAction(.stashApply, []) } label: { CommandLabel(title: "Stash apply", icon: .stashPop) }
                    Button { model.onAction(.stashPop, []) } label: { CommandLabel(title: "Stash pop", icon: .stashPop) }
                    Button { model.onAction(.stashList, []) } label: { CommandLabel(title: "Stash list", icon: .log) }
                }
                Button("Commit") { model.onAction(.commit, model.commitPaths()) }
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
        .onChange(of: model.filter) { _ in model.selection.formIntersection(Set(model.visibleFiles.map(\.id))) }
        .alert("Git operation failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }

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
