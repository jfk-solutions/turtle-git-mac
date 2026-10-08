import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

struct StatusRow: Identifiable {
    let file: WorkingTreeFile
    let statistics: CommitFile?
    var id: String { file.id }
    var path: String { file.id }
    var fileExtension: String { StatusListClipboard.fileExtension(path, isDirectory: statistics?.isSubmodule == true) }
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
}

@MainActor final class StatusWindowController: NSWindowController, NSWindowDelegate {
    let model: StatusWindowModel
    var onClosed: () -> Void = {}
    private var lfsOperation: LFSFileOperationController?
    var makeLFSOperation: (GitRepository, RepositoryAccessLease?) -> LFSFileOperationController = { LFSFileOperationController(repository: $0, access: $1) }
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        model = StatusWindowModel(repository: repository, access: access, defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 630),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Working Tree – TurtleGit"
        window.minSize = NSSize(width: 960, height: 540); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StatusDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 1100, height: 630)); window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.savePatch = { [weak self] text in self?.savePatch(text) }
        model.onLFSOperation = { [weak self, weak window] paths, locked in
            guard let self, let window, window.attachedSheet == nil, self.lfsOperation == nil else { return false }
            let progress = self.makeLFSOperation(repository, access)
            progress.onClosed = { [weak self] in
                guard let self else { return }
                self.lfsOperation = nil; self.model.busy = false; self.model.reload(); self.model.onChanged()
            }
            self.lfsOperation = progress; progress.present(owner: window, paths: paths, locked: locked)
            return true
        }


        DialogGeometry.attach(window, identifier: "StatusWindowController")
    }
    private func savePatch(_ bytes: Data) {
        guard let window else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "working-tree.patch"
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak model] response in
            guard response == .OK, let url = panel.url else { return }
            do { try bytes.write(to: url, options: .atomic) }
            catch { model?.error = error.localizedDescription }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.cancelLFSOwnerQuery() { return false }
        return !model.busy && !model.confirmingQuit && !model.unifiedViewerBusy && sender.attachedSheet == nil
    }
    func windowWillClose(_ notification: Notification) { model.unifiedWindow?.close(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class StatusWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var conflictRebase = false
    @Published var submodules = Set<String>()
    @Published var hasLFS = false
    @Published var showLFSOwners: Bool
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
    @Published var selection = Set<String>()
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
    var onAction: (RepositoryAction, [String]) -> Void = { _, _ in }
    var onChanged: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.defaults = defaults
        showLFSOwners = defaults.bool(forKey: "WorkingTree.LFSOwnerVisible")
        queryLFSOwners = { try await repository.lfsLocks(cancellation: $0) }
    }
    func setSortOrder(_ order: [StatusFileSort]) {
        guard !busy, !confirmingQuit else { return }
        sortOrder = Array(order.prefix(1))
    }
    func setShowLFSOwners(_ visible: Bool) {
        guard hasLFS, !busy, !confirmingQuit else { return }
        showLFSOwners = visible; defaults.set(visible, forKey: "WorkingTree.LFSOwnerVisible")
        if visible { reload() } else { lfsOwners = [:]; lfsLockedPaths = []; lfsOwnershipKnown = false }
    }
    @discardableResult func cancelLFSOwnerQuery() -> Bool {
        guard let ownerCancellation else { return false }
        ownerCancellation.cancel(); return true
    }

    var visibleFiles: [WorkingTreeFile] { files.filter { filter.includes($0) } }
    var sortedRows: [StatusRow] { visibleFiles.map { StatusRow(file: $0, statistics: statistics[$0.id], lfsOwner: lfsOwners[$0.id] ?? "") }.sorted(using: sortOrder) }
    var summary: String {
        let rows = visibleFiles
        return "\(rows.count) files shown, \(rows.filter { $0.entry.staged }.count) staged, \(rows.filter { $0.state == .modified }.count) modified, \(rows.filter { $0.state == .untracked }.count) unversioned"
    }
    func setScope(_ paths: [String]) {
        filter.paths = paths.contains(".") ? [] : paths; filter.wholeProject = filter.paths.isEmpty
        selection = []; reload()
    }
    func reload() {
        guard !busy, !confirmingQuit else { return }; busy = true
        lfsOwners = [:]; lfsLockedPaths = []; lfsOwnershipKnown = false
        Task {
            defer { busy = false }
            do {
                files = try await repository.workingTreeStatus(); branch = try await repository.branch()
                conflictRebase = (try await repository.conflictIsRebase()); submodules = try await repository.submodulePaths()
                hasLFS = try await repository.hasLFS()
                statistics = Dictionary(try await repository.workingTreeFiles().map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                selection.formIntersection(Set(visibleFiles.map(\.id)))
                if ownersVisible {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let token = OperationCancellation(); ownerCancellation = token
                    defer { ownerCancellation = nil }
                    let locks = try await queryLFSOwners(token)
                    guard !token.isCancelled else { return }
                    lfsOwners = Dictionary(locks.map { ($0.path, $0.owner) }, uniquingKeysWith: { first, _ in first })
                    lfsLockedPaths = Set(locks.map(\.path)); lfsOwnershipKnown = true
                }

            } catch { self.error = error.localizedDescription }
        }
    }
    func canLockLFS(_ selected: [WorkingTreeFile]) -> Bool {
        LFSLockingSelection.isAvailable(selected.map(\.entry), hasLFS: hasLFS, root: repository.root, directories: submodules)
    }
    func lfsActions(_ selected: [WorkingTreeFile]) -> [LFSLockMenuAction] {
        guard canLockLFS(selected) else { return [] }
        return LFSLockMenu.actions(paths: selected.map(\.id), ownersVisible: ownersVisible, lockedPaths: lfsLockedPaths, ownershipKnown: lfsOwnershipKnown)
    }
    func setLFSLocked(_ ids: Set<String>, locked: Bool) {
        guard !busy, !confirmingQuit else { return }
        let selected = sortedRows.map(\.file).filter { ids.contains($0.id) }
        guard selected.count == ids.count, lfsActions(selected).contains(locked ? .lock : .unlock) else { return }
        busy = true
        if !onLFSOperation(selected.map(\.id), locked) { busy = false }
    }
    func stage(_ ids: Set<String>, staged: Bool) {
        guard !busy, !ids.isEmpty else { return }; busy = true
        let paths = files.filter { ids.contains($0.id) && $0.state != .conflicted }.map(\.id)
        Task {
            do {
                if staged { try await repository.stage(paths) } else { try await repository.unstage(paths) }
                busy = false; reload(); onChanged()
            } catch { self.error = error.localizedDescription; busy = false; reload() }
        }
    }
    func setFlags(_ action: IndexFlagAction, files: [WorkingTreeFile]) {
        guard !busy, action.isAvailable(for: files), confirmIndexFlags(action) else { return }
        busy = true
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await repository.setIndexFlags(action, paths: files.map(\.id))
            }
            catch { self.error = error.localizedDescription }
            busy = false; reload(); onChanged()
        }
    }
    func diff(_ ids: Set<String>, saving: Bool = false) {
        if !saving {
            let paths = files.filter { ids.contains($0.id) }.map(\.id)
            guard !busy, !paths.isEmpty else { return }; onAction(.diff, paths); return
        }
        guard !busy else { return }; busy = true
        let paths = saving ? (filter.wholeProject ? [] : filter.paths) : files.filter { ids.contains($0.id) }.map(\.id)
        guard saving || !paths.isEmpty else { busy = false; return }
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let bytes = try await repository.workingTreeDiffData(paths: paths)
                savePatch(bytes)
            } catch { self.error = error.localizedDescription }
        }
    }
    func unifiedDiff(_ ids: Set<String>, alternate: Bool) {
        guard !busy, !unifiedViewerBusy else { return }
        let paths = visibleFiles.filter { ids.contains($0.id) }.map(\.id)
        guard !paths.isEmpty else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let bytes = try await repository.workingTreeDiffData(paths: paths)
                if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate) {
                    unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: "HEAD → Working tree", onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func commitPaths() -> [String] { filter.wholeProject ? [] : filter.paths }
    func didRename(_ source: String, to destination: String) {
        func moved(_ path: String) -> String { path == source ? destination : path.hasPrefix(source + "/") ? destination + path.dropFirst(source.count) : path }
        selection = Set(selection.map(moved)); filter.paths = filter.paths.map(moved); reload()
    }
    func reveal(_ ids: Set<String>) { NSWorkspace.shared.activateFileViewerSelecting(files.filter { ids.contains($0.id) }.map { repository.root.appendingPathComponent($0.id) }) }
    func copy(_ ids: Set<String>) {
        let text = files.filter { ids.contains($0.id) }.map(\.id).joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

struct StatusDialog: View {
    @ObservedObject var model: StatusWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.branch.isEmpty ? "Unborn / detached HEAD" : model.branch) { model.onAction(.switchBranch, []) }.buttonStyle(.link)
                Spacer(); if model.busy { ProgressView().controlSize(.small) }
            }
            Table(model.sortedRows, selection: $model.selection, sortOrder: Binding(get: { model.sortOrder }, set: { model.setSortOrder($0) })) {
                TableColumn("Path", sortUsing: StatusFileSort(column: .path)) { row in
                    HStack(spacing: 6) { if let icon = row.file.state.icon.image() { Image(nsImage: icon) }; Text(row.path).foregroundStyle(row.file.state.textColor).lineLimit(1) }
                        .help(row.file.entry.originalPath.map { "Renamed from \($0)" } ?? row.path)
                }.width(min: 250, ideal: 380)
                TableColumn("Extension", sortUsing: StatusFileSort(column: .fileExtension)) { Text($0.fileExtension) }.width(65)
                TableColumn("Status", sortUsing: StatusFileSort(column: .status)) { row in Text(row.status).foregroundStyle(row.file.state.textColor) }.width(min: 110, ideal: 155)
                TableColumn("Lines added", sortUsing: StatusFileSort(column: .added)) { Text($0.addedText) }.width(80)
                TableColumn("Lines removed", sortUsing: StatusFileSort(column: .removed)) { Text($0.removedText) }.width(90)
                TableColumn("Modification date", sortUsing: StatusFileSort(column: .lastModified)) { row in
                    if let date = row.modificationDate { Text(date, format: .dateTime.year().month().day().hour().minute()) } else { Text("–") }
                }.width(min: 150, ideal: 170)
                TableColumn("LFS Lock", sortUsing: StatusFileSort(column: .lfsOwner)) { Text($0.lfsOwner) }.width(min: 100, ideal: 160)
            }
            .background(WorkingTreeLFSColumn(model: model))
            .contextMenu(forSelectionType: String.self) { ids in
                TurtleGitContextMenu {
                    Button { model.diff(ids) } label: { CommandLabel(title: "Diff", icon: .compare) }.disabled(ids.isEmpty)
                    Button { model.unifiedDiff(ids, alternate: NSEvent.modifierFlags.contains(.shift)) } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(ids.isEmpty || model.busy)
                    Button { model.stage(ids, staged: true) } label: { CommandLabel(title: "Add / Stage", icon: .add) }.disabled(ids.isEmpty)
                    Button { model.stage(ids, staged: false) } label: { CommandLabel(title: "Unstage", icon: .revert) }.disabled(ids.isEmpty)
                    if ids.count == 1, let path = ids.first, let row = model.files.first(where: { $0.id == path }), ![FileState.untracked, .ignored, .deleted].contains(row.state) {
                        Button { model.onAction(.rename, [path]) } label: { CommandLabel(title: "Rename…", icon: .rename) }
                    }
                    let selected = model.files.filter { ids.contains($0.id) }
                    if !selected.isEmpty && selected.allSatisfy({ ![FileState.normal, .untracked, .ignored].contains($0.state) }) {
                        Button { model.onAction(.revert, selected.map(\.id)) } label: { CommandLabel(title: "Revert…", icon: .revert) }
                    }
                    ForEach(model.lfsActions(selected), id: \.self) { action in
                        Button { model.setLFSLocked(ids, locked: action == .lock) } label: { CommandLabel(title: action.rawValue, icon: action == .lock ? .lock : .unlock) }.disabled(model.busy || model.confirmingQuit)
                    }
                    IndexFlagsMenu(files: selected) { model.setFlags($0, files: selected) }
                    if !selected.isEmpty && selected.allSatisfy({ $0.state == .conflicted }) {
                        ResolveSelectionMenu(paths: selected.map(\.id), rebase: model.conflictRebase, canEdit: selected.count == 1, action: model.onAction)
                    }
                    if !selected.isEmpty && selected.allSatisfy({ [.untracked, .deleted].contains($0.state) }) {
                        IgnoreSelectionMenu(paths: selected.map(\.id), action: model.onAction)
                    }
                    Divider()
                    Button { model.onAction(.log, Array(ids)) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(ids.isEmpty)
                    Button { model.reveal(ids) } label: { Label("Show in Finder", systemImage: "folder") }.disabled(ids.isEmpty)
                    Button { model.copy(ids) } label: { CommandLabel(title: "Copy paths", icon: .copy) }.disabled(ids.isEmpty)
                }
            } primaryAction: { ids in
                if ids.count == 1, let entry = model.files.first(where: { ids.contains($0.id) }), entry.state == .conflicted { model.onAction(.editConflict, [entry.id]) }
                else { model.diff(ids) }
            }
            .frame(minHeight: 300)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show unversioned files", isOn: $model.filter.showUnversioned)
                    Toggle("Show ignore local changes flagged files", isOn: $model.filter.showLocalChangesIgnored)
                    Toggle("Show ignored files", isOn: $model.filter.showIgnored)
                    Toggle("Show all staged files", isOn: $model.filter.showAllStaged)
                    Toggle("Show Whole Project", isOn: $model.filter.wholeProject).disabled(model.filter.paths.isEmpty)
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
        }.padding(12).disabled(model.busy || model.confirmingQuit)
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
                lhsMetadata: StatusListMetadata(modificationDate: lhs.modificationDate, size: nil, isDirectory: lhs.statistics?.isSubmodule == true),
                rhsMetadata: StatusListMetadata(modificationDate: rhs.modificationDate, size: nil, isDirectory: rhs.statistics?.isSubmodule == true),
                lhsLFSOwner: lhs.lfsOwner, rhsLFSOwner: rhs.lfsOwner)
        }
        return order == .forward ? result : result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
    }
}

