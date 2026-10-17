import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class LFSLocksWindowController: NSWindowController, NSWindowDelegate {
    let model: LFSLocksWindowModel
    var onClosed: () -> Void = {}
    var onPullAfterLock: () -> Void = {}
    private var progressWindow: NSWindow?
    private var closed = false
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        model = LFSLocksWindowModel(repository: repository, access: access, defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 490), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "LFS Locks", preferences: defaults)
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 570, height: 330)
        let host = NSHostingController(rootView: LFSLocksDialog(model: model).defaultAppStorage(defaults)); host.sizingOptions = []; window.contentViewController = host
        super.init(window: window); window.delegate = self; window.setContentSize(NSSize(width: 760, height: 490)); window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.onProgressVisibility = { [weak self] visible in self?.setProgressPresented(visible) }
        model.onPullAfterLock = { [weak self] in self?.onPullAfterLock() }
        DialogGeometry.attach(window, identifier: "LFSLocksDlg", legacyName: "LFSLocksDlg")
    }
    private func setProgressPresented(_ visible: Bool) {
        guard let window else { return }
        if visible {
            guard progressWindow == nil else { return }
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 390), styleMask: [.titled], backing: .buffered, defer: false)
            RepositoryWindowTitles.set(sheet, repository: model.repository.root, location: model.progressLocation, dialog: model.operationLocked ? "LFS Lock" : "LFS Unlock", preferences: model.presentationPreferences); TurtleGitHelp.attach(sheet, topic: .lfs); sheet.isReleasedWhenClosed = false
            sheet.contentViewController = NSHostingController(rootView: LFSUnlockProgress(model: model).defaultAppStorage(model.presentationPreferences))
            model.progressActions.window = sheet
            progressWindow = sheet; window.beginSheet(sheet, completionHandler: nil)
        } else if let sheet = progressWindow {
            if sheet.sheetParent === window { window.endSheet(sheet) }
            sheet.orderOut(nil); sheet.close(); progressWindow = nil
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        return !model.confirmingQuit && !model.showingProgress && sender.attachedSheet == nil
    }
    func windowWillClose(_ notification: Notification) { guard !closed else { return }; closed = true; model.retire(); setProgressPresented(false); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class LFSLocksWindowModel: ObservableObject, ActionLogProgress {
    private(set) static var activeOperations = 0
    private(set) var retired = false
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var locks: [LFSLock] = [] { didSet { menuGeneration = UUID() } }
    @Published var hasLFS = false { didSet { menuGeneration = UUID() } }
    @Published var checked = Set<String>() {
        didSet { for lock in locks { checkedPaths[lock.path] = checked.contains(lock.id) } }
    }
    private var menuGeneration = UUID()
    struct MenuTarget {
        let owner: ObjectIdentifier
        let generation: UUID
        let rows: [LFSListRow]
        let columns: [StatusListColumn]
        let actions: [LFSLockMenuAction]
    }
    func menuTarget(_ ids: Set<String>) -> MenuTarget? {
        guard menuAvailable else { return nil }
        let selected = rows.filter { ids.contains($0.id) }
        guard !ids.isEmpty, selected.count == ids.count else { return nil }
        return MenuTarget(owner: ObjectIdentifier(self), generation: menuGeneration, rows: selected, columns: visibleColumns, actions: lfsActions(ids))
    }
    private var menuAvailable: Bool { !retired && !busy && !confirmingQuit && !showingProgress }
    func accepts(_ target: MenuTarget) -> Bool { menuAvailable && target.owner == ObjectIdentifier(self) && target.generation == menuGeneration }
    func copy(_ target: MenuTarget, information: StatusListCopy) {
        guard accepts(target) else { return }
        let text = clipboardText(selected: target.rows, copy: information, visible: target.columns)
        if !text.isEmpty { publishClipboard(text) }
    }
    func setSelectionLocked(_ target: MenuTarget, locked: Bool) async {
        guard accepts(target), target.actions.contains(locked ? .lock : .unlock) else { return }
        await perform(paths: target.rows.map(\.path), locked: locked)
    }
    var publishClipboard: (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) }
    private var checkedPaths: [String: Bool] = [:]
    @Published var selection = Set<String>()
    @Published var sortOrder = [LFSFileSort(column: .path)]
    @Published var fileColumns: StatusListColumnSettings { didSet { menuGeneration = UUID() } }
    @Published var fileMetadata: GitPathMap<StatusListMetadata> = [:] { didSet { menuGeneration = UUID() } }
    var presentationPreferences: UserDefaults { defaults }
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
    @Published private(set) var notifications: [LFSProgressRow] = []
    @Published private(set) var currentPath = ""
    private var attemptStarted = false
    private var operationCancelled = false
    private var operationFailed = false
    private var startedPaths = Set<String>()
    private var fileStarted: @Sendable (String) -> Void = { _ in }
    var actionLogRepository: URL { repository.root }
    var actionLogFailed: Bool { operationFailed }
    var actionLogCancelled: Bool { operationCancelled || cancellation.isCancelled }
    var actionLogEligible: Bool { attemptStarted }
    var output: String { notifications.map { $0.action + "\t" + $0.text }.joined(separator: "\n") + "\n" }
    var progressTotal: Int { operationPaths.count }
    var progressLocation: URL { RepositoryPresentationSettings.scopedLocation(repository: repository.root, paths: operationPaths, wholeProject: false) }
    func progressRowsAvailable(_ generation: UUID) -> Bool { !retired && !busy && !progressActionBusy && !confirmingQuit && showingProgress && batchID == generation }
    var progressGeneration: UUID { batchID }
    lazy var progressActions = LFSProgressActionHost(model: self, access: access)
    @Published private(set) var progressActionBusy = false
    var progressActionToken: UUID?
    var onProgressLog: ((String) -> Void)?
    var progressActionHandler: ((LFSProgressCommand, String) async throws -> Void)?
    func progressTarget(_ rows: [LFSProgressRow]) -> LFSProgressTarget? {
        guard progressRowsAvailable(batchID), !rows.isEmpty,
              rows.allSatisfy({ row in notifications.contains { $0.id == row.id } }) else { return nil }
        return LFSProgressTarget(generation: batchID, rows: rows)
    }
    func progressCommand(_ command: LFSProgressCommand, target: LFSProgressTarget) async {
        guard progressRowsAvailable(target.generation), let row = target.file else { return }
        if command == .open || command == .openWith {
            guard !progressActions.isDirectory(row.text) else { return }
        }
        let token = UUID(); progressActionToken = token; progressActionBusy = true
        Self.activeOperations += 1
        defer { progressActionBusy = false; progressActionToken = nil; Self.activeOperations -= 1; withExtendedLifetime(access) {} }
        do {
            try validateAccess()
            if let progressActionHandler { try await progressActionHandler(command, row.text) }
            else { try await progressActions.perform(command, path: row.text, token: token) }
        } catch { if !retired, progressGeneration == target.generation { self.error = error.localizedDescription } }
    }
    func progressDoubleClick(_ row: LFSProgressRow) async {
        guard let target = progressTarget([row]), target.file != nil else { return }
        await progressCommand(progressActions.isDirectory(row.text) ? .explore : .open, target: target)
    }
    func copyProgressKeyboard(_ text: String, generation: UUID) {
        guard !retired, !confirmingQuit, showingProgress, batchID == generation, !text.isEmpty else { return }
        publishClipboard(text)
    }
    func copyProgress(_ text: String, generation: UUID) { guard progressRowsAvailable(generation), !text.isEmpty else { return }; publishClipboard(text) }
    @Published var operationLocked = false
    @Published var showingProgress = false { didSet { if oldValue != showingProgress { onProgressVisibility(showingProgress) } } }
    private var cancellation = OperationCancellation()
    private var batchID = UUID()
    private var acceptingBatchResults = false
    private var operationPaths: [String] = []
    private var operationForce = false
    private var resetTargetChecks = false
    private var refreshAfterReview = false
    var onProgressVisibility: (Bool) -> Void = { _ in }
    var onPullAfterLock: () -> Void = {}
    var captureListPosition: () -> Void = {}
    var cancelListPosition: () -> Void = {}
    var restoreListPosition: ([String], Bool) async -> Void = { _,_ in }
    private var rememberListPosition: Bool { (defaults.object(forKey: "RememberFileListPosition") as? NSNumber)?.boolValue ?? true }
    private func restoreChecks() async {
        checked = Set(locks.filter { checkedPaths[$0.path] ?? true }.map(\.id))
        await restoreListPosition(rows.map(\.id), rememberListPosition)
    }
    var refreshLocksAfterOperation = true
    var close: () -> Void = {}
    var query: (OperationCancellation) async throws -> [LFSLock]
    var change: ([String], Bool, OperationCancellation, @escaping @Sendable (LFSFileResult) -> Void) async throws -> LFSBatchResult = { _,_,_,_ in throw LFSLocksFailure.selection }
    var lockChange: ([String], OperationCancellation, @escaping @Sendable (LFSFileResult) -> Void) async throws -> LFSBatchResult = { _,_,_ in throw LFSLocksFailure.selection }
    var canUnlock: Bool { !retired && !busy && !confirmingQuit && !showingProgress && locks.contains { checked.contains($0.id) } }
    var rows: [LFSListRow] { locks.map { LFSListRow(lock: $0, metadata: fileMetadata[$0.path]) }.sorted(using: sortOrder) }
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.defaults = defaults
        fileColumns = defaults.integer(forKey: Self.columnKey + ".Version") == 1 ? .load(from: defaults, key: Self.columnKey) : Self.defaultColumns
        query = { try await repository.lfsLocks(cancellation: $0) }
        change = { [weak self] paths, force, token, report in
            let started = self?.fileStarted
            return try await repository.setLFSLocked(paths: paths, locked: false, force: force, cancellation: token, onFileStarted: started, onResult: report)
        }
        lockChange = { [weak self] paths, token, report in
            let started = self?.fileStarted
            return try await repository.setLFSLocked(paths: paths, locked: true, cancellation: token, onFileStarted: started, onResult: report)
        }
    }
    func setSortOrder(_ order: [LFSFileSort]) {
        guard !retired, !busy, !confirmingQuit, !showingProgress else { return }
        sortOrder = Array(order.filter { Self.columns.contains($0.column) }.prefix(1))
    }
    func setColumn(_ column: StatusListColumn, visible: Bool) {
        guard !retired, !busy, !confirmingQuit, !showingProgress, column != .path, Self.columns.contains(column) else { return }
        menuGeneration = UUID()
        if visible { fileColumns.visible.insert(column) } else { fileColumns.visible.remove(column) }
        fileColumns.save(to: defaults, key: Self.columnKey)
    }
    @discardableResult func saveColumnLayout(order: [StatusListColumn], widths: [StatusListColumn: Double]) -> Bool {
        guard !retired, !busy, !confirmingQuit, !showingProgress else { return false }
        let next = StatusListColumnSettings(visible: fileColumns.visible, order: order, widths: widths)
        if fileColumns != next { menuGeneration = UUID(); fileColumns = next; fileColumns.save(to: defaults, key: Self.columnKey) }
        return true
    }
    func requestResetColumns(choose: @escaping () async -> Bool, onAccepted: @escaping () -> Void) {
        guard !retired, !busy, !confirmingQuit, !showingProgress else { return }
        busy = true; Self.activeOperations += 1
        Task {
            defer { busy = false; Self.activeOperations -= 1; withExtendedLifetime(access) {} }
            guard await choose(), !retired, !confirmingQuit else { return }
            menuGeneration = UUID(); fileColumns = Self.defaultColumns; fileColumns.save(to: defaults, key: Self.columnKey); onAccepted()
        }
    }
    func clipboardText(_ ids: Set<String>, copy: StatusListCopy) -> String {
        clipboardText(selected: rows.filter { ids.contains($0.id) }, copy: copy, visible: visibleColumns)
    }
    private func clipboardText(selected: [LFSListRow], copy: StatusListCopy, visible: [StatusListColumn]) -> String {
        guard !selected.isEmpty else { return "" }
        let columns: [StatusListColumn]
        switch copy {
        case .all: columns = visible
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
        guard let target = menuTarget(ids) else { return }; copy(target, information: information)
    }
    func checkClicked(_ id: String, value: Bool) {
        guard menuAvailable else { return }
        let targets: Set<String> = selection.contains(id) ? selection : [id]
        for id in targets { setChecked(id, value) }
    }
    func toggleChecks(_ ids: [String], mark: String) {
        guard !retired, !busy, !confirmingQuit, !showingProgress, locks.contains(where: { $0.id == mark }) else { return }
        let value = !checked.contains(mark)
        for id in ids { setChecked(id, value) }
    }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func setChecked(_ id: String, _ value: Bool) {
        guard !retired, !busy, !confirmingQuit, !showingProgress, locks.contains(where: { $0.id == id }) else { return }
        if value { checked.insert(id) } else { checked.remove(id) }
    }
    func selectAll(_ value: Bool) {
        guard !retired, !busy, !confirmingQuit, !showingProgress else { return }; checked = value ? Set(locks.map(\.id)) : []
    }
    func setForce(_ value: Bool) { guard !retired, !busy, !confirmingQuit, !showingProgress else { return }; force = value }
    func lfsActions(_ ids: Set<String>) -> [LFSLockMenuAction] {
        let selected = rows.filter { ids.contains($0.id) }
        guard !retired, hasLFS, !ids.isEmpty, selected.count == ids.count,
              selected.allSatisfy({ $0.metadata?.isDirectory != true }) else { return [] }
        return LFSLockMenu.actions(paths: selected.map(\.path), ownersVisible: fileColumns.visible.contains(.lfsOwner),
            lockedPaths: Set(locks.map(\.path)), ownershipKnown: true)
    }
    func setSelectionLocked(_ ids: Set<String>, locked: Bool) async {
        guard !retired, !busy, !confirmingQuit, !showingProgress,
              lfsActions(ids).contains(locked ? .lock : .unlock) else { return }
        await perform(paths: rows.filter { ids.contains($0.id) }.map(\.path), locked: locked)
    }
    func retire() {
        guard !retired else { return }; retired = true
        if !busy { saveActionLog() }; menuGeneration = UUID()
        progressActionToken = nil; progressActions.retire()
        cancellation.cancel(); batchID = UUID(); acceptingBatchResults = false
        refreshAfterReview = false
        onPullAfterLock = {}; onProgressVisibility = { _ in }; showingProgress = false
        cancelListPosition()
    }
    func cancel() { guard !retired, busy else { return }; cancellation.cancel(); information = "Cancelling…" }
    func refresh() async {
        guard !retired, !busy, !confirmingQuit, !showingProgress else { return }
        await reloadLocks(afterOperation: false)
    }
    private func reloadLocks(afterOperation: Bool) async {
        guard !retired else { return }
        captureListPosition()
        busy = true; error = nil; locks = []; fileMetadata = [:]; checked = []; selection = []; cancellation = OperationCancellation()
        let token = cancellation; Self.activeOperations += 1
        if !afterOperation { information = "Getting LFS locks…" }
        defer { busy = false; Self.activeOperations -= 1 }
        do {
            try validateAccess()
            let reply = try await query(token)
            guard !retired, !token.isCancelled else { if !retired { information = "Cancelled." }; return }
            let metadata = await repository.statusListMetadata(paths: reply.map(\.path))
            let installed = try await repository.hasLFS(cancellation: token)
            guard !retired, !token.isCancelled else { if !retired { information = "Cancelled." }; return }
            locks = reply; fileMetadata = metadata; hasLFS = installed
            await restoreChecks()
            guard !retired else { return }
            if !afterOperation { information = "\(locks.count) locked file(s)." }
        } catch {
            guard !retired else { return }
            locks = []; fileMetadata = [:]; checked = []; selection = []; hasLFS = false
            await restoreListPosition([], rememberListPosition)
            guard !retired else { return }
            self.error = token.isCancelled ? nil : afterOperation ? "Operation results are retained. Refresh failed: " + error.localizedDescription : error.localizedDescription
            if !afterOperation { information = token.isCancelled ? "Cancelled." : "Could not get LFS locks." }
        }
    }
    func unlock(forceRetry: Bool = false) async {
        guard !retired, !busy, !confirmingQuit, !forceRetry || !operationLocked else { return }
        guard forceRetry || !showingProgress else { return }
        if !forceRetry { operationLocked = false; operationForce = force; resetTargetChecks = false; operationPaths = rows.filter { checked.contains($0.id) }.map(\.path) }
        await runOperation(forceRetry: forceRetry)
    }
    func perform(paths: [String], locked: Bool) async {
        guard !retired, !busy, !confirmingQuit, !showingProgress, !paths.isEmpty else { return }
        operationPaths = paths; operationLocked = locked; operationForce = false; resetTargetChecks = true
        await runOperation(forceRetry: false)
    }
    private func runOperation(forceRetry: Bool) async {
        guard !retired, !progressActionBusy, !operationPaths.isEmpty, !forceRetry || showingProgress && results.contains(where: { !$0.success }) else { return }
        ProgressActionLog.nextAttempt(self); attemptStarted = true
        let began = ProcessInfo.processInfo.systemUptime
        let useForce = !operationLocked && (forceRetry || operationForce)
        refreshAfterReview = refreshLocksAfterOperation
        busy = true; showingProgress = true; results = []; error = nil
        cancellation = OperationCancellation(); batchID = UUID(); acceptingBatchResults = true; let generation = batchID
        menuGeneration = UUID(); notifications = []; currentPath = ""; startedPaths = []
        operationCancelled = false; operationFailed = false
        appendNotification(action: "Command", text: operationLocked ? "Lock" : "Unlock", kind: .command)
        let mailbox = LFSProgressMailbox()
        fileStarted = { [weak self] path in
            mailbox.append(.started(path))
            Task { @MainActor in self?.drain(mailbox, generation: generation) }
        }
        Self.activeOperations += 1
        information = "\(operationLocked ? "Locking" : "Unlocking") \(operationPaths.count) file(s)…"
        var openPull = false
        defer {
            busy = false; acceptingBatchResults = false; fileStarted = { _ in }; Self.activeOperations -= 1
            if !retired {
                let completion = LFSProgressRow.completion(success: !operationFailed && !operationCancelled, elapsed: ProcessInfo.processInfo.systemUptime - began)
                appendNotification(action: "Finished!", text: completion, kind: !operationFailed && !operationCancelled ? .finishedSuccess : .finishedFailure)
            } else { saveActionLog() }
            withExtendedLifetime(access) {}
            if !retired && openPull { onPullAfterLock() }
        }
        do {
            try validateAccess()
            let report: @Sendable (LFSFileResult) -> Void = { [weak self] file in
                mailbox.append(.result(file))
                Task { @MainActor in self?.drain(mailbox, generation: generation) }
            }
            let batch: LFSBatchResult
            if operationLocked { batch = try await lockChange(operationPaths, cancellation, report) }
            else { batch = try await change(operationPaths, useForce, cancellation, report) }
            guard !retired, batchID == generation else { return }
            drain(mailbox, generation: generation); acceptingBatchResults = false
            results = batch.files
            notifications = []; startedPaths = []
            appendNotification(action: "Command", text: operationLocked ? "Lock" : "Unlock", kind: .command)
            for result in batch.files { record(result, appendResult: false) }
            operationCancelled = batch.cancelled || cancellation.isCancelled
            operationFailed = batch.files.contains { !$0.success }
            if operationCancelled { appendNotification(action: "Error", text: "User cancelled", kind: .error) }
            openPull = operationLocked && !batch.cancelled && !cancellation.isCancelled &&
                batch.files.count == operationPaths.count && batch.files.allSatisfy(\.success)
            information = batch.cancelled || cancellation.isCancelled ? "Cancelled. Completed server changes remain; refresh to verify lock state." : "\(results.filter(\.success).count) of \(operationPaths.count) file(s) \(operationLocked ? "locked" : "unlocked")."
        } catch {
            guard !retired else { return }
            drain(mailbox, generation: generation)
            operationCancelled = cancellation.isCancelled; operationFailed = !operationCancelled
            appendNotification(action: "Error", text: operationCancelled ? "User cancelled" : error.localizedDescription, kind: .error)
            if cancellation.isCancelled {
                self.error = nil; information = "Cancelled. Completed server changes remain; refresh to verify lock state."
            } else { self.error = error.localizedDescription; information = "Could not \(operationLocked ? "lock" : "unlock") files." }
        }
    }
    private func appendNotification(action: String, text: String, kind: LFSProgressRow.Kind) {
        for line in (kind == .file ? [text] : text.components(separatedBy: .newlines)) where !line.isEmpty {
            notifications.append(LFSProgressRow(id: batchID.uuidString + ":" + String(notifications.count), action: action, text: line, kind: kind))
        }
    }
    private func recordStart(_ path: String) {
        currentPath = path
        if startedPaths.insert(path).inserted { appendNotification(action: operationLocked ? "Lock" : "Unlock", text: path, kind: .file) }
    }
    private func record(_ result: LFSFileResult, appendResult: Bool = true) {
        recordStart(result.path)
        if appendResult { results.append(result) }
        if !result.success { appendNotification(action: "Error", text: result.output, kind: .error) }
    }
    private func drain(_ mailbox: LFSProgressMailbox, generation: UUID) {
        guard !retired, busy, acceptingBatchResults, batchID == generation else { return }
        for event in mailbox.drain() { switch event { case .started(let path): recordStart(path); case .result(let file): record(file) } }
    }
    func finishProgress() {
        guard !retired, !busy, !progressActionBusy, !confirmingQuit, showingProgress else { return }
        saveActionLog()
        if resetTargetChecks { for path in operationPaths { checkedPaths.removeValue(forKey: path) } }
        let reload = refreshAfterReview; refreshAfterReview = false
        // Block a new batch before detaching the results sheet. Each dismissal
        // refreshes once, even after cancellation or a failed operation.
        if reload { busy = true }
        showingProgress = false
        if reload { Task { await reloadLocks(afterOperation: true) } }
    }
}

