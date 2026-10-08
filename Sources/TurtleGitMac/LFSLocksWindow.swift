import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class LFSLocksWindowController: NSWindowController, NSWindowDelegate {
    let model: LFSLocksWindowModel
    var onClosed: () -> Void = {}
    private var progressWindow: NSWindow?
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        model = LFSLocksWindowModel(repository: repository, access: access, defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 490), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – LFS Locks – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 570, height: 330)
        window.contentViewController = NSHostingController(rootView: LFSLocksDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.onProgressVisibility = { [weak self] visible in self?.setProgressPresented(visible) }
        DialogGeometry.attach(window, identifier: "LFSLocksDlg", legacyName: "LFSLocksDlg")
    }
    private func setProgressPresented(_ visible: Bool) {
        guard let window else { return }
        if visible {
            guard progressWindow == nil else { return }
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 390), styleMask: [.titled], backing: .buffered, defer: false)
            sheet.title = model.operationLocked ? "LFS Lock – TurtleGit" : "LFS Unlock – TurtleGit"; sheet.isReleasedWhenClosed = false
            sheet.contentViewController = NSHostingController(rootView: LFSUnlockProgress(model: model))
            progressWindow = sheet; window.beginSheet(sheet)
        } else if let sheet = progressWindow {
            if sheet.sheetParent === window { window.endSheet(sheet) }
            sheet.orderOut(nil); sheet.close(); progressWindow = nil
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        return !model.confirmingQuit && !model.showingProgress && sender.attachedSheet == nil
    }
    func windowWillClose(_ notification: Notification) { setProgressPresented(false); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class LFSLocksWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var locks: [LFSLock] = []
    @Published var hasLFS = false
    @Published var checked = Set<String>()
    @Published var selection = Set<String>()
    @Published var sortOrder = [LFSFileSort(column: .path)]
    @Published var fileColumns: StatusListColumnSettings
    @Published var fileMetadata: [String: StatusListMetadata] = [:]
    private let defaults: UserDefaults
    private static let columnKey = "LFSLocks.FileColumns"
    static let columns: [StatusListColumn] = [.path,.fileName,.fileExtension,.lastModified,.fileSize,.lfsOwner]
    static var defaultColumns: StatusListColumnSettings { StatusListColumnSettings(visible: [.path,.fileExtension,.lfsOwner]) }
    var visibleColumns: [StatusListColumn] { fileColumns.order.filter { fileColumns.visible.contains($0) && Self.columns.contains($0) } }
    @Published var force = false
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var information = ""
    @Published var results: [LFSFileResult] = []
    @Published var operationLocked = false
    @Published var showingProgress = false { didSet { if oldValue != showingProgress { onProgressVisibility(showingProgress) } } }
    private var cancellation = OperationCancellation()
    private var batchID = UUID()
    private var acceptingBatchResults = false
    private var operationPaths: [String] = []
    private var operationForce = false
    var onProgressVisibility: (Bool) -> Void = { _ in }
    var refreshLocksAfterOperation = true
    var close: () -> Void = {}
    var query: (OperationCancellation) async throws -> [LFSLock]
    var change: ([String], Bool, OperationCancellation, @escaping @Sendable (LFSFileResult) -> Void) async throws -> LFSBatchResult
    var lockChange: ([String], OperationCancellation, @escaping @Sendable (LFSFileResult) -> Void) async throws -> LFSBatchResult
    var canUnlock: Bool { !busy && !confirmingQuit && locks.contains { checked.contains($0.id) } }
    var rows: [LFSListRow] { locks.map { LFSListRow(lock: $0, metadata: fileMetadata[$0.path]) }.sorted(using: sortOrder) }
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.defaults = defaults
        fileColumns = defaults.integer(forKey: Self.columnKey + ".Version") == 1 ? .load(from: defaults, key: Self.columnKey) : Self.defaultColumns
        query = { try await repository.lfsLocks(cancellation: $0) }
        change = { try await repository.setLFSLocked(paths: $0, locked: false, force: $1, cancellation: $2, onResult: $3) }
        lockChange = { try await repository.setLFSLocked(paths: $0, locked: true, cancellation: $1, onResult: $2) }
    }
    func setSortOrder(_ order: [LFSFileSort]) {
        guard !busy, !confirmingQuit, !showingProgress else { return }
        sortOrder = Array(order.filter { Self.columns.contains($0.column) }.prefix(1))
    }
    func setColumn(_ column: StatusListColumn, visible: Bool) {
        guard !busy, !confirmingQuit, !showingProgress, column != .path, Self.columns.contains(column) else { return }
        if visible { fileColumns.visible.insert(column) } else { fileColumns.visible.remove(column) }
        fileColumns.save(to: defaults, key: Self.columnKey)
    }
    @discardableResult func saveColumnLayout(order: [StatusListColumn], widths: [StatusListColumn: Double]) -> Bool {
        guard !busy, !confirmingQuit, !showingProgress else { return false }
        let next = StatusListColumnSettings(visible: fileColumns.visible, order: order, widths: widths)
        if fileColumns != next { fileColumns = next; fileColumns.save(to: defaults, key: Self.columnKey) }
        return true
    }
    func requestResetColumns(choose: @escaping () async -> Bool, onAccepted: @escaping () -> Void) {
        guard !busy, !confirmingQuit, !showingProgress else { return }
        busy = true
        Task {
            defer { busy = false }
            guard await choose(), !confirmingQuit else { return }
            fileColumns = Self.defaultColumns; fileColumns.save(to: defaults, key: Self.columnKey); onAccepted()
        }
    }
    func clipboardText(_ ids: Set<String>, copy: StatusListCopy) -> String {
        let selected = rows.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return "" }
        let columns: [StatusListColumn]
        switch copy {
        case .all: columns = visibleColumns
        case .column(let column): columns = [column]
        case .pathsAndStatus: columns = [.path,.status]
        default: columns = []
        }
        let heading = StatusListClipboard.heading(copy: copy, columns: columns)
        return heading + selected.map { row in
            switch copy {
            case .fullPaths: return repository.root.appendingPathComponent(row.path).path
            case .relativePaths: return row.path
            case .names: return row.fileName
            default: return columns.map { row.text($0) }.joined(separator: "\t")
            }
        }.joined(separator: "\n") + "\n"
    }
    func copy(_ ids: Set<String>, information: StatusListCopy) {
        let text = clipboardText(ids, copy: information)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    func toggleChecks(_ ids: [String], mark: String) {
        guard !busy, !confirmingQuit, !showingProgress, locks.contains(where: { $0.id == mark }) else { return }
        let value = !checked.contains(mark)
        for id in ids { setChecked(id, value) }
    }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func setChecked(_ id: String, _ value: Bool) {
        guard !busy, !confirmingQuit, locks.contains(where: { $0.id == id }) else { return }
        if value { checked.insert(id) } else { checked.remove(id) }
    }
    func selectAll(_ value: Bool) {
        guard !busy, !confirmingQuit else { return }; checked = value ? Set(locks.map(\.id)) : []
    }
    func setForce(_ value: Bool) { guard !busy, !confirmingQuit else { return }; force = value }
    func lfsActions(_ ids: Set<String>) -> [LFSLockMenuAction] {
        let selected = rows.filter { ids.contains($0.id) }
        guard hasLFS, !ids.isEmpty, selected.count == ids.count,
              selected.allSatisfy({ $0.metadata?.isDirectory != true }) else { return [] }
        return LFSLockMenu.actions(paths: selected.map(\.path), ownersVisible: fileColumns.visible.contains(.lfsOwner),
            lockedPaths: Set(locks.map(\.path)), ownershipKnown: true)
    }
    func setSelectionLocked(_ ids: Set<String>, locked: Bool) async {
        guard !busy, !confirmingQuit, !showingProgress,
              lfsActions(ids).contains(locked ? .lock : .unlock) else { return }
        await perform(paths: rows.filter { ids.contains($0.id) }.map(\.path), locked: locked)
    }
    func cancel() { guard busy else { return }; cancellation.cancel(); information = "Cancelling…" }
    func refresh() async {
        guard !busy, !confirmingQuit, !showingProgress else { return }
        busy = true; error = nil; locks = []; fileMetadata = [:]; checked = []; selection = []; cancellation = OperationCancellation(); information = "Getting LFS locks…"
        defer { busy = false }
        do {
            try validateAccess()
            locks = try await query(cancellation); fileMetadata = await repository.statusListMetadata(paths: locks.map(\.path)); hasLFS = try await repository.hasLFS(); checked = Set(locks.map(\.id)); selection.formIntersection(checked)
            information = "\(locks.count) locked file(s)."
        } catch { self.error = error.localizedDescription; information = cancellation.isCancelled ? "Cancelled." : "Could not get LFS locks." }
    }
    func unlock(forceRetry: Bool = false) async {
        guard !busy, !confirmingQuit, !forceRetry || !operationLocked else { return }
        guard forceRetry || !showingProgress else { return }
        if !forceRetry { operationLocked = false; operationForce = force; operationPaths = rows.filter { checked.contains($0.id) }.map(\.path) }
        await runOperation(forceRetry: forceRetry)
    }
    func perform(paths: [String], locked: Bool) async {
        guard !busy, !confirmingQuit, !showingProgress, !paths.isEmpty else { return }
        operationPaths = paths; operationLocked = locked; operationForce = false
        await runOperation(forceRetry: false)
    }
    private func runOperation(forceRetry: Bool) async {
        guard !operationPaths.isEmpty, !forceRetry || showingProgress && results.contains(where: { !$0.success }) else { return }
        let useForce = !operationLocked && (forceRetry || operationForce)
        busy = true; showingProgress = true; results = []; error = nil
        cancellation = OperationCancellation(); batchID = UUID(); acceptingBatchResults = true; let generation = batchID
        information = "\(operationLocked ? "Locking" : "Unlocking") \(operationPaths.count) file(s)…"
        defer { busy = false; acceptingBatchResults = false }
        do {
            try validateAccess()
            let report: @Sendable (LFSFileResult) -> Void = { [weak self] file in
                Task { @MainActor in
                    guard let self, self.busy, self.acceptingBatchResults, self.batchID == generation else { return }
                    self.results.append(file)
                }
            }
            let batch: LFSBatchResult
            if operationLocked { batch = try await lockChange(operationPaths, cancellation, report) }
            else { batch = try await change(operationPaths, useForce, cancellation, report) }
            acceptingBatchResults = false
            results = batch.files
            information = batch.cancelled ? "Cancelled. Completed server changes remain; refresh to verify lock state." : "\(results.filter(\.success).count) of \(operationPaths.count) file(s) \(operationLocked ? "locked" : "unlocked")."
            if !batch.cancelled && refreshLocksAfterOperation {
                locks = []; fileMetadata = [:]; checked = []; selection = []
                do { locks = try await query(cancellation); fileMetadata = await repository.statusListMetadata(paths: locks.map(\.path)); hasLFS = try await repository.hasLFS(); checked = Set(locks.map(\.id)); selection.formIntersection(checked) }
                catch { self.error = "Operation results are retained. Refresh failed: " + error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription; information = "Could not \(operationLocked ? "lock" : "unlock") files." }
    }
    func finishProgress() { guard !busy, !confirmingQuit else { return }; showingProgress = false }
}

struct LFSLocksDialog: View {
    @ObservedObject var model: LFSLocksWindowModel
    @State private var focusedID: String?
    var body: some View {
        let rows = model.rows
        VStack(alignment: .leading, spacing: 10) {
            Table(rows, selection: $model.selection, sortOrder: Binding(get: { model.sortOrder }, set: { model.setSortOrder($0) })) {
                TableColumn("") { lock in Toggle("Select \(lock.path)", isOn: Binding(get: { model.checked.contains(lock.id) }, set: { model.setChecked(lock.id, $0) })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy || model.confirmingQuit) }.width(24)
                TableColumn("Path", sortUsing: LFSFileSort(column: .path)) { lock in HStack { Image(nsImage: MenuIcon.lock.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(lock.path) } }.width(min: 240, ideal: 420)
                TableColumn("Filename", sortUsing: LFSFileSort(column: .fileName)) { Text($0.fileName) }.width(min: 100, ideal: 180)
                TableColumn("Extension", sortUsing: LFSFileSort(column: .fileExtension)) { Text($0.fileExtension) }.width(min: 40, ideal: 75)
                TableColumn("Last modified", sortUsing: LFSFileSort(column: .lastModified)) { Text($0.metadata?.dateText ?? "–") }.width(min: 150, ideal: 170)
                TableColumn("File size", sortUsing: LFSFileSort(column: .fileSize)) { Text($0.metadata?.sizeText ?? "–") }.width(min: 70, ideal: 100)
                TableColumn("LFS Lock", sortUsing: LFSFileSort(column: .lfsOwner)) { Text($0.owner) }.width(min: 100, ideal: 160)
            }.background(CommitFileInteraction(rows: [], keyboardDeleteEnabled: false, nativeColumns: LFSLocksWindowModel.columns,
                rowTexts: rows.map { row in Dictionary(uniqueKeysWithValues: LFSLocksWindowModel.columns.map { ($0,row.text($0)) }) }, itemIDs: rows.map(\.id),
                copyIDs: { model.copy(Set($0), information: $1 ? .pathsAndStatus : .relativePaths) }, copyColumnIDs: { model.copy(Set($0), information: .column($1)) },
                toggleCheckIDs: { model.toggleChecks($0, mark: $1) }, visibleColumns: Set(model.visibleColumns), availableColumns: Set(LFSLocksWindowModel.columns),
                columnText: { _,_ in "" }, savedOrder: model.fileColumns.order, savedWidths: model.fileColumns.widths,
                saveLayout: { model.saveColumnLayout(order: $0, widths: $1) }, setColumnVisible: { model.setColumn($0, visible: $1) },
                resetColumns: { choose, accepted in model.requestResetColumns(choose: choose, onAccepted: accepted) }, focusedPath: $focusedID,
                enabled: !model.busy && !model.confirmingQuit && !model.showingProgress, delete: { _,_,_ in }, copy: { _,_ in }, copyColumn: { _,_ in }, toggleCheck: { _,_ in }))
            .contextMenu(forSelectionType: String.self) { ids in
                TurtleGitContextMenu {
                    ForEach(model.lfsActions(ids), id: \.self) { action in
                        Button { Task { await model.setSelectionLocked(ids, locked: action == .lock) } } label: {
                            CommandLabel(title: action.rawValue, icon: action == .lock ? .lock : .unlock)
                        }.disabled(model.busy || model.confirmingQuit || model.showingProgress)
                    }
                    Menu {
                        Button { model.copy(ids, information: .fullPaths) } label: { CommandLabel(title: "Full paths", icon: .copy) }
                        Button { model.copy(ids, information: .relativePaths) } label: { CommandLabel(title: "Relative paths", icon: .copy) }
                        Button { model.copy(ids, information: .names) } label: { CommandLabel(title: "File/folder names", icon: .copy) }
                        Button { model.copy(ids, information: .all) } label: { CommandLabel(title: "Copy all information to clipboard", icon: .copy) }
                    } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }.disabled(ids.isEmpty)
                }
            }.disabled(model.busy || model.confirmingQuit)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.information).font(.caption); Spacer(); Button("Refresh") { Task { await model.refresh() } }.disabled(model.busy || model.confirmingQuit).keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: []) }
            HStack {
                SelectionAllCheckbox(checked: model.locks.filter { model.checked.contains($0.id) }.count, total: model.locks.count, checkedCount: { model.locks.filter { model.checked.contains($0.id) }.count }) { model.selectAll($0) }.frame(width: 190, height: 22).disabled(model.busy || model.confirmingQuit)
                Toggle("Force", isOn: Binding(get: { model.force }, set: { model.setForce($0) })).toggleStyle(.checkbox).disabled(model.busy || model.confirmingQuit)
                Spacer()
                Button { Task { await model.unlock() } } label: { CommandLabel(title: "Unlock", icon: .unlock) }.disabled(!model.canUnlock).keyboardShortcut(.defaultAction)
                Button("Cancel") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-unlock.adoc")!) }
            }.disabled(model.confirmingQuit)
        }.padding(12)
    }
}
struct LFSUnlockProgress: View {
    @ObservedObject var model: LFSLocksWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CommandLabel(title: model.operationLocked ? "LFS Lock" : "LFS Unlock", icon: model.operationLocked ? .lock : .unlock).font(.headline)
            Table(model.results) {
                TableColumn("Path", value: \.path).width(min: 230, ideal: 340)
                TableColumn("Result") { result in Text(result.success ? (model.operationLocked ? "Locked" : "Unlocked") : "Failed").foregroundStyle(result.success ? .green : .red) }.width(80)
                TableColumn("Message", value: \.output).width(min: 170, ideal: 330)
            }.frame(minHeight: 200)
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.information).textSelection(.enabled)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if !model.busy && !model.operationLocked && model.results.contains(where: { !$0.success }) {
                    Button { Task { await model.unlock(forceRetry: true) } } label: { CommandLabel(title: "Force unlock", icon: .unlock) }.disabled(model.confirmingQuit)
                }
                Spacer()
                if model.busy { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
                else { Button("Close") { model.finishProgress() }.keyboardShortcut(.defaultAction).disabled(model.confirmingQuit) }
            }
        }.padding(14).frame(width: 760, height: 390).interactiveDismissDisabled(model.busy || model.confirmingQuit)
    }
}

