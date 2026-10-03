import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class CommitWindowController: NSWindowController, NSWindowDelegate {
    let model: CommitWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = CommitWindowModel(repository: repository, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Commit – TurtleGit"
        window.minSize = NSSize(width: 900, height: 680); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CommitDialog(model: model))
        super.init(window: window); window.delegate = self; window.setContentSize(NSSize(width: 1000, height: 760)); window.center()
        model.close = { [weak window] in window?.close() }
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class CommitWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var entries: [StatusEntry] = []
    @Published var stagedStatistics: [String: CommitFile] = [:]
    @Published var unstagedStatistics: [String: CommitFile] = [:]
    @Published var stagingEnabled = false
    @Published var stagedDiff = true
    private var hasLoaded = false
    @Published var statistics: [String: CommitFile] = [:]
    @Published var checked = Set<String>()
    @Published var selection = Set<String>()
    @Published var branch = ""
    @Published var message = ""
    @Published var amend = false
    @Published var setAuthor = false
    @Published var author = ""
    @Published var showUnversioned = true
    @Published var showWholeProject = true
    @Published var scopePaths: [String] = []
    @Published var busy = false
    @Published var error: String?
    @Published var patch: String?
    var close: () -> Void = {}
    var onCommitted: (String) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
    var visibleEntries: [StatusEntry] {
        entries.filter { entry in
            entry.state != .ignored && (showUnversioned || entry.state != .untracked) &&
                (entry.staged || showWholeProject || scopePaths.contains { $0 == entry.path || entry.path.hasPrefix($0 + "/") })
        }
    }
    var stagedEntries: [StatusEntry] { visibleEntries.filter(\.staged) }
    var unstagedEntries: [StatusEntry] { visibleEntries.filter { $0.worktree != " " && $0.worktree != "!" } }
    func moveToStage(_ paths: Set<String>, staged: Bool) {
        guard !busy, !paths.isEmpty else { return }; busy = true
        let valid = entries.filter { paths.contains($0.id) && $0.state != .conflicted }.map(\.path)
        Task {
            do {
                if staged { try await repository.stage(valid) } else { try await repository.unstage(valid) }
                busy = false; reload()
            } catch { self.error = error.localizedDescription; busy = false; reload() }
        }
    }
    var canCommit: Bool { !busy && (stagingEnabled ? entries.contains(where: \.staged) || amend : !checked.isEmpty || amend) && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!setAuthor || !author.isEmpty) }
    func reload(paths: [String]? = nil) {
        guard !busy else { return }; busy = true
        let resetChecks = paths != nil && (!hasLoaded || (paths!.contains(".") ? [] : paths!) != scopePaths)
        if let paths { scopePaths = paths.contains(".") ? [] : paths; showWholeProject = scopePaths.isEmpty }
        Task {
            defer { busy = false }
            do {
                entries = try await repository.status(); branch = try await repository.branch()
                statistics = Dictionary(try await repository.workingTreeFiles().map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                stagedStatistics = Dictionary(try await repository.stagingFiles(staged: true).map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                unstagedStatistics = Dictionary(try await repository.stagingFiles(staged: false).map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                if resetChecks {
                    checked = Set(visibleEntries.filter { entry in
                        let inScope = scopePaths.isEmpty || scopePaths.contains { $0 == entry.path || entry.path.hasPrefix($0 + "/") }
                        return inScope && entry.state != .conflicted && (entry.state != .untracked || !scopePaths.isEmpty)
                    }.map(\.id))
                } else { checked.formIntersection(Set(entries.map(\.id))) }
                selection.formIntersection(Set(entries.map(\.id)))
                hasLoaded = true
            } catch { self.error = error.localizedDescription }
        }
    }
    func check(_ predicate: (StatusEntry) -> Bool) {
        let paths = Set(visibleEntries.filter { $0.state != .conflicted && predicate($0) }.map(\.id))
        if stagingEnabled { moveToStage(paths, staged: true) } else { checked.formUnion(paths) }
    }
    func uncheckAll() {
        if stagingEnabled { moveToStage(Set(visibleEntries.filter(\.staged).map(\.id)), staged: false) }
        else { checked.subtract(visibleEntries.map(\.id)) }
    }
    func amendChanged() {
        guard amend, message.isEmpty else { return }
        Task {
            do {
                var options = HistoryOptions(); options.limit = 1
                let previous = try await repository.history(options: options).first?.message ?? ""
                if amend, message.isEmpty { message = previous }
            } catch { self.error = error.localizedDescription }
        }
    }
    func addSignOff() {
        Task {
            do {
                let name = try await repository.run(["config", "user.name"]).text.trimmingCharacters(in: .newlines)
                let email = try await repository.run(["config", "user.email"]).text.trimmingCharacters(in: .newlines)
                let trailer = "Signed-off-by: \(name) <\(email)>"
                if !message.components(separatedBy: .newlines).contains(trailer) { message += (message.isEmpty ? "" : "\n\n") + trailer }
            } catch { self.error = "Configure your Git user name and email before adding a sign-off.\n" + error.localizedDescription }
        }
    }
    func diff(paths selected: Set<String>, staged: Bool? = nil) {
        let paths = entries.filter { selected.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }
        Task {
            do {
                let text: String
                if let staged { text = try await repository.diff(paths: paths, staged: staged) }
                else {
                    let head = try? await repository.run(["rev-parse", "--verify", "HEAD"])
                    let args = ["diff", "--no-ext-diff", "--no-color"] + (head == nil ? ["--cached"] : ["HEAD"]) + ["--"] + paths
                    text = try await repository.run(args).text
                }
                patch = text.isEmpty ? "No diff is available. Unversioned files have no Git base revision." : text
            } catch { self.error = error.localizedDescription }
        }
    }
    func commit() {
        guard canCommit else { return }
        let text = message, paths = checked, staging = stagingEnabled
        var options = CommitOptions(); options.amend = amend; options.author = setAuthor ? author : nil
        busy = true
        Task {
            do {
                let output: String
                if staging { output = try await repository.commitIndex(message: text, options: options) }
                else { output = try await repository.commitSelected(message: text, paths: paths, options: options) }
                busy = false; onCommitted(output); close()
            } catch { self.error = error.localizedDescription; busy = false; reload() }
        }
    }
}

struct CommitDialog: View {
    @ObservedObject var model: CommitWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Commit to:"); Text(model.branch.isEmpty ? "Detached / unborn HEAD" : model.branch).foregroundStyle(.blue); Spacer(); if model.busy { ProgressView().controlSize(.small) } }
            GroupBox("Message:") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.message).font(.system(.body, design: .monospaced)).frame(minHeight: 100, idealHeight: 140, maxHeight: 200).border(Color.secondary.opacity(0.3))
                    HStack {
                        Toggle("Amend Last Commit", isOn: $model.amend).toggleStyle(.checkbox).onChange(of: model.amend) { _ in model.amendChanged() }
                        Spacer(); Text("\(model.message.count) characters").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Toggle("Set author", isOn: $model.setAuthor).toggleStyle(.checkbox)
                        TextField("Name <email>", text: $model.author).textFieldStyle(.roundedBorder).disabled(!model.setAuthor)
                        Button("Add Signed-off-by") { model.addSignOff() }
                    }
                }.padding(4)
            }
                GroupBox("Changes made (double-click on file for diff):") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text("Check:")
                            checkButton("All") { model.check { _ in true } }
                            checkButton("None") { model.uncheckAll() }
                            checkButton("Unversioned") { model.check { $0.state == .untracked } }
                            checkButton("Versioned") { model.check { $0.state != .untracked } }
                            checkButton("Added") { model.check { $0.state == .added } }
                            checkButton("Deleted") { model.check { $0.state == .deleted } }
                            checkButton("Modified") { model.check { $0.state == .modified } }
                        }.font(.system(size: 12))
                        fileTable(model.visibleEntries, selection: $model.selection, staged: model.stagingEnabled ? model.stagedDiff : nil).frame(minHeight: 200)
                    }.padding(4)
                }
            HStack {
                Toggle("Enable staging area", isOn: $model.stagingEnabled).toggleStyle(.checkbox)
                Toggle("Show Unversioned Files", isOn: $model.showUnversioned).toggleStyle(.checkbox)
                if !model.scopePaths.isEmpty { Toggle("Show Whole Project", isOn: $model.showWholeProject).toggleStyle(.checkbox) }
                Spacer(); Text(model.stagingEnabled ? "\(model.stagedEntries.count) staged, \(model.unstagedEntries.count) unstaged files shown" : "\(model.checked.count) files checked, \(model.visibleEntries.count) files shown").font(.caption)
            }
            if model.stagingEnabled {
                HStack {
                    Button("Stage selected") { model.moveToStage(model.selection, staged: true) }.disabled(model.selection.isEmpty)
                    Button("Unstage selected") { model.moveToStage(model.selection, staged: false) }.disabled(model.selection.isEmpty)
                    Toggle("Staged diff", isOn: $model.stagedDiff).toggleStyle(.checkbox)
                    Spacer(); Text("A mixed checkbox means the file has both staged and unstaged changes.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(model.stagingEnabled ? "Commit includes all staged changes, including files outside the current view. Unstaged contents remain in the working tree." : "Checked files commit their current whole-file contents. Unchecked staged changes remain staged.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refresh") { model.reload() }
                Spacer()
                Button("Commit") { model.commit() }.keyboardShortcut(.return, modifiers: [.command]).disabled(!model.canCommit)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-commit.html")!) }
            }
        }.padding(12).disabled(model.busy)
        .alert("Commit failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(get: { model.patch != nil }, set: { if !$0 { model.patch = nil } })) {
            VStack { Text("Unified Diff").font(.headline); OutputView(text: model.patch ?? "").frame(minWidth: 850, minHeight: 520); Button("Close") { model.patch = nil }.keyboardShortcut(.cancelAction) }.padding(12)
        }
    }
    func fileTable(_ entries: [StatusEntry], selection: Binding<Set<String>>, staged: Bool?) -> some View {
        let statistics = staged.map { $0 ? model.stagedStatistics : model.unstagedStatistics } ?? model.statistics
        return Table(entries, selection: selection) {
            TableColumn("") { entry in
                if staged != nil {
                    StagingCheckbox(entry: entry, enabled: !model.busy) { model.moveToStage([entry.id], staged: $0) }.frame(width: 20, height: 20)
                } else {
                    Toggle("Include \(entry.path)", isOn: Binding(get: { model.checked.contains(entry.id) }, set: { if $0 { model.checked.insert(entry.id) } else { model.checked.remove(entry.id) } }))
                        .labelsHidden().toggleStyle(.checkbox).disabled(entry.state == .conflicted)
                }
            }.width(24)
            TableColumn("Path") { entry in HStack { Image(nsImage: entry.state.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(entry.path).foregroundStyle(.blue) }.help(entry.originalPath.map { "Renamed from \($0)" } ?? entry.path) }.width(min: 260, ideal: 420)
            TableColumn("Extension") { entry in Text((entry.path as NSString).pathExtension) }.width(75)
            TableColumn("Status") { entry in Text(statistics[entry.path]?.status ?? entry.state.rawValue.capitalized) }.width(90)
            TableColumn("Lines added") { entry in Text(statistics[entry.path]?.added.map(String.init) ?? "–").foregroundStyle(.blue) }.width(80)
            TableColumn("Lines removed") { entry in Text(statistics[entry.path]?.removed.map(String.init) ?? "–").foregroundStyle(.blue) }.width(95)
        }.contextMenu(forSelectionType: String.self) { ids in
            Button { model.diff(paths: ids, staged: staged) } label: { CommandLabel(title: "Compare with base", icon: .compare) }.disabled(ids.isEmpty)
            Button { model.diff(paths: ids, staged: staged) } label: { CommandLabel(title: "Show changes as unified diff", icon: .compare) }.disabled(ids.isEmpty)
            Divider()
            if staged != nil {
                Button { model.moveToStage(ids, staged: true) } label: { CommandLabel(title: "Stage selected files", icon: .add) }.disabled(ids.isEmpty)
                Button { model.moveToStage(ids, staged: false) } label: { CommandLabel(title: "Unstage selected files", icon: .revert) }.disabled(ids.isEmpty)
            } else {
                Button { model.check { ids.contains($0.id) } } label: { CommandLabel(title: "Check selected files", icon: .add) }
                Button { model.checked.subtract(ids) } label: { CommandLabel(title: "Uncheck selected files", icon: .revert) }
            }
        } primaryAction: { ids in selection.wrappedValue = ids; model.diff(paths: ids, staged: staged) }
    }
    func checkButton(_ title: String, action: @escaping () -> Void) -> some View { Button(title, action: action).buttonStyle(.plain).foregroundStyle(.blue) }
}

/// Preserve TortoiseGit's three-state staging checkbox in the same file list.
private struct StagingCheckbox: NSViewRepresentable {
    let entry: StatusEntry
    let enabled: Bool
    let change: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(change: change) }
    func makeNSView(context: Context) -> NSButton {
        let button = StageButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.change = change
        context.coordinator.nextStaged = !(entry.staged && entry.worktree == " ")
        button.state = entry.staged ? (entry.worktree == " " ? .on : .mixed) : .off
        button.isEnabled = enabled && entry.state != .conflicted
        button.setAccessibilityLabel("Stage \(entry.path)")
        button.toolTip = entry.staged ? "Click to change staging; a mixed state stages the remaining working-tree changes." : "Click to stage the current file contents."
    }
    final class Coordinator: NSObject {
        var change: (Bool) -> Void
        var nextStaged = true
        init(change: @escaping (Bool) -> Void) { self.change = change }
        @objc func clicked(_ sender: NSButton) { change(nextStaged) }
    }
    private final class StageButton: NSButton {
        override func setNextState() { state = state == .on ? .off : .on }
    }
}
