import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class CommitWindowController: NSWindowController, NSWindowDelegate {
    let model: CommitWindowModel
    var onClosed: () -> Void = {}
    private var partial: PatchWindowController?
    private var closingCommit = false
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = CommitWindowModel(repository: repository, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Commit – TurtleGit"
        window.minSize = NSSize(width: 900, height: 680); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CommitDialog(model: model))
        super.init(window: window); window.delegate = self; window.setContentSize(NSSize(width: 1000, height: 760)); window.center()
        model.close = { [weak window] in window?.close() }
        model.showPartial = { [weak self] staged in self?.showPartial(staged: staged) }
        model.showViewPatch = { [weak self] in self?.showPartial(staged: false, readOnly: true) }
        model.refreshPartial = { [weak self] in self?.reloadPartial() }
        model.closePartial = { [weak self] in self?.partial?.close() }
    }
    func windowWillClose(_ notification: Notification) { closingCommit = true; partial?.close(); partial = nil; onClosed() }
    private func showPartial(staged: Bool, readOnly: Bool = false) {
        guard let window else { return }
        if let partial, partial.model.readOnly == readOnly, partial.model.staged == staged { partial.close(); return }
        let controller = partial ?? PatchWindowController(repository: model.repository, access: model.access)
        partial = controller
        controller.onClosed = { [weak self] in
            guard let self else { return }
            self.partial = nil; self.model.partialMode = nil; self.model.viewingPatch = false
            if !self.closingCommit { self.model.savePatchPreference(false) }
        }
        controller.model.onApplying = { [weak model] busy in model?.busy = busy }
        controller.model.onApplied = { [weak model] in model?.reload() }
        controller.model.readOnly = readOnly
        controller.model.staged = staged
        controller.model.base = model.comparisonBase
        model.partialMode = readOnly ? nil : staged
        model.viewingPatch = readOnly
        model.savePatchPreference(true)
        controller.model.comparisonTitle = model.comparisonBase != nil ? "Parent → Working tree" : model.hasHead ? "HEAD → Working tree" : "Initial commit"
        controller.window?.title = readOnly ? "View Patch – " + controller.model.comparisonTitle : staged ? "Partial Unstaging – HEAD → Index" : "Partial Staging – Index → Working tree"
        if let patchWindow = controller.window, patchWindow.parent == nil { window.addChildWindow(patchWindow, ordered: .above) }
        if let child = controller.window, let visible = window.screen?.visibleFrame,
           window.frame.width + child.frame.width <= visible.width {
            let x = min(max(window.frame.minX, visible.minX), visible.maxX - window.frame.width - child.frame.width)
            window.setFrameOrigin(NSPoint(x: x, y: window.frame.minY))
        }
        alignPartial(); controller.showWindow(nil); reloadPartial()
    }
    private func reloadPartial() {
        guard let partial else { return }
        partial.model.base = model.comparisonBase
        partial.model.comparisonTitle = model.comparisonBase != nil ? "Parent → Working tree" : model.hasHead ? "HEAD → Working tree" : "Initial commit"
        partial.window?.title = partial.model.readOnly ? "View Patch – " + partial.model.comparisonTitle : partial.model.staged ? (model.comparisonBase == nil ? "Partial Unstaging – HEAD → Index" : "Partial Unstaging – Parent → Index") : "Partial Staging – Index → Working tree"
        let selected = model.entries.filter { model.selection.contains($0.id) && $0.state != .untracked && $0.state != .ignored }
        let paths = selected.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        partial.model.reload(paths: Array(Set(paths)).sorted(), staged: partial.model.staged)
    }
    private func alignPartial() {
        guard let window, let child = partial?.window else { return }
        var frame = child.frame
        frame.origin = NSPoint(x: window.frame.maxX, y: window.frame.minY)
        frame.size.height = window.frame.height
        child.setFrame(frame, display: true)
    }
    func windowDidMove(_ notification: Notification) { alignPartial() }
    func windowDidResize(_ notification: Notification) { alignPartial() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class CommitWindowModel: ObservableObject {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    @Published var entries: [StatusEntry] = []
    @Published var comparisonBase: String?
    @Published var stagedStatistics: [String: CommitFile] = [:]
    @Published var unstagedStatistics: [String: CommitFile] = [:]
    @Published var stagingEnabled = false
    @Published var viewingPatch = false
    private var loadedPreferences = false
    private var persistedStaging: Bool?
    @Published var partialMode: Bool?
    @Published var stagedDiff = true
    private var hasLoaded = false
    @Published var statistics: [String: CommitFile] = [:]
    @Published var checked = Set<String>()
    @Published var selection = Set<String>()
    @Published var branch = ""
    @Published var createBranch = false
    @Published var newBranch = ""
    @Published var message = ""
    @Published var hasHead = false
    @Published var hasParent = false
    @Published var amend = false
    @Published var amendDiffToLastCommit = false
    private var nonAmendMessage = ""
    private var amendMessage = ""
    var amendToParent: Bool { amend && !amendDiffToLastCommit }
    @Published var setAuthorDate = false
    @Published var authorDate = Date()
    @Published var resetAuthorDate = false
    @Published var messageOnly = false
    @Published var doNotAutoselectSubmodules = UserDefaults.standard.bool(forKey: "Commit.DoNotAutoselectSubmodules")
    @Published var submodules = Set<String>()
    @Published var setAuthor = false
    @Published var author = ""
    @Published var showUnversioned = true
    @Published var showWholeProject = true
    @Published var scopePaths: [String] = []
    @Published var busy = false
    @Published var error: String?
    @Published var patch: String?
    var showViewPatch: () -> Void = {}
    var showPartial: (Bool) -> Void = { _ in }
    var refreshPartial: () -> Void = {}
    var closePartial: () -> Void = {}
    var close: () -> Void = {}
    var onCommitted: (String) -> Void = { _ in }
    var onPush: () -> Void = {}
    enum CompletionAction: String, CaseIterable { case commit = "Commit", recommit = "ReCommit", push = "Commit & Push" }
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
                if staged { try await repository.stage(valid) } else { try await repository.unstageCommitPaths(valid, amendToParent: amendToParent) }
                busy = false; reload()
            } catch { self.error = error.localizedDescription; busy = false; reload() }
        }
    }
    var canCommit: Bool { !busy && (messageOnly || (stagingEnabled ? entries.contains(where: \.staged) || amend : !checked.isEmpty || (amend && amendDiffToLastCommit))) && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!createBranch || !newBranch.isEmpty) && (!setAuthor || !author.isEmpty) }
    func reload(paths: [String]? = nil) {
        guard !busy else { return }; busy = true
        let resetChecks = paths != nil && (!hasLoaded || (paths!.contains(".") ? [] : paths!) != scopePaths)
        if let paths { scopePaths = paths.contains(".") ? [] : paths; showWholeProject = scopePaths.isEmpty }
        Task {
            defer { busy = false }
            do {
                var restorePatch = false
                if !loadedPreferences {
                    let preferences = try await repository.commitPreferences()
                    persistedStaging = preferences.staging; stagingEnabled = preferences.staging; restorePatch = preferences.showPatch; loadedPreferences = true
                }
                hasHead = (try? await repository.run(["rev-parse", "--verify", "HEAD"])) != nil
                hasParent = (try? await repository.run(["rev-parse", "--verify", "HEAD^1"])) != nil
                if amend && !hasParent { amendDiffToLastCommit = true }
                comparisonBase = amendToParent ? try await repository.commitComparisonBase(amendToParent: true) : nil
                entries = try await repository.commitDialogStatus(amendToParent: amendToParent); submodules = try await repository.submodulePaths(); branch = try await repository.branch()
                statistics = Dictionary(try await repository.workingTreeFiles(amendToParent: amendToParent).map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                stagedStatistics = Dictionary(try await repository.stagingFiles(staged: true, base: comparisonBase).map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                unstagedStatistics = Dictionary(try await repository.stagingFiles(staged: false).map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                if resetChecks {
                    checked = Set(visibleEntries.filter { entry in
                        let inScope = scopePaths.isEmpty || scopePaths.contains { $0 == entry.path || entry.path.hasPrefix($0 + "/") }
                        return inScope && (!doNotAutoselectSubmodules || !submodules.contains(entry.path)) && entry.state != .conflicted && (entry.state != .untracked || !scopePaths.isEmpty)
                    }.map(\.id))
                } else { checked.formIntersection(Set(entries.map(\.id))) }
                selection.formIntersection(Set(entries.map(\.id)))
                if !hasLoaded && author.isEmpty {
                    let name = (try? await repository.run(["config", "user.name"]).text.trimmingCharacters(in: .newlines)) ?? ""
                    let email = (try? await repository.run(["config", "user.email"]).text.trimmingCharacters(in: .newlines)) ?? ""
                    author = name.isEmpty ? "" : "\(name) <\(email)>"
                }
                hasLoaded = true; refreshPartial()
                if restorePatch { if stagingEnabled { showPartial(false) } else { showViewPatch() } }
            } catch { self.error = error.localizedDescription }
        }
    }
    func savePatchPreference(_ visible: Bool) {
        Task { do { try await repository.saveCommitPreferences(showPatch: visible) } catch { self.error = error.localizedDescription } }
    }
    func stagingChanged() {
        guard loadedPreferences, persistedStaging != stagingEnabled else { return }
        closePartial()
        let enabled = stagingEnabled; persistedStaging = enabled
        Task { do { try await repository.saveCommitPreferences(staging: enabled) } catch { self.error = error.localizedDescription } }
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
        if amend {
            nonAmendMessage = message
            Task {
                do {
                    var options = HistoryOptions(); options.limit = 1
                    let previous = try await repository.history(options: options).first
                    guard amend else { return }
                    message = amendMessage.isEmpty ? previous?.message ?? "" : amendMessage
                    if setAuthorDate { dateChanged() }
                    authorChanged()
                    comparisonChanged()
                } catch { self.error = error.localizedDescription }
            }
        } else {
            amendMessage = message; message = nonAmendMessage; resetAuthorDate = false; authorChanged(); comparisonChanged()
        }
    }
    func comparisonChanged() {
        hasLoaded = false
        reload(paths: scopePaths.isEmpty ? ["."] : scopePaths)
    }
    func authorChanged() {
        Task {
            do {
                if amend {
                    var options = HistoryOptions(); options.limit = 1
                    if let previous = try await repository.history(options: options).first, amend { author = "\(previous.author) <\(previous.email)>" }
                } else {
                    let name = try await repository.run(["config", "user.name"]).text.trimmingCharacters(in: .newlines)
                    let email = try await repository.run(["config", "user.email"]).text.trimmingCharacters(in: .newlines)
                    if !amend { author = "\(name) <\(email)>" }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func dateChanged() {
        resetAuthorDate = false
        guard setAuthorDate else { return }
        if !amend { authorDate = Date(); return }
        Task {
            do {
                let value = try await repository.run(["show", "-s", "--format=%at", "HEAD"]).text.trimmingCharacters(in: .newlines)
                if amend, setAuthorDate, let timestamp = TimeInterval(value) { authorDate = Date(timeIntervalSince1970: timestamp) }
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
                if let staged { text = try await repository.patch(paths: paths, staged: staged, base: amendToParent && staged ? try await repository.commitComparisonBase(amendToParent: true) : nil).text }
                else {
                    let head = try? await repository.run(["rev-parse", "--verify", "HEAD"])
                    let base = amendToParent ? try await repository.commitComparisonBase(amendToParent: true) : "HEAD"
                    let args = ["diff", "--no-ext-diff", "--no-color"] + (head == nil ? ["--cached"] : [base]) + ["--"] + paths
                    text = try await repository.run(args).text
                }
                patch = text.isEmpty ? "No diff is available. Unversioned files have no Git base revision." : text
            } catch { self.error = error.localizedDescription }
        }
    }
    func commit(_ action: CompletionAction = .commit) {
        guard canCommit else { return }
        let text = message, paths = checked, staging = stagingEnabled
        var options = CommitOptions(); options.amend = amend; options.amendDiffToLastCommit = amendDiffToLastCommit; options.author = setAuthor ? author : nil
        options.authorDate = setAuthorDate ? authorDate : nil; options.resetAuthorDate = amend && setAuthorDate && resetAuthorDate; options.messageOnly = messageOnly; options.newBranch = createBranch ? newBranch : nil
        busy = true
        Task {
            do {
                let output: String
                if staging { output = try await repository.commitIndex(message: text, options: options) }
                else { output = try await repository.commitSelected(message: text, paths: paths, options: options) }
                busy = false; onCommitted(output)
                if action == .recommit {
                    message = ""; createBranch = false; newBranch = ""; amend = false; amendDiffToLastCommit = false; amendMessage = ""; nonAmendMessage = ""; setAuthorDate = false; resetAuthorDate = false; setAuthor = false; messageOnly = false
                    checked = []; selection = []; hasLoaded = false
                    reload(paths: scopePaths.isEmpty ? ["."] : scopePaths)
                } else { close(); if action == .push { onPush() } }
            } catch { self.error = error.localizedDescription; busy = false; reload() }
        }
    }
}

struct CommitDialog: View {
    @ObservedObject var model: CommitWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Commit to:")
                if model.createBranch { TextField("New branch name", text: $model.newBranch).frame(width: 250) }
                else { Text(model.branch.isEmpty ? "Detached / unborn HEAD" : model.branch).foregroundStyle(.blue) }
                Toggle("new branch", isOn: $model.createBranch).toggleStyle(.checkbox)
                Spacer(); if model.busy { ProgressView().controlSize(.small) }
            }
            messageSection
            changesSection
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show Whole Project", isOn: $model.showWholeProject).disabled(model.scopePaths.isEmpty)
                    Toggle("Message only", isOn: $model.messageOnly)
                }.toggleStyle(.checkbox)
                Button("Refresh") { model.reload() }
                Spacer()
                HStack(spacing: 0) {
                    Button("Commit") { model.commit() }.keyboardShortcut(.return, modifiers: [.command])
                    Menu {
                        ForEach(CommitWindowModel.CompletionAction.allCases, id: \.self) { action in
                            Button { model.commit(action) } label: { CommandLabel(title: action.rawValue, icon: action == .push ? .push : .commit) }
                        }
                    } label: { Image(systemName: "chevron.down") }.menuIndicator(.hidden).fixedSize().accessibilityLabel("Commit actions")
                }.disabled(!model.canCommit)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-commit.html")!) }
            }
        }.padding(12).disabled(model.busy)
        .onChange(of: model.amendDiffToLastCommit) { _ in model.comparisonChanged() }
        .onChange(of: model.setAuthor) { _ in model.authorChanged() }
        .onChange(of: model.setAuthorDate) { _ in model.dateChanged() }
        .onChange(of: model.doNotAutoselectSubmodules) { disabled in
            UserDefaults.standard.set(disabled, forKey: "Commit.DoNotAutoselectSubmodules")
            if !model.stagingEnabled {
                if disabled { model.checked.subtract(model.submodules) }
                else { model.check { model.submodules.contains($0.path) } }
            }
        }
        .onChange(of: model.selection) { _ in model.refreshPartial() }
        .onChange(of: model.stagingEnabled) { _ in model.stagingChanged() }
        .alert("Commit failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(get: { model.patch != nil }, set: { if !$0 { model.patch = nil } })) {
            VStack { Text("Unified Diff").font(.headline); OutputView(text: model.patch ?? "").frame(minWidth: 850, minHeight: 520); Button("Close") { model.patch = nil }.keyboardShortcut(.cancelAction) }.padding(12)
        }
    }
    private var messageSection: some View {
GroupBox("Message:") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.message).font(.system(.body, design: .monospaced)).frame(minHeight: 100, idealHeight: 140, maxHeight: 200).border(Color.secondary.opacity(0.3))
                    HStack {
                        Toggle("Amend Last Commit", isOn: $model.amend).toggleStyle(.checkbox).disabled(!model.hasHead).onChange(of: model.amend) { _ in model.amendChanged() }
                        if model.amend { Toggle("Show diff to last commit", isOn: $model.amendDiffToLastCommit).toggleStyle(.checkbox).disabled(!model.hasParent) }
                        Spacer(); Text("\(model.message.count) characters").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Toggle("Set author date", isOn: $model.setAuthorDate).toggleStyle(.checkbox).frame(width: 170, alignment: .leading)
                        if model.setAuthorDate {
                            CommitDatePicker(selection: $model.authorDate, time: false, enabled: !(model.amend && model.resetAuthorDate)).frame(width: 130, height: 24)
                            CommitDatePicker(selection: $model.authorDate, time: true, enabled: !(model.amend && model.resetAuthorDate)).frame(width: 115, height: 24)
                            if model.amend { Toggle("Reset", isOn: $model.resetAuthorDate).toggleStyle(.checkbox) }
                        }
                        Spacer()
                    }
                    HStack {
                        Toggle("Set author", isOn: $model.setAuthor).toggleStyle(.checkbox).frame(width: 170, alignment: .leading)
                        TextField("Name <email>", text: $model.author).textFieldStyle(.roundedBorder).disabled(!model.setAuthor)
                        Button("Add Signed-off-by") { model.addSignOff() }
                    }
                }.padding(4)
            }
    }
    private var changesSection: some View {
GroupBox("Changes made (double-click on file for diff):") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text("Check:")
                            checkButton("All") { model.check { _ in true } }
                            checkButton("None") { model.uncheckAll() }
                            checkButton("Unversioned", enabled: model.visibleEntries.contains { $0.state == .untracked }) { model.check { $0.state == .untracked } }
                            checkButton("Versioned", enabled: model.visibleEntries.contains { $0.state != .untracked }) { model.check { $0.state != .untracked } }
                            checkButton("Added", enabled: model.visibleEntries.contains { $0.state == .added }) { model.check { $0.state == .added } }
                            checkButton("Deleted", enabled: model.visibleEntries.contains { $0.state == .deleted }) { model.check { $0.state == .deleted } }
                            checkButton("Modified", enabled: model.visibleEntries.contains { $0.state == .modified }) { model.check { $0.state == .modified } }
                            checkButton("Files", enabled: model.visibleEntries.contains { !model.submodules.contains($0.path) }) { model.check { !model.submodules.contains($0.path) } }
                            checkButton("Submodules", enabled: model.visibleEntries.contains { model.submodules.contains($0.path) }) { model.check { model.submodules.contains($0.path) } }
                        }.font(.system(size: 12)).disabled(model.messageOnly)
                        fileTable(model.visibleEntries, selection: $model.selection, staged: model.stagingEnabled ? model.stagedDiff : nil).frame(minHeight: 180).disabled(model.messageOnly)
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Staging support (EXPERIMENTAL)", isOn: $model.stagingEnabled)
                                Toggle("Show Unversioned Files", isOn: $model.showUnversioned)
                                Toggle("Do not autoselect submodules", isOn: $model.doNotAutoselectSubmodules).disabled(model.stagingEnabled)
                            }.toggleStyle(.checkbox)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 6) {
                                if model.stagingEnabled {
                                    Button(model.partialMode == false ? "Hide Staging «" : "Partial Staging »") { model.showPartial(false) }
                                    Button(model.partialMode == true ? "Hide Unstaging «" : "Partial Unstaging »") { model.showPartial(true) }
                                } else {
                                    Button(model.viewingPatch ? "Hide Patch «" : "View Patch »") { model.showViewPatch() }
                                }
                                Text(model.stagingEnabled ? "\(model.stagedEntries.count) staged, \(model.unstagedEntries.count) unstaged files shown" : "\(model.checked.count) files checked, \(model.visibleEntries.count) files shown").font(.caption)
                            }
                        }
                    }.padding(4)
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
            TableColumn("Path") { entry in HStack { Image(nsImage: entry.state.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(entry.path).foregroundStyle(entry.state.textColor) }.help(entry.originalPath.map { "Renamed from \($0)" } ?? entry.path) }.width(min: 260, ideal: 420)
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
    func checkButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View { Button(title, action: action).buttonStyle(.plain).foregroundStyle(enabled ? Color.blue : Color.secondary).disabled(!enabled) }
}

/// Upstream has separate date and time fields, including seconds.
private struct CommitDatePicker: NSViewRepresentable {
    @Binding var selection: Date
    @Environment(\.isEnabled) private var environmentEnabled
    let time: Bool
    let enabled: Bool
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single
        picker.datePickerElements = time ? .hourMinuteSecond : .yearMonthDay
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.setAccessibilityLabel(time ? "Author time" : "Author date")
        return picker
    }
    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.selection = $selection
        if picker.dateValue != selection { picker.dateValue = selection }
        picker.isEnabled = enabled && environmentEnabled
    }
    final class Coordinator: NSObject {
        var selection: Binding<Date>
        init(selection: Binding<Date>) { self.selection = selection }
        @objc func changed(_ sender: NSDatePicker) { selection.wrappedValue = sender.dateValue }
    }
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
