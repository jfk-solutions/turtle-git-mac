import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class LFSLocksWindowController: NSWindowController, NSWindowDelegate {
    let model: LFSLocksWindowModel
    var onClosed: () -> Void = {}
    private var progressWindow: NSWindow?
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = LFSLocksWindowModel(repository: repository, access: access)
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
            sheet.title = "LFS Unlock – TurtleGit"; sheet.isReleasedWhenClosed = false
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
    @Published var checked = Set<String>()
    @Published var selection = Set<String>()
    @Published var sortOrder = [KeyPathComparator(\LFSLock.path)]
    @Published var force = false
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var information = ""
    @Published var results: [LFSFileResult] = []
    @Published var showingProgress = false { didSet { if oldValue != showingProgress { onProgressVisibility(showingProgress) } } }
    private var cancellation = OperationCancellation()
    private var batchID = UUID()
    private var operationPaths: [String] = []
    var onProgressVisibility: (Bool) -> Void = { _ in }
    var close: () -> Void = {}
    var query: (OperationCancellation) async throws -> [LFSLock]
    var change: ([String], Bool, OperationCancellation, @escaping @Sendable (LFSFileResult) -> Void) async throws -> LFSBatchResult
    var canUnlock: Bool { !busy && !confirmingQuit && locks.contains { checked.contains($0.id) } }
    var rows: [LFSLock] { locks.sorted(using: sortOrder) }
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        self.repository = repository; self.access = access
        query = { try await repository.lfsLocks(cancellation: $0) }
        change = { try await repository.setLFSLocked(paths: $0, locked: false, force: $1, cancellation: $2, onResult: $3) }
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
    func unlockSelection(_ ids: Set<String>) async {
        guard !busy, !confirmingQuit, !showingProgress else { return }
        checked = ids.intersection(Set(locks.map(\.id))); await unlock()
    }
    func cancel() { guard busy else { return }; cancellation.cancel(); information = "Cancelling…" }
    func refresh() async {
        guard !busy, !confirmingQuit, !showingProgress else { return }
        busy = true; error = nil; locks = []; checked = []; selection = []; cancellation = OperationCancellation(); information = "Getting LFS locks…"
        defer { busy = false }
        do {
            try validateAccess()
            locks = try await query(cancellation); checked = Set(locks.map(\.id)); selection.formIntersection(checked)
            information = "\(locks.count) locked file(s)."
        } catch { self.error = error.localizedDescription; information = cancellation.isCancelled ? "Cancelled." : "Could not get LFS locks." }
    }
    func unlock(forceRetry: Bool = false) async {
        guard !busy, !confirmingQuit else { return }
        guard forceRetry || !showingProgress else { return }
        if !forceRetry { operationPaths = rows.filter { checked.contains($0.id) }.map(\.path) }
        guard !operationPaths.isEmpty, !forceRetry || showingProgress && results.contains(where: { !$0.success }) else { return }
        let useForce = forceRetry || force
        busy = true; showingProgress = true; results = []; error = nil
        cancellation = OperationCancellation(); batchID = UUID(); let generation = batchID
        information = "Unlocking \(operationPaths.count) file(s)…"
        defer { busy = false }
        do {
            try validateAccess()
            let batch = try await change(operationPaths, useForce, cancellation) { [weak self] file in
                Task { @MainActor in
                    guard let self, self.busy, self.batchID == generation else { return }
                    self.results.append(file)
                }
            }
            results = batch.files
            information = batch.cancelled ? "Cancelled. Completed server changes remain; refresh to verify lock state." : "\(results.filter(\.success).count) of \(operationPaths.count) file(s) unlocked."
            if !batch.cancelled {
                locks = []; checked = []; selection = []
                do { locks = try await query(cancellation); checked = Set(locks.map(\.id)); selection.formIntersection(checked) }
                catch { self.error = "Unlock results are retained. Refresh failed: " + error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription; information = "Could not unlock files." }
    }
    func finishProgress() { guard !busy, !confirmingQuit else { return }; showingProgress = false }
}

struct LFSLocksDialog: View {
    @ObservedObject var model: LFSLocksWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
                TableColumn("") { lock in Toggle("Select \(lock.path)", isOn: Binding(get: { model.checked.contains(lock.id) }, set: { model.setChecked(lock.id, $0) })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy || model.confirmingQuit) }.width(24)
                TableColumn("Path", value: \.path) { lock in HStack { Image(nsImage: MenuIcon.lock.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(lock.path) } }.width(min: 240, ideal: 420)
                TableColumn("Extension") { lock in Text(StatusListClipboard.fileExtension(lock.path)) }.width(min: 40, ideal: 75)
                TableColumn("LFS Lock", value: \.owner).width(min: 100, ideal: 160)
            }.contextMenu(forSelectionType: String.self) { ids in
                TurtleGitContextMenu {
                    Button { Task { await model.unlockSelection(ids) } } label: { CommandLabel(title: "LFS Unlock", icon: .unlock) }.disabled(ids.isEmpty || model.busy || model.confirmingQuit)
                }
            }.disabled(model.busy || model.confirmingQuit)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.information).font(.caption); Spacer(); Button("Refresh") { Task { await model.refresh() } }.disabled(model.busy || model.confirmingQuit).keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: []) }
            HStack {
                Toggle("Select/deselect all", isOn: Binding(get: { !model.locks.isEmpty && model.checked.count == model.locks.count }, set: { model.selectAll($0) })).toggleStyle(.checkbox).disabled(model.busy || model.confirmingQuit)
                Toggle("Force", isOn: Binding(get: { model.force }, set: { model.setForce($0) })).toggleStyle(.checkbox).disabled(model.busy || model.confirmingQuit)
                Spacer()
                Button { Task { await model.unlock() } } label: { CommandLabel(title: "Unlock", icon: .unlock) }.disabled(!model.canUnlock).keyboardShortcut(.defaultAction)
                Button("Cancel") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-unlock.adoc")!) }
            }.disabled(model.confirmingQuit)
        }.padding(12)
    }
}
private struct LFSUnlockProgress: View {
    @ObservedObject var model: LFSLocksWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CommandLabel(title: "LFS Unlock", icon: .unlock).font(.headline)
            Table(model.results) {
                TableColumn("Path", value: \.path).width(min: 230, ideal: 340)
                TableColumn("Result") { result in Text(result.success ? "Unlocked" : "Failed").foregroundStyle(result.success ? .green : .red) }.width(80)
                TableColumn("Message", value: \.output).width(min: 170, ideal: 330)
            }.frame(minHeight: 200)
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.information).textSelection(.enabled)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if !model.busy && model.results.contains(where: { !$0.success }) {
                    Button { Task { await model.unlock(forceRetry: true) } } label: { CommandLabel(title: "Force unlock", icon: .unlock) }.disabled(model.confirmingQuit)
                }
                Spacer()
                if model.busy { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
                else { Button("Close") { model.finishProgress() }.keyboardShortcut(.defaultAction).disabled(model.confirmingQuit) }
            }
        }.padding(14).frame(width: 760, height: 390).interactiveDismissDisabled(model.busy || model.confirmingQuit)
    }
}