/// Status lists with the optional owner column hidden match upstream's two actions.
@MainActor enum LFSLockingSelection {
    static func isAvailable(_ entries: [StatusEntry], hasLFS: Bool, root: URL, directories: Set<String>) -> Bool {
        guard hasLFS, !entries.isEmpty else { return false }
        return entries.allSatisfy { entry in
            guard entry.state != .conflicted, !directories.contains(entry.path) else { return false }
            var directory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.path).path, isDirectory: &directory)
            return !directory.boolValue
        }
    }
}

/// Shared progress sheet for Commit and Working Tree; the owner remains busy
/// through result review so a new Git operation cannot overlap the batch.
@MainActor final class LFSFileOperationController: NSWindowController, NSWindowDelegate {
    let model: LFSLocksWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = LFSLocksWindowModel(repository: repository, access: access)
        model.refreshLocksAfterOperation = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 390), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: LFSUnlockProgress(model: model))
        super.init(window: window); window.delegate = self
        model.onProgressVisibility = { [weak self] visible in if !visible { self?.finish() } }
    }
    func present(owner: NSWindow, paths: [String], locked: Bool) {
        guard owner.attachedSheet == nil, let window else { return }
        window.title = locked ? "LFS Lock – TurtleGit" : "LFS Unlock – TurtleGit"
        model.operationLocked = locked
        owner.beginSheet(window)
        Task { await model.perform(paths: paths, locked: locked) }
    }
    private func finish() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil); window.close(); onClosed()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct LFSListRow: Identifiable {
    let lock: LFSLock
    let metadata: StatusListMetadata?
    var id: String { lock.id }
    var path: String { lock.path }
    var owner: String { lock.owner }
    var fileName: String { (path as NSString).lastPathComponent }
    var fileExtension: String { StatusListClipboard.fileExtension(path, isDirectory: metadata?.isDirectory == true) }
    func text(_ column: StatusListColumn) -> String {
        switch column {
        case .path: return path
        case .fileName: return fileName
        case .fileExtension: return fileExtension
        case .lastModified: return metadata?.dateText ?? "–"
        case .fileSize: return metadata?.sizeText ?? "–"
        case .lfsOwner: return owner
        case .status: return "Unknown"
        case .added, .removed: return ""
        }
    }
}
struct LFSFileSort: SortComparator {
    var column: StatusListColumn
    var order: SortOrder = .forward
    func compare(_ lhs: LFSListRow, _ rhs: LFSListRow) -> ComparisonResult {
        func text(_ a: String, _ b: String, numeric: Bool = true) -> ComparisonResult {
            a.compare(b, options: numeric ? [.caseInsensitive,.numeric] : [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        var result: ComparisonResult
        switch column {
        case .lastModified:
            let a = lhs.metadata?.modificationDate ?? .distantPast, b = rhs.metadata?.modificationDate ?? .distantPast
            result = a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        case .fileSize:
            let a = lhs.metadata?.size ?? 0, b = rhs.metadata?.size ?? 0
            result = a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        default: result = text(lhs.text(column), rhs.text(column), numeric: column != .lfsOwner)
        }
        if result == .orderedSame { result = text(lhs.path,rhs.path) }
        if result == .orderedSame && !lhs.path.utf8.elementsEqual(rhs.path.utf8) { result = lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8) ? .orderedAscending : .orderedDescending }
        if result == .orderedSame { result = text(lhs.id,rhs.id) }
        return order == .forward ? result : result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
    }
}