struct LFSLocksDialog: View {
    @ObservedObject var model: LFSLocksWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LFSLocksTable(model: model)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.information).font(.caption); Spacer(); Button("Refresh") { Task { await model.refresh() } }.disabled(model.busy || model.confirmingQuit).keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: []) }
            HStack {
                SelectionAllCheckbox(checked: model.locks.filter { model.checked.contains($0.id) }.count, total: model.locks.count, checkedCount: { model.locks.filter { model.checked.contains($0.id) }.count }) { model.selectAll($0) }.frame(width: 190, height: 22).disabled(model.busy || model.confirmingQuit)
                Toggle("Force", isOn: Binding(get: { model.force }, set: { model.setForce($0) })).toggleStyle(.checkbox).disabled(model.busy || model.confirmingQuit)
                Spacer()
                Button { Task { await model.unlock() } } label: { CommandLabel(title: "Unlock", icon: .unlock) }.disabled(!model.canUnlock).keyboardShortcut(.defaultAction)
                Button("Cancel") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction)
                Button("Help") { TurtleGitHelp.show(.lfs) }
            }.disabled(model.confirmingQuit)
        }.padding(12)
    }
}
struct LFSUnlockProgress: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: LFSLocksWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CommandLabel(title: model.operationLocked ? "LFS Lock" : "LFS Unlock", icon: model.operationLocked ? .lock : .unlock).font(.headline)
            LFSProgressTable(model: model).frame(minHeight: 200)
            HStack {
                Text(model.currentPath).lineLimit(1).truncationMode(.middle).help(model.currentPath)
                Spacer()
                if model.progressTotal > 0 { ProgressView(value: Double(model.results.count), total: Double(model.progressTotal)).frame(width: 220) }
            }
            if model.busy || model.progressActionBusy { ProgressView().controlSize(.small) }
            Text(model.information).textSelection(.enabled)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if !model.busy && !model.operationLocked && model.results.contains(where: { !$0.success }) {
                    Button { Task { await model.unlock(forceRetry: true) } } label: { CommandLabel(title: "Force unlock", icon: .unlock) }.disabled(model.confirmingQuit || model.progressActionBusy)
                }
                Spacer()
                if model.busy { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
                else { Button("Close") { model.finishProgress() }.keyboardShortcut(.defaultAction).disabled(model.confirmingQuit || model.progressActionBusy) }
            }
        }.padding(14).frame(width: 760, height: 390).interactiveDismissDisabled(model.busy || model.progressActionBusy || model.confirmingQuit)
    }
}

