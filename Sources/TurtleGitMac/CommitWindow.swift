import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

@MainActor final class CommitWindowController: NSWindowController, NSWindowDelegate {
    let model: CommitWindowModel
    var onClosed: () -> Void = {}
    private var partial: PatchWindowController?
    private var closingCommit = false
    private var historyWindow: NSWindow?
    private var logPicker: LogWindowController?
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
        model.showMessageHistory = { [weak self] insert in self?.showHistory(insert: insert) }
        model.pickRevision = { [weak self] message, insert in self?.showRevisionPicker(message: message, insert: insert) }
        model.chooseApplication = { [weak self] path in
            guard let self, let window = self.window else { return }
            let panel = NSOpenPanel()
            panel.title = "Open With"; panel.prompt = "Open"
            panel.allowedContentTypes = [.applicationBundle]
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let app = panel.url else { return }
                self?.model.openFile(path, application: app)
            }
        }
        model.chooseExportFolder = { [weak self] paths in
            // Finish context-menu tracking before starting the native sheet.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.attachedSheet == nil else { return }
                let panel = NSOpenPanel()
                panel.title = "Export selected files"; panel.prompt = "Export"
                panel.canChooseFiles = false; panel.canChooseDirectories = true
                panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
                panel.beginSheetModal(for: window) { [weak self] response in
                    guard response == .OK, let folder = panel.url else { return }
                    self?.model.exportFiles(paths, to: folder)
                }
            }
        }
        model.chooseRestoreCopies = { [weak window] allowCancel, choose in
            guard let window else { choose(.cancel); return }
            let alert = NSAlert()
            alert.messageText = "You marked some files as “Restore after commit”."
            alert.informativeText = "Do you want to restore them now? You might lose all changes to this file after marking it."
            alert.addButton(withTitle: "Keep current state"); alert.addButton(withTitle: "Restore old state")
            if allowCancel { alert.addButton(withTitle: "Cancel") }
            alert.beginSheetModal(for: window) { response in
                choose(response == .alertSecondButtonReturn ? .restore : response == .alertFirstButtonReturn ? .keep : .cancel)
            }
        }
        model.confirmCancel = { [weak window] choose in
            guard let window else { choose(false); return }
            let alert = NSAlert(); alert.messageText = "Do you really want to cancel?"
            alert.informativeText = "Your commit message is saved in Recent messages."
            alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
            alert.showsSuppressionButton = true
            alert.beginSheetModal(for: window) { response in
                if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "Commit.SkipCancelConfirmation") }
                choose(response == .alertSecondButtonReturn)
            }
        }
        model.confirmUneditedTemplate = { [weak window] proceed in
            guard let window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The commit message template has not been edited."
            alert.informativeText = "Do you want to proceed with this commit anyway?"
            alert.addButton(withTitle: "Proceed anyway"); alert.addButton(withTitle: "No")
            alert.showsSuppressionButton = true
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "Commit.TemplateNotEdited.Proceed") }
                    proceed()
                }
            }
        }
    }
    func setQuitConfirmation(_ pending: Bool) { model.confirmingQuit = pending; partial?.model.confirmingQuit = pending }
    func windowWillClose(_ notification: Notification) { closingCommit = true; logPicker?.close(); logPicker = nil; partial?.close(); partial = nil; onClosed() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.cancel(); return false }
    private func showHistory(insert: @escaping (String) -> Void) {
        guard let window, let history = model.messageHistory, historyWindow == nil else { return }
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        child.title = "Log History – TurtleGit"; child.minSize = NSSize(width: 400, height: 260)
        child.contentViewController = NSHostingController(rootView: CommitMessageHistoryDialog(history: history) { [weak self, weak window, weak child] text in
            guard let child else { return }; window?.endSheet(child); child.orderOut(nil); self?.historyWindow = nil
            if let text { insert(text) }
        })
        historyWindow = child; window.beginSheet(child)
    }
    private func showRevisionPicker(message: Bool, insert: @escaping (String) -> Void) {
        guard let window, logPicker == nil else { return }
        let picker = LogWindowController(repository: model.repository, access: model.access) { [weak self] revision in
            if let revision { insert(message ? revision.message : revision.hash) }
            if let self, !self.closingCommit { self.model.reload() }
        }
        logPicker = picker
        picker.onClosed = { [weak self] in self?.logPicker = nil }
        model.configureLogPicker(picker.model)
        guard let child = picker.window else { logPicker = nil; return }
        window.beginSheet(child)
    }
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
    @Published var conflictRebase = false
    @Published var entries: [StatusEntry] = []
    @Published var indexFlagFiles: [WorkingTreeFile] = []
    @Published var restoreCopies: [String: WorkingFileRestoreCopy] = [:]
    enum RestoreChoice { case restore, keep, cancel }
    var chooseRestoreCopies: (Bool, @escaping (RestoreChoice) -> Void) -> Void = { _, choose in choose(.keep) }
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
    @Published var focusedFiles: [String: String] = [:]
    @Published var changelists = GitChangelists()
    @Published var changelistsLoaded = false
    @Published var keepChangelists = UserDefaults.standard.bool(forKey: "Commit.KeepChangelists")
    @Published var creatingChangelist = false
    @Published var changelistName = ""
    private var changelistPaths: [String] = []
    @Published var branch = ""
    @Published var createBranch = false
    @Published var newBranch = ""
    @Published var message = ""
    private var loadedMessage = false
    private(set) var messageTemplate = ""
    private(set) var messageHistory: CommitMessageHistory?
    var showMessageHistory: (@escaping (String) -> Void) -> Void = { _ in }
    var pickRevision: (Bool, @escaping (String) -> Void) -> Void = { _, _ in }
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    var onCompare: ([String], Bool) -> Void = { _, _ in }
    var onFileLog: (String) -> Void = { _ in }
    var onFileBlame: (String) -> Void = { _ in }
    var onResolve: (RepositoryAction, [String]) -> Void = { _, _ in }
    var onIgnore: (RepositoryAction, [String]) -> Void = { _, _ in }
    var onRename: (String) -> Void = { _ in }
    var chooseApplication: (String) -> Void = { _ in }
    var chooseExportFolder: ([String]) -> Void = { _ in }
    var confirmCancel: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    private var originalAmendMessage = ""
    var confirmUneditedTemplate: (@escaping () -> Void) -> Void = { _ in }
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
    @Published var confirmingQuit = false
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
    func openFile(_ path: String, application: URL? = nil) {
        guard !busy else { return }
        let url = repository.root.appendingPathComponent(path)
        if let application {
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, failure in
                if let failure { Task { @MainActor in self?.error = failure.localizedDescription } }
            }
        } else if !NSWorkspace.shared.open(url) { error = "Could not open \(path)." }
    }
    func exportFiles(_ paths: [String], to folder: URL) {
        guard !busy, !confirmingQuit else { return }
        busy = true
        let scoped = folder.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { folder.stopAccessingSecurityScopedResource() }; busy = false }
            do {
                try validateRestoreAccess()
                try await repository.exportWorkingFiles(paths: paths, to: folder)
            } catch { self.error = error.localizedDescription }
        }
    }
    func openInEditor(_ path: String) {
        guard !busy, !confirmingQuit else { return }
        do { try validateRestoreAccess() } catch { self.error = error.localizedDescription; return }
        AlternativeEditor.open(repository.root.appendingPathComponent(path)) { [weak self] failure in
            if let failure { self?.error = failure }
        }
    }
    enum CopyFileInformation: String, CaseIterable {
        case fullPaths = "Full paths", relativePaths = "Relative paths", names = "File/folder names", all = "Copy all information to clipboard"
    }
    func copyFiles(_ selected: [StatusEntry], information: CopyFileInformation, staged: Bool?) {
        let stats = staged.map { $0 ? stagedStatistics : unstagedStatistics } ?? statistics
        let copy: StatusListCopy
        switch information {
        case .fullPaths: copy = .fullPaths
        case .relativePaths: copy = .relativePaths
        case .names: copy = .names
        case .all: copy = .all
        }
        copyFileText(selected, statistics: stats, copy: copy)
    }
    func copyFileText(_ selected: [StatusEntry], statistics: [String: CommitFile], copy: StatusListCopy) {
        guard !selected.isEmpty else { return }
        let text = StatusListClipboard.text(selected, root: repository.root, statistics: statistics, copy: copy)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    private func validateRestoreAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    var onRevert: ([StatusEntry], Bool, Bool, @escaping (Bool) -> Void) -> Void = { _, _, _, done in done(false) }
    func revertFiles(_ selected: [StatusEntry]) {
        guard !busy, !confirmingQuit, !selected.isEmpty else { return }
        if selected.contains(where: { [.modified, .conflicted].contains($0.state) }) {
            let alert = NSAlert()
            alert.messageText = "Are you sure you want to revert \(selected.count) item(s)?"
            alert.informativeText = "You will lose ALL changes since the last update! Existing replaced file contents are moved to Trash. Added files remain on disk as unversioned files."
            alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        busy = true
        onRevert(selected, amend, amendDiffToLastCommit) { [weak self] succeeded in
            guard let self else { return }
            if succeeded { self.checked.subtract(selected.map(\.path)); self.selection.subtract(selected.map(\.path)) }
            self.busy = false; self.reload(); self.refreshPartial()
        }
    }
    func markForRestore(_ paths: Set<String>) {
        guard !busy, !paths.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try validateRestoreAccess()
                for path in paths.sorted() where restoreCopies[path] == nil {
                    restoreCopies[path] = try await repository.captureWorkingFileRestoreCopy(path: path)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func restoreSavedCopies(_ paths: Set<String>) async throws {
        guard paths.contains(where: { restoreCopies[$0] != nil }) else { return }
        try validateRestoreAccess()
        for path in paths.sorted() {
            guard let copy = restoreCopies[path] else { continue }
            try await repository.restoreWorkingFile(copy)
            restoreCopies.removeValue(forKey: path)
        }
    }
    func restoreNow(_ paths: Set<String>) {
        guard !busy, paths.contains(where: { restoreCopies[$0] != nil }) else { return }
        let alert = NSAlert()
        alert.messageText = "Do you really want to restore the copy?"
        alert.informativeText = "You will lose all changes that you have done after creating the copy."
        alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Restore")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        Task {
            do { try await restoreSavedCopies(paths) }
            catch { self.error = error.localizedDescription }
            busy = false; reload()
        }
    }
    private func chooseSavedCopies(allowCancel: Bool) async -> RestoreChoice {
        await withCheckedContinuation { continuation in
            chooseRestoreCopies(allowCancel) { continuation.resume(returning: $0) }
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
            busy = false; reload()
        }
    }
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
    func addFiles(_ selected: [StatusEntry], mode: WorkingFileAddMode) {
        guard !busy, !confirmingQuit, !selected.isEmpty else { return }
        busy = true
        let paths = selected.map(\.path)
        Task {
            do {
                try validateRestoreAccess()
                try await repository.addWorkingFiles(paths: paths, mode: mode)
                checked.formUnion(paths)
            } catch { self.error = error.localizedDescription }
            busy = false; reload()
        }
    }
    func deleteFiles(_ selected: [StatusEntry], selectionMark: StatusEntry? = nil, permanently: Bool) {
        guard !busy, !confirmingQuit, !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = permanently ? "Permanently delete the selected paths?" : "Move the selected paths to Trash?"
        alert.informativeText = "\(selected.count) selected item(s). Their index entries will also be removed." + (permanently ? " This cannot be undone." : " Files moved to Trash can be recovered in Finder.")
        alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        Task {
            do {
                try validateRestoreAccess()
                _ = try await repository.deleteWorkingFiles(selected, selectionMark: selectionMark, permanently: permanently)
                checked.subtract(selected.map(\.path)); selection.subtract(selected.map(\.path))
            } catch { self.error = error.localizedDescription }
            busy = false; reload()
        }
    }
    func newChangelist(_ selected: [StatusEntry]) {
        guard !busy, !confirmingQuit, !selected.isEmpty else { return }
        changelistPaths = selected.map(\.path); changelistName = ""; creatingChangelist = true
    }
    func createChangelist() {
        guard !changelistName.isEmpty else { return }
        let paths = changelistPaths, name = changelistName
        creatingChangelist = false; changelistPaths = []; changelistName = ""
        moveToChangelist(paths, name: name)
    }
    func cancelChangelist() { creatingChangelist = false; changelistPaths = []; changelistName = "" }
    func saveKeepChangelists(_ value: Bool) {
        keepChangelists = value; UserDefaults.standard.set(value, forKey: "Commit.KeepChangelists")
    }
    func moveToChangelist(_ paths: [String], name: String?) {
        guard !busy, !confirmingQuit, !paths.isEmpty else { return }
        busy = true
        Task {
            do {
                try validateRestoreAccess()
                changelists = try await repository.assignChangelist(paths: paths, name: name)
                if name == GitChangelists.ignored {
                    checked.subtract(paths)
                    if stagingEnabled {
                        do { try await repository.unstage(paths) }
                        catch { self.error = "The changelist was saved, but unstaging its paths failed.\n\n" + error.localizedDescription }
                    }
                }
            } catch { self.error = error.localizedDescription }
            busy = false; reload()
        }
    }
    func fileHelp(_ entry: StatusEntry) -> String {
        let origin = entry.originalPath.map { "Renamed from " + $0 } ?? entry.path
        return changelists.assignments[entry.path].map { origin + "\nChangelist: " + $0 } ?? origin
    }
    var canCommit: Bool { !busy && !confirmingQuit && changelistsLoaded && (messageOnly || (stagingEnabled ? entries.contains(where: \.staged) || amend : !checked.isEmpty || (amend && amendDiffToLastCommit))) && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!createBranch || !newBranch.isEmpty) && (!setAuthor || !author.isEmpty) }
    func didRename(_ source: String, to destination: String) {
        func moved(_ path: String) -> String { path == source ? destination : path.hasPrefix(source + "/") ? destination + path.dropFirst(source.count) : path }
        checked = Set(checked.map(moved)); selection = Set(selection.map(moved)); scopePaths = scopePaths.map(moved); reload()
    }
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
                changelistsLoaded = false
                changelists = try await repository.changelists(); changelistsLoaded = true
                indexFlagFiles = try await repository.workingTreeStatus()
                conflictRebase = (try await repository.conflictIsRebase())
                statistics = Dictionary(try await repository.workingTreeFiles(amendToParent: amendToParent).map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                stagedStatistics = Dictionary(try await repository.stagingFiles(staged: true, base: comparisonBase).map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                unstagedStatistics = Dictionary(try await repository.stagingFiles(staged: false).map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                if resetChecks {
                    checked = Set(visibleEntries.filter { entry in
                        let inScope = scopePaths.isEmpty || scopePaths.contains { $0 == entry.path || entry.path.hasPrefix($0 + "/") }
                        return inScope && !changelists.ignores(entry.path) && (!doNotAutoselectSubmodules || !submodules.contains(entry.path)) && entry.state != .conflicted && (entry.state != .untracked || !scopePaths.isEmpty)
                    }.map(\.id))
                } else { checked.formIntersection(Set(entries.map(\.id))) }
                selection.formIntersection(Set(entries.map(\.id)))
                if !hasLoaded && author.isEmpty {
                    let name = (try? await repository.run(["config", "user.name"]).text.trimmingCharacters(in: .newlines)) ?? ""
                    let email = (try? await repository.run(["config", "user.email"]).text.trimmingCharacters(in: .newlines)) ?? ""
                    author = name.isEmpty ? "" : "\(name) <\(email)>"
                }
                hasLoaded = true; refreshPartial()
                if !loadedMessage {
                    let identity = try await repository.commitMessageHistoryIdentity()
                    let storedLimit = UserDefaults.standard.object(forKey: "Commit.MaxHistoryItems") as? Int ?? 25
                    messageHistory = CommitMessageHistory(repositoryIdentity: identity, limit: storedLimit)
                    let seed = try await repository.commitMessageSeed()
                    messageTemplate = seed.template
                    if message.isEmpty && !amend { message = seed.message }
                    loadedMessage = true
                    if !seed.warnings.isEmpty { self.error = seed.warnings.joined(separator: "\n\n") }
                }
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
                    originalAmendMessage = message
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
    func compare(paths selected: Set<String>) {
        guard !busy, !confirmingQuit else { return }
        let paths = entries.filter { selected.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }; onCompare(paths, amendToParent)
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
    func commit(_ action: CompletionAction = .commit, templateConfirmed: Bool = false) {
        guard canCommit else { return }
        if !templateConfirmed && !messageTemplate.isEmpty && message == messageTemplate && !UserDefaults.standard.bool(forKey: "Commit.TemplateNotEdited.Proceed") {
            confirmUneditedTemplate { [weak self] in self?.commit(action, templateConfirmed: true) }
            return
        }
        let text = message, paths = checked, staging = stagingEnabled
        let committedPaths = staging ? Set(entries.filter(\.staged).map(\.path)) : paths
        let retainedChangelists = Set(visibleEntries.filter { !committedPaths.contains($0.path) }.map(\.path)).union(restoreCopies.keys)
        let pruningScope = showWholeProject ? [] : scopePaths
        let preserveChangelists = keepChangelists
        var options = CommitOptions(); options.amend = amend; options.amendDiffToLastCommit = amendDiffToLastCommit; options.author = setAuthor ? author : nil
        options.authorDate = setAuthorDate ? authorDate : nil; options.resetAuthorDate = amend && setAuthorDate && resetAuthorDate; options.messageOnly = messageOnly; options.newBranch = createBranch ? newBranch : nil
        busy = true
        Task {
            do {
                let output: String
                if staging { output = try await repository.commitIndex(message: text, options: options) }
                else { output = try await repository.commitSelected(message: text, paths: paths, options: options) }
                messageHistory?.add(text)
                if options.amend && !nonAmendMessage.isEmpty && nonAmendMessage != messageTemplate { messageHistory?.add(nonAmendMessage) }
                onCommitted(output)
                do { try await restoreSavedCopies(Set(restoreCopies.keys)) }
                catch {
                    self.error = "The commit succeeded, but restoring saved working copies failed. The remaining copies are retained in this dialog.\n\n" + error.localizedDescription
                    busy = false; reload(); return
                }
                if !preserveChangelists {
                    do { changelists = try await repository.pruneChangelists(retaining: retainedChangelists, scope: pruningScope) }
                    catch {
                        self.error = "The commit succeeded, but updating changelists failed.\n\n" + error.localizedDescription
                        busy = false; reload(); return
                    }
                }
                if action == .recommit {
                    do {
                        let seed = try await repository.commitMessageSeed(includeOperationMessages: false)
                        messageTemplate = seed.template; message = seed.template
                        if !seed.warnings.isEmpty { self.error = seed.warnings.joined(separator: "\n\n") }
                    } catch { messageTemplate = ""; message = ""; self.error = error.localizedDescription }
                    createBranch = false; newBranch = ""; amend = false; amendDiffToLastCommit = false; amendMessage = ""; nonAmendMessage = ""; setAuthorDate = false; resetAuthorDate = false; setAuthor = false; messageOnly = false
                    checked = []; selection = []; hasLoaded = false
                    busy = false
                    reload(paths: scopePaths.isEmpty ? ["."] : scopePaths)
                } else { busy = false; close(); if action == .push { onPush() } }
            } catch {
                let commitError = error.localizedDescription
                var failureMessage = commitError
                if !restoreCopies.isEmpty, await chooseSavedCopies(allowCancel: false) == .restore {
                    do { try await restoreSavedCopies(Set(restoreCopies.keys)) }
                    catch { failureMessage = commitError + "\n\nRestoring saved working copies failed: " + error.localizedDescription }
                }
                self.error = failureMessage
                busy = false; reload()
            }
        }
    }
    var checkedFileList: String {
        visibleEntries.filter { stagingEnabled ? $0.staged : checked.contains($0.id) }.map { entry in
            let label = entry.state == .untracked ? "Added" : entry.state.rawValue.capitalized
            return label.padding(toLength: max(10, label.count), withPad: " ", startingAt: 0) + " " + entry.path + "\n"
        }.joined()
    }
    func cancel(closeWindow: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard !busy, !confirmingQuit || !closeWindow else { completion?(false); return }
        let changed = !message.isEmpty && message != (amend ? originalAmendMessage : messageTemplate)
        let finish = { [weak self] in
            guard let self else { completion?(false); return }
            if changed { self.messageHistory?.add(self.message) }
            if self.amend && !self.nonAmendMessage.isEmpty && self.nonAmendMessage != self.messageTemplate { self.messageHistory?.add(self.nonAmendMessage) }
            if closeWindow { self.restoreCopies.removeAll(); self.close() }
            completion?(true)
        }
        let restoreAndFinish = { [weak self] in
            guard let self else { completion?(false); return }
            guard !self.restoreCopies.isEmpty else { finish(); return }
            self.busy = true
            Task {
                let choice = await self.chooseSavedCopies(allowCancel: true)
                if choice == .cancel { self.busy = false; completion?(false); return }
                if choice == .restore {
                    do { try await self.restoreSavedCopies(Set(self.restoreCopies.keys)) }
                    catch { self.error = error.localizedDescription; self.busy = false; self.reload(); completion?(false); return }
                }
                self.busy = false; finish()
            }
        }
        if (changed || !entries.isEmpty) && !UserDefaults.standard.bool(forKey: "Commit.SkipCancelConfirmation") {
            confirmCancel { approved in if approved { restoreAndFinish() } else { completion?(false) } }
        } else { restoreAndFinish() }
    }
}

struct CommitDialog: View {
    @ObservedObject var model: CommitWindowModel
    @AppStorage("Commit.MessagePaneHeight") private var messagePaneHeight = 300.0
    @State private var dividerStart: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Commit to:")
                if model.createBranch { TextField("New branch name", text: $model.newBranch).frame(width: 250) }
                else { Text(model.branch.isEmpty ? "Detached / unborn HEAD" : model.branch).foregroundStyle(.blue) }
                Toggle("new branch", isOn: $model.createBranch).toggleStyle(.checkbox)
                Spacer(); if model.busy { ProgressView().controlSize(.small) }
            }
            GeometryReader { geometry in
                let maximum = max(245.0, geometry.size.height - 288)
                let height = min(max(messagePaneHeight, 245), maximum)
                VStack(spacing: 0) {
                    messageSection.frame(height: height)
                    Divider().frame(height: 8).contentShape(Rectangle())
                        .background(CommitDividerCursor().accessibilityHidden(true))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            guard !model.busy else { return }
                            if dividerStart == nil { dividerStart = height }
                            messagePaneHeight = min(max((dividerStart ?? height) + drag.translation.height, 245), maximum)
                        }.onEnded { _ in dividerStart = nil })
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Message and changes divider")
                        .accessibilityValue("\(Int(height)) points")
                        .accessibilityAdjustableAction { direction in
                            guard !model.busy else { return }
                            switch direction {
                            case .increment: messagePaneHeight = min(height + 20, maximum)
                            case .decrement: messagePaneHeight = max(height - 20, 245)
                            @unknown default: break
                            }
                        }
                    changesSection.frame(maxHeight: .infinity)
                }
            }
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
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-commit.html")!) }
            }
        }.padding(12).disabled(model.busy || model.confirmingQuit)
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
        .alert("TurtleGit", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.creatingChangelist) { CreateChangelistSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.patch != nil }, set: { if !$0 { model.patch = nil } })) {
            VStack { Text("Unified Diff").font(.headline); OutputView(text: model.patch ?? "").frame(minWidth: 850, minHeight: 520); Button("Close") { model.patch = nil }.keyboardShortcut(.cancelAction) }.padding(12)
        }
    }
    private var messageSection: some View {
GroupBox("Message:") {
                VStack(alignment: .leading, spacing: 8) {
                    CommitMessageEditor(model: model).frame(minHeight: 100, maxHeight: .infinity).border(Color.secondary.opacity(0.3))
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
                        fileTable(model.visibleEntries, selection: $model.selection, staged: model.stagingEnabled ? model.stagedDiff : nil).frame(minHeight: 120).disabled(model.messageOnly)
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
        let focusKey = staged.map { $0 ? "staged" : "unstaged" } ?? "checkbox"
        let focus = Binding<String?>(get: { model.focusedFiles[focusKey] }, set: { model.focusedFiles[focusKey] = $0 })
        return Table(entries, selection: selection) {
            TableColumn("") { entry in
                if staged != nil {
                    StagingCheckbox(entry: entry, enabled: !model.busy) { model.moveToStage([entry.id], staged: $0) }.frame(width: 20, height: 20)
                } else {
                    Toggle("Include \(entry.path)", isOn: Binding(get: { model.checked.contains(entry.id) }, set: { if $0 { model.checked.insert(entry.id) } else { model.checked.remove(entry.id) } }))
                        .labelsHidden().toggleStyle(.checkbox).disabled(entry.state == .conflicted)
                }
            }.width(24)
            TableColumn("Path") { entry in HStack { Image(nsImage: entry.state.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16).overlay { if model.restoreCopies[entry.path] != nil { Image(nsImage: MenuIcon.restoreOverlay.image() ?? NSImage()).resizable().frame(width: 16, height: 16) } }; Text(StatusListClipboard.displayedPath(entry)).foregroundStyle(selection.wrappedValue.contains(entry.id) ? Color.primary : entry.state.textColor) }.help(model.fileHelp(entry)) }.width(min: 260, ideal: 420)
            TableColumn("Extension") { entry in Text(StatusListClipboard.fileExtension(entry.path, isDirectory: model.submodules.contains(entry.path))) }.width(75)
            TableColumn("Status") { entry in Text(entry.index == "R" || entry.worktree == "R" ? "Renamed" : statistics[entry.path]?.status ?? entry.state.rawValue.capitalized) }.width(90)
            TableColumn("Lines added") { entry in Text(statistics[entry.path]?.added.map(String.init) ?? "–").foregroundStyle(selection.wrappedValue.contains(entry.id) ? Color.primary : Color.blue) }.width(80)
            TableColumn("Lines removed") { entry in Text(statistics[entry.path]?.removed.map(String.init) ?? "–").foregroundStyle(selection.wrappedValue.contains(entry.id) ? Color.primary : Color.blue) }.width(95)
        }.contextMenu(forSelectionType: String.self) { ids in
            let selected = entries.filter { ids.contains($0.id) }
            let flagFiles = model.indexFlagFiles.filter { ids.contains($0.id) }
            let selectionMark = entries.first { $0.path == focus.wrappedValue } ?? (selected.count == 1 ? selected.first : nil)
            if !selected.isEmpty && selected.allSatisfy({ [.untracked, .ignored].contains($0.state) }) {
                Button { model.addFiles(selected, mode: .normal) } label: { CommandLabel(title: WorkingFileAddMode.normal.rawValue, icon: .add) }.disabled(model.busy || model.confirmingQuit)
                if NSEvent.modifierFlags.contains(.shift), selected.allSatisfy({ !model.submodules.contains($0.path) }) {
                    ForEach([WorkingFileAddMode.executable, .symlink], id: \.self) { mode in
                        Button { model.addFiles(selected, mode: mode) } label: { CommandLabel(title: mode.rawValue, icon: .add) }.disabled(model.busy || model.confirmingQuit)
                    }
                }
                Divider()
            }
            Button { model.compare(paths: ids) } label: { CommandLabel(title: "Compare with base", icon: .compare) }.disabled(ids.isEmpty)
            Button { model.diff(paths: ids, staged: staged) } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(ids.isEmpty)
            Divider()
            if staged != nil {
                Button { model.moveToStage(ids, staged: true) } label: { CommandLabel(title: "Stage selected files", icon: .add) }.disabled(ids.isEmpty)
                Button { model.moveToStage(ids, staged: false) } label: { CommandLabel(title: "Unstage selected files", icon: .revert) }.disabled(ids.isEmpty)
            } else {
                Button { model.check { ids.contains($0.id) } } label: { CommandLabel(title: "Check selected files", icon: .add) }
                Button { model.checked.subtract(ids) } label: { CommandLabel(title: "Uncheck selected files", icon: .revert) }
            }
            if !selected.isEmpty && selected.allSatisfy({ ![FileState.untracked, .ignored].contains($0.state) }) {
                Button { model.revertFiles(selected) } label: { CommandLabel(title: "Revert", icon: .revert) }
            }
            if !selected.isEmpty && selected.allSatisfy({ ![FileState.untracked, .ignored].contains($0.state) && !model.submodules.contains($0.path) }) {
                if let first = selected.first, model.restoreCopies[first.path] != nil {
                    Button { model.restoreNow(ids) } label: { CommandLabel(title: "Restore", icon: .restore) }
                } else {
                    Button { model.markForRestore(ids) } label: { CommandLabel(title: "Restore after commit", icon: .restore) }
                }
            }
            if flagFiles.count == selected.count { IndexFlagsMenu(files: flagFiles) { model.setFlags($0, files: flagFiles) } }
            if !selected.isEmpty && selected.allSatisfy({ $0.state == .conflicted }) {
                Divider()
                ResolveSelectionMenu(paths: selected.map(\.path), rebase: model.conflictRebase, canEdit: selected.count == 1, action: model.onResolve)
            }
            if selected.count == 1, let entry = selected.first {
                Divider()
                if entry.state != .untracked && entry.state != .ignored {
                    Button { model.onFileLog(entry.path) } label: { CommandLabel(title: "Show log", icon: .log) }
                    if entry.state != .deleted {
                        Button { model.onRename(entry.path) } label: { CommandLabel(title: "Rename…", icon: .rename) }
                    }
                    if let oldPath = entry.originalPath {
                        Button { model.onFileLog(oldPath) } label: { CommandLabel(title: "Show log of old name", icon: .log) }
                    }
                    if entry.state != .added && entry.state != .deleted && !model.submodules.contains(entry.path) {
                        Button { model.onFileBlame(entry.path) } label: { CommandLabel(title: "Blame", icon: .blame) }
                    }
                }
            }
            if !selected.isEmpty && selected.allSatisfy({ $0.state != .deleted && FileManager.default.fileExists(atPath: model.repository.root.appendingPathComponent($0.path).path) }) {
                Button { model.chooseExportFolder(selected.map(\.path)) } label: { CommandLabel(title: "Export…", icon: .export) }.disabled(model.busy || model.confirmingQuit)
            }
            if selected.count == 1, let entry = selected.first {
                if entry.state != .deleted && FileManager.default.fileExists(atPath: model.repository.root.appendingPathComponent(entry.path).path) {
                    if !model.submodules.contains(entry.path) {
                        Button { model.openInEditor(entry.path) } label: { CommandLabel(title: "View revision in alternative editor", icon: .editor) }.disabled(model.busy || model.confirmingQuit)
                        Button { model.openFile(entry.path) } label: { CommandLabel(title: "Open", icon: .open) }
                        Button { model.chooseApplication(entry.path) } label: { CommandLabel(title: "Open With…", icon: .open) }
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([model.repository.root.appendingPathComponent(entry.path)]) } label: { CommandLabel(title: "Reveal in Finder", icon: .explore) }
                }
            }
            if !selected.isEmpty && selectionMark?.canDeleteFromStatusList == true {
                Button { model.deleteFiles(selected, selectionMark: selectionMark, permanently: NSEvent.modifierFlags.contains(.shift)) } label: { CommandLabel(title: "Delete", icon: .remove) }.disabled(model.busy || model.confirmingQuit)
            }
            if !selected.isEmpty && selected.allSatisfy({ [.untracked, .deleted].contains($0.state) }) {
                Divider()
                IgnoreSelectionMenu(paths: selected.map(\.path), action: model.onIgnore)
            }
            if !selected.isEmpty {
                Divider()
                Menu {
                    ForEach(CommitWindowModel.CopyFileInformation.allCases, id: \.self) { information in
                        Button { model.copyFiles(selected, information: information, staged: staged) } label: { CommandLabel(title: information.rawValue, icon: .copy) }
                    }
                } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }
            }
            // The pinned upstream gate compares legacy status values to action
            // bits: only a pure Added action (1) is excluded, not UNVER (0x80000000).
            if !selected.isEmpty, let mark = selectionMark, !(mark.index == "A" && mark.worktree == " ") {
                Divider()
                if selected.contains(where: { model.changelists.assignments[$0.path] != nil }) {
                    Button("Remove from changelist") { model.moveToChangelist(selected.map(\.path), name: nil) }
                }
                Menu("Move to changelist") {
                    Button("<new changelist>") { model.newChangelist(selected) }
                    Divider()
                    Button(GitChangelists.ignored) { model.moveToChangelist(selected.map(\.path), name: GitChangelists.ignored) }
                    let names = model.changelists.names.filter { $0 != GitChangelists.ignored }
                    if !names.isEmpty {
                        Divider()
                        ForEach(names, id: \.self) { name in Button(name) { model.moveToChangelist(selected.map(\.path), name: name) } }
                    }
                }
                Toggle("Keep changelists", isOn: Binding(get: { model.keepChangelists }, set: { model.saveKeepChangelists($0) }))
            }
        } primaryAction: { ids in
            selection.wrappedValue = ids
            if ids.count == 1, let entry = model.entries.first(where: { ids.contains($0.id) }), entry.state == .conflicted { model.onResolve(.editConflict, [entry.path]) }
            else { model.compare(paths: ids) }
        }
        .background(CommitFileInteraction(entries: entries, focusedPath: focus, enabled: !model.busy && !model.confirmingQuit, delete: { model.deleteFiles($0, selectionMark: $1, permanently: $2) }, copy: { model.copyFileText($0, statistics: statistics, copy: $1 ? .pathsAndStatus : .relativePaths) }, copyColumn: { model.copyFileText($0, statistics: statistics, copy: .column($1)) }))
        .onChange(of: selection.wrappedValue) { ids in
            if ids.count == 1 && NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty { focus.wrappedValue = ids.first }
        }
    }
    func checkButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View { Button(title, action: action).buttonStyle(.plain).foregroundStyle(enabled ? Color.blue : Color.secondary).disabled(!enabled) }
}

/// The divider uses the system cursor; SwiftUI handles dragging and accessibility.
private struct CommitDividerCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {}
    final class CursorView: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
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
