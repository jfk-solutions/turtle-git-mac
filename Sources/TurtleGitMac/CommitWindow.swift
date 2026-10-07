import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

@MainActor private final class CommitNativeWindow: NSWindow {
    weak var model: CommitWindowModel?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 96, attachedSheet == nil, let model, !model.busy, !model.confirmingQuit {
            model.reload(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class CommitWindowController: NSWindowController, NSWindowDelegate {
    let model: CommitWindowModel
    var onClosed: () -> Void = {}
    private var partial: PatchWindowController?
    private var closingCommit = false
    private var historyWindow: NSWindow?
    private var logPicker: LogWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = CommitWindowModel(repository: repository, access: access)
        let window = CommitNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Commit – TurtleGit"
        window.minSize = NSSize(width: 900, height: 680); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CommitDialog(model: model))
        super.init(window: window); window.model = model; window.delegate = self; window.setContentSize(NSSize(width: 1000, height: 760)); window.center()
        model.close = { [weak self, weak window] in
            guard let self, self.partial?.model.busy != true, self.partial?.window?.attachedSheet == nil, !self.model.unifiedViewerBusy else { return }
            window?.close()
        }
        model.showPartial = { [weak self] staged in self?.showPartial(staged: staged) }
        model.showViewPatch = { [weak self] in self?.showPartial(staged: false, readOnly: true) }
        model.refreshPartial = { [weak self] in self?.reloadPartial() }
        model.closePartial = { [weak self] in
            guard let self, self.partial?.model.busy != true, self.partial?.window?.attachedSheet == nil else { return }
            self.partial?.close()
        }
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
        model.confirmUneditedTemplate = { [weak window] choose in
            guard let window else { choose(false); return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The commit message template has not been edited."
            alert.informativeText = "Do you want to proceed with this commit anyway?"
            alert.addButton(withTitle: "Proceed anyway"); alert.addButton(withTitle: "No")
            alert.showsSuppressionButton = true
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "Commit.TemplateNotEdited.Proceed") }
                }
                choose(response == .alertFirstButtonReturn)
            }
        }
        model.confirmMissingIssue = { [weak window] choose in
            guard let window else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "You have not entered an issue ID."
            alert.informativeText = "Do you want to commit without an issue ID?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
        model.confirmMissingSignOff = { [weak window] choose in
            guard let window else { choose(.abort); return }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "The commit message has no Signed-off-by line for your Git identity."
            alert.addButton(withTitle: "Add Signed-off-by"); alert.addButton(withTitle: "Commit without Signed-off-by"); alert.addButton(withTitle: "Abort")
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn ? .add : $0 == .alertSecondButtonReturn ? .proceed : .abort) }
        }
        model.confirmDirtySubmodule = { [weak window] path, choose in
            guard let window, window.attachedSheet == nil else { choose(.cancel); return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "The submodule \"" + path + "\" is dirty."
            alert.informativeText = "Merely committing the superproject cannot track or save such changes to the submodule.\nCommit the submodule now or ignore dirty changes?"
            alert.addButton(withTitle: "Commit"); alert.addButton(withTitle: "Ignore"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn ? .commit : $0 == .alertSecondButtonReturn ? .ignore : .cancel) }
        }
    }
    func setQuitConfirmation(_ pending: Bool) { model.confirmingQuit = pending; partial?.model.confirmingQuit = pending }
    func windowWillClose(_ notification: Notification) { closingCommit = true; logPicker?.close(); logPicker = nil; partial?.close(); partial = nil; model.unifiedWindow?.close(); onClosed() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard partial?.model.busy != true, partial?.window?.attachedSheet == nil, !model.unifiedViewerBusy else { return false }
        model.cancel(); return false
    }
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
        let picker = LogWindowController(repository: model.repository, access: model.access, onChoose: { [weak self] revision in
            if let revision { insert(message ? revision.message : revision.hash) }
            if let self, !self.closingCommit { self.model.reload() }
        })
        logPicker = picker
        picker.onClosed = { [weak self] in self?.logPicker = nil }
        model.configureLogPicker(picker.model)
        guard let child = picker.window else { logPicker = nil; return }
        window.beginSheet(child)
    }
    private func showPartial(staged: Bool, readOnly: Bool = false) {
        guard let window, partial?.model.busy != true, partial?.window?.attachedSheet == nil else { return }
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
    @Published var message = "" { didSet { if message != oldValue { scheduleIssueStyling() } } }
    @Published var issueProperties = IssueTrackerProperties() { didSet { if issueProperties != oldValue { scheduleIssueStyling() } } }
    @Published private(set) var issueMessageStyles: [IssueMessageStyle] = []
    private let issueStyler = IssueMessageStyler()
    private var issueStyleTask: Task<Void, Never>?
    @Published var formattingEnabled = UserDefaults.standard.object(forKey: "StyleCommitMessages") as? Bool ?? true {
        didSet { if formattingEnabled != oldValue { scheduleIssueStyling() } }
    }
    private(set) var messageSnippets = MessageSnippets()
    @Published private(set) var messageCompletionCatalog = MessageCompletionCatalog()
    private var completionTask: Task<Void, Never>?
    private var completionGeneration = UUID()
    private var completionSources: [MessageCodeScanner.Source] = []
    private var completionOptions: MessageCodeScanner.Options?
    private var completionEnabled: Bool?
    deinit { completionTask?.cancel(); issueStyleTask?.cancel() }
    func prepareMessageCompletions(force: Bool = false) {
        var options = MessageCodeScanner.Options()
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "Autocompletion") as? Bool ?? true
        options.removeExtensions = defaults.bool(forKey: "AutocompleteRemovesExtensions")
        options.parseUnversioned = defaults.bool(forKey: "AutocompleteParseUnversioned")
        options.maximumBytes = defaults.object(forKey: "AutocompleteParseMaxSize") as? Int ?? 300000
        options.timeoutSeconds = UInt32(clamping: defaults.object(forKey: "AutocompleteParseTimeout") as? Int ?? 5)
        options.useUTF8 = defaults.bool(forKey: "Merge.UseUTF8")
        let locallyIgnored = Set(indexFlagFiles.filter { $0.assumeUnchanged || $0.skipWorktree }.map { $0.entry.path })
        let rows = StatusListGroups.rows(entries: visibleEntries, changelists: changelists, locallyIgnored: locallyIgnored)
        let sources = rows.compactMap(\.entry).map { MessageCodeScanner.Source(path: $0.path, state: $0.state) }
        guard force || sources != completionSources || options != completionOptions || enabled != completionEnabled else { return }
        completionTask?.cancel()
        completionSources = sources; completionOptions = options; completionEnabled = enabled
        let generation = UUID(); completionGeneration = generation
        let snippets = messageSnippets, root = repository.root, lease = access
        let userDefinitions = RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("autolist.txt")
        completionTask = Task { [weak self] in
            guard !Task.isCancelled, self?.completionGeneration == generation else { return }
            self?.messageCompletionCatalog = MessageCompletionCatalog(snippets: snippets, paths: sources.map(\.path), removeExtensions: options.removeExtensions)
            guard enabled else { return }
            do {
                if GitRuntime.isAppStoreBuild && (lease?.hasSecurityScope != true || lease?.contains(root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result = try await MessageCodeScanner.shared.scan(root: root, sources: sources, snippets: snippets, userDefinitions: userDefinitions, options: options)
                guard !Task.isCancelled, let self, self.completionGeneration == generation else { return }
                self.messageCompletionCatalog = result.catalog
            } catch { /* Filename/snippet fallback remains available after cancellation or inaccessible contents. */ }
            withExtendedLifetime(lease) {}
        }
    }
    private let snippetLoader = MessageSnippetLoader()
    @Published var issueID = ""
    private func scheduleIssueStyling() {
        issueStyleTask?.cancel(); issueMessageStyles = []
        let text = message, properties = issueProperties, worker = issueStyler, formatting = formattingEnabled
        guard !text.isEmpty else { return }
        issueStyleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                let styles = try await worker.styles(properties: properties, message: text, formattingEnabled: formatting)
                guard !Task.isCancelled, let self, self.message == text, self.issueProperties == properties, self.formattingEnabled == formatting else { return }
                self.issueMessageStyles = styles
            } catch { /* Invalid/stale styling does not interrupt text entry. Commit validation reports configuration failures. */ }
        }
    }
    func updateIssueFromHistory(_ selectedMessage: String, insertedInto text: String) {
        let properties = issueProperties, previousID = issueID
        guard properties.showsIssueField else { return }
        Task { [weak self, repository] in
            guard let id = try? await repository.issueFieldValue(properties: properties, message: selectedMessage), !id.isEmpty,
                  let self, self.message == text, self.issueID == previousID, self.issueProperties == properties else { return }
            self.issueID = id
        }
    }
    private var loadedMessage = false
    private(set) var messageTemplate = ""
    private(set) var messageHistory: CommitMessageHistory?
    var showMessageHistory: (@escaping (String) -> Void) -> Void = { _ in }
    var pickRevision: (Bool, @escaping (String) -> Void) -> Void = { _, _ in }
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    var onCompare: ([String], Bool) -> Void = { _, _ in }
    var onCompareTwoFiles: ([String]) -> Void = { _ in }
    var onFileLog: (String) -> Void = { _ in }
    var onFileBlame: (String) -> Void = { _ in }
    var onResolve: (RepositoryAction, [String]) -> Void = { _, _ in }
    var onIgnore: (RepositoryAction, [String]) -> Void = { _, _ in }
    var onRename: (String) -> Void = { _ in }
    var chooseApplication: (String) -> Void = { _ in }
    var chooseExportFolder: ([String]) -> Void = { _ in }
    var confirmCancel: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    private var originalAmendMessage = ""
    var confirmUneditedTemplate: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    var confirmMissingIssue: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    enum DirtySubmoduleChoice { case commit, ignore, cancel }
    var confirmDirtySubmodule: (String, @escaping (DirtySubmoduleChoice) -> Void) -> Void = { _, choose in choose(.cancel) }
    var onCommitSubmodule: (URL) -> Void = { _ in }
    enum SignOffChoice { case add, proceed, abort }
    var confirmMissingSignOff: (@escaping (SignOffChoice) -> Void) -> Void = { choose in choose(.abort) }
    @Published var operation: CommitOperation?
    @Published var hasHead = false
    @Published var hasParent = false
    var replaySplit: RebaseSplitState?
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
    private let unversionedDefaults: UserDefaults
    private let dialogDefaults: UserDefaults
    private var selectFilesAutomatically: Bool
    private let doNotAutoselectMissing: Bool
    @Published var showWholeProject = true
    @Published var scopePaths: [String] = []
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    var unifiedWindow: PatchWindowController?
    var unifiedViewerBusy: Bool { unifiedWindow?.model.busy == true || unifiedWindow?.window?.attachedSheet != nil }
    var showViewPatch: () -> Void = {}
    var showPartial: (Bool) -> Void = { _ in }
    var refreshPartial: () -> Void = {}
    var closePartial: () -> Void = {}
    var close: () -> Void = {}
    var onCommitted: (String) -> Void = { _ in }
    var onPush: () -> Void = {}
    enum CompletionAction: String, CaseIterable { case commit = "Commit", recommit = "ReCommit", push = "Commit & Push" }
    init(repository: GitRepository, access: RepositoryAccessLease?, unversionedDefaults: UserDefaults = .standard, dialogDefaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.unversionedDefaults = unversionedDefaults
        self.dialogDefaults = dialogDefaults
        selectFilesAutomatically = dialogDefaults.object(forKey: "SelectFilesForCommit") as? Bool ?? true
        doNotAutoselectMissing = dialogDefaults.bool(forKey: "AutoselectMissingFiles")
        showUnversioned = unversionedDefaults.object(forKey: "AddBeforeCommit") == nil || unversionedDefaults.bool(forKey: "AddBeforeCommit")
    }
    func setShowUnversioned(_ enabled: Bool) {
        guard !busy, !confirmingQuit else { return }
        showUnversioned = enabled
        unversionedDefaults.set(enabled, forKey: "AddBeforeCommit")
    }
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
    func setFlags(_ action: IndexFlagAction, files: [WorkingTreeFile], selectionMark: WorkingTreeFile) {
        guard !busy, !confirmingQuit, !files.isEmpty, action.isAvailable(for: [selectionMark]), confirmIndexFlags(action) else { return }
        busy = true
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await repository.setIndexFlags(action, paths: files.map(\.id), markedPath: selectionMark.id)
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
    var checkedPathsForCommit: Set<String> { Set(visibleEntries.filter { checked.contains($0.id) }.map(\.path)) }
    var canCommit: Bool { !busy && !confirmingQuit && loadedMessage && changelistsLoaded && (messageOnly || (stagingEnabled ? entries.contains(where: \.staged) || operation == .merge || amend : !checkedPathsForCommit.isEmpty || operation == .merge || (amend && amendDiffToLastCommit))) && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!createBranch || !newBranch.isEmpty) && (!setAuthor || !author.isEmpty) }
    func didRename(_ source: String, to destination: String) {
        func moved(_ path: String) -> String { path == source ? destination : path.hasPrefix(source + "/") ? destination + path.dropFirst(source.count) : path }
        checked = Set(checked.map(moved)); selection = Set(selection.map(moved)); scopePaths = scopePaths.map(moved); reload()
    }
    func loadReplaySplit(_ split: RebaseSplitState, message: String) {
        replaySplit = split; amend = split.conflictRecovery == true || split.parts == 0; amendDiffToLastCommit = split.conflictRecovery == true
        self.message = split.conflictRecovery == true || split.parts == 0 ? message : ""
        if split.parts == 0, let date = split.squashDate {
            setAuthor = true; author = split.firstAuthor
            if date != .current, let value = ISO8601DateFormatter().date(from: split.firstDate) { setAuthorDate = true; authorDate = value }
            else if date == .current { setAuthorDate = true; resetAuthorDate = true }
        }
        reload(paths: ["."])
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
                operation = try await repository.commitOperation()
                if operation != nil { createBranch = false; amend = false }
                hasHead = (try? await repository.run(["rev-parse", "--verify", "HEAD"])) != nil
                hasParent = (try? await repository.run(["rev-parse", "--verify", "HEAD^1"])) != nil
                if amend && !hasParent { amendDiffToLastCommit = true }
                comparisonBase = amendToParent ? try await repository.commitComparisonBase(amendToParent: true) : nil
                entries = try await repository.commitDialogStatus(amendToParent: amendToParent); submodules = try await repository.submodulePaths(); branch = try await repository.branch()
                let snippetURL = RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("snippet.txt")
                messageSnippets = await snippetLoader.load(userURL: snippetURL)
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
                        let directFile = scopePaths.contains(entry.path)
                        let missing = entry.worktree == "D"
                        let automatic = (selectFilesAutomatically || replaySplit != nil) && entry.state != .untracked && (!doNotAutoselectMissing || !missing)
                        return inScope && (directFile || automatic) && !changelists.ignores(entry.path) && (!doNotAutoselectSubmodules || !submodules.contains(entry.path)) && entry.state != .conflicted
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
                    issueProperties = try await repository.issueTrackerProperties()
                    let identity = try await repository.commitMessageHistoryIdentity()
                    let storedLimit = dialogDefaults.object(forKey: "Commit.MaxHistoryItems") as? Int ?? 25
                    messageHistory = CommitMessageHistory(repositoryIdentity: identity, defaults: dialogDefaults, limit: storedLimit)
                    let seed = try await repository.commitMessageSeed()
                    messageTemplate = seed.template
                    if message.isEmpty && !amend {
                        let separated = issueProperties.separateIssueLine(from: seed.message)
                        message = separated.message; issueID = separated.issueID
                    }
                    loadedMessage = true
                    if !seed.warnings.isEmpty { self.error = seed.warnings.joined(separator: "\n\n") }
                }
                prepareMessageCompletions(force: true)
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
    func setGroupChecked(_ files: [StatusEntry], checked value: Bool) {
        guard !busy, !confirmingQuit else { return }
        let paths = Set(files.map(\.id))
        if stagingEnabled { moveToStage(paths, staged: value) }
        else if value { checked.formUnion(paths) }
        else { checked.subtract(paths) }
    }
    func setFileChecked(_ entry: StatusEntry, files: [StatusEntry], highlighted: Set<String>, checked value: Bool) {
        guard !busy, !confirmingQuit, entry.state != .conflicted else { return }
        let targets = StatusListSelection.checkboxEntries(entry: entry, entries: files, highlighted: highlighted)
        let paths = Set(targets.map(\.id))
        if stagingEnabled { moveToStage(paths, staged: value) }
        else if value { checked.formUnion(paths) }
        else { checked.subtract(paths) }
    }
    func uncheckAll() {
        if stagingEnabled { moveToStage(Set(visibleEntries.filter(\.staged).map(\.id)), staged: false) }
        else { checked.subtract(visibleEntries.map(\.id)) }
    }
    func amendChanged() {
        if replaySplit != nil { comparisonChanged(); return }
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
        guard replaySplit == nil else { return }
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
                let trailer = try await repository.commitSignOffLine()
                message = IssueTrackerProperties.addingSignOff(trailer, to: message)
            } catch { self.error = "Configure your Git user name and email before adding a sign-off.\n" + error.localizedDescription }
        }
    }
    func compare(paths selected: Set<String>) {
        guard !busy, !confirmingQuit else { return }
        let paths = entries.filter { selected.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }; onCompare(paths, amendToParent)
    }
    func diff(paths selected: Set<String>, staged: Bool? = nil, alternate: Bool = false) {
        guard !busy, !confirmingQuit, !unifiedViewerBusy else { return }
        let paths = entries.filter { selected.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let bytes: Data
                if let staged { bytes = try await repository.patchData(paths: paths, staged: staged, base: amendToParent && staged ? try await repository.commitComparisonBase(amendToParent: true) : nil) }
                else {
                    let head = try? await repository.run(["rev-parse", "--verify", "HEAD"])
                    let base = amendToParent ? try await repository.commitComparisonBase(amendToParent: true) : "HEAD"
                    let args = ["diff", "--no-ext-diff", "--no-color"] + (head == nil ? ["--cached"] : [base]) + ["--"] + paths
                    bytes = try await repository.run(args).stdout
                }
                if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate) {
                    unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: staged == true ? "Index changes" : staged == false ? "Working tree changes" : "Commit changes", onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func commit(_ action: CompletionAction = .commit) {
        guard canCommit, replaySplit == nil || action == .commit else { return }
        let rawMessage = message, rawIssueID = issueID, properties = issueProperties, paths = checkedPathsForCommit, staging = stagingEnabled
        let committedPaths = staging ? Set(entries.filter(\.staged).map(\.path)) : messageOnly ? Set<String>() : paths
        let retainedChangelists = Set(visibleEntries.filter { !committedPaths.contains($0.path) }.map(\.path)).union(restoreCopies.keys)
        let pruningScope = showWholeProject ? [] : scopePaths
        let preserveChangelists = keepChangelists
        var options = CommitOptions(); options.amend = amend; options.amendDiffToLastCommit = amendDiffToLastCommit; options.author = setAuthor ? author : nil
        options.authorDate = setAuthorDate ? authorDate : nil; options.resetAuthorDate = amend && setAuthorDate && resetAuthorDate; options.messageOnly = messageOnly; options.newBranch = createBranch ? newBranch : nil
        busy = true
        Task {
            var commitAttempted = false
            do {
                let validation = try await repository.prepareIssueCommit(properties: properties, message: rawMessage, issueID: rawIssueID)
                if validation.requiresIssueWarning {
                    let proceed = await withCheckedContinuation { continuation in confirmMissingIssue { continuation.resume(returning: $0) } }
                    guard proceed else { busy = false; return }
                }
                if !messageTemplate.isEmpty && rawMessage == messageTemplate && !UserDefaults.standard.bool(forKey: "Commit.TemplateNotEdited.Proceed") {
                    let proceed = await withCheckedContinuation { continuation in confirmUneditedTemplate { continuation.resume(returning: $0) } }
                    guard proceed else { busy = false; return }
                }
                var text = rawMessage
                if properties.warnNoSignedOffBy {
                    let line = try await repository.commitSignOffLine()
                    if !text.contains(line) {
                        let choice = await withCheckedContinuation { continuation in confirmMissingSignOff { continuation.resume(returning: $0) } }
                        if choice == .abort { busy = false; return }
                        if choice == .add { text = IssueTrackerProperties.addingSignOff(line, to: text) }
                    }
                }
                let prepared = text == rawMessage ? validation : try await repository.prepareIssueCommit(properties: properties, message: text, issueID: rawIssueID)
                text = prepared.message; message = text
                if !options.messageOnly {
                    let candidates = staging ? visibleEntries.filter(\.staged).map(\.path) : visibleEntries.filter { paths.contains($0.path) }.map(\.path)
                    let dirty = try await repository.commitDirtySubmodules(paths: candidates)
                    for child in dirty {
                        let choice = await withCheckedContinuation { continuation in confirmDirtySubmodule(child.path) { continuation.resume(returning: $0) } }
                        guard choice == .ignore else {
                            busy = false
                            if choice == .commit { onCommitSubmodule(child.checkout) }
                            return
                        }
                    }
                }
                let written = try await repository.prepareCommitMessageFile(text, stripComments: dialogDefaults.bool(forKey: "StripCommentedLines"), sanitize: dialogDefaults.object(forKey: "SanitizeCommitMsg") as? Bool ?? true)
                text = written.contents; message = written.draft
                let output: String
                commitAttempted = true
                if let replaySplit { output = try await repository.commitRebaseSplit(message: text, paths: paths, staging: staging, options: options, expected: replaySplit) }
                else if staging { output = try await repository.commitIndex(message: text, options: options) }
                else { output = try await repository.commitSelected(message: text, paths: paths, options: options) }
                messageHistory?.add(written.draft)
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
                        messageTemplate = seed.template
                        let separated = properties.separateIssueLine(from: seed.template)
                        message = separated.message; issueID = separated.issueID
                        if !seed.warnings.isEmpty { self.error = seed.warnings.joined(separator: "\n\n") }
                    } catch { messageTemplate = ""; message = ""; self.error = error.localizedDescription }
                    createBranch = false; newBranch = ""; amend = false; amendDiffToLastCommit = false; amendMessage = ""; nonAmendMessage = ""; setAuthorDate = false; resetAuthorDate = false; setAuthor = false; messageOnly = false
                    selectFilesAutomatically = true
                    checked = []; selection = []; hasLoaded = false
                    busy = false
                    reload(paths: scopePaths.isEmpty ? ["."] : scopePaths)
                } else { busy = false; close(); if action == .push { onPush() } }
            } catch {
                let commitError = error.localizedDescription
                var failureMessage = commitError
                if commitAttempted && !restoreCopies.isEmpty, await chooseSavedCopies(allowCancel: false) == .restore {
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
    @AppStorage("StyleCommitMessages") private var styleCommitMessages = true
    @State private var dividerStart: Double?
    @FocusState private var issueFieldFocused: Bool
    @State private var initialIssueFocusApplied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Commit to:")
                if model.createBranch { TextField("New branch name", text: $model.newBranch).frame(width: 250) }
                else { Text(model.branch.isEmpty ? "Detached / unborn HEAD" : model.branch).foregroundStyle(.blue) }
                Toggle("new branch", isOn: $model.createBranch).toggleStyle(.checkbox).disabled(model.operation != nil || model.replaySplit != nil)
                Spacer()
                if model.issueProperties.showsIssueField {
                    Text(model.issueProperties.label)
                    TextField("", text: $model.issueID).textFieldStyle(.roundedBorder).frame(width: 140).accessibilityLabel(model.issueProperties.label).focused($issueFieldFocused)
                }
                if model.busy { ProgressView().controlSize(.small) }
            }
            if let operation = model.operation {
                CommandLabel(title: operation.title, icon: operation == .merge ? .merge : operation == .cherryPick ? .cherryPick : .revert).font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    if model.replaySplit == nil { Menu {
                        ForEach(CommitWindowModel.CompletionAction.allCases, id: \.self) { action in
                            Button { model.commit(action) } label: { CommandLabel(title: action.rawValue, icon: action == .push ? .push : .commit) }
                        }
                    } label: { Image(systemName: "chevron.down") }.menuIndicator(.hidden).fixedSize().accessibilityLabel("Commit actions") }
                }.disabled(!model.canCommit)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-commit.html")!) }
            }
        }.padding(12).disabled(model.busy || model.confirmingQuit)
        .onAppear { model.formattingEnabled = styleCommitMessages }
        .onChange(of: styleCommitMessages) { model.formattingEnabled = $0 }
        .onChange(of: model.busy) { loading in
            if !loading, model.issueProperties.showsIssueField, !initialIssueFocusApplied {
                initialIssueFocusApplied = true; issueFieldFocused = true
            }
        }
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

    }
    private var messageSection: some View {
GroupBox("Message:") {
                VStack(alignment: .leading, spacing: 8) {
                    CommitMessageEditor(model: model).frame(minHeight: 100, maxHeight: .infinity).border(Color.secondary.opacity(0.3))
                    HStack {
                        Toggle("Amend Last Commit", isOn: $model.amend).toggleStyle(.checkbox).disabled(!model.hasHead || model.operation != nil || model.replaySplit != nil).onChange(of: model.amend) { _ in model.amendChanged() }
                        if model.amend { Toggle("Show diff to last commit", isOn: $model.amendDiffToLastCommit).toggleStyle(.checkbox).disabled(!model.hasParent || model.replaySplit != nil) }
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
                                Toggle("Show Unversioned Files", isOn: Binding(get: { model.showUnversioned }, set: { model.setShowUnversioned($0) }))
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
                                Text(model.stagingEnabled ? "\(model.stagedEntries.count) staged, \(model.unstagedEntries.count) unstaged files shown" : "\(model.checkedPathsForCommit.count) files checked, \(model.visibleEntries.count) files shown").font(.caption)
                            }
                        }
                    }.padding(4)
                }
    }
    func fileTable(_ entries: [StatusEntry], selection: Binding<Set<String>>, staged: Bool?) -> some View {
        let statistics = staged.map { $0 ? model.stagedStatistics : model.unstagedStatistics } ?? model.statistics
        let focusKey = staged.map { $0 ? "staged" : "unstaged" } ?? "checkbox"
        let focus = Binding<String?>(get: { model.focusedFiles[focusKey] }, set: { model.focusedFiles[focusKey] = $0 })
        let ignored = Set(model.indexFlagFiles.filter { $0.assumeUnchanged || $0.skipWorktree }.map { $0.entry.path })
        let rows = StatusListGroups.rows(entries: entries, changelists: model.changelists, locallyIgnored: ignored)
        return Table(rows, selection: selection) {
            TableColumn("") { (row: StatusListRow) in
                if let entry = row.entry {
                    if staged != nil {
                        StagingCheckbox(entry: entry, enabled: !model.busy && !model.confirmingQuit) { model.setFileChecked(entry, files: entries, highlighted: selection.wrappedValue, checked: $0) }.frame(width: 20, height: 20)
                    } else {
                        Toggle("Include \(entry.path)", isOn: Binding(get: { model.checked.contains(entry.id) }, set: { model.setFileChecked(entry, files: entries, highlighted: selection.wrappedValue, checked: $0) }))
                            .labelsHidden().toggleStyle(.checkbox).disabled(entry.state == .conflicted)
                    }
                }
            }.width(24)
            TableColumn("Path") { (row: StatusListRow) in
                if let entry = row.entry {
                    HStack {
                        Image(nsImage: entry.state.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16).overlay {
                            if model.restoreCopies[entry.path] != nil { Image(nsImage: MenuIcon.restoreOverlay.image() ?? NSImage()).resizable().frame(width: 16, height: 16) }
                        }
                        Text(StatusListClipboard.displayedPath(entry)).foregroundStyle(selection.wrappedValue.contains(entry.id) ? Color.primary : entry.state.textColor)
                    }.help(model.fileHelp(entry))
                } else if let group = row.group {
                    HStack {
                        Text(group.title).font(.headline).foregroundStyle(Color.accentColor)
                        Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1)
                    }.accessibilityLabel(group.title)
                }
            }.width(min: 260, ideal: 420)
            TableColumn("Extension") { (row: StatusListRow) in
                if let entry = row.entry { Text(StatusListClipboard.fileExtension(entry.path, isDirectory: model.submodules.contains(entry.path))) }
                else { groupRule }
            }.width(75)
            TableColumn("Status") { (row: StatusListRow) in
                if let entry = row.entry { Text(entry.index == "R" || entry.worktree == "R" ? "Renamed" : statistics[entry.path]?.status ?? entry.state.rawValue.capitalized) }
                else { groupRule }
            }.width(90)
            TableColumn("Lines added") { (row: StatusListRow) in
                lineCount(row, statistics: statistics, selected: selection.wrappedValue, added: true)
            }.width(80)
            TableColumn("Lines removed") { (row: StatusListRow) in
                lineCount(row, statistics: statistics, selected: selection.wrappedValue, added: false)
            }.width(95)
        }.contextMenu(forSelectionType: String.self) { requested in
            TurtleGitContextMenu {
                let ids = requested.intersection(Set(entries.map(\.id)))
                if requested.count == 1, let group = rows.first(where: { requested.contains($0.id) })?.group {
                    let files = StatusListGroups.files(in: group, rows: rows)
                    Button("Check group") { model.setGroupChecked(files, checked: true) }.disabled(model.busy || model.confirmingQuit)
                    Button("Uncheck group") { model.setGroupChecked(files, checked: false) }.disabled(model.busy || model.confirmingQuit)
                } else {
                    let selected = entries.filter { ids.contains($0.id) }
                    let flagFiles = model.indexFlagFiles.filter { ids.contains($0.id) }
                    let selectionMark = StatusListSelection.mark(entries: entries, requested: ids, highlighted: selection.wrappedValue, focusedPath: focus.wrappedValue)
                    if !selected.isEmpty && selected.allSatisfy({ [.untracked, .ignored].contains($0.state) }) {
                        Button { model.addFiles(selected, mode: .normal) } label: { CommandLabel(title: WorkingFileAddMode.normal.rawValue, icon: .add) }.disabled(model.busy || model.confirmingQuit)
                        if NSEvent.modifierFlags.contains(.shift), selected.allSatisfy({ !model.submodules.contains($0.path) }) {
                            ForEach([WorkingFileAddMode.executable, .symlink], id: \.self) { mode in
                                Button { model.addFiles(selected, mode: mode) } label: { CommandLabel(title: mode.rawValue, icon: .add) }.disabled(model.busy || model.confirmingQuit)
                            }
                        }
                        Divider()
                    }
                    if !selected.isEmpty, selectionMark?.canCompareWithBaseFromStatusList == true {
                        Button { model.compare(paths: ids) } label: { CommandLabel(title: "Compare with base", icon: .compare) }
                        if model.hasHead {
                            Button { model.diff(paths: ids, staged: staged, alternate: NSEvent.modifierFlags.contains(.shift)) } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(model.busy || model.confirmingQuit)
                        }
                        Divider()
                    }
                    if selected.count == 2, selected.allSatisfy({ !model.submodules.contains($0.path) }) {
                        Button { model.onCompareTwoFiles(rows.compactMap(\.entry).filter { ids.contains($0.id) }.map(\.path)) } label: { CommandLabel(title: "Compare two files", icon: .compare) }
                            .disabled(model.busy || model.confirmingQuit)
                        Divider()
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
                    if !selected.isEmpty, let mark = model.indexFlagFiles.first(where: { $0.id == selectionMark?.id }) {
                        IndexFlagsMenu(files: flagFiles, selectionMark: mark) { model.setFlags($0, files: flagFiles, selectionMark: mark) }
                    }
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
                }
            }
        } primaryAction: { requested in
            let ids = requested.intersection(Set(entries.map(\.id)))
            selection.wrappedValue = ids
            if ids.count == 1, let entry = model.entries.first(where: { ids.contains($0.id) }), entry.state == .conflicted { model.onResolve(.editConflict, [entry.path]) }
            else { model.compare(paths: ids) }
        }
        .background(CommitFileInteraction(rows: rows, focusedPath: focus, enabled: !model.busy && !model.confirmingQuit, delete: { model.deleteFiles($0, selectionMark: $1, permanently: $2) }, copy: { model.copyFileText($0, statistics: statistics, copy: $1 ? .pathsAndStatus : .relativePaths) }, copyColumn: { model.copyFileText($0, statistics: statistics, copy: .column($1)) }, toggleCheck: { files, mark in
            let next = model.stagingEnabled ? !(mark.staged && mark.worktree == " ") : !model.checked.contains(mark.id)
            model.setFileChecked(mark, files: files, highlighted: Set(files.map(\.id)), checked: next)
        }))
        .onChange(of: selection.wrappedValue) { ids in
            let files = ids.intersection(Set(entries.map(\.id)))
            if files.count == 1 && NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty { focus.wrappedValue = files.first }
        }
    }
    @ViewBuilder private func lineCount(_ row: StatusListRow, statistics: [String: CommitFile], selected: Set<String>, added: Bool) -> some View {
        if let entry = row.entry {
            let count: Int? = added ? statistics[entry.path]?.added : statistics[entry.path]?.removed
            let label = count.map { String($0) } ?? "–"
            Text(label).foregroundStyle(selected.contains(entry.id) ? Color.primary : Color.blue)
        } else { groupRule }
    }
    private var groupRule: some View { Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1) }
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