/// Status lists with the optional owner column hidden match upstream's two actions.
@MainActor enum LFSLockingSelection {
    static func isAvailable(_ entries: [StatusEntry], hasLFS: Bool, root: URL, directories paths: some Sequence<String>) -> Bool {
        let directories = GitPathSet(paths)
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
    var standalonePresentation: ((NSWindow) -> Void)?
    private var started = false, finished = false
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        model = LFSLocksWindowModel(repository: repository, access: access, defaults: defaults)
        model.refreshLocksAfterOperation = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 390), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: LFSUnlockProgress(model: model).defaultAppStorage(model.presentationPreferences))
        super.init(window: window); window.delegate = self
        model.progressActions.window = window
        model.onProgressVisibility = { [weak self] visible in if !visible { self?.finish() } }
    }
    @discardableResult func present(owner: NSWindow? = nil, paths: [String], locked: Bool) -> Bool {
        guard !started, !finished, !model.retired, owner?.attachedSheet == nil, let window else { return false }
        started = true
        RepositoryWindowTitles.set(window, repository: model.repository.root, location: RepositoryPresentationSettings.scopedLocation(repository: model.repository.root, paths: paths, wholeProject: false), dialog: locked ? "LFS Lock" : "LFS Unlock", preferences: model.presentationPreferences); TurtleGitHelp.attach(window, topic: .lfs)
        model.operationLocked = locked
        if let owner { owner.beginSheet(window, completionHandler: nil) }
        else if let standalonePresentation { standalonePresentation(window) }
        else { window.center(); showWindow(nil); window.makeKeyAndOrderFront(nil) }
        Task { await model.perform(paths: paths, locked: locked) }
        return true
    }
    private func finish() {
        guard !finished, let window else { return }; finished = true
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil); window.close(); model.retire(); onClosed()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    func windowWillClose(_ notification: Notification) {
        model.retire()
        if let window, let parent = window.sheetParent { parent.endSheet(window); window.orderOut(nil) }
        guard !finished else { return }; finished = true; onClosed()
    }
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
