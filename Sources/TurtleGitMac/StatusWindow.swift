import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

struct StatusRow: Identifiable {
    let file: WorkingTreeFile
    let statistics: CommitFile?
    var id: String { file.id }
    var path: String { file.id }
    var fileExtension: String { (path as NSString).pathExtension }
    var status: String { file.status + (file.entry.staged ? " (staged)" : "") }
    var added: Int? { statistics?.added }
    var removed: Int? { statistics?.removed }
    var sortAdded: Int { added ?? -1 }
    var sortRemoved: Int { removed ?? -1 }
    var addedText: String { added.map { String($0) } ?? "–" }
    var removedText: String { removed.map { String($0) } ?? "–" }
    var modificationDate: Date? { file.modificationDate }
    var sortDate: Date { modificationDate ?? .distantPast }
}

@MainActor final class StatusWindowController: NSWindowController, NSWindowDelegate {
    let model: StatusWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = StatusWindowModel(repository: repository, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 630),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Working Tree – TurtleGit"
        window.minSize = NSSize(width: 960, height: 540); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StatusDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 1100, height: 630)); window.center()
        model.close = { [weak window] in window?.close() }
        model.savePatch = { [weak self] text in self?.savePatch(text) }
    }
    private func savePatch(_ text: String) {
        guard let window else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "working-tree.patch"
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak model] response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(text.utf8).write(to: url, options: .atomic) }
            catch { model?.error = error.localizedDescription }
        }
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class StatusWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var conflictRebase = false
    @Published var submodules = Set<String>()
    @Published var files: [WorkingTreeFile] = []
    @Published var statistics: [String: CommitFile] = [:]
    @Published var selection = Set<String>()
    @Published var filter = WorkingTreeFilter()
    @Published var branch = ""
    @Published var busy = false
    @Published var error: String?
    @Published var patch: String?
    var close: () -> Void = {}
    var savePatch: (String) -> Void = { _ in }
    var onAction: (RepositoryAction, [String]) -> Void = { _, _ in }
    var onChanged: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
    var visibleFiles: [WorkingTreeFile] { files.filter { filter.includes($0) } }
    var summary: String {
        let rows = visibleFiles
        return "\(rows.count) files shown, \(rows.filter { $0.entry.staged }.count) staged, \(rows.filter { $0.state == .modified }.count) modified, \(rows.filter { $0.state == .untracked }.count) unversioned"
    }
    func setScope(_ paths: [String]) {
        filter.paths = paths.contains(".") ? [] : paths; filter.wholeProject = filter.paths.isEmpty
        selection = []; reload()
    }
    func reload() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                files = try await repository.workingTreeStatus(); branch = try await repository.branch()
                conflictRebase = (try await repository.conflictIsRebase()); submodules = try await repository.submodulePaths()
                statistics = Dictionary(try await repository.workingTreeFiles().map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                selection.formIntersection(Set(visibleFiles.map(\.id)))
            } catch { self.error = error.localizedDescription }
        }
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
                let text = try await repository.workingTreeDiff(paths: paths)
                if saving { savePatch(text) } else { patch = text.isEmpty ? "No diff is available for these paths." : text }
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
    @State private var sortOrder = [KeyPathComparator(\StatusRow.path)]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.branch.isEmpty ? "Unborn / detached HEAD" : model.branch) { model.onAction(.switchBranch, []) }.buttonStyle(.link)
                Spacer(); if model.busy { ProgressView().controlSize(.small) }
            }
            Table(model.visibleFiles.map { StatusRow(file: $0, statistics: model.statistics[$0.id]) }.sorted(using: sortOrder), selection: $model.selection, sortOrder: $sortOrder) {
                TableColumn("Path", value: \.path) { row in
                    HStack(spacing: 6) { if let icon = row.file.state.icon.image() { Image(nsImage: icon) }; Text(row.path).foregroundStyle(row.file.state.textColor).lineLimit(1) }
                        .help(row.file.entry.originalPath.map { "Renamed from \($0)" } ?? row.path)
                }.width(min: 250, ideal: 380)
                TableColumn("Extension", value: \.fileExtension).width(65)
                TableColumn("Status", value: \.status) { row in Text(row.status).foregroundStyle(row.file.state.textColor) }.width(min: 110, ideal: 155)
                TableColumn("Lines added", value: \.sortAdded) { Text($0.addedText) }.width(80)
                TableColumn("Lines removed", value: \.sortRemoved) { Text($0.removedText) }.width(90)
                TableColumn("Modification date", value: \.sortDate) { row in
                    if let date = row.modificationDate { Text(date, format: .dateTime.year().month().day().hour().minute()) } else { Text("–") }
                }.width(min: 150, ideal: 170)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button { model.diff(ids) } label: { CommandLabel(title: "Diff", icon: .compare) }.disabled(ids.isEmpty)
                Button { model.stage(ids, staged: true) } label: { CommandLabel(title: "Add / Stage", icon: .add) }.disabled(ids.isEmpty)
                Button { model.stage(ids, staged: false) } label: { CommandLabel(title: "Unstage", icon: .revert) }.disabled(ids.isEmpty)
                if ids.count == 1, let path = ids.first, let row = model.files.first(where: { $0.id == path }), ![FileState.untracked, .ignored, .deleted].contains(row.state) {
                    Button { model.onAction(.rename, [path]) } label: { CommandLabel(title: "Rename…", icon: .rename) }
                }
                let selected = model.files.filter { ids.contains($0.id) }
                if !selected.isEmpty && selected.allSatisfy({ ![FileState.normal, .untracked, .ignored].contains($0.state) }) {
                    Button { model.onAction(.revert, selected.map(\.id)) } label: { CommandLabel(title: "Revert…", icon: .revert) }
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
        }.padding(12).disabled(model.busy)
        .onChange(of: model.filter) { _ in model.selection.formIntersection(Set(model.visibleFiles.map(\.id))) }
        .alert("Git operation failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(get: { model.patch != nil }, set: { if !$0 { model.patch = nil } })) {
            VStack { Text("Unified Diff").font(.headline); OutputView(text: model.patch ?? "").frame(minWidth: 850, minHeight: 520); Button("Close") { model.patch = nil }.keyboardShortcut(.cancelAction) }.padding(12)
        }
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
