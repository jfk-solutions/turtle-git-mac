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
    private var progressController: CommitProgressWindowController?
    var onPullAfterLFSLock: () -> Void = {}
    private var lfsOperation: LFSFileOperationController?
    var makeLFSOperation: (GitRepository, RepositoryAccessLease?) -> LFSFileOperationController = { LFSFileOperationController(repository: $0, access: $1) }
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        model = CommitWindowModel(repository: repository, access: access, unversionedDefaults: defaults, dialogDefaults: defaults)
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
        model.onCommitProgress = { [weak self, weak window] progress in
            guard let self, let window, window.attachedSheet == nil else { progress.dismissWithoutWindow = true; if progress.cancellable { progress.cancellation.cancel() }; return }
            let controller = CommitProgressWindowController(model: progress)
            controller.onClosed = { [weak self] in self?.progressController = nil }
            self.progressController = controller
            if let child = controller.window { window.beginSheet(child) }
        }
        model.onLFSOperation = { [weak self, weak window] paths, locked in
            guard let self, let window, window.attachedSheet == nil, self.lfsOperation == nil else { return false }
            let progress = self.makeLFSOperation(repository, access)
            progress.model.onPullAfterLock = { [weak self] in self?.onPullAfterLFSLock() }
            progress.onClosed = { [weak self] in
                guard let self else { return }
                self.lfsOperation = nil; self.model.busy = false; self.model.reload(); self.model.refreshPartial()
            }
            self.lfsOperation = progress; progress.present(owner: window, paths: paths, locked: locked)
            return true
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
                if alert.suppressionButton?.state == .on { defaults.set(true, forKey: "Commit.SkipCancelConfirmation") }
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
        model.confirmConflictHints = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false, false); return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "Conflict hints remain in the commit message"
            alert.informativeText = "Git's commented conflict list remains in the message. Ignore this warning to keep those lines, or abort to edit the message. You can remove them automatically by enabling comment stripping in Commit message settings."
            alert.addButton(withTitle: "Ignore"); let abort = alert.addButton(withTitle: "Abort")
            alert.buttons.first?.keyEquivalent = ""; abort.keyEquivalent = "\r"; alert.window.defaultButtonCell = abort.cell as? NSButtonCell
            alert.showsSuppressionButton = true
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn, alert.suppressionButton?.state == .on) }
        }
        model.confirmDirtySubmodule = { [weak window] path, choose in
            guard let window, window.attachedSheet == nil else { choose(.cancel); return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "The submodule \"" + path + "\" is dirty."
            alert.informativeText = "Merely committing the superproject cannot track or save such changes to the submodule.\nCommit the submodule now or ignore dirty changes?"
            alert.addButton(withTitle: "Commit"); alert.addButton(withTitle: "Ignore"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn ? .commit : $0 == .alertSecondButtonReturn ? .ignore : .cancel) }
        }

        DialogGeometry.attach(window, identifier: "CommitWindowController")
    }
    func setQuitConfirmation(_ pending: Bool) { model.confirmingQuit = pending; partial?.model.confirmingQuit = pending }
    func windowWillClose(_ notification: Notification) { closingCommit = true; model.invalidateForClose(); logPicker?.close(); logPicker = nil; partial?.close(); partial = nil; model.unifiedWindow?.close(); onClosed() }
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
        DialogGeometry.attach(child, identifier: "HistoryDlg")
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
    private var reloadTask: Task<Void, Never>?
    private var reloadCancellation: OperationCancellation?
    @Published private var pendingReloadCancel = false
    var queryCommitStatus: (Bool, OperationCancellation) async throws -> [StatusEntry]
    @Published var statistics: [String: CommitFile] = [:]
    @Published var checked = Set<String>()
    @Published var selection = Set<String>()
    @Published var fileMetadata: [String: StatusListMetadata] = [:]
    @Published var hasLFS = false
    @Published var lfsOwners: [String: String] = [:]
    @Published var lfsLockedPaths = Set<String>()
    @Published var lfsOwnershipKnown = false
    private var lfsOwnerCancellation: OperationCancellation?
    var queryLFSOwners: (OperationCancellation) async throws -> [LFSLock]
    var onLFSOperation: ([String], Bool) -> Bool = { _, _ in false }
    @Published var fileColumns = StatusListColumnSettings()
    var availableFileColumns: Set<StatusListColumn> { Set(StatusListColumn.allCases).subtracting(hasLFS ? [] : [.lfsOwner]) }
    var visibleFileColumns: [StatusListColumn] { fileColumns.order.filter { fileColumns.visible.contains($0) && availableFileColumns.contains($0) } }
    @Published var fileSortOrder = [CommitFileSort(column: .path)]
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
    deinit { reloadCancellation?.cancel(); reloadTask?.cancel(); completionTask?.cancel(); issueStyleTask?.cancel(); authorCancellation?.cancel(); dateCancellation?.cancel(); amendCancellation?.cancel() }
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
    var confirmConflictHints: (@escaping (Bool, Bool) -> Void) -> Void = { choose in choose(false, false) }
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
    @Published var messageCaretPosition = MessageCaretPosition.at("", utf16Offset: 0)
    @Published var authorDate = Date()
    @Published var resetAuthorDate = false
    @Published var messageOnly = false
    @Published var doNotAutoselectSubmodules = UserDefaults.standard.bool(forKey: "Commit.DoNotAutoselectSubmodules")
    @Published var submodules = Set<String>()
    @Published var setAuthor = false
    @Published var author = ""
    @Published private(set) var loadingAuthorIdentity = false
    @Published private(set) var loadingAuthorDate = false
    @Published private(set) var loadingAmendMessage = false
    @Published private(set) var messageFocusRequest = 0
    private(set) var appliedMessageFocusRequest = 0
    private(set) var messageFocusAvailable = true
    private var authorGeneration = 0
    private var dateGeneration = 0
    private var amendGeneration = 0
    private var replayAuthorPreset: (enabled: Bool, value: String)?
    private var replayDatePreset: (enabled: Bool, value: Date, reset: Bool)?
    private var authorCancellation: OperationCancellation?
    private var dateCancellation: OperationCancellation?
    private var amendCancellation: OperationCancellation?
    var queryCommitAuthor: (Bool, OperationCancellation) async throws -> String?
    var queryCommitAuthorDate: (OperationCancellation) async throws -> Date?
    var queryAmendMessage: (OperationCancellation) async throws -> String?
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
    var onPull: () -> Void = {}
    var onCreateTag: () -> Void = {}
    var onCommitProgress: ((CommitProgressWindowModel) -> Void)?
    @Published private(set) var commitProgress: CommitProgressWindowModel?
    enum CompletionAction: String, CaseIterable {
        case commit = "Commit", recommit = "ReCommit", push = "Commit & Push"
        var sourceIndex: Int { switch self { case .commit: return 0; case .recommit: return 1; case .push: return 2 } }
        init(sourceIndex: Int) { self = Self.allCases.first { $0.sourceIndex == sourceIndex } ?? .commit }
    }
    @Published private(set) var completionAction: CompletionAction = .commit
    var currentCompletionAction: CompletionAction { replaySplit == nil ? completionAction : .commit }
    func commitCurrentAction() { commit(currentCompletionAction) }
    private func rememberCompletionAction(_ action: CompletionAction) {
        guard replaySplit == nil else { return }
        dialogDefaults.set(action.sourceIndex, forKey: "CommitLastAction")
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, unversionedDefaults: UserDefaults = .standard, dialogDefaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.unversionedDefaults = unversionedDefaults
        self.dialogDefaults = dialogDefaults
        queryLFSOwners = { try await repository.lfsLocks(cancellation: $0) }
        queryCommitStatus = { try await repository.commitDialogStatus(amendToParent: $0, cancellation: $1) }
        queryCommitAuthor = { amend, cancellation in
            if amend {
                var options = HistoryOptions(); options.limit = 1
                guard let previous = try await repository.history(options: options, cancellation: cancellation).first else { return nil }
                return "\(previous.author) <\(previous.email)>"
            }
            let name = try await repository.run(["config", "user.name"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            let email = try await repository.run(["config", "user.email"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            return "\(name) <\(email)>"
        }
        queryCommitAuthorDate = { cancellation in
            let value = try await repository.run(["show", "-s", "--format=%at", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            return TimeInterval(value).map { Date(timeIntervalSince1970: $0) }
        }
        queryAmendMessage = { cancellation in
            var options = HistoryOptions(); options.limit = 1
            return try await repository.history(options: options, cancellation: cancellation).first?.message
        }
        fileColumns = .load(from: dialogDefaults)
        completionAction = CompletionAction(sourceIndex: dialogDefaults.integer(forKey: "CommitLastAction"))
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
    func sortedFiles(_ files: [StatusEntry], statistics: [String: CommitFile]) -> [StatusEntry] {
        guard let comparator = fileSortOrder.first else { return files }
        return files.map { CommitSortableRow(row: .file($0), statistics: statistics[$0.path], isDirectory: submodules.contains($0.path) || fileMetadata[$0.path]?.isDirectory == true, metadata: fileMetadata[$0.path], lfsOwner: lfsOwners[$0.path] ?? "") }
            .sorted(using: comparator).compactMap(\.entry)
    }
    @discardableResult func saveFileColumnLayout(order: [StatusListColumn], widths: [StatusListColumn: Double]) -> Bool {
        guard !busy, !confirmingQuit else { return false }
        let next = StatusListColumnSettings(visible: fileColumns.visible, order: order, widths: widths)
        if fileColumns != next { fileColumns = next; fileColumns.save(to: dialogDefaults) }
        return true
    }
    func setFileColumn(_ column: StatusListColumn, visible: Bool) {
        guard column != .path, availableFileColumns.contains(column), !busy, !confirmingQuit else { return }
        if visible { fileColumns.visible.insert(column) } else { fileColumns.visible.remove(column) }
        fileColumns.save(to: dialogDefaults)
        if column == .lfsOwner { if visible { reload() } else { lfsOwners = [:]; lfsLockedPaths = []; lfsOwnershipKnown = false } }
    }
    @discardableResult func resetFileColumns() -> Bool {
        guard !busy, !confirmingQuit else { return false }
        fileColumns = StatusListColumnSettings(); fileColumns.save(to: dialogDefaults); return true
    }
    func requestResetFileColumns(choose: @escaping () async -> Bool, onAccepted: @escaping () -> Void) {
        guard !busy, !confirmingQuit else { return }
        busy = true
        Task {
            defer { busy = false }
            guard await choose(), !confirmingQuit else { return }
            fileColumns = StatusListColumnSettings(); fileColumns.save(to: dialogDefaults)
            onAccepted()
        }
    }
    func setFileSortOrder(_ order: [CommitFileSort]) {
        guard !busy, !confirmingQuit else { return }
        // The source retains one column, with its path tie-break, rather than
        // accumulating old columns as additional sorting priorities.
        fileSortOrder = Array(order.prefix(1))
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
        let text = StatusListClipboard.text(selected, root: repository.root, statistics: statistics, copy: copy, metadata: fileMetadata, lfsOwners: lfsOwners, visibleColumns: visibleFileColumns)
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
    func canLockLFS(_ selected: [StatusEntry]) -> Bool {
        LFSLockingSelection.isAvailable(selected, hasLFS: hasLFS, root: repository.root, directories: submodules)
    }
    func lfsActions(_ selected: [StatusEntry]) -> [LFSLockMenuAction] {
        guard canLockLFS(selected) else { return [] }
        return LFSLockMenu.actions(paths: selected.map(\.path), ownersVisible: visibleFileColumns.contains(.lfsOwner), lockedPaths: lfsLockedPaths, ownershipKnown: lfsOwnershipKnown)
    }
    func setLFSLocked(_ ids: Set<String>, locked: Bool) {
        guard !busy, !confirmingQuit else { return }
        let selected = entries.filter { ids.contains($0.id) }
        guard selected.count == ids.count, lfsActions(selected).contains(locked ? .lock : .unlock) else { return }
        busy = true
        if !onLFSOperation(selected.map(\.path), locked) { busy = false }
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
    var canCommit: Bool { messageFocusAvailable && !pendingReloadCancel && !busy && !confirmingQuit && !loadingAuthorIdentity && !loadingAuthorDate && !loadingAmendMessage && loadedMessage && changelistsLoaded && (messageOnly || (stagingEnabled ? entries.contains(where: \.staged) || operation == .merge || amend : !checkedPathsForCommit.isEmpty || operation == .merge || (amend && amendDiffToLastCommit))) && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!createBranch || !newBranch.isEmpty) && (!setAuthor || !author.isEmpty) }
    func didRename(_ source: String, to destination: String) {
        func moved(_ path: String) -> String { path == source ? destination : path.hasPrefix(source + "/") ? destination + path.dropFirst(source.count) : path }
        checked = Set(checked.map(moved)); selection = Set(selection.map(moved)); scopePaths = scopePaths.map(moved); reload()
    }
    func loadReplaySplit(_ split: RebaseSplitState, message: String) {
        invalidateMetadataLoads()
        appliedMessageFocusRequest = messageFocusRequest
        replaySplit = split; amend = split.conflictRecovery == true || split.parts == 0; amendDiffToLastCommit = split.conflictRecovery == true
        self.message = split.conflictRecovery == true || split.parts == 0 ? message : ""
        if split.parts == 0, let date = split.squashDate {
            setAuthor = true; author = split.firstAuthor
            if date != .current, let value = ISO8601DateFormatter().date(from: split.firstDate) { setAuthorDate = true; authorDate = value }
            else if date == .current { setAuthorDate = true; resetAuthorDate = true }
            // Suppress only the onChange generated by installing caller
            // presets. Later user checkbox changes still run normal handlers.
            replayAuthorPreset = (setAuthor, author)
            if setAuthorDate { replayDatePreset = (setAuthorDate, authorDate, resetAuthorDate) }
        }
        reload(paths: ["."])
    }
    func reload(paths: [String]? = nil) {
        guard messageFocusAvailable, !busy, !pendingReloadCancel else { return }; busy = true
        let token = OperationCancellation(); reloadCancellation = token
        lfsOwners = [:]; lfsLockedPaths = []; lfsOwnershipKnown = false
        let resetChecks = paths != nil && (!hasLoaded || (paths!.contains(".") ? [] : paths!) != scopePaths)
        if let paths { scopePaths = paths.contains(".") ? [] : paths; showWholeProject = scopePaths.isEmpty }
        reloadTask = Task {
            defer {
                if reloadCancellation === token { reloadCancellation = nil; reloadTask = nil; busy = false }
            }
            do {
                var restorePatch = false
                if !loadedPreferences {
                    let preferences = try await readReload(token) { try await repository.commitPreferences(cancellation: token) }
                    persistedStaging = preferences.staging; stagingEnabled = preferences.staging; restorePatch = preferences.showPatch; loadedPreferences = true
                }
                operation = try await readReload(token) { try await repository.commitOperation(cancellation: token) }
                if operation != nil { createBranch = false; amend = false }
                hasHead = try await readReload(token) { (try? await repository.run(["rev-parse", "--verify", "HEAD"], cancellation: token)) != nil }
                hasParent = try await readReload(token) { (try? await repository.run(["rev-parse", "--verify", "HEAD^1"], cancellation: token)) != nil }
                if amend && !hasParent { amendDiffToLastCommit = true }
                comparisonBase = amendToParent ? try await readReload(token) { try await repository.commitComparisonBase(amendToParent: true, cancellation: token) } : nil
                entries = try await readReload(token) { try await queryCommitStatus(amendToParent, token) }; submodules = try await readReload(token) { try await repository.submodulePaths(cancellation: token) }; branch = try await readReload(token) { try await repository.branch(cancellation: token) }
                try validateRestoreAccess()
                fileMetadata = try await readReload(token) { await repository.statusListMetadata(paths: entries.map(\.path)) }
                hasLFS = try await readReload(token) { try await repository.hasLFS(cancellation: token) }
                let snippetURL = RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("snippet.txt")
                messageSnippets = try await readReload(token) { await snippetLoader.load(userURL: snippetURL) }
                changelistsLoaded = false
                changelists = try await readReload(token) { try await repository.changelists(cancellation: token) }; changelistsLoaded = true
                indexFlagFiles = try await readReload(token) { try await repository.workingTreeStatus(cancellation: token) }
                conflictRebase = try await readReload(token) { try await repository.conflictIsRebase(cancellation: token) }
                statistics = Dictionary(try await readReload(token) { try await repository.workingTreeFiles(amendToParent: amendToParent, cancellation: token) }.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                stagedStatistics = Dictionary(try await readReload(token) { try await repository.stagingFiles(staged: true, base: comparisonBase, cancellation: token) }.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                unstagedStatistics = Dictionary(try await readReload(token) { try await repository.stagingFiles(staged: false, cancellation: token) }.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
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
                    author = try await readReload(token) {
                        let name = (try? await repository.run(["config", "user.name"], cancellation: token).text.trimmingCharacters(in: .newlines)) ?? ""
                        let email = (try? await repository.run(["config", "user.email"], cancellation: token).text.trimmingCharacters(in: .newlines)) ?? ""
                        return name.isEmpty ? "" : "\(name) <\(email)>"
                    }
                }
                hasLoaded = true; refreshPartial()
                if !loadedMessage {
                    issueProperties = try await readReload(token) { try await repository.issueTrackerProperties(cancellation: token) }
                    let identity = try await readReload(token) { try await repository.commitMessageHistoryIdentity(cancellation: token) }
                    let storedLimit = dialogDefaults.object(forKey: "Commit.MaxHistoryItems") as? Int ?? 25
                    messageHistory = CommitMessageHistory(repositoryIdentity: identity, defaults: dialogDefaults, limit: storedLimit)
                    let seed = try await readReload(token) { try await repository.commitMessageSeed(cancellation: token) }
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
                if visibleFileColumns.contains(.lfsOwner) {
                    lfsOwnerCancellation = token
                    defer { if lfsOwnerCancellation === token { lfsOwnerCancellation = nil } }
                    do {
                        let locks = try await readReload(token) { try await queryLFSOwners(token) }
                        guard !token.isCancelled else { return }
                        lfsOwners = Dictionary(locks.map { ($0.path, $0.owner) }, uniquingKeysWith: { first, _ in first })
                        lfsLockedPaths = Set(locks.map(\.path)); lfsOwnershipKnown = true
                    } catch { if messageFocusAvailable, !token.isCancelled { self.error = "Could not get LFS locks: " + error.localizedDescription } }
                }

            } catch { if messageFocusAvailable, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    /// Check on both sides of every suspension: even an injected read that
    /// ignores cancellation cannot publish into a closed Commit window.
    private func readReload<Value>(_ token: OperationCancellation, _ read: () async throws -> Value) async throws -> Value {
        guard messageFocusAvailable, reloadCancellation === token, !token.isCancelled, !Task.isCancelled else { throw OperationCancellationFailure.cancelled }
        let value = try await read()
        guard messageFocusAvailable, reloadCancellation === token, !token.isCancelled, !Task.isCancelled else { throw OperationCancellationFailure.cancelled }
        return value
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
        guard messageFocusAvailable else { return }
        if replaySplit != nil { comparisonChanged(); return }
        let wasLoading = loadingAmendMessage
        invalidateMetadataLoads()
        if amend {
            nonAmendMessage = message
            if !amendMessage.isEmpty { finishAmendMessage(amendMessage); return }
            loadingAmendMessage = true
            let generation = amendGeneration, draft = message, token = OperationCancellation()
            amendCancellation = token
            Task {
                defer { if generation == amendGeneration { loadingAmendMessage = false; amendCancellation = nil } }
                do {
                    if token.isCancelled { throw OperationCancellationFailure.cancelled }
                    let previous = try await queryAmendMessage(token)
                    if token.isCancelled { throw OperationCancellationFailure.cancelled }
                    guard generation == amendGeneration, amend else { return }
                    finishAmendMessage(message.utf8.elementsEqual(draft.utf8) ? previous ?? "" : message)
                } catch { if generation == amendGeneration, amend { self.error = error.localizedDescription; requestMessageFocus() } }
            }
        } else {
            if !wasLoading { amendMessage = message }
            message = nonAmendMessage
            dateChanged(); authorChanged(); requestMessageFocus(); comparisonChanged()
        }
    }
    private func invalidateMetadataLoads() {
        authorCancellation?.cancel(); dateCancellation?.cancel(); amendCancellation?.cancel()
        authorCancellation = nil; dateCancellation = nil; amendCancellation = nil
        authorGeneration += 1; dateGeneration += 1; amendGeneration += 1
        loadingAuthorIdentity = false; loadingAuthorDate = false; loadingAmendMessage = false
        replayAuthorPreset = nil; replayDatePreset = nil
    }
    private func finishAmendMessage(_ value: String) {
        message = value; originalAmendMessage = value; loadingAmendMessage = false
        dateChanged(); authorChanged(); requestMessageFocus(); comparisonChanged()
    }
    private func requestMessageFocus() {
        guard messageFocusAvailable else { return }
        messageFocusRequest += 1
    }
    func invalidateMessageFocus() {
        messageFocusAvailable = false; messageFocusRequest = 0; appliedMessageFocusRequest = 0
    }
    func invalidateForClose() {
        reloadCancellation?.cancel(); reloadTask?.cancel(); lfsOwnerCancellation?.cancel()
        reloadCancellation = nil; reloadTask = nil; lfsOwnerCancellation = nil
        pendingReloadCancel = false; busy = false
        invalidateMessageFocus()
        invalidateMetadataLoads()
        completionTask?.cancel(); issueStyleTask?.cancel()
    }
    func acknowledgeMessageFocus(_ request: Int) {
        guard messageFocusAvailable, request == messageFocusRequest else { return }
        appliedMessageFocusRequest = request
    }
    func comparisonChanged() {
        hasLoaded = false
        reload(paths: scopePaths.isEmpty ? ["."] : scopePaths)
    }
    func authorChanged() {
        guard messageFocusAvailable else { return }
        authorCancellation?.cancel(); authorCancellation = nil
        authorGeneration += 1
        loadingAuthorIdentity = false
        if let preset = replayAuthorPreset {
            replayAuthorPreset = nil
            if setAuthor == preset.enabled, author.utf8.elementsEqual(preset.value.utf8) { return }
        }
        let generation = authorGeneration, wasAmend = amend, wasSetAuthor = setAuthor, draft = author
        let token = OperationCancellation(); authorCancellation = token
        loadingAuthorIdentity = true
        Task {
            defer { if generation == authorGeneration { loadingAuthorIdentity = false; authorCancellation = nil } }
            do {
                if token.isCancelled { throw OperationCancellationFailure.cancelled }
                let value = try await queryCommitAuthor(wasAmend, token)
                if token.isCancelled { throw OperationCancellationFailure.cancelled }
                guard generation == authorGeneration, amend == wasAmend, setAuthor == wasSetAuthor,
                      author.utf8.elementsEqual(draft.utf8), let value else { return }
                author = value
            } catch { if generation == authorGeneration, amend == wasAmend, setAuthor == wasSetAuthor { self.error = error.localizedDescription } }
        }
    }
    func dateChanged() {
        guard messageFocusAvailable else { return }
        dateCancellation?.cancel(); dateCancellation = nil
        dateGeneration += 1
        loadingAuthorDate = false
        if let preset = replayDatePreset {
            replayDatePreset = nil
            if setAuthorDate == preset.enabled, authorDate == preset.value, resetAuthorDate == preset.reset { return }
        }
        resetAuthorDate = false
        guard setAuthorDate else { return }
        if !amend { authorDate = Date(); return }
        let generation = dateGeneration, draft = authorDate
        let token = OperationCancellation(); dateCancellation = token
        loadingAuthorDate = true
        Task {
            defer { if generation == dateGeneration { loadingAuthorDate = false; dateCancellation = nil } }
            do {
                if token.isCancelled { throw OperationCancellationFailure.cancelled }
                let value = try await queryCommitAuthorDate(token)
                if token.isCancelled { throw OperationCancellationFailure.cancelled }
                guard generation == dateGeneration, amend, setAuthorDate, authorDate == draft, let value else { return }
                authorDate = value
            } catch { if generation == dateGeneration, amend, setAuthorDate { self.error = error.localizedDescription } }
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
        if replaySplit == nil { completionAction = action }
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
            var progress: CommitProgressWindowModel?
            var selectedPostAction: CommitPostAction?
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
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
                        if choice == .add { text = IssueTrackerProperties.addingSignOff(line, to: text); message = text }
                    }
                }
                // AppUtils' detector is shared by Commit and Rebase. Test the
                // draft after sign-off handling, before issue insertion or staging.
                if !dialogDefaults.bool(forKey: "CommitMessageContainsConflictHint"), try await repository.rebaseMessageContainsConflictHints(text, stripComments: dialogDefaults.bool(forKey: "StripCommentedLines")) {
                    let choice = await withCheckedContinuation { continuation in confirmConflictHints { continuation.resume(returning: ($0, $1)) } }
                    guard choice.0 else { busy = false; return }
                    if choice.1 { dialogDefaults.set(true, forKey: "CommitMessageContainsConflictHint") }
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
                let result = CommitProgressWindowModel(repository: repository, action: action, staging: staging, paths: paths, options: options, preferences: dialogDefaults, cancellable: replaySplit == nil)
                progress = result; commitProgress = result
                onCommitProgress?(result)
                let presented = onCommitProgress != nil && !result.dismissWithoutWindow
                let output: String
                commitAttempted = true
                if let replaySplit { output = try await repository.commitRebaseSplit(message: text, paths: paths, staging: staging, options: options, expected: replaySplit) }
                else {
                    let parser = GitCliOutputParser(limit: result.outputLimit)
                    let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    let operation = Task {
                        defer { continuation.finish() }
                        let onOutput: @Sendable (GitOutputChunk) -> Void = { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }
                        if staging { return try await repository.commitIndex(message: text, options: options, cancellation: result.cancellation, onOutput: onOutput) }
                        return try await repository.commitSelected(message: text, paths: paths, options: options, cancellation: result.cancellation, onOutput: onOutput)
                    }
                    for await _ in updates { result.consume(parser.processPending(), parser: parser) }
                    result.consume(parser.processPending(), parser: parser); result.consume(parser.finish(), parser: parser)
                    output = try await operation.value
                }
                messageHistory?.add(written.draft)
                if options.amend && !nonAmendMessage.isEmpty && nonAmendMessage != messageTemplate { messageHistory?.add(nonAmendMessage) }
                if !result.isAbandoned { onCommitted(output) }
                result.complete(output: output, success: true, cancelled: false, postActions: replaySplit == nil ? [.push, .pull, .recommit, .createTag] : [])
                if action != .commit || replaySplit != nil || !presented || result.isAbandoned { result.choose(nil) }
                selectedPostAction = await result.waitForChoice()
                rememberCompletionAction(action)
                commitProgress = nil
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
                if action == .recommit || selectedPostAction == .recommit {
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
                } else {
                    busy = false; close()
                    if action == .push || selectedPostAction == .push { onPush() }
                    else if selectedPostAction == .pull { onPull() }
                    else if selectedPostAction == .createTag { onCreateTag() }
                }
            } catch {
                let commitError = error.localizedDescription
                let shownInProgress = progress != nil && onCommitProgress != nil && progress?.dismissWithoutWindow != true
                if let progress {
                    progress.complete(output: (error as? GitFailure)?.message ?? commitError, success: false, cancelled: progress.cancellation.isCancelled, postActions: [], exitCode: (error as? GitFailure)?.code)
                    if !shownInProgress || progress.cancelled { progress.choose(nil) }
                    _ = await progress.waitForChoice(); rememberCompletionAction(action); commitProgress = nil
                }
                var failureMessage = shownInProgress ? "" : commitError
                if commitAttempted && !restoreCopies.isEmpty, await chooseSavedCopies(allowCancel: false) == .restore {
                    do { try await restoreSavedCopies(Set(restoreCopies.keys)) }
                    catch { failureMessage = commitError + "\n\nRestoring saved working copies failed: " + error.localizedDescription }
                }
                if commitAttempted, let created = options.newBranch, (try? await repository.branch()) == created {
                    createBranch = false; newBranch = ""
                }
                self.error = failureMessage.isEmpty ? nil : failureMessage
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
    var inputsBlocked: Bool { busy || confirmingQuit || pendingReloadCancel }
    var canCancel: Bool { messageFocusAvailable && !confirmingQuit && !pendingReloadCancel && (!busy || reloadCancellation != nil) }
    func cancel(closeWindow: Bool = true, completion: ((Bool) -> Void)? = nil) {
        cancel(closeWindow: closeWindow, completion: completion, confirmationAccepted: false)
    }
    private func cancel(closeWindow: Bool, completion: ((Bool) -> Void)?, confirmationAccepted: Bool) {
        guard messageFocusAvailable else { completion?(false); return }
        if let token = reloadCancellation, let task = reloadTask {
            guard !pendingReloadCancel, !confirmingQuit || !closeWindow else { completion?(false); return }
            pendingReloadCancel = true
            var answered = false
            let stop: (Bool) -> Void = { [weak self] approved in
                guard !answered else { return }; answered = true
                guard let self, self.messageFocusAvailable, self.pendingReloadCancel else { completion?(false); return }
                if !approved { self.pendingReloadCancel = false; completion?(false); return }
                self.invalidateMetadataLoads()
                token.cancel(); task.cancel()
                Task { [weak self] in
                    await task.value
                    guard let self, self.messageFocusAvailable else { completion?(false); return }
                    self.pendingReloadCancel = false
                    self.cancel(closeWindow: closeWindow, completion: completion, confirmationAccepted: true)
                }
            }
            let changed = !message.isEmpty && message != (amend ? originalAmendMessage : messageTemplate)
            if !confirmationAccepted, (changed || !entries.isEmpty), !dialogDefaults.bool(forKey: "Commit.SkipCancelConfirmation") {
                confirmCancel(stop)
            } else { stop(true) }
            return
        }
        if let token = lfsOwnerCancellation { token.cancel(); completion?(false); return }
        if let commitProgress { commitProgress.cancel(); completion?(false); return }
        guard !busy, !confirmingQuit || !closeWindow else { completion?(false); return }
        let changed = !message.isEmpty && message != (amend ? originalAmendMessage : messageTemplate)
        let finish = { [weak self] in
            guard let self, self.messageFocusAvailable else { completion?(false); return }
            if changed { self.messageHistory?.add(self.message) }
            if self.amend && !self.nonAmendMessage.isEmpty && self.nonAmendMessage != self.messageTemplate { self.messageHistory?.add(self.nonAmendMessage) }
            if closeWindow { self.restoreCopies.removeAll(); self.close() }
            completion?(true)
        }
        let restoreAndFinish = { [weak self] in
            guard let self, self.messageFocusAvailable else { completion?(false); return }
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
        if !confirmationAccepted, (changed || !entries.isEmpty), !dialogDefaults.bool(forKey: "Commit.SkipCancelConfirmation") {
            confirmCancel { approved in if approved { restoreAndFinish() } else { completion?(false) } }
        } else { restoreAndFinish() }
    }
}

struct CommitSortableRow: Identifiable {
    let row: StatusListRow
    let statistics: CommitFile?
    let isDirectory: Bool
    var metadata: StatusListMetadata? = nil
    var lfsOwner = ""
    var id: String { row.id }
    var entry: StatusEntry? { row.entry }
    var group: StatusListGroup? { row.group }
}
struct CommitFileSort: SortComparator {
    var column: StatusListColumn
    var order: SortOrder = .forward
    func compare(_ lhs: CommitSortableRow, _ rhs: CommitSortableRow) -> ComparisonResult {
        guard let a = lhs.entry, let b = rhs.entry else { return .orderedSame }
        let comparison = StatusListSorting.compare(a, b, column: column, lhsStatistics: lhs.statistics, rhsStatistics: rhs.statistics, lhsDirectory: lhs.isDirectory, rhsDirectory: rhs.isDirectory, lhsMetadata: lhs.metadata, rhsMetadata: rhs.metadata, lhsLFSOwner: lhs.lfsOwner, rhsLFSOwner: rhs.lfsOwner)
        if order == .forward { return comparison }
        return comparison == .orderedAscending ? .orderedDescending : comparison == .orderedDescending ? .orderedAscending : .orderedSame
    }
}

/// The upstream new-branch toggle focuses the newly shown edit control and
/// selects its entire draft. Request this once per insertion, after attachment.
struct CommitNewBranchField: NSViewRepresentable {
    @Binding var name: String
    func makeCoordinator() -> Coordinator { Coordinator(name: $name) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = "New branch name"
        field.setAccessibilityLabel("New branch name")
        field.delegate = context.coordinator
        field.stringValue = name
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.name = $name
        if !field.stringValue.utf8.elementsEqual(name.utf8) { field.stringValue = name }
        field.isEnabled = context.environment.isEnabled
    }
    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        field.focusPending = false
        field.delegate = nil
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var name: Binding<String>
        init(name: Binding<String>) { self.name = name }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            name.wrappedValue = field.stringValue
        }
    }
    final class Field: NSTextField {
        var focusPending = true
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let owner = window, focusPending else { return }
            DispatchQueue.main.async { [weak self, weak owner] in
                guard let self, let owner, self.window === owner,
                      self.focusPending, self.isEnabled, owner.attachedSheet == nil else { return }
                self.focusPending = false
                if owner.makeFirstResponder(self), let editor = self.currentEditor() {
                    editor.selectedRange = NSRange(location: 0, length: self.stringValue.utf16.count)
                }
            }
        }
    }
}

struct CommitAuthorField: NSViewRepresentable {
    @Binding var author: String
    var editable: Bool
    func makeCoordinator() -> Coordinator { Coordinator(author: $author) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.drawsBackground = true; field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = "Name <email>"
        field.setAccessibilityLabel("Author identity")
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.author = $author
        if !field.stringValue.utf8.elementsEqual(author.utf8) { field.stringValue = author }
        field.isEnabled = context.environment.isEnabled
        field.isEditable = editable && field.isEnabled
        // EM_SETREADONLY in CommitDlg preserves selection and copy access.
        field.isSelectable = true
        if let editor = field.currentEditor() as? NSTextView {
            editor.isEditable = field.isEditable
        }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) { field.delegate = nil }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var author: Binding<String>
        init(author: Binding<String>) { self.author = author }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field.isEnabled, field.isEditable else { return }
            author.wrappedValue = field.stringValue
        }
    }
}

struct CommitDialog: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: CommitWindowModel
    @AppStorage("Commit.MessagePaneHeight") private var messagePaneHeight = 300.0
    @AppStorage("StyleCommitMessages") private var styleCommitMessages = true
    @State private var dividerStart: Double?
    @FocusState private var issueFieldFocused: Bool
    @State private var initialIssueFocusApplied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                HStack {
                    Text("Commit to:")
                    if model.createBranch { CommitNewBranchField(name: $model.newBranch).frame(width: 250) }
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
            }.disabled(model.inputsBlocked)
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show Whole Project", isOn: $model.showWholeProject).disabled(model.scopePaths.isEmpty)
                    Toggle("Message only", isOn: $model.messageOnly)
                }.toggleStyle(.checkbox).disabled(model.inputsBlocked)
                Button("Refresh") { model.reload() }.disabled(model.inputsBlocked)
                Spacer()
                HStack(spacing: 0) {
                    Button(model.currentCompletionAction.rawValue) { model.commitCurrentAction() }.keyboardShortcut(.return, modifiers: [.command])
                    if model.replaySplit == nil { Menu {
                        ForEach(CommitWindowModel.CompletionAction.allCases, id: \.self) { action in
                            Button { model.commit(action) } label: { CommandLabel(title: action.rawValue, icon: action == .push ? .push : .commit) }
                        }
                    } label: { Image(systemName: "chevron.down") }.menuIndicator(.hidden).fixedSize().accessibilityLabel("Commit actions") }
                }.disabled(!model.canCommit || model.inputsBlocked)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-commit.html")!) }.disabled(model.inputsBlocked)
            }
        }.padding(12)
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
                    HStack { Spacer(); CommitMessagePositionIndicator(model: model) }
                    HStack {
                        Toggle("Amend Last Commit", isOn: $model.amend).toggleStyle(.checkbox).disabled(!model.hasHead || model.operation != nil || model.replaySplit != nil).onChange(of: model.amend) { _ in model.amendChanged() }
                        if model.amend { Toggle("Show diff to last commit", isOn: $model.amendDiffToLastCommit).toggleStyle(.checkbox).disabled(!model.hasParent || model.replaySplit != nil) }
                        Spacer()
                    }
                    HStack {
                        Toggle("Set author date", isOn: $model.setAuthorDate).toggleStyle(.checkbox).frame(width: 170, alignment: .leading)
                        if model.setAuthorDate {
                            CommitDatePicker(selection: $model.authorDate, time: false, enabled: !model.loadingAuthorDate && !(model.amend && model.resetAuthorDate)).frame(width: 130, height: 24)
                            CommitDatePicker(selection: $model.authorDate, time: true, enabled: !model.loadingAuthorDate && !(model.amend && model.resetAuthorDate)).frame(width: 115, height: 24)
                            if model.amend { Toggle("Reset", isOn: $model.resetAuthorDate).toggleStyle(.checkbox) }
                        }
                        Spacer()
                    }
                    HStack {
                        Toggle("Set author", isOn: $model.setAuthor).toggleStyle(.checkbox).frame(width: 170, alignment: .leading)
                        CommitAuthorField(author: $model.author, editable: model.setAuthor && !model.loadingAuthorIdentity)
                        Button("Add Signed-off-by") { model.addSignOff() }
                    }
                }.padding(4)
            }
    }
    private var changesSection: some View {
GroupBox("Changes made (F5: refresh, double-click on file for diff):") {
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
        let entries = model.sortedFiles(entries, statistics: statistics)
        let focusKey = staged.map { $0 ? "staged" : "unstaged" } ?? "checkbox"
        let focus = Binding<String?>(get: { model.focusedFiles[focusKey] }, set: { model.focusedFiles[focusKey] = $0 })
        let ignored = Set(model.indexFlagFiles.filter { $0.assumeUnchanged || $0.skipWorktree }.map { $0.entry.path })
        let rows = StatusListGroups.rows(entries: entries, changelists: model.changelists, locallyIgnored: ignored)
        let tableRows = rows.map { CommitSortableRow(row: $0, statistics: $0.entry.flatMap { statistics[$0.path] }, isDirectory: $0.entry.map { model.submodules.contains($0.path) } ?? false, metadata: $0.entry.flatMap { model.fileMetadata[$0.path] }, lfsOwner: $0.entry.flatMap { model.lfsOwners[$0.path] } ?? "") }
        let sort = Binding(get: { model.fileSortOrder }, set: { model.setFileSortOrder($0) })
        return Table(tableRows, selection: selection, sortOrder: sort) {
            TableColumn("") { (row: CommitSortableRow) in
                if let entry = row.entry {
                    if staged != nil {
                        StagingCheckbox(entry: entry, enabled: !model.busy && !model.confirmingQuit) { model.setFileChecked(entry, files: entries, highlighted: selection.wrappedValue, checked: $0) }.frame(width: 20, height: 20)
                    } else {
                        Toggle("Include \(entry.path)", isOn: Binding(get: { model.checked.contains(entry.id) }, set: { model.setFileChecked(entry, files: entries, highlighted: selection.wrappedValue, checked: $0) }))
                            .labelsHidden().toggleStyle(.checkbox).disabled(entry.state == .conflicted)
                    }
                }
            }.width(24)
            TableColumn("Path", sortUsing: CommitFileSort(column: .path)) { (row: CommitSortableRow) in
                if let entry = row.entry {
                    HStack {
                        Image(nsImage: entry.state.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16).overlay {
                            if model.restoreCopies[entry.path] != nil { Image(nsImage: MenuIcon.restoreOverlay.image() ?? NSImage()).resizable().frame(width: 16, height: 16) }
                        }
                        Text(StatusListClipboard.displayedPath(entry)).foregroundStyle(entry.statusTextColor(selected: selection.wrappedValue.contains(entry.id)))
                    }.help(model.fileHelp(entry))
                } else if let group = row.group {
                    HStack {
                        Text(group.title).font(.headline).foregroundStyle(Color.accentColor)
                        Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1)
                    }.accessibilityLabel(group.title)
                }
            }.width(min: 260, ideal: 420)
            TableColumn("Filename", sortUsing: CommitFileSort(column: .fileName)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text((entry.path as NSString).lastPathComponent).foregroundStyle(entry.statusTextColor(selected: selection.wrappedValue.contains(entry.id))) } else { groupRule }
            }.width(min: 100, ideal: 180)
            TableColumn("Extension", sortUsing: CommitFileSort(column: .fileExtension)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(StatusListClipboard.fileExtension(entry.path, isDirectory: model.submodules.contains(entry.path) || model.fileMetadata[entry.path]?.isDirectory == true)).foregroundStyle(entry.statusTextColor(selected: selection.wrappedValue.contains(entry.id))) }
                else { groupRule }
            }.width(min: 40, ideal: 75)
            TableColumn("Status", sortUsing: CommitFileSort(column: .status)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(entry.index == "R" || entry.worktree == "R" ? "Renamed" : statistics[entry.path]?.status ?? entry.state.rawValue.capitalized).foregroundStyle(entry.statusTextColor(selected: selection.wrappedValue.contains(entry.id))) }
                else { groupRule }
            }.width(min: 60, ideal: 90)
            TableColumn("Lines added", sortUsing: CommitFileSort(column: .added)) { (row: CommitSortableRow) in
                lineCount(row.row, statistics: statistics, selected: selection.wrappedValue, added: true)
            }.width(min: 40, ideal: 80)
            TableColumn("Lines removed", sortUsing: CommitFileSort(column: .removed)) { (row: CommitSortableRow) in
                lineCount(row.row, statistics: statistics, selected: selection.wrappedValue, added: false)
            }.width(min: 40, ideal: 95)
            TableColumn("Last modified", sortUsing: CommitFileSort(column: .lastModified)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(row.metadata?.dateText ?? "–").foregroundStyle(entry.statusTextColor(selected: selection.wrappedValue.contains(entry.id))) } else { groupRule }
            }.width(min: 140, ideal: 180)
            TableColumn("File size", sortUsing: CommitFileSort(column: .fileSize)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(row.metadata?.sizeText ?? "–").foregroundStyle(entry.statusTextColor(selected: selection.wrappedValue.contains(entry.id))) } else { groupRule }
            }.width(min: 60, ideal: 90)
            TableColumn("LFS Lock", sortUsing: CommitFileSort(column: .lfsOwner)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(row.lfsOwner).foregroundStyle(entry.statusTextColor(selected: selection.wrappedValue.contains(entry.id))) } else { groupRule }
            }.width(min: 100, ideal: 160)
        }.fileListFont().contextMenu(forSelectionType: String.self) { requested in
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
                    ForEach(model.lfsActions(selected), id: \.self) { action in
                        Button { model.setLFSLocked(ids, locked: action == .lock) } label: { CommandLabel(title: action.rawValue, icon: action == .lock ? .lock : .unlock) }.disabled(model.busy || model.confirmingQuit)
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
        .background(CommitFileInteraction(rows: rows, visibleColumns: Set(model.visibleFileColumns), availableColumns: model.availableFileColumns, columnText: { entry, column in
            String(StatusListClipboard.text([entry], root: model.repository.root, statistics: statistics, copy: .column(column), metadata: model.fileMetadata, lfsOwners: model.lfsOwners).dropLast())
        }, savedOrder: model.fileColumns.order, savedWidths: model.fileColumns.widths, saveLayout: { model.saveFileColumnLayout(order: $0, widths: $1) }, setColumnVisible: { model.setFileColumn($0, visible: $1) }, resetColumns: { choose, accepted in model.requestResetFileColumns(choose: choose, onAccepted: accepted) }, focusedPath: focus, enabled: !model.busy && !model.confirmingQuit, delete: { model.deleteFiles($0, selectionMark: $1, permanently: $2) }, copy: { model.copyFileText($0, statistics: statistics, copy: $1 ? .pathsAndStatus : .relativePaths) }, copyColumn: { model.copyFileText($0, statistics: statistics, copy: .column($1)) }, toggleCheck: { files, mark in
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
            Text(label).foregroundStyle(entry.statusTextColor(selected: selected.contains(entry.id)))
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

enum CommitPostAction: String, CaseIterable, Hashable {
    case push, pull, recommit, createTag
    var title: String { switch self { case .push: return "Push…"; case .pull: return "Pull…"; case .recommit: return "ReCommit"; case .createTag: return "Create Tag…" } }
    var icon: MenuIcon { switch self { case .push: return .push; case .pull: return .pull; case .recommit: return .commit; case .createTag: return .tag } }
}
@MainActor final class CommitProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let action: CommitWindowModel.CompletionAction
    let staging: Bool
    let paths: Set<String>
    let options: CommitOptions
    let cancellation = OperationCancellation()
    let cancellable: Bool
    private let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private var outputState: GitProgressOutputState
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    private(set) var isAbandoned = false
    var outputLimit: Int { outputState.limit }
    var actionLogEligible: Bool { !busy && !isAbandoned }
    @Published private(set) var completionRange: NSRange?
    private let startedAt = ProcessInfo.processInfo.systemUptime
    @Published private(set) var postActions: [CommitPostAction] = []
    private var resolved = false
    private var selected: CommitPostAction?
    private var waiter: CheckedContinuation<CommitPostAction?, Never>?
    private var autoCloseRequested = false
    var dismissWithoutWindow = false
    var onClose: () -> Void = {}
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { !isAbandoned && busy && cancellable && !cancelling && !confirmingCancellation }
    init(repository: GitRepository, action: CommitWindowModel.CompletionAction, staging: Bool, paths: Set<String>, options: CommitOptions, preferences: UserDefaults, cancellable: Bool) {
        self.repository = repository; self.action = action; self.staging = staging; self.paths = paths; self.options = options; self.preferences = preferences; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences); self.cancellable = cancellable; outputState = GitProgressOutputState(preferences: preferences)
    }
    func complete(output: String, success: Bool, cancelled: Bool, postActions: [CommitPostAction], exitCode: Int32? = nil) {
        guard busy else { return }
        if !outputState.hasOutput && !isAbandoned {
            let parser = GitCliOutputParser(limit: outputState.limit)
            parser.appendChunk(Data(output.utf8)); outputState.consume(parser.processPending(), parser: parser); outputState.consume(parser.finish(), parser: parser)
        }
        self.output = isAbandoned ? "" : outputState.output; self.success = success; self.cancelled = cancelled
        let completion = SubmoduleProgressCompletion(success: success, cancelled: cancelled, exitCode: exitCode,
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt, preferences: preferences)
        if !isAbandoned { currentWork = completion.currentWork; percentage = 100; completionRange = completion.append(to: &self.output) }
        self.postActions = isAbandoned ? [] : postActions; busy = false; cancelling = false
        if isAbandoned { choose(nil); return }
        if autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { choose(nil) }
    }
    func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        guard busy, !isAbandoned else { return }
        outputState.consume(emission, parser: parser); output = outputState.output
        currentWork = outputState.currentWork; percentage = outputState.percentage
    }
    func invalidate() {
        guard !isAbandoned else { return }; isAbandoned = true; confirmingCancellation = false
        cancellation.cancel(); onClose = {}
    }
    func waitForChoice() async -> CommitPostAction? {
        if resolved { return selected }
        return await withCheckedContinuation { waiter = $0 }
    }
    func choose(_ action: CommitPostAction?) {
        guard !busy, !resolved else { return }
        if confirmingCancellation { if action == nil { autoCloseRequested = true }; return }
        guard action == nil || postActions.contains(action!) else { return }
        resolved = true; selected = action; onClose()
        waiter?.resume(returning: action); waiter = nil
    }
    func cancel() {
        guard canCancel else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, self.confirmingCancellation else { return }
                self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; self.cancellation.cancel() }
                else if !self.busy && self.autoCloseRequested { self.choose(nil) }
            }
        } else { cancelling = true; cancellation.cancel() }
    }
}
@MainActor final class CommitProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: CommitProgressWindowModel
    var onClosed: () -> Void = {}
    init(model: CommitProgressWindowModel) {
        self.model = model
        let window = SubmoduleProgressNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.title = "\(model.repository.root.lastPathComponent) – Commit progress – TurtleGit"; window.minSize = NSSize(width: 620,height: 340); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CommitProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.onClose = { [weak window] in guard let window else { return }; window.sheetParent?.endSheet(window); window.close() }
        window.escapeAction = { [weak model] in guard let model else { return }; if model.busy { model.cancel() } else { model.choose(nil) } }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            window.makeFirstResponder(nil)
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }

        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        guard sender.attachedSheet == nil, !model.confirmingCancellation else { return false }
        model.choose(nil); return false
    }
    func windowWillClose(_ notification: Notification) { if model.busy { model.invalidate() }; model.saveActionLog(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
private struct CommitProgressDialog: View {
    @ObservedObject var model: CommitProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            Text(model.currentWork.isEmpty ? " " : model.currentWork).font(.caption).lineLimit(1).help(model.currentWork)
            ProgressView(value: Double(model.busy ? model.percentage ?? 0 : 100), total: 100)
                .tint(model.busy ? .accentColor : model.success ? .blue : .red).accessibilityLabel("Git command progress")
            SubmoduleProgressOutputView(text: model.output, completed: !model.busy, completionRange: model.completionRange, success: model.success)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.busy ? model.cancelling ? "Cancelling…" : "Committing…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Commit failed").foregroundStyle(model.busy ? Color.primary : model.success ? .green : .red); Spacer() }
            HStack {
                if let first = model.postActions.first {
                    Button { model.choose(first) } label: { CommandLabel(title: first.title,icon: first.icon) }.disabled(model.confirmingCancellation)
                    Menu { ForEach(model.postActions,id: \.self) { action in Button { model.choose(action) } label: { CommandLabel(title: action.title,icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Commit post-actions") }.menuStyle(.borderlessButton).fixedSize().disabled(model.confirmingCancellation)
                }
                Spacer()
                Button("Close") { model.choose(nil) }.keyboardShortcut(.defaultAction).disabled(model.busy || model.confirmingCancellation)
                Button("Abort") { if model.busy { model.cancel() } else { model.choose(nil) } }.keyboardShortcut(.cancelAction)
                    .disabled(model.success || model.confirmingCancellation || model.busy && !model.canCancel)
            }
        }.padding(12)
    }
}