/// Public AppKit header integration for the optional Working Tree owner column.
/// Saved full shared-column layout remains a separate port task.
struct WorkingTreeLFSColumn: NSViewRepresentable {
    @ObservedObject var model: StatusWindowModel
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.model = model
        DispatchQueue.main.async { [weak view] in view?.configure() }
    }
    final class Probe: NSView {
        weak var model: StatusWindowModel?
        private weak var table: NSTableView?
        func configure() {
            guard let content = window?.contentView, let model else { return }
            func find(_ view: NSView) -> NSTableView? {
                if let table = view as? NSTableView, table.tableColumns.count == 7 { return table }
                return view.subviews.lazy.compactMap(find).first
            }
            guard let table = find(content), let owner = table.tableColumns.first(where: { $0.headerCell.stringValue == "LFS Lock" }) else { return }
            self.table = table; owner.isHidden = !model.ownersVisible
            let menu = NSMenu(); menu.autoenablesItems = false
            if model.hasLFS {
                let item = NSMenuItem(title: "LFS Lock", action: #selector(toggleOwner(_:)), keyEquivalent: "")
                item.target = self; item.state = model.showLFSOwners ? .on : .off
                item.isEnabled = !model.busy && !model.confirmingQuit; menu.addItem(item)
            }
            table.headerView?.menu = menu
        }
        @objc func toggleOwner(_ sender: NSMenuItem) { guard let model else { return }; model.setShowLFSOwners(!model.showLFSOwners) }
    }
}
