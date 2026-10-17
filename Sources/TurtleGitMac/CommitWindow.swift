import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import TurtleGitCore
import UniformTypeIdentifiers

@MainActor private final class CommitNativeWindow: NSWindow {
    weak var model: CommitWindowModel?
    weak var commandMenu:CommitCommandMenu?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if commandMenu?.performKeyEquivalent(event)==true {return true}
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class CommitWindowController: NSWindowController, NSWindowDelegate {
    let model: CommitWindowModel
    private(set) var commandMenu:CommitCommandMenu?
    func windowDidResignKey(_ notification:Notification) {commandMenu?.remove()}
    var commandsAvailable:Bool {!closingCommit && !hasMessagePicker && !model.inputsBlocked && window?.attachedSheet==nil && model.messageFocusAvailable}
    func messageEditor(in view:NSView? = nil)->CommitMessageTextView? {
        guard let view=view ?? window?.contentView else {return nil}
        if let editor=view as? CommitMessageTextView {return editor}
        return view.subviews.compactMap {messageEditor(in:$0)}.first
    }
    var onClosed: () -> Void = {}
    private(set) var partial: PatchWindowController?
    private(set) var stagingHintAlert:NSAlert?
    private var stagingHintAnswer:((Bool?)->Void)?
    private var previousPartialParentFrame: NSRect?
    private var positioningPartial = false
    var partialPlacementScreens: () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    private(set) var templatePanel: NSOpenPanel?
    private var closingCommit = false
    private var historyWindow: NSWindow?
    var makeHistoryWindow: () -> NSWindow = {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    }
    private var logPicker: LogWindowController?
    private(set) var preflightAlert:NSAlert?
    var hasMessagePicker: Bool { historyWindow != nil || logPicker != nil }
    private(set) var issueProviderOwner: CommitIssueProviderOwner?
    private var progressController: CommitProgressWindowController?
    var onPullAfterLFSLock: () -> Void = {}
    private var lfsOperation: LFSFileOperationController?
    var makeLFSOperation: (GitRepository, RepositoryAccessLease?) -> LFSFileOperationController = { LFSFileOperationController(repository: $0, access: $1) }
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        makeLFSOperation = { LFSFileOperationController(repository: $0, access: $1, defaults: defaults) }
        preferences = defaults
        model = CommitWindowModel(repository: repository, access: access, unversionedDefaults: defaults, dialogDefaults: defaults)
        let window = CommitNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Commit", preferences: defaults)
        window.minSize = NSSize(width: 900, height: 680); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CommitDialog(model: model).defaultAppStorage(defaults))
        super.init(window: window); model.comparisonWindow = window; model.clientHooks.windowProvider = { [weak window] in window?.attachedSheet ?? window }; window.model = model; window.delegate = self; window.setContentSize(NSSize(width: 1000, height: 760)); window.center()
        model.presentStagingHint={ [weak self,weak window] in
            guard let self,!self.closingCommit,let window,window.isVisible,window.attachedSheet==nil else {return nil}
            let alert=NSAlert();alert.alertStyle = .informational;alert.messageText="Staging support";alert.informativeText=CommitWindowModel.stagingHint
            alert.addButton(withTitle:"OK");alert.showsSuppressionButton=true;alert.suppressionButton?.title="Do not show this message again"
            self.stagingHintAlert=alert
            return await withCheckedContinuation { continuation in
                var answered=false
                let answer:(Bool?)->Void = {value in guard !answered else {return};answered=true;continuation.resume(returning:value)}
                self.stagingHintAnswer=answer
                alert.beginSheetModal(for:window) { [weak self] response in
                    if self?.stagingHintAlert === alert {self?.stagingHintAlert=nil;self?.stagingHintAnswer=nil}
                    answer(response == .alertFirstButtonReturn ? alert.suppressionButton?.state == .on:nil)
                }
            }
        }
        model.authorizeTemplateFile = { [weak self, weak window] file in
            guard let self, let window, !self.closingCommit, window.attachedSheet == nil else { throw OperationCancellationFailure.cancelled }
            let panel = NSOpenPanel(); self.templatePanel = panel
            panel.title = "Allow access to commit template"; panel.prompt = "Allow Access"
            panel.message = "Select the configured commit template: " + file.path
            panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.directoryURL = file.deletingLastPathComponent(); panel.nameFieldStringValue = file.lastPathComponent
            defer { if self.templatePanel === panel { self.templatePanel = nil } }
            let response = await withCheckedContinuation { reply in panel.beginSheetModal(for: window) { reply.resume(returning: $0) } }
            guard !self.closingCommit else { throw OperationCancellationFailure.cancelled }
            return response == .OK ? panel.url : nil
        }
        issueProviderOwner = CommitIssueProviderOwner(model: model, parent: window)
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
            guard let self, !self.closingCommit, let window, window.attachedSheet == nil, self.lfsOperation == nil else { return false }
            let progress = self.makeLFSOperation(repository, access)
            progress.model.onProgressLog = { [weak self] path in self?.model.onFileLog(path) }
            progress.model.onPullAfterLock = { [weak self] in guard let self, !self.closingCommit else { return }; self.onPullAfterLFSLock() }
            progress.onClosed = { [weak self, weak progress] in
                guard let self, !self.closingCommit, self.lfsOperation === progress else { return }
                self.lfsOperation = nil; self.model.busy = false; self.model.reload(); self.model.refreshPartial()
            }
            self.lfsOperation = progress
            guard progress.present(owner: window, paths: paths, locked: locked) else { self.lfsOperation = nil; return false }
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
        model.chooseApplication = { [weak window] _ in
            await Task.yield()
            guard let window, window.attachedSheet == nil else { return nil }
            let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"
            panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            let response = await withCheckedContinuation { reply in panel.beginSheetModal(for: window) { reply.resume(returning: $0) } }
            return response == .OK ? panel.url : nil
        }
        model.chooseExportFolder = { [weak window] _ in
            await Task.yield()
            guard let window, window.attachedSheet == nil else { return nil }
            let panel = NSOpenPanel(); panel.title = "Export selected files"; panel.prompt = "Export"
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
            let response = await withCheckedContinuation { reply in panel.beginSheetModal(for: window) { reply.resume(returning: $0) } }
            return response == .OK ? panel.url : nil
        }
        model.confirmFileDeletion = { [weak window] paths, permanently in
            await Task.yield()
            guard let window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = permanently ? "Permanently delete the selected paths?" : "Move the selected paths to Trash?"
            alert.informativeText = "\(paths.count) selected item(s). Their index entries will also be removed." + (permanently ? " This cannot be undone." : " Files moved to Trash can be recovered in Finder.")
            alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
            return await withCheckedContinuation { reply in alert.beginSheetModal(for: window) { reply.resume(returning: $0 == .alertSecondButtonReturn) } }
        }
        model.confirmFileRestore = { [weak window] in
            guard let window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Do you really want to restore the copy?"
            alert.informativeText = "You will lose all changes that you have done after creating the copy."
            alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Restore")
            return await withCheckedContinuation { reply in alert.beginSheetModal(for: window) { reply.resume(returning: $0 == .alertSecondButtonReturn) } }
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
            alert.beginSheetModal(for: window) { [weak model = self.model] response in
                guard let model, model.messageFocusAvailable else { choose(false); return }
                if response == .alertFirstButtonReturn {
                    if alert.suppressionButton?.state == .on { model.rememberTemplateProceed() }
                }
                choose(response == .alertFirstButtonReturn)
            }
        }
        model.confirmUnresolvedConflicts={ [weak self,weak window] paths,choose in
            guard let self,!self.closingCommit,let window,window.attachedSheet==nil else { choose(false);return }
            let alert=NSAlert();alert.alertStyle = .warning;alert.messageText="One or more files are in a conflicted state."
            alert.informativeText="OK selects the first conflicted file. Ignore continues with the current commit selection.\n\n"+paths.prefix(8).joined(separator:"\n")
            alert.addButton(withTitle:"OK");alert.addButton(withTitle:"Ignore");self.preflightAlert=alert
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self else { choose(false);return };if self.preflightAlert===alert { self.preflightAlert=nil }
                choose(!self.closingCommit && response == .alertSecondButtonReturn)
            }
        }
        model.confirmBranchTagCollision={ [weak self,weak window] name,choose in
            guard let self,!self.closingCommit,let window,window.attachedSheet==nil else { choose(false);return }
            let alert=NSAlert();alert.alertStyle = .warning;alert.messageText="A tag with this name already exists."
            alert.informativeText="Creating branch “"+name+"” makes the short name ambiguous. Continue anyway?"
            alert.addButton(withTitle:"Continue");let abort=alert.addButton(withTitle:"Abort");alert.buttons[0].keyEquivalent="";abort.keyEquivalent="\r";alert.window.defaultButtonCell=abort.cell as? NSButtonCell;self.preflightAlert=alert
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self else { choose(false);return };if self.preflightAlert===alert { self.preflightAlert=nil }
                choose(!self.closingCommit && response == .alertFirstButtonReturn)
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

        commandMenu=CommitCommandMenu(owner:self);window.commandMenu=commandMenu
        DialogGeometry.attach(window, identifier: "CommitWindowController")
    }
    func setQuitConfirmation(_ pending: Bool) { model.confirmingQuit = pending; partial?.model.confirmingQuit = pending }
    func windowWillClose(_ notification: Notification) {
        commandMenu?.retire()
        let hintAnswer=stagingHintAnswer;stagingHintAnswer=nil;stagingHintAlert=nil;hintAnswer?(nil)
        templatePanel?.cancel(nil); templatePanel = nil
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        closingCommit = true;preflightAlert=nil; model.invalidateForClose(); issueProviderOwner?.retire(); issueProviderOwner = nil; lfsOperation?.close(); lfsOperation = nil
        if let child = historyWindow {
            historyWindow = nil; window?.endSheet(child); child.orderOut(nil); child.close()
        }
        logPicker?.close(); logPicker = nil; partial?.close(); partial = nil; model.unifiedWindow?.close(); onClosed()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.submoduleLog.isReading { model.submoduleLog.cancel(); return false }
        guard sender.attachedSheet == nil, !hasMessagePicker, partial?.model.busy != true, partial?.window?.attachedSheet == nil, !model.unifiedViewerBusy else { return false }
        model.cancel(); return false
    }
    private func showHistory(insert: @escaping (String) -> Void) {
        guard !closingCommit, !model.inputsBlocked, let window, window.attachedSheet == nil,
              logPicker == nil, let history = model.messageHistory, historyWindow == nil else { return }
        let child = makeHistoryWindow(); child.isReleasedWhenClosed = false
        child.title = "Log History – TurtleGit"; child.minSize = NSSize(width: 400, height: 260)
        child.contentView = MessageHistoryPickerView(history: history) { [weak self, weak window, weak child] text in
            guard let self, !self.closingCommit, let child, self.historyWindow === child else { return }
            self.historyWindow = nil; window?.endSheet(child); child.orderOut(nil); child.close()
            if let text { insert(text) }
        }
        DialogGeometry.attach(child, identifier: "HistoryDlg")
        historyWindow = child; window.beginSheet(child)
    }
    private func showRevisionPicker(message: Bool, insert: @escaping (String) -> Void) {
        guard !closingCommit, !model.inputsBlocked, let window, window.attachedSheet == nil,
              historyWindow == nil, logPicker == nil else { return }
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
        let controller = partial ?? PatchWindowController(repository: model.repository, access: model.access, preferences: preferences)
        partial = controller
        controller.onClosed = { [weak self, weak controller] in
            guard let self, self.partial === controller else { return }
            if let child = controller?.window { child.parent?.removeChildWindow(child) }
            self.previousPartialParentFrame = nil
            self.partial = nil; self.model.partialMode = nil; self.model.viewingPatch = false
            if !self.closingCommit { self.model.savePatchPreference(false) }
        }
        controller.onMoved = { [weak self] in self?.snapPartial() }
        controller.model.onApplying = { [weak self] busy in
            guard let self, !self.closingCommit else { return }
            self.model.busy = busy
        }
        controller.model.onSettled = { [weak self] _ in
            guard let self, !self.closingCommit else { return }
            self.model.refreshStagingState(refreshPatch: false)
        }
        controller.model.onApplied = {}
        controller.model.readOnly = readOnly
        controller.model.staged = staged
        controller.model.base = model.comparisonBase
        model.partialMode = readOnly ? nil : staged
        model.viewingPatch = readOnly
        model.savePatchPreference(true)
        controller.model.comparisonTitle = model.comparisonBase != nil ? "Parent → Working tree" : model.hasHead ? "HEAD → Working tree" : "Initial commit"
        controller.window?.title = readOnly ? "View Patch – " + controller.model.comparisonTitle : staged ? "Partial Unstaging – HEAD → Index" : "Partial Staging – Index → Working tree"
        if let child = controller.window {
            // A modeless native companion can be moved independently, as upstream's
            // sticky PatchView. AppKit child windows otherwise translate on every
            // parent move, including deliberately detached placements.
            child.parent?.removeChildWindow(child)
            if previousPartialParentFrame == nil {
                positioningPartial = true
                child.setFrame(LogPatchPlacement.initial(parent: window.frame, width: child.frame.width, screens: partialPlacementScreens()), display: false)
                positioningPartial = false
            }
            child.alphaValue = window.alphaValue; child.appearance = window.appearance
        }
        previousPartialParentFrame = window.frame
        if let preview = controller.window, window.isVisible { preview.order(.above, relativeTo: window.windowNumber) }
        reloadPartial()
    }
    private func reloadPartial() {
        guard let partial else { return }
        partial.model.base = model.comparisonBase
        partial.model.comparisonTitle = model.comparisonBase != nil ? "Parent → Working tree" : model.hasHead ? "HEAD → Working tree" : "Initial commit"
        partial.window?.title = partial.model.readOnly ? "View Patch – " + partial.model.comparisonTitle : partial.model.staged ? (model.comparisonBase == nil ? "Partial Unstaging – HEAD → Index" : "Partial Unstaging – Parent → Index") : "Partial Staging – Index → Working tree"
        let selected = model.entries.filter { model.selection.contains($0.id) && $0.state != .untracked && $0.state != .ignored }
        let statistics = partial.model.readOnly ? model.statistics : partial.model.staged ? model.stagedStatistics : model.unstagedStatistics
        // A copied row may have no originalPath in porcelain status. Include
        // its diff source so the preview retains the copy header and whole-file gate.
        let paths = selected.flatMap { entry in
            let source = entry.originalPath ?? statistics[entry.path]?.oldPath
            return [entry.path] + (source.map { [$0] } ?? [])
        }
        partial.model.reload(paths: Array(GitPathSet(paths)).sorted(), staged: partial.model.staged)
    }
    private func snapPartial() {
        guard !closingCommit, !positioningPartial, let parent = window, let preview = partial?.window,
              let frame = LogPatchPlacement.snap(preview: preview.frame, parent: parent.frame), frame != preview.frame else { return }
        positioningPartial = true; preview.setFrame(frame, display: false); positioningPartial = false
    }
    private func followPartial() {
        guard !closingCommit, let parent = window, let preview = partial?.window, let previous = previousPartialParentFrame else { return }
        previousPartialParentFrame = parent.frame
        guard previous != parent.frame,
              let frame = LogPatchPlacement.follow(preview: preview.frame, oldParent: previous, newParent: parent.frame, minimumHeight: preview.minSize.height) else { return }
        positioningPartial = true; preview.setFrame(frame, display: false); positioningPartial = false
    }
    private func showPartialWithoutActivation() {
        guard !closingCommit, let parent = window, parent.isVisible, !parent.isMiniaturized, let preview = partial?.window else { return }
        preview.appearance = parent.appearance; preview.alphaValue = parent.alphaValue
        preview.order(.above, relativeTo: parent.windowNumber)
    }
    func windowDidMove(_ notification: Notification) { followPartial() }
    func windowDidResize(_ notification: Notification) { followPartial() }
    func windowWillMiniaturize(_ notification: Notification) { partial?.window?.orderOut(nil) }
    func windowDidDeminiaturize(_ notification: Notification) { showPartialWithoutActivation() }
    func windowDidBecomeKey(_ notification: Notification) {commandMenu?.install();showPartialWithoutActivation();model.offerStagingHint()}
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class CommitWindowModel: ObservableObject {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    lazy var clientHooks = ClientHookSession(preferences: dialogDefaults)
    @Published var conflictRebase = false
    @Published var entries: [StatusEntry] = [] { didSet { if entries != oldValue { fileMenuGeneration = UUID() } } }
    @Published var indexFlagFiles: [WorkingTreeFile] = []
    @Published var restoreCopies: GitPathMap<WorkingFileRestoreCopy> = [:] { didSet { fileMenuGeneration = UUID() } }
    enum RestoreChoice { case restore, keep, cancel }
    var chooseRestoreCopies: (Bool, @escaping (RestoreChoice) -> Void) -> Void = { _, choose in choose(.keep) }
    @Published var comparisonBase: String?
    @Published var stagedStatistics: GitPathMap<CommitFile> = [:]
    @Published var unstagedStatistics: GitPathMap<CommitFile> = [:]
    @Published var stagingEnabled = false { didSet { if stagingEnabled != oldValue { fileMenuGeneration = UUID() } } }
    @Published var viewingPatch = false
    private var loadedPreferences = false
    private var persistedStaging: Bool?
    @Published var partialMode: Bool?
    @Published var stagedDiff = true { didSet { if stagedDiff != oldValue { fileMenuGeneration = UUID() } } }
    private var hasLoaded = false
    static private(set) var activeFileDrops = 0
    var readDroppedURL: (NSItemProvider) async throws -> URL = CommitFileURLReader.read
    var applyDroppedURLs: (([URL], OperationCancellation) async throws -> [CommitDroppedItem])?
    private var droppedChecks: [CommitDroppedItem] = []
    private var reloadTask: Task<Void, Never>?
    private var reloadCancellation: OperationCancellation?
    private var reloadError:String?
    @Published private var pendingReloadCancel = false
    var queryCommitStatus: (Bool, OperationCancellation) async throws -> [StatusEntry]
    var queryStagingStates: ([StatusEntry], String?, OperationCancellation) async throws -> GitPathMap<CommitStagingState>
    @Published var statistics: GitPathMap<CommitFile> = [:]
    @Published var checked = GitPathSet()
    private var selectedPaths = GitPathSet()
    @Published var nativeFileSelection = Set<String>() {
        didSet {
            guard nativeFileSelection != oldValue else {return}
            selectedPaths = GitPathRowIdentity.paths(nativeFileSelection)
            fileMenuGeneration = UUID()
        }
    }
    var selection: GitPathSet {
        get {selectedPaths}
        set {
            let ids = Set(newValue.map(GitPathRowIdentity.encode))
            if nativeFileSelection != ids {nativeFileSelection = ids}
        }
    }

    @Published var fileMetadata: GitPathMap<StatusListMetadata> = [:] { didSet { if fileMetadata.mapValues({ $0.isDirectory }) != oldValue.mapValues({ $0.isDirectory }) { fileMenuGeneration = UUID() } } }
    @Published var hasLFS = false
    @Published var lfsOwners: [String: String] = [:]
    @Published var lfsLockedPaths = GitPathSet()
    @Published var lfsOwnershipKnown = false
    private var lfsOwnerCancellation: OperationCancellation?
    var queryLFSOwners: (OperationCancellation) async throws -> [LFSLock]
    var onLFSOperation: ([String], Bool) -> Bool = { _, _ in false }
    @Published var fileColumns = StatusListColumnSettings()
    var availableFileColumns: Set<StatusListColumn> { Set(StatusListColumn.allCases).subtracting(hasLFS ? [] : [.lfsOwner]) }
    var visibleFileColumns: [StatusListColumn] { fileColumns.order.filter { fileColumns.visible.contains($0) && availableFileColumns.contains($0) } }
    @Published var fileSortOrder = [CommitFileSort(column: .path)] { didSet { if !fileSortOrder.elementsEqual(oldValue, by: { $0.column == $1.column && $0.order == $1.order }) { fileMenuGeneration = UUID() } } }
    @Published var focusedFiles: [String: String] = [:] { didSet { if focusedFiles.mapValues({ GitReferenceName($0) }) != oldValue.mapValues({ GitReferenceName($0) }) { fileMenuGeneration = UUID() } } }
    @Published var changelists = GitChangelists() { didSet { if changelists != oldValue { fileMenuGeneration = UUID() } } }
    @Published var changelistsLoaded = false
    @Published var keepChangelists = false
    @Published var creatingChangelist = false
    @Published var changelistName = ""
    private var changelistPaths: [String] = []
    private var changelistMenu: StatusFileMenuSnapshot?
    @Published var branch = ""
    @Published var createBranch = false
    @Published var newBranch = ""
    @Published var message = "" { didSet { if !GitReferenceName.equal(message,oldValue) { cancelHistoryIssueUpdate(); scheduleIssueStyling() } } }
    @Published var projectSettings = ProjectDialogSettings()
    var projectIconAccess: RepositoryAccessLease? { access }
    static private(set) var activeIssueProviderOperations = 0
    @Published private(set) var issueProviderBusy = false
    @Published private(set) var nativeIssueProvider: NativeIssueCatalogProvider?
    @Published private(set) var issueProviderError: String?
    private var issueProviderGeneration = UUID()
    var chooseProviderIssues: (NativeIssueCatalogProvider, NativeIssueProviderContext) async -> NativeIssueProviderResult? = { _, _ in nil }
    var providerContext: NativeIssueProviderContext { NativeIssueProviderContext(repositoryRoot: repository.root, paths: scopePaths, message: message, issueID: issueID) }
    func selectProviderIssues() {
        guard messageFocusAvailable, !inputsBlocked, let provider = nativeIssueProvider else { return }
        let context = providerContext, generation = UUID(); issueProviderGeneration = generation; issueProviderBusy = true; Self.activeIssueProviderOperations += 1
        Task {
            defer { Self.activeIssueProviderOperations -= 1; withExtendedLifetime(access) {}; if issueProviderGeneration == generation { issueProviderBusy = false } }
            let result = await chooseProviderIssues(provider, context)
            guard messageFocusAvailable, issueProviderGeneration == generation, !confirmingQuit, message.utf8.elementsEqual(context.message.utf8), issueID.utf8.elementsEqual(context.issueID.utf8), scopePaths == context.paths, let result else { return }
            message = result.message; issueID = result.issueID; requestMessageFocus()
        }
    }
    private func readNativeIssueProvider(_ token: OperationCancellation) async throws -> (provider:NativeIssueCatalogProvider?,error:String?) {
        let rows: [NativeIssueAssociation]
        do { rows = try NativeIssueAssociations.load(from: dialogDefaults) }
        catch { return (nil,error.localizedDescription) }
        let association = try await readReload(token) { try await repository.nativeIssueAssociation(rows: rows, cancellation: token) }
        do { return (try association.map { try NativeIssueCatalogProvider(parameters: $0.parameters, identifier: $0.provider) },nil) }
        catch { return (nil,error.localizedDescription) }
    }
    @Published var issueProperties = IssueTrackerProperties() { didSet { if issueProperties != oldValue { cancelHistoryIssueUpdate(); scheduleIssueStyling() } } }
    @Published private(set) var issueMessageStyles: [IssueMessageStyle] = []
    private let issueStyler = IssueMessageStyler()
    private var issueStyleTask: Task<Void, Never>?
    private var issueStyleCancellation: OperationCancellation?
    private var historyIssueTask: Task<Void, Never>?
    private var historyIssueCancellation: OperationCancellation?
    private var historyIssueGeneration = UUID()
    var queryHistoryIssue: (IssueTrackerProperties, String, OperationCancellation) async throws -> String
    @Published var formattingEnabled = true {
        didSet { if formattingEnabled != oldValue { scheduleIssueStyling() } }
    }
    private(set) var messageSnippets = MessageSnippets()
    @Published private(set) var messageCompletionCatalog = MessageCompletionCatalog()
    private var completionTask: Task<Void, Never>?
    private var completionGeneration = UUID()
    private var completionSources: [MessageCodeScanner.Source] = []
    private var completionOptions: MessageCodeScanner.Options?
    private var completionEnabled: Bool?
    deinit { reloadCancellation?.cancel(); reloadTask?.cancel(); completionTask?.cancel(); issueStyleTask?.cancel(); issueStyleCancellation?.cancel(); historyIssueTask?.cancel(); historyIssueCancellation?.cancel(); authorCancellation?.cancel(); dateCancellation?.cancel(); amendCancellation?.cancel() }
    func prepareMessageCompletions(force: Bool = false) {
        var options = MessageCodeScanner.Options()
        let defaults = dialogDefaults
        let enabled = defaults.object(forKey: "Autocompletion") as? Bool ?? true
        options.removeExtensions = defaults.bool(forKey: "AutocompleteRemovesExtensions")
        options.parseUnversioned = defaults.bool(forKey: "AutocompleteParseUnversioned")
        options.maximumBytes = defaults.object(forKey: "AutocompleteParseMaxSize") as? Int ?? 300000
        options.timeoutSeconds = UInt32(clamping: defaults.object(forKey: "AutocompleteParseTimeout") as? Int ?? 5)
        options.useUTF8 = ComparisonTextEncoding.preferUTF8(from: defaults)
        let locallyIgnored = GitPathSet(indexFlagFiles.filter { $0.assumeUnchanged || $0.skipWorktree }.map { $0.entry.path })
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
    @Published var issueID = "" { didSet { if !GitReferenceName.equal(issueID,oldValue) { cancelHistoryIssueUpdate() } } }
    private func cancelHistoryIssueUpdate() {
        historyIssueGeneration = UUID()
        historyIssueCancellation?.cancel(); historyIssueTask?.cancel()
        historyIssueCancellation = nil; historyIssueTask = nil
    }
    private func scheduleIssueStyling() {
        issueStyleTask?.cancel(); issueStyleCancellation?.cancel(); issueMessageStyles = []
        let cancellation = OperationCancellation(); issueStyleCancellation = cancellation
        let text = message, properties = issueProperties, worker = issueStyler, formatting = formattingEnabled
        guard !text.isEmpty else { return }
        issueStyleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                try Task.checkCancellation(); try cancellation.check()
                MessageEditorStylingSession.beginOperation()
                defer { MessageEditorStylingSession.endOperation() }
                let styles = try await worker.styles(properties: properties, message: text, formattingEnabled: formatting, cancellation: cancellation)
                guard !Task.isCancelled, let self, GitReferenceName.equal(self.message,text), self.issueProperties == properties, self.formattingEnabled == formatting else { return }
                self.issueMessageStyles = styles
            } catch { /* Invalid/stale styling does not interrupt text entry. Commit validation reports configuration failures. */ }
        }
    }
    func updateIssueFromHistory(_ selectedMessage: String, insertedInto text: String) {
        cancelHistoryIssueUpdate()
        let properties = issueProperties, previousID = issueID
        guard messageFocusAvailable, properties.showsIssueField else { return }
        let generation = historyIssueGeneration, token = OperationCancellation(), query = queryHistoryIssue
        historyIssueCancellation = token
        historyIssueTask = Task { [weak self] in
            defer {
                if self?.historyIssueGeneration == generation { self?.historyIssueTask = nil; self?.historyIssueCancellation = nil }
            }
            guard !Task.isCancelled, !token.isCancelled else { return }
            guard let id = try? await query(properties, selectedMessage, token), !id.isEmpty,
                  !Task.isCancelled, !token.isCancelled, let self, self.messageFocusAvailable,
                  self.historyIssueGeneration == generation,
                  GitReferenceName.equal(self.message,text), GitReferenceName.equal(self.issueID,previousID), self.issueProperties == properties else { return }
            self.issueID = id
        }
    }
    private var loadedMessage = false
    let templateFileAccess: CommitTemplateFileAccess
    var authorizeTemplateFile: (URL) async throws -> URL? = { _ in nil }
    private(set) var messageTemplate = ""
    private(set) var messageHistory: CommitMessageHistory?
    var showMessageHistory: (@escaping (String) -> Void) -> Void = { _ in }
    var pickRevision: (Bool, @escaping (String) -> Void) -> Void = { _, _ in }
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    var onCompare: ([String], Bool) -> Void = { _, _ in }
    var onCompareTwoFiles: ([String]) -> Void = { _ in }
    lazy var submoduleLog = SubmoduleWorkingLogSession(repository: repository, access: access)
    var onSubmoduleLog: (GitRepository) -> Void = { _ in }
    var onFileLog: (String) -> Void = { _ in }
    var onFileBlame: (String) -> Void = { _ in }
    var onResolve: (RepositoryAction, [String]) -> Void = { _, _ in }
    var onIgnore: (RepositoryAction, [String]) -> Void = { _, _ in }
    var onCopyAdd: ([String]) -> Void = { _ in }
    var onPasteFiles: (Bool, [URL]) -> Void = { _, _ in }
    var onMove: ([String]) -> Void = { _ in }
    var onRename: (String) -> Void = { _ in }
    var chooseApplication: (String) async -> URL? = { _ in nil }
    var chooseExportFolder: ([String]) async -> URL? = { _ in nil }
    var confirmFileDeletion: ([String], Bool) async -> Bool = { _, _ in false }
    var confirmFileRestore: () async -> Bool = { false }
    var openWorkingFile: (URL, URL?) async throws -> Void = { url, application in
        if let application {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, failure in
                    if let failure { reply.resume(throwing: failure) } else { reply.resume() }
                }
            }
        } else if !NSWorkspace.shared.open(url) { throw StatusFileActionFailure(message: "Could not open " + url.lastPathComponent + ".") }
    }
    lazy var openAlternativeEditor: (URL) async throws -> Void = { [weak self] url in
        guard let self else { throw OperationCancellationFailure.cancelled }
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            AlternativeEditor.open(url, preferences: self.dialogDefaults, permissions: self.access.map { [$0] } ?? []) { failure in
                if let failure { reply.resume(throwing: StatusFileActionFailure(message: failure)) } else { reply.resume() }
            }
        }
    }

    var confirmCancel: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    private var originalAmendMessage = ""
    var confirmUneditedTemplate: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    var confirmUnresolvedConflicts:([String],@escaping (Bool)->Void)->Void = { _,choose in choose(false) }
    var confirmBranchTagCollision:(String,@escaping (Bool)->Void)->Void = { _,choose in choose(false) }
    private var preflightCancellation:OperationCancellation?
    private var preflightRequest=UUID()
    private(set) static var activeCommitPreflights=0
    private func validatePreflight(_ request:UUID,_ token:OperationCancellation) throws {
        guard messageFocusAvailable,preflightRequest==request,!token.isCancelled else { throw OperationCancellationFailure.cancelled }
    }
    private func focusConflictedFile(_ conflicts:[StatusEntry]) {
        guard let first=visibleEntries.first(where:{ $0.state == .conflicted }) ?? conflicts.first else { return }
        if !visibleEntries.contains(where:{ GitReferenceName.equal($0.path,first.path) }) { showWholeProject=true }
        selection=[first.id];focusedFiles[stagingEnabled ? "unstaged" : "checkbox"]=first.id
    }
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
    private(set) var historyCombine: HistoryCombinePlan?
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
    @Published var doNotAutoselectSubmodules = false
    @Published var submodules = GitPathSet() { didSet { if submodules != oldValue { fileMenuGeneration = UUID() } } }
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
    @Published var showUnversioned = true { didSet { if showUnversioned != oldValue { fileMenuGeneration = UUID() } } }
    private let unversionedDefaults: UserDefaults
    var messageEditorPreferences: UserDefaults { dialogDefaults }
    private let dialogDefaults: UserDefaults
    private var selectFilesAutomatically: Bool
    private let doNotAutoselectMissing: Bool
    @Published var showWholeProject = true {
        willSet {if newValue != showWholeProject,messageFocusAvailable,!busy {filterPosition = fileListRefresh.begin(preferences:dialogDefaults,selectedIDs:selection)}}
        didSet {updateScopeTitle();if let position = filterPosition {filterPosition = nil;restoreVisibleFilePosition(position)}}
    }
    @Published var scopePaths: [String] = [] { didSet { updateScopeTitle() } }
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    private var diffSession: FileListComparisonSession?
    var onUnifiedDiff: ((Data, Bool) async throws -> Void)?
    weak var comparisonWindow: NSWindow? { didSet { updateScopeTitle() } }
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
    var onSVNDCommit: () -> Void = {}
    var onCommitProgress: ((CommitProgressWindowModel) -> Void)?
    @Published private(set) var commitProgress: CommitProgressWindowModel?
    enum CompletionAction: String, CaseIterable {
        case commit = "Commit", recommit = "ReCommit", push = "Commit & Push"
        var sourceIndex: Int { switch self { case .commit: return 0; case .recommit: return 1; case .push: return 2 } }
        init(sourceIndex: Int) { self = Self.allCases.first { $0.sourceIndex == sourceIndex } ?? .commit }
    }
    @Published private(set) var completionAction: CompletionAction = .commit
    var currentCompletionAction: CompletionAction { replaySplit == nil && historyCombine == nil ? completionAction : .commit }
    func commitCurrentAction() { commit(currentCompletionAction) }
    private func rememberCompletionAction(_ action: CompletionAction) {
        guard replaySplit == nil, historyCombine == nil else { return }
        dialogDefaults.set(action.sourceIndex, forKey: "CommitLastAction")
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, unversionedDefaults: UserDefaults = .standard, dialogDefaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.unversionedDefaults = unversionedDefaults
        self.dialogDefaults = dialogDefaults
        templateFileAccess = CommitTemplateFileAccess(preferences: dialogDefaults)
        queryLFSOwners = { try await repository.lfsLocks(cancellation: $0) }
        queryHistoryIssue = { try await repository.issueFieldValue(properties: $0, message: $1, cancellation: $2) }
        queryCommitStatus = { try await repository.commitDialogStatus(amendToParent: $0, cancellation: $1) }
        queryStagingStates = { try await repository.commitStagingStates(for: $0, base: $1, cancellation: $2) }
        queryCommitAuthor = { amend, cancellation in
            if amend {
                var options = HistoryOptions(); options.useMailmap = false; options.limit = 1
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
        keepChangelists = dialogDefaults.bool(forKey: "Commit.KeepChangelists")
        doNotAutoselectSubmodules = dialogDefaults.bool(forKey: "Commit.DoNotAutoselectSubmodules")
        formattingEnabled = dialogDefaults.object(forKey: "StyleCommitMessages") as? Bool ?? true
    }
    func setShowUnversioned(_ enabled: Bool) {
        guard messageFocusAvailable, !busy, !confirmingQuit else { return }
        let position = fileListRefresh.begin(preferences:dialogDefaults,selectedIDs:selection)
        showUnversioned = enabled
        unversionedDefaults.set(enabled, forKey: "AddBeforeCommit");restoreVisibleFilePosition(position)
    }
    private func restoreVisibleFilePosition(_ position:FileListRefreshCoordinator.Ticket) {
        if !position.remember {selection = []}
        Task { [self] in await fileListRefresh.restore(position,ids:visibleFileRowIDs);fileListRefresh.finish(position) }
    }
    var visibleFileRowIDs:[String] {
        let ignored = GitPathSet(indexFlagFiles.filter {$0.assumeUnchanged || $0.skipWorktree}.map {$0.entry.path})
        return StatusListGroups.rows(entries:sortedFiles(visibleEntries,statistics:statistics),changelists:changelists,locallyIgnored:ignored).map(\.id)
    }
    var visibleEntries: [StatusEntry] {
        entries.filter { entry in
            entry.state != .ignored && (showUnversioned || entry.state != .untracked) &&
                (entry.staged || showWholeProject || scopePaths.contains { GitReferenceName.equal($0,entry.path) || entry.path.utf8.starts(with:($0 + "/").utf8) })
        }
    }
    func sortedFiles(_ files: [StatusEntry], statistics: GitPathMap<CommitFile>) -> [StatusEntry] {
        guard let comparator = fileSortOrder.first else { return files }
        return files.map { CommitSortableRow(row: .file($0), statistics: statistics[$0.path], isDirectory: submodules.contains($0.path) || fileMetadata[$0.path]?.isDirectory == true, metadata: fileMetadata[$0.path], lfsOwner: lfsOwners[$0.path] ?? "") }
            .sorted(using: comparator).compactMap(\.entry)
    }
    @discardableResult func saveFileColumnLayout(order: [StatusListColumn], widths: [StatusListColumn: Double]) -> Bool {
        guard messageFocusAvailable, !busy, !confirmingQuit else { return false }
        let next = StatusListColumnSettings(visible: fileColumns.visible, order: order, widths: widths)
        if fileColumns != next { fileColumns = next; fileColumns.save(to: dialogDefaults) }
        return true
    }
    func setFileColumn(_ column: StatusListColumn, visible: Bool) {
        guard messageFocusAvailable, column != .path, availableFileColumns.contains(column), !busy, !confirmingQuit else { return }
        if visible { fileColumns.visible.insert(column) } else { fileColumns.visible.remove(column) }
        fileColumns.save(to: dialogDefaults)
        if column == .lfsOwner { if visible { reload() } else { lfsOwners = [:]; lfsLockedPaths = []; lfsOwnershipKnown = false } }
    }
    @discardableResult func resetFileColumns() -> Bool {
        guard messageFocusAvailable, !busy, !confirmingQuit else { return false }
        fileColumns = StatusListColumnSettings(); fileColumns.save(to: dialogDefaults); return true
    }
    func requestResetFileColumns(choose: @escaping () async -> Bool, onAccepted: @escaping () -> Void) {
        guard messageFocusAvailable, !busy, !confirmingQuit else { return }
        busy = true
        Task {
            defer { busy = false }
            guard await choose(), messageFocusAvailable, !confirmingQuit else { return }
            fileColumns = StatusListColumnSettings(); fileColumns.save(to: dialogDefaults)
            onAccepted()
        }
    }
    func setFileSortOrder(_ order: [CommitFileSort]) {
        guard messageFocusAvailable, !busy, !confirmingQuit else { return }
        // The source retains one column, with its path tie-break, rather than
        // accumulating old columns as additional sorting priorities.
        fileSortOrder = Array(order.prefix(1))
    }
    // Upstream keeps m_Action, list groups and line statistics until F5, while
    // m_stagingStatus changes independently. Do not replace the displayed rows
    // with porcelain records after each checkbox or partial patch operation.
    @Published private(set) var stagingStateNeedsRefresh = false
    @Published private var stagingStates: GitPathMap<NSControl.StateValue>?
    func stagingState(_ entry: StatusEntry) -> NSControl.StateValue {
        if let stagingStates { return stagingStates[entry.path] ?? .off }
        return entry.staged ? (entry.worktree == " " ? .on : .mixed) : .off
    }
    func isStaged(_ entry: StatusEntry) -> Bool { stagingState(entry) != .off }
    var stagedEntries: [StatusEntry] { visibleEntries.filter { isStaged($0) } }
    var unstagedEntries: [StatusEntry] { visibleEntries.filter { stagingState($0) != .on } }

    /// Reuse the owned reload lifetime without reloading groups, metadata, hooks,
    /// message completions, preferences or LFS locks. Publish one coherent index
    /// snapshot only after every cancellable read has completed.
    func refreshStagingState(refreshPatch: Bool = true) {
        guard stagingEnabled else { reload(); return }
        guard messageFocusAvailable, !busy, !pendingReloadCancel else { return }
        let position = fileListRefresh.begin(preferences:dialogDefaults,selectedIDs:selection)
        fileMenuGeneration = UUID(); busy = true; stagingStateNeedsRefresh = true
        Self.activeFileOperations += 1
        let token = OperationCancellation(); reloadCancellation = token
        let base = comparisonBase, retainedEntries = entries
        reloadTask = Task {
            defer {
                Self.activeFileOperations -= 1;fileListRefresh.finish(position)
                if reloadCancellation === token { reloadCancellation = nil; reloadTask = nil; busy = false }
                withExtendedLifetime(access) {}
            }
            do {
                try validateRestoreAccess()
                let current = try await readReload(token) { try await queryStagingStates(retainedEntries, base, token) }
                let staged = try await readReload(token) { try await repository.stagingFiles(staged: true, base: base, cancellation: token) }
                let unstaged = try await readReload(token) { try await repository.stagingFiles(staged: false, cancellation: token) }
                stagingStates = current.mapValues { state in
                    switch state { case .unstaged: return .off; case .partial: return .mixed; case .staged: return .on }
                }
                stagedStatistics = GitPathMap(staged.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                unstagedStatistics = GitPathMap(unstaged.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                stagingStateNeedsRefresh = false
                if refreshPatch { refreshPartial() }
                if !position.remember {selection = []}
                await fileListRefresh.restore(position,ids:visibleFileRowIDs);try token.check()
            } catch {
                if messageFocusAvailable, reloadCancellation === token, !token.isCancelled { self.error = "Could not refresh staging. Press F5 to reload before committing.\n\n" + error.localizedDescription }
            }
        }
    }
    private(set) static var activeReloads = 0
    let fileListRefresh = FileListRefreshCoordinator()
    private var filterPosition:FileListRefreshCoordinator.Ticket?
    private(set) static var activeFileOperations = 0
    private var fileMenuGeneration = UUID()
    private var activeFileMenu: StatusFileMenuSnapshot?
    private var fileOperationToken: OperationCancellation?
    @Published private(set) var fileOperationTitle = ""
    @Published private(set) var fileOperationCancelling = false
    func fileMenu(_ ids: some Sequence<String>, mark: String? = nil, orderedEntries: [StatusEntry]? = nil) -> StatusFileMenuSnapshot { let ids = GitPathSet(ids);
        let selected = (orderedEntries ?? visibleEntries).filter { ids.contains($0.id) }
        let focused = entries.first { GitReferenceName.equal($0.id,mark) } ?? selected.first
        func directory(_ entry: StatusEntry) -> Bool { submodules.contains(entry.path) || fileMetadata[entry.path]?.isDirectory == true }
        var commands: [StatusFileCommand] = []
        if selected.count == 2, selected.allSatisfy({ !directory($0) }) { commands.append(.compareTwo) }
        if let entry = selected.first, selected.count == 1, ![FileState.untracked, .ignored].contains(entry.state) {
            commands.append(.log)
            if directory(entry) { commands.append(.submoduleLog) }
            if entry.originalPath != nil { commands.append(.oldNameLog) }
            if !directory(entry), entry.index != "A", entry.worktree != "A", entry.index != "D" { commands.append(.blame) }
        }
        if !selected.isEmpty, let focused, focused.state != .deleted, focused.worktree != "D" { commands.append(.export) }
        if let entry = selected.first, selected.count == 1, entry.state != .deleted, entry.worktree != "D", !directory(entry) { commands += [.editor, .open, .openWith] }
        if let entry = selected.first, selected.count == 1, entry.index != "D" { commands.append(.reveal) }
        if focused?.canDeleteFromStatusList == true { commands.append(.delete) }
        return StatusFileMenuSnapshot(generation: fileMenuGeneration, entries: selected, mark: focused, commands: commands, markIsDirectory: focused.map(directory) ?? false)
    }
    private func acceptsFileMenu(_ snapshot: StatusFileMenuSnapshot, duringOperation: Bool = false) -> Bool {
        guard messageFocusAvailable,!savingPreferences,!stagingHintVisible,!confirmingQuit,!pendingReloadCancel,duringOperation || !busy,
              snapshot.generation == fileMenuGeneration, !snapshot.entries.isEmpty else { return false }
        let current = GitPathMap(entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        return snapshot.entries.allSatisfy { current[$0.path] == $0 } && (snapshot.mark.map { current[$0.path] == $0 } ?? true)
    }
    func withFileMenu(_ snapshot: StatusFileMenuSnapshot, perform: () -> Void) {
        guard acceptsFileMenu(snapshot) else { return }
        let previous = activeFileMenu; activeFileMenu = snapshot
        defer { activeFileMenu = previous }; perform()
    }
    private func isFileOperationLive(_ token: OperationCancellation) -> Bool {
        messageFocusAvailable && fileOperationToken === token && !token.isCancelled && !Task.isCancelled
    }
    @discardableResult func cancelFileOperation() -> Bool {
        guard let fileOperationToken else { return false }
        fileOperationCancelling = true; fileOperationToken.cancel(); return true
    }
    private func runFileOperation(_ title: String, operation: @escaping (OperationCancellation, StatusFileMenuSnapshot?) async throws -> Void, completed: @escaping () -> Void = {}, failed: @escaping () -> Void = {}) {
        guard messageFocusAvailable, !inputsBlocked else { return }
        let snapshot = activeFileMenu
        guard snapshot.map({ acceptsFileMenu($0) }) ?? true else { return }
        let token = OperationCancellation(); fileOperationToken = token
        busy = true; fileOperationCancelling = false; fileOperationTitle = title; Self.activeFileOperations += 1
        Task {
            defer {
                Self.activeFileOperations -= 1
                if fileOperationToken === token { fileOperationToken = nil; busy = false; fileOperationCancelling = false; fileOperationTitle = "" }
                withExtendedLifetime(access) {}
            }
            do {
                try validateRestoreAccess(); try await operation(token, snapshot)
                guard messageFocusAvailable, fileOperationToken === token else { return }
                finishFileOperation(token)
                if token.isCancelled { failed(); self.error = "Operation cancelled. Any completed changes are retained." }
                else { completed() }
            } catch {
                guard messageFocusAvailable, fileOperationToken === token else { return }
                let diagnostic = token.isCancelled ? "Operation cancelled. Any completed changes are retained." : error.localizedDescription
                finishFileOperation(token); failed(); self.error = diagnostic
            }
        }
    }
    private func finishFileOperation(_ token: OperationCancellation) {
        guard fileOperationToken === token else { return }
        fileOperationToken = nil; busy = false; fileOperationCancelling = false; fileOperationTitle = ""
    }
    private func acceptsPendingFileMenu(_ snapshot: StatusFileMenuSnapshot?, token: OperationCancellation) -> Bool {
        isFileOperationLive(token) && (snapshot.map { acceptsFileMenu($0, duringOperation: true) } ?? true)
    }
    func fileAction(_ command: StatusFileCommand, snapshot: StatusFileMenuSnapshot, permanently: Bool = false) {
        guard snapshot.commands.contains(command) else { return }
        withFileMenu(snapshot) {
            let paths = snapshot.entries.map(\.path)
            switch command {
            case .compareTwo: onCompareTwoFiles(paths)
            case .log: onFileLog(paths[0])
            case .oldNameLog: if let old = snapshot.entries.first?.originalPath { onFileLog(old) }
            case .submoduleLog: showSubmoduleLog(paths[0])
            case .blame: onFileBlame(paths[0])
            case .reveal:
                var location = repository.root.appendingPathComponent(paths[0])
                while !FileManager.default.fileExists(atPath: location.path), location.path != repository.root.path { location.deleteLastPathComponent() }
                NSWorkspace.shared.activateFileViewerSelecting([location])
            case .export:
                runFileOperation("Exporting working files…", operation: { [self] token, captured in
                    guard let folder = await chooseExportFolder(paths), acceptsPendingFileMenu(captured, token: token) else { return }
                    let scoped = folder.startAccessingSecurityScopedResource(); defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                    _ = try await repository.exportWorkingFiles(paths: paths, to: folder, cancellation: token)
                })
            case .delete: deleteFiles(snapshot.entries, selectionMark: snapshot.mark, permanently: permanently)
            case .editor, .open, .openWith:
                runFileOperation(command.rawValue, operation: { [self] token, captured in
                    let application = command == .openWith ? await chooseApplication(paths[0]) : nil
                    guard command != .openWith || application != nil, acceptsPendingFileMenu(captured, token: token) else { return }
                    let url = repository.root.appendingPathComponent(paths[0])
                    if command == .editor { try await openAlternativeEditor(url) } else { try await openWorkingFile(url, application) }
                })
            }
        }
    }
    func showSubmoduleLog(_ path: String) {
        guard submodules.contains(path) else { return }
        runFileOperation("Reading submodule checkout…", operation: { [self] token, captured in
            let child = try await submoduleLog.load(path, cancellation: token)
            guard acceptsPendingFileMenu(captured, token: token) else { return }; onSubmoduleLog(child)
        })
    }

    func openFile(_ path: String, application: URL? = nil) {
        runFileOperation("Open", operation: { [self] token, captured in
            guard acceptsPendingFileMenu(captured, token: token) else { return }
            try await openWorkingFile(repository.root.appendingPathComponent(path), application)
        })
    }

    func exportFiles(_ paths: [String], to folder: URL) {
        runFileOperation("Exporting working files…", operation: { [self] token, captured in
            guard acceptsPendingFileMenu(captured, token: token) else { return }
            let scoped = folder.startAccessingSecurityScopedResource(); defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            _ = try await repository.exportWorkingFiles(paths: paths, to: folder, cancellation: token)
        })
    }

    func openInEditor(_ path: String) {
        runFileOperation("View revision in alternative editor", operation: { [self] token, captured in
            guard acceptsPendingFileMenu(captured, token: token) else { return }
            try await openAlternativeEditor(repository.root.appendingPathComponent(path))
        })
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
    func copyFileText(_ selected: [StatusEntry], statistics: GitPathMap<CommitFile>, copy: StatusListCopy) {
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
        guard messageFocusAvailable, activeFileMenu.map({ acceptsFileMenu($0) }) ?? true else { return }
        busy = true
        onRevert(selected, amend, amendDiffToLastCommit) { [weak self] succeeded in
            guard let self, self.messageFocusAvailable else { return }
            if succeeded { self.checked.subtract(selected.map(\.path)); self.selection.subtract(selected.map(\.path)) }
            self.busy = false; self.reload(); self.refreshPartial()
        }
    }
    func markForRestore(_ paths: some Sequence<String>) { let paths = GitPathSet(paths);
        guard !paths.isEmpty else { return }
        runFileOperation("Saving working file copies…", operation: { [self] token, _ in
            for path in paths.sorted() where restoreCopies[path] == nil {
                let copy = try await repository.captureWorkingFileRestoreCopy(path: path, cancellation: token)
                guard isFileOperationLive(token) else { return }; restoreCopies[path] = copy
            }
        })
    }

    private func restoreSavedCopies(_ paths: some Sequence<String>, cancellation: OperationCancellation? = nil) async throws { let paths = GitPathSet(paths);
        guard paths.contains(where: { restoreCopies[$0] != nil }) else { return }
        try validateRestoreAccess()
        for path in paths.sorted() {
            guard let copy = restoreCopies[path] else { continue }
            try await repository.restoreWorkingFile(copy, cancellation: cancellation)
            restoreCopies.removeValue(forKey: path)
        }
    }
    func restoreNow(_ paths: some Sequence<String>) { let paths = GitPathSet(paths);
        guard paths.contains(where: { restoreCopies[$0] != nil }) else { return }
        var restored = false
        runFileOperation("Restoring working copies…", operation: { [self] token, captured in
            guard await confirmFileRestore(), acceptsPendingFileMenu(captured, token: token) else { return }
            try await restoreSavedCopies(paths, cancellation: token); restored = true
        }, completed: { [self] in if restored { reload() } }, failed: { [self] in reload() })
    }

    private func chooseSavedCopies(allowCancel: Bool) async -> RestoreChoice {
        await withCheckedContinuation { continuation in
            chooseRestoreCopies(allowCancel) { continuation.resume(returning: $0) }
        }
    }
    func setFlags(_ action: IndexFlagAction, files: [WorkingTreeFile], selectionMark: WorkingTreeFile) {
        guard messageFocusAvailable, !inputsBlocked, !files.isEmpty, action.isAvailable(for: [selectionMark]), confirmIndexFlags(action) else { return }
        runFileOperation(action.rawValue, operation: { [self] token, _ in
            try await repository.setIndexFlags(action, paths: files.map(\.id), markedPath: selectionMark.id, cancellation: token)
        }, completed: { [self] in reload() }, failed: { [self] in reload() })
    }

    func moveToStage(_ paths: some Sequence<String>, staged: Bool) { let paths = GitPathSet(paths);
        let valid = entries.filter { paths.contains($0.id) && $0.state != .conflicted }
        guard !valid.isEmpty else { return }
        let amendToParent = self.amendToParent
        runFileOperation(staged ? "Staging selected files…" : "Unstaging selected files…", operation: { [self] token, _ in
            try await repository.setCommitFilesStaged(valid, staged: staged, amendToParent: amendToParent, cancellation: token)
        }, completed: { [self] in refreshStagingState() }, failed: { [self] in refreshStagingState() })
    }

    func canLockLFS(_ selected: [StatusEntry]) -> Bool {
        LFSLockingSelection.isAvailable(selected, hasLFS: hasLFS, root: repository.root, directories: submodules)
    }
    func lfsActions(_ selected: [StatusEntry]) -> [LFSLockMenuAction] {
        guard canLockLFS(selected) else { return [] }
        return LFSLockMenu.actions(paths: selected.map(\.path), ownersVisible: visibleFileColumns.contains(.lfsOwner), lockedPaths: lfsLockedPaths, ownershipKnown: lfsOwnershipKnown)
    }
    func setLFSLocked(_ ids: some Sequence<String>, locked: Bool) { let ids = GitPathSet(ids);
        guard !busy, !confirmingQuit else { return }
        let selected = entries.filter { ids.contains($0.id) }
        guard selected.count == ids.count, lfsActions(selected).contains(locked ? .lock : .unlock) else { return }
        busy = true
        if !onLFSOperation(selected.map(\.path), locked) { busy = false }
    }
    func addFiles(_ selected: [StatusEntry], mode: WorkingFileAddMode) {
        let paths = selected.map(\.path); guard !paths.isEmpty else { return }
        runFileOperation(mode.rawValue, operation: { [self] token, _ in
            try await repository.addWorkingFiles(paths: paths, mode: mode, cancellation: token)
            guard isFileOperationLive(token) else { return }; checked.formUnion(paths)
        }, completed: { [self] in reload() }, failed: { [self] in reload() })
    }

    func deleteFiles(_ selected: [StatusEntry], selectionMark: StatusEntry? = nil, permanently: Bool) {
        guard !selected.isEmpty else { return }
        var changed = false
        runFileOperation(permanently ? "Deleting working files…" : "Moving working files to Trash…", operation: { [self] token, captured in
            guard await confirmFileDeletion(selected.map(\.path), permanently), acceptsPendingFileMenu(captured, token: token) else { return }
            _ = try await repository.deleteWorkingFiles(selected, selectionMark: selectionMark, permanently: permanently, cancellation: token)
            changed = true
            guard isFileOperationLive(token) else { return }
            checked.subtract(selected.map(\.path)); selection.subtract(selected.map(\.path))
        }, completed: { [self] in if changed { reload() } }, failed: { [self] in reload() })
    }

    func newChangelist(_ selected: [StatusEntry]) {
        guard !busy, !confirmingQuit, !selected.isEmpty else { return }
        changelistMenu = activeFileMenu ?? fileMenu(GitPathSet(selected.map(\.id)))
        changelistPaths = selected.map(\.path); changelistName = ""; creatingChangelist = true
    }
    func createChangelist() {
        guard messageFocusAvailable, !changelistName.isEmpty, let captured = changelistMenu, acceptsFileMenu(captured) else { cancelChangelist(); return }
        let paths = changelistPaths, name = changelistName
        creatingChangelist = false; changelistPaths = []; changelistName = ""
        changelistMenu = nil
        withFileMenu(captured) { moveToChangelist(paths, name: name) }
    }
    func cancelChangelist() { changelistMenu = nil; creatingChangelist = false; changelistPaths = []; changelistName = "" }
    func saveKeepChangelists(_ value: Bool) {
        guard messageFocusAvailable, !inputsBlocked else { return }
        keepChangelists = value; dialogDefaults.set(value, forKey: "Commit.KeepChangelists")
    }
    var colorPreferences: UserDefaults { dialogDefaults }
    func setDoNotAutoselectSubmodules(_ disabled: Bool) {
        guard messageFocusAvailable, !inputsBlocked, !stagingEnabled else { return }
        doNotAutoselectSubmodules = disabled
        dialogDefaults.set(disabled, forKey: "Commit.DoNotAutoselectSubmodules")
        if disabled { checked.subtract(submodules) }
        else { check { submodules.contains($0.path) } }
    }
    func rememberTemplateProceed() {
        guard messageFocusAvailable else { return }
        dialogDefaults.set(true, forKey: "Commit.TemplateNotEdited.Proceed")
    }
    func moveToChangelist(_ paths: [String], name: String?) {
        guard !paths.isEmpty else { return }
        let staging = stagingEnabled
        runFileOperation("Moving to changelist…", operation: { [self] token, _ in
            let saved = try await repository.assignChangelist(paths: paths, name: name, cancellation: token)
            guard isFileOperationLive(token) else { return }; changelists = saved
            if name == GitChangelists.ignored {
                checked.subtract(paths)
                if staging {
                    do { try await repository.unstage(paths, cancellation: token) }
                    catch { throw StatusFileActionFailure(message: "The changelist was saved, but unstaging its paths failed.\n\n" + error.localizedDescription) }
                }
            }
        }, completed: { [self] in reload() }, failed: { [self] in reload() })
    }

    private func updateScopeTitle() {
        let location = RepositoryPresentationSettings.scopedLocation(repository: repository.root, paths: scopePaths, wholeProject: showWholeProject)
        RepositoryWindowTitles.set(comparisonWindow, repository: repository.root, location: location, dialog: "Commit", preferences: dialogDefaults)
    }
    func fileHelp(_ entry: StatusEntry) -> String {
        let origin = entry.originalPath.map { "Renamed from " + $0 } ?? ""
        return changelists.name(for: entry.path).map { origin + (origin.isEmpty ? "" : "\n") + "Changelist: " + $0 } ?? origin
    }
    var checkedPathsForCommit: GitPathSet { GitPathSet(visibleEntries.filter { checked.contains($0.id) }.map(\.path)) }
    var canCommit: Bool { messageFocusAvailable && !stagingStateNeedsRefresh && !savingPreferences && !stagingHintVisible && !issueProviderBusy && !pendingReloadCancel && !busy && !confirmingQuit && !loadingAuthorIdentity && !loadingAuthorDate && !loadingAmendMessage && loadedMessage && changelistsLoaded && (messageOnly || (stagingEnabled ? entries.contains(where: { isStaged($0) }) || operation == .merge || amend : !checkedPathsForCommit.isEmpty || operation == .merge || (amend && amendDiffToLastCommit))) && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count >= projectSettings.minimumLength && (!createBranch || !newBranch.isEmpty) && (!setAuthor || !author.isEmpty) }
    func didRename(_ source: String, to destination: String) {
        func moved(_ path: String) -> String { GitReferenceName.equal(path,source) ? destination : path.utf8.starts(with:(source + "/").utf8) ? destination + path.dropFirst(source.count) : path }
        checked = GitPathSet(checked.map(moved)); selection = GitPathSet(selection.map(moved)); scopePaths = scopePaths.map(moved); reload()
    }
    func loadHistoryCombine(_ plan: HistoryCombinePlan, date: RebaseSquashDate) {
        invalidateMetadataLoads(); historyCombine = plan
        createBranch = false; newBranch = ""
        amend = true; amendDiffToLastCommit = plan.lastParentCount != 1
        message = plan.message; amendMessage = plan.message; originalAmendMessage = plan.message
        showWholeProject = true; selectFilesAutomatically = true
        setAuthorDate = true; authorDate = date == .first ? plan.lastAuthorDate : date == .latest ? plan.firstAuthorDate : Date()
        resetAuthorDate = date == .current
        replayDatePreset = (setAuthorDate, authorDate, resetAuthorDate)
        reload(paths: ["."])
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
    var canReceiveFileDrop: Bool { messageFocusAvailable && !inputsBlocked && !messageOnly && hasLoaded }
    @discardableResult func receiveFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canReceiveFileDrop, !providers.isEmpty, providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        busy = true; let token = OperationCancellation(); reloadCancellation = token
        Self.activeFileDrops += 1
        reloadTask = Task {
            var refresh = false
            defer {
                Self.activeFileDrops -= 1
                if reloadCancellation === token {
                    reloadCancellation = nil; reloadTask = nil; busy = false
                    if refresh && messageFocusAvailable && !pendingReloadCancel { reload() }
                }
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                var urls: [URL] = []
                for provider in providers { urls.append(try await readReload(token) { try await readDroppedURL(provider) }) }
                let items = try await readReload(token) {
                    if let applyDroppedURLs { return try await applyDroppedURLs(urls, token) }
                    return try await repository.addDroppedCommitFiles(urls, cancellation: token)
                }
                guard !items.isEmpty else { return }
                refresh = true; droppedChecks.append(contentsOf: items)
                if items.contains(where: { $0.path == "." }) { scopePaths = []; showWholeProject = true }
                else if !scopePaths.isEmpty {
                    for item in items where !visibleEntries.contains(where: { $0.path.utf8.elementsEqual(item.path.utf8) }) && !scopePaths.contains(where: { $0.utf8.elementsEqual(item.path.utf8) || item.path.hasPrefix($0 + "/") }) { scopePaths.append(item.path) }
                }
                let errors = items.compactMap(\.error)
                if !errors.isEmpty { error = errors.joined(separator: "\n") }
            } catch { if messageFocusAvailable, !token.isCancelled, !Task.isCancelled { self.error = error.localizedDescription } }
        }
        return true
    }
    func reload(paths: [String]? = nil) {
        guard messageFocusAvailable, !issueProviderBusy, !busy, !pendingReloadCancel else { return }
        fileMenuGeneration = UUID(); busy = true
        let requestedScope = paths.map { $0.contains(".") ? [] : $0 } ?? scopePaths
        let requestedWholeProject = paths == nil ? showWholeProject : requestedScope.isEmpty
        let resetChecks = paths != nil && (!hasLoaded || requestedScope != scopePaths)
        let position = fileListRefresh.begin(preferences:dialogDefaults,reset:!hasLoaded || requestedScope != scopePaths,selectedIDs:selection)
        let token = OperationCancellation(); reloadCancellation = token; Self.activeReloads += 1
        reloadTask = Task {
            defer {
                Self.activeReloads -= 1; fileListRefresh.finish(position); withExtendedLifetime(access) {}
                if reloadCancellation === token {reloadCancellation=nil;reloadTask=nil;busy=false;offerStagingHint()}
            }
            do {
                try validateRestoreAccess()
                // Collect the entire next display before changing the accepted
                // one. Every suspension checks both token and owning window.
                let preferences:CommitPreferences?
                if loadedPreferences { preferences=nil }
                else { preferences=try await readReload(token) { try await repository.commitPreferences(cancellation:token) } }
                let nextOperation = try await readReload(token) { try await repository.commitOperation(cancellation:token) }
                let nextHasHead = try await readReload(token) { (try? await repository.run(["rev-parse","--verify","HEAD"],cancellation:token)) != nil }
                let nextHasParent = try await readReload(token) { (try? await repository.run(["rev-parse","--verify","HEAD^1"],cancellation:token)) != nil }
                let nextAmend = nextOperation == nil && amend
                let nextAmendDiff = nextAmend && !nextHasParent ? true : amendDiffToLastCommit
                let compareParent = nextAmend && !nextAmendDiff
                let nextBase = compareParent ? try await readReload(token) { try await repository.commitComparisonBase(amendToParent:true,cancellation:token) } : nil
                let nextEntries = try await readReload(token) { try await queryCommitStatus(compareParent,token) }
                let nextSubmodules = try await readReload(token) { try await repository.submodulePathNames(cancellation:token).map(\.rawValue) }
                let nextBranch = try await readReload(token) { try await repository.branch(cancellation:token) }
                let nextMetadata = try await readReload(token) { await repository.statusListMetadata(paths:nextEntries.map(\.path)) }
                let nextHasLFS = try await readReload(token) { try await repository.hasLFS(cancellation:token) }
                let snippetURL = RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("snippet.txt")
                let nextSnippets = try await readReload(token) { await snippetLoader.load(userURL:snippetURL) }
                let nextChangelists = try await readReload(token) { try await repository.changelists(cancellation:token) }
                let nextIndexFlags = try await readReload(token) { try await repository.workingTreeStatus(cancellation:token) }
                let nextConflictRebase = try await readReload(token) { try await repository.conflictIsRebase(cancellation:token) }
                let nextStatistics = GitPathMap(try await readReload(token) { try await repository.workingTreeFiles(amendToParent:compareParent,cancellation:token) }.map {($0.path,$0)},uniquingKeysWith:{_,new in new})
                let nextStaged = GitPathMap(try await readReload(token) { try await repository.stagingFiles(staged:true,base:nextBase,cancellation:token) }.map {($0.path,$0)},uniquingKeysWith:{_,new in new})
                let nextUnstaged = GitPathMap(try await readReload(token) { try await repository.stagingFiles(staged:false,cancellation:token) }.map {($0.path,$0)},uniquingKeysWith:{_,new in new})
                let nextAuthor:String?
                if !hasLoaded && author.isEmpty {
                    nextAuthor = try await readReload(token) {
                        let name=(try? await repository.run(["config","user.name"],cancellation:token).text.trimmingCharacters(in:.newlines)) ?? ""
                        let email=(try? await repository.run(["config","user.email"],cancellation:token).text.trimmingCharacters(in:.newlines)) ?? ""
                        return name.isEmpty ? "" : "\(name) <\(email)>"
                    }
                } else { nextAuthor=nil }
                let provider = try await readNativeIssueProvider(token)
                let nextIssueProperties:IssueTrackerProperties?,nextProjectSettings:ProjectDialogSettings?,nextHistory:CommitMessageHistory?,seed:CommitMessageSeed?
                let draftMessage=message,draftIssueID=issueID
                if !loadedMessage {
                    nextIssueProperties = try await readReload(token) { try await repository.issueTrackerProperties(cancellation:token) }
                    nextProjectSettings = try await readReload(token) { try await repository.projectDialogSettings(source:.effective,cancellation:token) }
                    let identity = try await readReload(token) { try await repository.commitMessageHistoryIdentity(cancellation:token) }
                    let limit = dialogDefaults.object(forKey:"MaxHistoryItems") as? Int ?? dialogDefaults.object(forKey:"Commit.MaxHistoryItems") as? Int ?? 25
                    nextHistory = CommitMessageHistory(repositoryIdentity:identity,defaults:dialogDefaults,limit:limit)
                    seed = try await readReload(token) { try await loadMessageSeed(cancellation:token) }
                } else { nextIssueProperties=nil;nextProjectSettings=nil;nextHistory=nil;seed=nil }
                var nextOwners:[String:String]=[:],nextLocked=GitPathSet(),nextOwnershipKnown=false
                var warnings=seed?.warnings ?? []
                if nextHasLFS && fileColumns.visible.contains(.lfsOwner) {
                    lfsOwnerCancellation=token
                    defer {if lfsOwnerCancellation === token {lfsOwnerCancellation=nil}}
                    do {
                        let locks = try await readReload(token) { try await queryLFSOwners(token) }
                        nextOwners=Dictionary(locks.map {($0.path,$0.owner)},uniquingKeysWith:{first,_ in first})
                        nextLocked=GitPathSet(locks.map(\.path));nextOwnershipKnown=true
                    } catch {
                        try token.check()
                        warnings.append("Could not get LFS locks: " + error.localizedDescription)
                    }
                }
                var nextMessage=draftMessage,nextIssueID=draftIssueID
                if let seed {
                    if draftMessage.isEmpty && !nextAmend {
                        let separated=(nextIssueProperties ?? issueProperties).separateIssueLine(from:seed.message)
                        nextMessage=separated.message;nextIssueID=separated.issueID
                    }
                    do {
                        if let hook = try await clientHooks.run(.startCommit,repository:repository,access:access,paths:requestedScope.isEmpty ? [repository.root.path] : requestedScope.map {repository.root.appendingPathComponent($0).path},message:nextMessage,cancellation:token,allowContinue:true) { nextMessage=hook.message }
                    } catch {
                        guard messageFocusAvailable,reloadCancellation === token,!token.isCancelled else {return}
                        self.error=error.localizedDescription;busy=false;close();return
                    }
                }
                _ = try await readReload(token) { () }
                // No suspension until every field and dependent command target
                // belongs to the same accepted read. Native row settlement follows.
                if let preferences {
                    persistedStaging=preferences.staging;stagingEnabled=preferences.staging;appliedStagingMode=preferences.staging;stagingHintPending=preferences.staging;loadedPreferences=true
                }
                operation=nextOperation;if nextOperation != nil {createBranch=false}
                amend=nextAmend;amendDiffToLastCommit=nextAmendDiff
                hasHead=nextHasHead;hasParent=nextHasParent;comparisonBase=nextBase
                scopePaths=requestedScope;showWholeProject=requestedWholeProject
                entries=nextEntries;submodules=GitPathSet(nextSubmodules);branch=nextBranch;fileMetadata=nextMetadata
                hasLFS=nextHasLFS;messageSnippets=nextSnippets;changelists=nextChangelists;changelistsLoaded=true
                indexFlagFiles=nextIndexFlags;conflictRebase=nextConflictRebase
                statistics=nextStatistics;stagedStatistics=nextStaged;unstagedStatistics=nextUnstaged
                stagingStates=nil;stagingStateNeedsRefresh=false
                lfsOwners=nextOwners;lfsLockedPaths=nextLocked;lfsOwnershipKnown=nextOwnershipKnown
                nativeIssueProvider=provider.provider;issueProviderError=provider.error
                if resetChecks {
                    checked=GitPathSet(visibleEntries.filter {entry in
                        let inScope=requestedScope.isEmpty || requestedScope.contains {$0 == entry.path || entry.path.hasPrefix($0 + "/")}
                        let directFile=requestedScope.contains(entry.path)
                        let missing=entry.worktree == "D"
                        let automatic=(selectFilesAutomatically || replaySplit != nil) && entry.state != .untracked && (!doNotAutoselectMissing || !missing)
                        return inScope && (directFile || automatic) && !changelists.ignores(entry.path) && (!doNotAutoselectSubmodules || !submodules.contains(entry.path)) && entry.state != .conflicted
                    }.map(\.id))
                } else {checked.formIntersection(GitPathSet(entries.map(\.id)))}
                for item in droppedChecks {
                    for entry in visibleEntries where item.path == "." || entry.path.utf8.elementsEqual(item.path.utf8) || item.directory && entry.path.hasPrefix(item.path + "/") {
                        let missing=entry.worktree == "D"
                        let automatic=(selectFilesAutomatically || replaySplit != nil) && entry.state != .untracked && (!doNotAutoselectMissing || !missing)
                        let direct=requestedScope.contains(entry.path)
                        if (direct || automatic) && !changelists.ignores(entry.path) && (!doNotAutoselectSubmodules || !submodules.contains(entry.path)) && entry.state != .conflicted {checked.insert(entry.id)}
                        else {checked.remove(entry.id)}
                    }
                }
                droppedChecks=[];selection.formIntersection(GitPathSet(entries.map(\.id)))
                if author.isEmpty,let nextAuthor {author=nextAuthor}
                hasLoaded=true
                if let seed {
                    issueProperties=nextIssueProperties!;projectSettings=nextProjectSettings!;messageHistory=nextHistory;messageTemplate=seed.template
                    if message.utf8.elementsEqual(draftMessage.utf8),issueID.utf8.elementsEqual(draftIssueID.utf8) {message=nextMessage;issueID=nextIssueID}
                    loadedMessage=true
                }
                if !warnings.isEmpty {reloadError=warnings.joined(separator:"\n\n");self.error=reloadError}
                else if self.error == reloadError {self.error=nil;reloadError=nil}
                refreshPartial();prepareMessageCompletions(force:true)
                if preferences?.showPatch == true {if stagingEnabled {showPartial(false)} else {showViewPatch()}}
                if !position.remember {selection=[]}
                await fileListRefresh.restore(position,ids:visibleFileRowIDs);try token.check()
            } catch {if messageFocusAvailable,!token.isCancelled {reloadError=error.localizedDescription;self.error=reloadError}}
        }
    }
    /// Capture config before presenting a permission sheet. A config edit while
    /// that sheet is open must not redirect the subsequent read to another file.
    func loadMessageSeed(includeOperationMessages: Bool = true, cancellation: OperationCancellation) async throws -> CommitMessageSeed {
        func check() throws {
            try cancellation.check()
            guard messageFocusAvailable, !Task.isCancelled else { throw OperationCancellationFailure.cancelled }
        }
        try check()
        var selection = try await repository.commitMessageTemplate(cancellation: cancellation)
        try check()
        var permission: RepositoryAccessLease?, warning: String?
        if let file = selection.url, templateFileAccess.needsPermission(file, repositoryAccess: access) {
            do { permission = try templateFileAccess.acquire(file) } catch { /* Re-authorize missing, stale or invalid saved access. */ }
            if permission == nil {
                let selected = try await authorizeTemplateFile(file)
                try check()
                if let selected {
                    do { permission = try templateFileAccess.remember(selected, for: file) }
                    catch { warning = "Could not authorize commit.template file: " + file.path + "\n" + error.localizedDescription }
                } else { warning = "The commit template was not loaded because file access was cancelled: " + file.path }
                if permission == nil { selection = CommitMessageTemplate(url: nil) }
            }
        }
        defer { withExtendedLifetime(permission) {} }
        try check()
        let seed = try await repository.commitMessageSeed(includeOperationMessages: includeOperationMessages, template: selection, cancellation: cancellation)
        try check()
        return CommitMessageSeed(template: seed.template, message: seed.message, warnings: seed.warnings + (warning.map { [$0] } ?? []))
    }
    /// Check on both sides of every suspension: even an injected read that
    /// ignores cancellation cannot publish into a closed Commit window.
    private func readReload<Value>(_ token: OperationCancellation, _ read: () async throws -> Value) async throws -> Value {
        guard messageFocusAvailable, reloadCancellation === token, !token.isCancelled, !Task.isCancelled else { throw OperationCancellationFailure.cancelled }
        let value = try await read()
        guard messageFocusAvailable, reloadCancellation === token, !token.isCancelled, !Task.isCancelled else { throw OperationCancellationFailure.cancelled }
        return value
    }
    private(set) static var activePreferenceOperations=0
    @Published private(set) var savingPreferences=false
    @Published private(set) var stagingHintVisible=false
    private var preferenceTask:Task<Void,Never>?
    private var preferenceCancellation:OperationCancellation?
    private var pendingStagingPreference:Bool?,pendingPatchPreference:Bool?
    private var appliedStagingMode=false
    private var stagingHintPending=false
    private var stagingHintRequest=UUID()
    var presentStagingHint:(() async -> Bool?)?
    static let stagingHint="""
    The file checkboxes now show what is staged for commit:
    • Checked: all changes in the file are staged.
    • Unchecked: the changes are unstaged.
    • Mixed (a square): only some changes are staged.

    Clicking a checkbox immediately stages or unstages the whole file. Clicking a mixed checkbox stages its remaining working changes.

    For performance, status labels, line counts and groups stay as they were when the list was loaded. Press F5 to refresh them. The checkboxes always reflect the latest staging action.

    Use Partial Staging or Partial Unstaging to open the selected file's patch and choose individual hunks or lines. Commit includes the whole index, including staged files outside the displayed scope.
    """
    func offerStagingHint() {
        guard stagingHintPending else {return}
        guard stagingEnabled,!dialogDefaults.bool(forKey:"HintStagingMode") else {stagingHintPending=false;return}
        guard messageFocusAvailable,!inputsBlocked,let presentStagingHint else {return}
        let request=UUID();stagingHintRequest=request;stagingHintVisible=true;Self.activePreferenceOperations += 1
        Task { [self,access] in
            defer {Self.activePreferenceOperations -= 1;withExtendedLifetime(access){};if stagingHintRequest==request {stagingHintVisible=false}}
            let suppress=await presentStagingHint()
            guard messageFocusAvailable,stagingHintRequest==request,stagingEnabled else {return}
            if let suppress {stagingHintPending=false;if suppress {dialogDefaults.set(true,forKey:"HintStagingMode")}}
        }
    }
    func setStagingEnabled(_ enabled:Bool) {
        guard messageFocusAvailable,!inputsBlocked,loadedPreferences,stagingEnabled != enabled else {return}
        stagingEnabled=enabled;stagingChanged()
    }
    func savePatchPreference(_ visible:Bool) {
        guard messageFocusAvailable else {return};queuePreferences(showPatch:visible)
    }
    func stagingChanged() {
        guard messageFocusAvailable,loadedPreferences,!busy,!confirmingQuit,!stagingHintVisible,appliedStagingMode != stagingEnabled else {return}
        appliedStagingMode=stagingEnabled;closePartial();stagingHintPending=stagingEnabled
        queuePreferences(staging:stagingEnabled)
    }
    private func queuePreferences(staging:Bool? = nil,showPatch:Bool? = nil) {
        if let staging {pendingStagingPreference=staging}
        if let showPatch {pendingPatchPreference=showPatch}
        guard preferenceTask==nil else {return}
        let token=OperationCancellation();preferenceCancellation=token;savingPreferences=true;Self.activePreferenceOperations += 1
        preferenceTask=Task { [self,repository,access] in
            var refresh=false
            defer {
                Self.activePreferenceOperations -= 1;withExtendedLifetime(access){}
                preferenceTask=nil;preferenceCancellation=nil;savingPreferences=false
                if messageFocusAvailable,!token.isCancelled {if refresh {reload()} else {offerStagingHint()}}
            }
            while messageFocusAvailable,!token.isCancelled,pendingStagingPreference != nil || pendingPatchPreference != nil {
                let mode=pendingStagingPreference,patch=pendingPatchPreference;pendingStagingPreference=nil;pendingPatchPreference=nil
                if mode != nil {refresh=true}
                do {
                    try validateRestoreAccess()
                    try await repository.saveCommitPreferences(staging:mode,showPatch:patch,cancellation:token)
                    guard messageFocusAvailable,!token.isCancelled else {return}
                    if let mode {persistedStaging=mode}
                } catch {if messageFocusAvailable,!token.isCancelled {self.error=error.localizedDescription}}
            }
        }
    }
    func check(_ predicate: (StatusEntry) -> Bool,checking:Bool = true) {
        guard messageFocusAvailable,!inputsBlocked else {return}
        let paths = GitPathSet(visibleEntries.filter {(!checking || $0.state != .conflicted) && predicate($0)}.map(\.id))
        if stagingEnabled {moveToStage(paths,staged:checking)} else if checking {checked.formUnion(paths)} else {checked.subtract(paths)}
    }
    func setGroupChecked(_ files: [StatusEntry], checked value: Bool) {
        guard messageFocusAvailable,!inputsBlocked else {return}
        let paths = GitPathSet(files.map(\.id))
        if stagingEnabled { moveToStage(paths, staged: value) }
        else if value { checked.formUnion(paths) }
        else { checked.subtract(paths) }
    }
    func setFileChecked(_ entry: StatusEntry, files: [StatusEntry], highlighted: some Sequence<String>, checked value: Bool) { let highlighted = GitPathSet(highlighted);
        guard messageFocusAvailable,!inputsBlocked,entry.state != .conflicted else {return}
        let targets = StatusListSelection.checkboxEntries(entry: entry, entries: files, highlighted: highlighted)
        let paths = GitPathSet(targets.map(\.id))
        if stagingEnabled { moveToStage(paths, staged: value) }
        else if value { checked.formUnion(paths) }
        else { checked.subtract(paths) }
    }
    func checkAll(_ checking:Bool) {check({_ in true},checking:checking)}
    func uncheckAll() {
        guard messageFocusAvailable,!inputsBlocked else {return}
        if stagingEnabled { moveToStage(GitPathSet(visibleEntries.filter { isStaged($0) }.map(\.id)), staged: false) }
        else { checked.subtract(visibleEntries.map(\.id)) }
    }
    func amendChanged() {
        guard messageFocusAvailable else { return }
        if replaySplit != nil || historyCombine != nil { comparisonChanged(); return }
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
    func focusMessage() {guard !inputsBlocked else {return};requestMessageFocus()}
    private func requestMessageFocus() {
        guard messageFocusAvailable else { return }
        messageFocusRequest += 1
    }
    func invalidateMessageFocus() {
        cancelHistoryIssueUpdate()
        messageFocusAvailable = false; messageFocusRequest = 0; appliedMessageFocusRequest = 0
    }
    func invalidateForClose() {
        preferenceCancellation?.cancel();pendingStagingPreference=nil;pendingPatchPreference=nil
        stagingHintRequest=UUID();stagingHintVisible=false;stagingHintPending=false
        preflightRequest=UUID();preflightCancellation?.cancel();preflightCancellation=nil
        if let progress=commitProgress { progress.invalidate();if !progress.busy { progress.choose(nil) } }
        issueProviderGeneration = UUID(); issueProviderBusy = false
        fileMenuGeneration = UUID(); fileOperationToken?.cancel(); cancelChangelist()
        diffSession?.cancel(); diffSession = nil
        clientHooks.retire(); submoduleLog.retire();fileListRefresh.retire()
        reloadCancellation?.cancel(); reloadTask?.cancel(); lfsOwnerCancellation?.cancel()
        reloadCancellation = nil; reloadTask = nil; lfsOwnerCancellation = nil
        pendingReloadCancel = false; busy = false
        invalidateMessageFocus()
        invalidateMetadataLoads()
        completionTask?.cancel(); issueStyleTask?.cancel(); issueStyleCancellation?.cancel()
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
    var querySignOff:((OperationCancellation) async throws -> String)?
    func addSignOff() {
        runFileOperation("Reading signing identity…",operation:{ [self] token,_ in
            let trailer:String
            do {
                if let querySignOff {trailer=try await querySignOff(token)}
                else {trailer=try await repository.commitSignOffLine(cancellation:token)}
            } catch {
                guard !token.isCancelled else {throw error}
                throw NSError(domain:"TurtleGit.CommitSignOff",code:1,userInfo:[NSLocalizedDescriptionKey:"Configure your Git user name and email before adding a sign-off.\n" + error.localizedDescription])
            }
            guard isFileOperationLive(token) else {return}
            message=IssueTrackerProperties.addingSignOff(trailer,to:message)
        },completed:{ [weak self] in self?.requestMessageFocus() })
    }
    func compare(paths selected: some Sequence<String>) { let selected = GitPathSet(selected);
        guard !busy, !confirmingQuit else { return }
        let paths = entries.filter { selected.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }; onCompare(paths, amendToParent)
    }
    func diff(paths selected: some Sequence<String>, staged: Bool? = nil, alternate: Bool = false) { let selected = GitPathSet(selected);
        guard messageFocusAvailable, !busy, !confirmingQuit, !unifiedViewerBusy else { return }
        let paths = entries.filter { selected.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }
        let amendToParent = self.amendToParent
        let session = FileListComparisonSession(window: comparisonWindow, preferences: dialogDefaults)
        diffSession = session; busy = true
        Task {
            defer { if diffSession === session { diffSession = nil; busy = false }; withExtendedLifetime(access) {} }
            do {
                try await session.run(selectedCount: 0) { [self] token in
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let bytes: Data
                    if let staged { bytes = try await repository.patchData(paths: paths, staged: staged, base: amendToParent && staged ? try await repository.commitComparisonBase(amendToParent: true, cancellation: token) : nil, cancellation: token) }
                    else {
                        let head = try? await repository.run(["rev-parse", "--verify", "HEAD"], cancellation: token)
                        let base = amendToParent ? try await repository.commitComparisonBase(amendToParent: true, cancellation: token) : "HEAD"
                        let args = ["diff", "--no-ext-diff", "--no-color"] + (head == nil ? ["--cached"] : [base]) + ["--"] + paths
                        bytes = try await repository.run(args, cancellation: token).stdout
                }
                guard messageFocusAvailable, !confirmingQuit, !token.isCancelled else { return }
                if let onUnifiedDiff { try await onUnifiedDiff(bytes, alternate) }
                else if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: dialogDefaults, title: staged == true ? "Index changes" : staged == false ? "Working tree changes" : "Commit changes", permissions: access.map { [$0] } ?? [], cancellation: token) {
                    guard messageFocusAvailable, !confirmingQuit, !token.isCancelled else { return }
                    unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: staged == true ? "Index changes" : staged == false ? "Working tree changes" : "Commit changes", onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
                }
            } catch { if messageFocusAvailable, !session.cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func commit(_ action: CompletionAction = .commit) {
        guard canCommit, replaySplit == nil && historyCombine == nil || action == .commit,
              historyCombine == nil || (amend && !createBranch) else { return }
        if replaySplit == nil && historyCombine == nil { completionAction = action }
        let rawMessage = message, rawIssueID = issueID, properties = issueProperties, provider = nativeIssueProvider, paths = checkedPathsForCommit, staging = stagingEnabled
        let committedPaths = staging ? GitPathSet(entries.filter { isStaged($0) }.map(\.path)) : messageOnly ? GitPathSet() : paths
        let committedPathNames = Set(committedPaths.map { GitReferenceName($0) })
        let retainedChangelists = Set(visibleEntries.filter { !committedPathNames.contains(GitReferenceName($0.path)) }.map { GitReferenceName($0.path) }).union(restoreCopies.keys.map { GitReferenceName($0) })
        let pruningScope = showWholeProject ? [] : scopePaths
        let preserveChangelists = keepChangelists
        var options = CommitOptions(); options.amend = amend; options.amendDiffToLastCommit = amendDiffToLastCommit; options.author = setAuthor ? author : nil
        options.authorDate = setAuthorDate ? authorDate : nil; options.resetAuthorDate = amend && setAuthorDate && resetAuthorDate; options.messageOnly = messageOnly; options.newBranch = createBranch ? newBranch : nil
        if !staging { options.checkboxIndexPolicy = CommitCheckboxIndexPolicy(paths:GitPathSet(visibleEntries.map(\.path)),defaults:dialogDefaults) }
        let preflight=UUID(),preflightToken=OperationCancellation();preflightRequest=preflight;preflightCancellation=preflightToken
        busy = true;Self.activeCommitPreflights += 1
        Task { [self,access] in
            defer { Self.activeCommitPreflights -= 1;withExtendedLifetime(access) {};if preflightRequest==preflight { preflightCancellation=nil } }
            var commitAttempted = false
            var progress: CommitProgressWindowModel?
            var selectedPostAction: CommitPostAction?
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let current=try await repository.commitDialogStatus(amendToParent:options.amend && !options.amendDiffToLastCommit,cancellation:preflightToken)
                try validatePreflight(preflight,preflightToken)
                let conflicts=current.filter { $0.state == .conflicted }
                if !conflicts.isEmpty {
                    let ignore=await withCheckedContinuation { continuation in confirmUnresolvedConflicts(conflicts.map(\.path)) { continuation.resume(returning:$0) } }
                    try validatePreflight(preflight,preflightToken)
                    guard ignore else { entries=current;focusConflictedFile(conflicts);busy=false;return }
                    options.ignoreUnresolvedConflicts=true
                }
                if let name=options.newBranch {
                    let collision=try await repository.validateCommitBranch(name,cancellation:preflightToken)
                    try validatePreflight(preflight,preflightToken)
                    if collision {
                        let proceed=await withCheckedContinuation { continuation in confirmBranchTagCollision(name) { continuation.resume(returning:$0) } }
                        try validatePreflight(preflight,preflightToken);guard proceed else { busy=false;return }
                    }
                }
                if let historyCombine { try await repository.verifyHistoryCombineAmend(historyCombine) }
                let validation = try await repository.prepareIssueCommit(properties: properties, message: rawMessage, issueID:rawIssueID,cancellation:preflightToken)
                try validatePreflight(preflight,preflightToken)
                if validation.requiresIssueWarning {
                    let proceed = await withCheckedContinuation { continuation in confirmMissingIssue { continuation.resume(returning: $0) } }
                    try validatePreflight(preflight,preflightToken)
                    guard proceed else { busy = false; return }
                }
                if !messageTemplate.isEmpty && GitReferenceName.equal(rawMessage,messageTemplate) && !dialogDefaults.bool(forKey: "Commit.TemplateNotEdited.Proceed") {
                    let proceed = await withCheckedContinuation { continuation in confirmUneditedTemplate { continuation.resume(returning: $0) } }
                    try validatePreflight(preflight,preflightToken)
                    guard proceed else { busy = false; return }
                }
                var text = rawMessage
                if properties.warnNoSignedOffBy {
                    let line = try await repository.commitSignOffLine(cancellation:preflightToken)
                    try validatePreflight(preflight,preflightToken)
                    if !text.contains(line) {
                        let choice = await withCheckedContinuation { continuation in confirmMissingSignOff { continuation.resume(returning: $0) } }
                        try validatePreflight(preflight,preflightToken)
                        if choice == .abort { busy = false; return }
                        if choice == .add { text = IssueTrackerProperties.addingSignOff(line, to: text); message = text }
                    }
                }
                // AppUtils' detector is shared by Commit and Rebase. Test the
                // draft after sign-off handling, before issue insertion or staging.
                let conflictHints = !dialogDefaults.bool(forKey:"CommitMessageContainsConflictHint") ? try await repository.rebaseMessageContainsConflictHints(text,stripComments:dialogDefaults.bool(forKey:"StripCommentedLines"),cancellation:preflightToken) : false
                try validatePreflight(preflight,preflightToken)
                if conflictHints {
                    let choice = await withCheckedContinuation { continuation in confirmConflictHints { continuation.resume(returning: ($0, $1)) } }
                    try validatePreflight(preflight,preflightToken)
                    guard choice.0 else { busy = false; return }
                    if choice.1 { dialogDefaults.set(true, forKey: "CommitMessageContainsConflictHint") }
                }
                if let hook = try await clientHooks.run(.preCommit, repository: repository, access: access, paths: committedPaths.sorted().map { repository.root.appendingPathComponent($0).path }, message: text, allowContinue: true) { text = hook.message; message = text }
                try validatePreflight(preflight,preflightToken)
                let prepared = text == rawMessage ? validation : try await repository.prepareIssueCommit(properties: properties, message: text, issueID:rawIssueID,cancellation:preflightToken)
                try validatePreflight(preflight,preflightToken)
                text = prepared.message; message = text
                try provider?.checkCommit(context: NativeIssueProviderContext(repositoryRoot:repository.root,paths:committedPaths.sorted(),message:text,issueID:rawIssueID))
                if !options.messageOnly {
                    let candidates = staging ? visibleEntries.filter { isStaged($0) }.map(\.path) : visibleEntries.filter { paths.contains($0.path) }.map(\.path)
                    let dirty = try await repository.commitDirtySubmodules(paths:candidates,cancellation:preflightToken)
                    try validatePreflight(preflight,preflightToken)
                    for child in dirty {
                        let choice = await withCheckedContinuation { continuation in confirmDirtySubmodule(child.path) { continuation.resume(returning: $0) } }
                        try validatePreflight(preflight,preflightToken)
                        guard choice == .ignore else {
                            busy = false
                            if choice == .commit { onCommitSubmodule(child.checkout) }
                            return
                        }
                    }
                }
                try validatePreflight(preflight,preflightToken)
                let isGitSVN = try await repository.finderMetadata(knownBare:false,cancellation:preflightToken).hasGitSVN
                let written = try await repository.prepareCommitMessageFile(text, stripComments: dialogDefaults.bool(forKey: "StripCommentedLines"), sanitize:dialogDefaults.object(forKey:"SanitizeCommitMsg") as? Bool ?? true,cancellation:preflightToken)
                text = written.contents; message = written.draft
                try validatePreflight(preflight,preflightToken)
                let result = CommitProgressWindowModel(repository: repository, action: action, staging: staging, paths: paths, options: options, preferences: dialogDefaults, cancellable: replaySplit == nil && historyCombine == nil)
                progress = result; commitProgress = result
                onCommitProgress?(result)
                let presented = onCommitProgress != nil && !result.dismissWithoutWindow
                let output: String
                commitAttempted = true
                if let historyCombine { try await repository.verifyHistoryCombineAmend(historyCombine) }
                let countedReplay = replaySplit != nil
                if countedReplay { RebaseWindowModel.beginReplayWork() }
                defer { if countedReplay { RebaseWindowModel.endReplayWork() } }
                do {
                    let parser = GitCliOutputParser(limit: result.outputLimit)
                    let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    let operation = Task {
                        defer { continuation.finish() }
                        let onOutput: @Sendable (GitOutputChunk) -> Void = { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }
                        if let replaySplit { return try await repository.commitRebaseSplit(message: text, paths: paths, staging: staging, options: options, expected: replaySplit, onOutput: onOutput) }
                        if staging { return try await repository.commitIndex(message: text, options: options, cancellation: result.cancellation, onOutput: onOutput) }
                        return try await repository.commitSelected(message: text, paths: paths, options: options, cancellation: result.cancellation, onOutput: onOutput)
                    }
                    for await _ in updates { result.consume(parser.processPending(), parser: parser) }
                    result.consume(parser.processPending(), parser: parser); result.consume(parser.finish(), parser: parser)
                    output = try await operation.value
                }
                guard messageFocusAvailable,preflightRequest==preflight,!preflightToken.isCancelled else {
                    result.complete(output:output,success:true,cancelled:false,postActions:[]);commitProgress=nil;return
                }
                var postHookFailure: String?
                if let provider {
                    do { let revision = try await repository.run(["rev-parse", "--verify", "HEAD"]).text.trimmingCharacters(in: .newlines); try provider.commitFinished(context: NativeIssueProviderContext(repositoryRoot:repository.root,paths:committedPaths.sorted(),message:text,issueID:rawIssueID), revision: revision) }
                    catch { postHookFailure = "The commit succeeded, but its issue-provider completion failed.\n\n" + error.localizedDescription }
                }
                do { _ = try await clientHooks.run(.postCommit, repository: repository, access: access, amend: options.amend) }
                catch { postHookFailure = (postHookFailure.map { $0 + "\n\n" } ?? "") + "The commit succeeded, but its post-commit hook failed.\n\n" + error.localizedDescription }
                try validatePreflight(preflight,preflightToken)
                messageHistory?.add(written.draft)
                if options.amend && !nonAmendMessage.isEmpty && !GitReferenceName.equal(nonAmendMessage,messageTemplate) { messageHistory?.add(nonAmendMessage) }
                if !result.isAbandoned { onCommitted(output) }
                result.complete(output: output + (postHookFailure.map { "\n" + $0 } ?? ""), success: true, cancelled: false, postActions: replaySplit == nil && historyCombine == nil ? (isGitSVN ? [.svnDCommit, .push, .pull, .recommit, .createTag] : [.push, .pull, .recommit, .createTag]) : [])
                if action != .commit || replaySplit != nil || historyCombine != nil || !presented || result.isAbandoned { result.choose(nil) }
                selectedPostAction = await result.waitForChoice()
                try validatePreflight(preflight,preflightToken)
                rememberCompletionAction(action)
                commitProgress = nil
                do { try await restoreSavedCopies(GitPathSet(restoreCopies.keys)) }
                catch {
                    self.error = "The commit succeeded, but restoring saved working copies failed. The remaining copies are retained in this dialog.\n\n" + error.localizedDescription
                    busy = false; reload(); return
                }
                if !preserveChangelists {
                    do { changelists = try await repository.pruneChangelists(retainingPathNames: retainedChangelists, scope: pruningScope) }
                    catch {
                        self.error = "The commit succeeded, but updating changelists failed.\n\n" + error.localizedDescription
                        busy = false; reload(); return
                    }
                }
                if let postHookFailure { self.error = postHookFailure; busy = false; reload(); return }
                if action == .recommit || selectedPostAction == .recommit {
                    do {
                        let seed = try await loadMessageSeed(includeOperationMessages: false, cancellation: preflightToken)
                        messageTemplate = seed.template
                        let separated = properties.separateIssueLine(from: seed.template)
                        message = separated.message; issueID = separated.issueID
                        if !seed.warnings.isEmpty { self.error = seed.warnings.joined(separator: "\n\n") }
                    } catch {
                        guard messageFocusAvailable, !preflightToken.isCancelled else { return }
                        messageTemplate = ""; message = ""; self.error = error.localizedDescription
                    }
                    createBranch = false; newBranch = ""; amend = false; amendDiffToLastCommit = false; amendMessage = ""; nonAmendMessage = ""; setAuthorDate = false; resetAuthorDate = false; setAuthor = false; messageOnly = false
                    selectFilesAutomatically = true
                    checked = []; selection = []; hasLoaded = false; loadedMessage = false
                    busy = false
                    reload(paths: scopePaths.isEmpty ? ["."] : scopePaths)
                } else {
                    busy = false; close()
                    if action == .push || selectedPostAction == .push { onPush() }
                    else if selectedPostAction == .pull { onPull() }
                    else if selectedPostAction == .createTag { onCreateTag() }
                    else if selectedPostAction == .svnDCommit { onSVNDCommit() }
                }
            } catch {
                guard messageFocusAvailable,preflightRequest==preflight,!preflightToken.isCancelled else {
                    if let progress { progress.complete(output:error.localizedDescription,success:false,cancelled:true,postActions:[]);progress.choose(nil) };commitProgress=nil;return
                }
                let commitError = error.localizedDescription
                let shownInProgress = progress != nil && onCommitProgress != nil && progress?.dismissWithoutWindow != true
                if let progress {
                    progress.complete(output: (error as? GitFailure)?.message ?? commitError, success: false, cancelled: progress.cancellation.isCancelled, postActions: [], exitCode: (error as? GitFailure)?.code)
                    if !shownInProgress || progress.cancelled { progress.choose(nil) }
                    _ = await progress.waitForChoice(); rememberCompletionAction(action); commitProgress = nil
                }
                var failureMessage = shownInProgress ? "" : commitError
                if commitAttempted && !restoreCopies.isEmpty, await chooseSavedCopies(allowCancel: false) == .restore {
                    do { try await restoreSavedCopies(GitPathSet(restoreCopies.keys)) }
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
        visibleEntries.filter { stagingEnabled ? isStaged($0) : checked.contains($0.id) }.map { entry in
            let label = entry.state == .untracked ? "Added" : entry.state.rawValue.capitalized
            return label.padding(toLength: max(10, label.count), withPad: " ", startingAt: 0) + " " + entry.path + "\n"
        }.joined()
    }
    var inputsBlocked:Bool {busy || issueProviderBusy || confirmingQuit || pendingReloadCancel || savingPreferences || stagingHintVisible}
    var canCancel: Bool { messageFocusAvailable && !stagingHintVisible && !confirmingQuit && !pendingReloadCancel && (!busy || reloadCancellation != nil || fileOperationToken != nil) }
    func cancel(closeWindow: Bool = true, completion: ((Bool) -> Void)? = nil) {
        cancel(closeWindow: closeWindow, completion: completion, confirmationAccepted: false)
    }
    private func cancel(closeWindow: Bool, completion: ((Bool) -> Void)?, confirmationAccepted: Bool) {
        guard messageFocusAvailable else { completion?(false); return }
        guard !stagingHintVisible else {completion?(false);return}
        if let task=preferenceTask {
            preferenceCancellation?.cancel();pendingStagingPreference=nil;pendingPatchPreference=nil
            Task { [weak self] in
                await task.value
                guard let self,self.messageFocusAvailable else {completion?(false);return}
                self.cancel(closeWindow:closeWindow,completion:completion,confirmationAccepted:confirmationAccepted)
            }
            return
        }
        if cancelFileOperation() { completion?(false); return }
        if let token = reloadCancellation, let task = reloadTask {
            guard !pendingReloadCancel, !confirmingQuit || !closeWindow else { completion?(false); return }
            pendingReloadCancel = true
            var answered = false
            let stop: (Bool) -> Void = { [weak self] approved in
                guard !answered else { return }; answered = true
                guard let self, self.messageFocusAvailable, self.pendingReloadCancel else { completion?(false); return }
                if !approved { self.pendingReloadCancel = false; completion?(false); return }
                self.invalidateMetadataLoads()
                token.cancel();fileListRefresh.cancel(); task.cancel()
                Task { [weak self] in
                    await task.value
                    guard let self, self.messageFocusAvailable else { completion?(false); return }
                    self.pendingReloadCancel = false
                    self.cancel(closeWindow: closeWindow, completion: completion, confirmationAccepted: true)
                }
            }
            let changed = !message.isEmpty && !GitReferenceName.equal(message,amend ? originalAmendMessage : messageTemplate)
            if !confirmationAccepted, (changed || !entries.isEmpty), !dialogDefaults.bool(forKey: "Commit.SkipCancelConfirmation") {
                confirmCancel(stop)
            } else { stop(true) }
            return
        }
        if let token = lfsOwnerCancellation { token.cancel(); completion?(false); return }
        if let commitProgress { commitProgress.cancel(); completion?(false); return }
        guard !busy, !confirmingQuit || !closeWindow else { completion?(false); return }
        let changed = !message.isEmpty && !GitReferenceName.equal(message,amend ? originalAmendMessage : messageTemplate)
        let finish = { [weak self] in
            guard let self, self.messageFocusAvailable else { completion?(false); return }
            if changed { self.messageHistory?.add(self.message) }
            if self.amend && !self.nonAmendMessage.isEmpty && !GitReferenceName.equal(self.nonAmendMessage,self.messageTemplate) { self.messageHistory?.add(self.nonAmendMessage) }
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
                    do { try await self.restoreSavedCopies(GitPathSet(self.restoreCopies.keys)) }
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
    var id: String { GitPathRowIdentity.encode(row.id) }
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
    @StateObject private var dropTargets = CommitFileDropTargets()
    @State private var dividerStart: Double?
    @FocusState private var issueFieldFocused: Bool
    @State private var initialIssueFocusApplied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                CommitDestinationLayout {
                    HStack(spacing:8) {
                        Text("Commit to:").fixedSize()
                        if model.createBranch { CommitNewBranchField(name:$model.newBranch).frame(width:250) }
                        else { CommitDestinationLabel(branch:model.branch.isEmpty ? "Detached / unborn HEAD" : model.branch).frame(minWidth:30,idealWidth:100,maxWidth:250) }
                        Toggle("new branch",isOn:$model.createBranch).toggleStyle(.checkbox).fixedSize().disabled(model.operation != nil || model.replaySplit != nil || model.historyCombine != nil)
                    }
                    HStack(spacing:8) {
                        if let provider = model.nativeIssueProvider {
                            Button { model.selectProviderIssues() } label: { CommandLabel(title:provider.linkText,icon:.settingsIssueTracker).lineLimit(1).truncationMode(.tail) }
                                .frame(maxWidth:200).help(provider.linkText).disabled(model.inputsBlocked)
                        }
                        if model.issueProperties.showsIssueField {
                            Text(model.issueProperties.label).lineLimit(1).truncationMode(.tail).frame(maxWidth:180).help(model.issueProperties.label)
                            TextField("",text:$model.issueID).textFieldStyle(.roundedBorder).frame(width:140).accessibilityLabel(model.issueProperties.label).focused($issueFieldFocused).onSubmit {issueFieldFocused=false;model.focusMessage()}
                        }
                        if model.busy { ProgressView().controlSize(.small) }
                    }
                }
                if let error = model.issueProviderError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if !model.fileOperationTitle.isEmpty { HStack { Text(model.fileOperationCancelling ? "Cancelling…" : model.fileOperationTitle).font(.caption); Spacer(); Button("Cancel operation") { model.cancelFileOperation() }.disabled(model.fileOperationCancelling) } }
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
                    if model.replaySplit == nil && model.historyCombine == nil { Menu {
                        ForEach(CommitWindowModel.CompletionAction.allCases, id: \.self) { action in
                            Button { model.commit(action) } label: { CommandLabel(title: action.rawValue, icon: action == .push ? .push : .commit) }
                        }
                    } label: { Image(systemName: "chevron.down") }.menuIndicator(.hidden).fixedSize().accessibilityLabel("Commit actions") }
                }.disabled(!model.canCommit || model.inputsBlocked)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel)
                Button("Help") { TurtleGitHelp.show(.commit) }.disabled(model.inputsBlocked)
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
        .onChange(of: model.selection) { _ in model.refreshPartial() }
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
                    DialogCommandRows {
                        Toggle("Amend Last Commit", isOn: $model.amend).toggleStyle(.checkbox).disabled(!model.hasHead || model.operation != nil || model.replaySplit != nil || model.historyCombine != nil).onChange(of: model.amend) { _ in model.amendChanged() }
                        if model.amend { Toggle("Show diff to last commit", isOn: $model.amendDiffToLastCommit).toggleStyle(.checkbox).disabled(!model.hasParent || model.replaySplit != nil || model.historyCombine != nil) }
                    }
                    DialogCommandRows {
                        Toggle("Set author date", isOn: $model.setAuthorDate).toggleStyle(.checkbox).frame(minWidth:170,alignment:.leading).fixedSize()
                        if model.setAuthorDate {
                            CommitDatePicker(selection: $model.authorDate, time: false, enabled: !model.loadingAuthorDate && !(model.amend && model.resetAuthorDate)).frame(width: 130, height: 24)
                            CommitDatePicker(selection: $model.authorDate, time: true, enabled: !model.loadingAuthorDate && !(model.amend && model.resetAuthorDate)).frame(width: 115, height: 24)
                            if model.amend { Toggle("Reset", isOn: $model.resetAuthorDate).toggleStyle(.checkbox) }
                        }
                    }
                    DialogCommandRows {
                        Toggle("Set author", isOn: $model.setAuthor).toggleStyle(.checkbox).frame(minWidth:170,alignment:.leading).fixedSize()
                        CommitAuthorField(author: $model.author, editable: model.setAuthor && !model.loadingAuthorIdentity)
                            .frame(minWidth:220,idealWidth:280).layoutValue(key:DialogCommandRows.Flexible.self,value:true)
                        Button("Add Signed-off-by") { model.addSignOff() }
                    }
                }.padding(4)
            }
    }
    private var changesSection: some View {
GroupBox("Changes made (F5: refresh, double-click on file for diff):") {
                    VStack(alignment: .leading, spacing: 6) {
                        DialogCommandRows(spacing:10) {
                            Text("Check:")
                            checkButton("All") { checking in model.check({ _ in true },checking:checking) }
                            checkButton("None") { model.checkAll(!$0) }
                            checkButton("Unversioned", enabled: model.visibleEntries.contains { $0.state == .untracked }) { checking in model.check({ $0.state == .untracked },checking:checking) }
                            checkButton("Versioned", enabled: model.visibleEntries.contains { $0.state != .untracked }) { checking in model.check({ $0.state != .untracked },checking:checking) }
                            checkButton("Added", enabled: model.visibleEntries.contains { $0.state == .added }) { checking in model.check({ $0.state == .added },checking:checking) }
                            checkButton("Deleted", enabled: model.visibleEntries.contains { $0.state == .deleted }) { checking in model.check({ $0.state == .deleted },checking:checking) }
                            checkButton("Modified", enabled: model.visibleEntries.contains { $0.state == .modified }) { checking in model.check({ $0.state == .modified },checking:checking) }
                            checkButton("Files", enabled: model.visibleEntries.contains { !model.submodules.contains($0.path) }) { checking in model.check({ !model.submodules.contains($0.path) },checking:checking) }
                            checkButton("Submodules", enabled: model.visibleEntries.contains { model.submodules.contains($0.path) }) { checking in model.check({ model.submodules.contains($0.path) },checking:checking) }
                        }.font(.system(size: 12)).disabled(model.messageOnly)
                        fileTable(model.visibleEntries, staged: model.stagingEnabled ? model.stagedDiff : nil).frame(minHeight: 120).disabled(model.messageOnly)
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Staging support (EXPERIMENTAL)",isOn:Binding(get:{model.stagingEnabled},set:{model.setStagingEnabled($0)}))
                                Toggle("Show Unversioned Files", isOn: Binding(get: { model.showUnversioned }, set: { model.setShowUnversioned($0) }))
                                Toggle("Do not autoselect submodules", isOn: Binding(get: { model.doNotAutoselectSubmodules }, set: model.setDoNotAutoselectSubmodules)).disabled(model.stagingEnabled)
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
    func fileTable(_ entries: [StatusEntry], staged: Bool?) -> some View {
        let statistics = model.statistics
        let entries = model.sortedFiles(entries, statistics: statistics)
        let focusKey = staged.map { $0 ? "staged" : "unstaged" } ?? "checkbox"
        let focus = Binding<String?>(get: { model.focusedFiles[focusKey] }, set: { model.focusedFiles[focusKey] = $0 })
        let ignored = GitPathSet(model.indexFlagFiles.filter { $0.assumeUnchanged || $0.skipWorktree }.map { $0.entry.path })
        let rows = StatusListGroups.rows(entries: entries, changelists: model.changelists, locallyIgnored: ignored)
        let tableRows = rows.map { CommitSortableRow(row: $0, statistics: $0.entry.flatMap { statistics[$0.path] }, isDirectory: $0.entry.map { model.submodules.contains($0.path) } ?? false, metadata: $0.entry.flatMap { model.fileMetadata[$0.path] }, lfsOwner: $0.entry.flatMap { model.lfsOwners[$0.path] } ?? "") }
        let sort = Binding(get: { model.fileSortOrder }, set: { model.setFileSortOrder($0) })
        return Table(tableRows, selection: $model.nativeFileSelection, sortOrder: sort) {
            TableColumn("") { (row: CommitSortableRow) in
                if let entry = row.entry {
                    if staged != nil {
                        StagingCheckbox(entry:entry,state:model.stagingState(entry),enabled:!model.inputsBlocked) { model.setFileChecked(entry, files: entries, highlighted: model.selection, checked: $0) }.frame(width: 20, height: 20)
                    } else {
                        StagingCheckbox(entry:entry,state:model.checked.contains(entry.id) ? .on : .off,enabled:!model.inputsBlocked,inclusion:true) {
                            model.setFileChecked(entry,files:entries,highlighted:model.selection,checked:$0)
                        }.frame(width:20,height:20)
                    }
                }
            }.width(24)
            TableColumn("Path", sortUsing: CommitFileSort(column: .path)) { (row: CommitSortableRow) in
                if let entry = row.entry {
                    HStack {
                        Image(nsImage: entry.state.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16).overlay {
                            if model.restoreCopies[entry.path] != nil { Image(nsImage: MenuIcon.restoreOverlay.image() ?? NSImage()).resizable().frame(width: 16, height: 16) }
                        }
                        Text(StatusListClipboard.displayedPath(entry)).foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences))
                    }.repositoryFileHelp(repository: model.repository.root, path: entry.path, detail: model.fileHelp(entry), preferences: model.colorPreferences)
                } else if let group = row.group {
                    HStack {
                        Text(group.title).font(.headline).foregroundStyle(Color.accentColor)
                        Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1)
                    }.help(changelistGroupHelp(group, lists: model.changelists)).accessibilityLabel(changelistGroupHelp(group, lists: model.changelists))
                }
            }.width(min: 260, ideal: 420)
            TableColumn("Filename", sortUsing: CommitFileSort(column: .fileName)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text((entry.path as NSString).lastPathComponent).foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)) } else { groupRule }
            }.width(min: 100, ideal: 180)
            TableColumn("Extension", sortUsing: CommitFileSort(column: .fileExtension)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(StatusListClipboard.fileExtension(entry.path, isDirectory: model.submodules.contains(entry.path) || model.fileMetadata[entry.path]?.isDirectory == true)).foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)) }
                else { groupRule }
            }.width(min: 40, ideal: 75)
            TableColumn("Status", sortUsing: CommitFileSort(column: .status)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(entry.index == "R" || entry.worktree == "R" ? "Renamed" : statistics[entry.path]?.status ?? entry.state.rawValue.capitalized).foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)) }
                else { groupRule }
            }.width(min: 60, ideal: 90)
            TableColumn("Lines added", sortUsing: CommitFileSort(column: .added)) { (row: CommitSortableRow) in
                lineCount(row.row, statistics: statistics, selected: model.selection, added: true)
            }.width(min: 40, ideal: 80)
            TableColumn("Lines removed", sortUsing: CommitFileSort(column: .removed)) { (row: CommitSortableRow) in
                lineCount(row.row, statistics: statistics, selected: model.selection, added: false)
            }.width(min: 40, ideal: 95)
            TableColumn("Last modified", sortUsing: CommitFileSort(column: .lastModified)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(row.metadata?.dateText ?? "–").foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)) } else { groupRule }
            }.width(min: 140, ideal: 180)
            TableColumn("File size", sortUsing: CommitFileSort(column: .fileSize)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(row.metadata?.sizeText ?? "–").foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)) } else { groupRule }
            }.width(min: 60, ideal: 90)
            TableColumn("LFS Lock", sortUsing: CommitFileSort(column: .lfsOwner)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(row.lfsOwner).foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)) } else { groupRule }
            }.width(min: 100, ideal: 160)
        }.fileListFont().contextMenu(forSelectionType: String.self) { nativeIDs in
            let requested = GitPathRowIdentity.paths(nativeIDs)
            TurtleGitContextMenu {
                let ids = requested.intersection(GitPathSet(entries.map(\.id)))
                let mark = StatusListSelection.mark(entries: entries, requested: ids, highlighted: model.selection, focusedPath: focus.wrappedValue)
                let menuSnapshot = model.fileMenu(ids, mark: mark?.id, orderedEntries: rows.compactMap(\.entry))
                if requested.count == 1, let group = rows.first(where: { requested.contains($0.id) })?.group {
                    let files = StatusListGroups.files(in: group, rows: rows)
                    let groupSnapshot = model.fileMenu(GitPathSet(files.map(\.id)), orderedEntries: files)
                    Button("Check group") { model.withFileMenu(groupSnapshot) { model.setGroupChecked(files, checked: true) } }.disabled(model.busy || model.confirmingQuit)
                    Button("Uncheck group") { model.withFileMenu(groupSnapshot) { model.setGroupChecked(files, checked: false) } }.disabled(model.busy || model.confirmingQuit)
                } else {
                    let selected = entries.filter { ids.contains($0.id) }
                    let flagFiles = model.indexFlagFiles.filter { ids.contains($0.id) }
                    let selectionMark = menuSnapshot.mark
                    if menuSnapshot.offersResolve {
                        ResolveSelectionMenu(paths:selected.map(\.path), rebase:model.conflictRebase, canEdit:selected.count == 1, action: { action, paths in model.withFileMenu(menuSnapshot) { model.onResolve(action, paths) } })
                        Divider()
                    }
                    if menuSnapshot.offersAdd {
                        ForEach(menuSnapshot.addModes(extended:NSEvent.modifierFlags.contains(.shift)), id: \.self) { mode in
                            Button { model.withFileMenu(menuSnapshot) { model.addFiles(selected, mode:mode) } } label: { CommandLabel(title:mode.rawValue, icon:.add) }.disabled(model.busy || model.confirmingQuit)
                        }
                        Divider()
                    }
                    if menuSnapshot.offersCompare {
                        Button { model.withFileMenu(menuSnapshot) { model.compare(paths: ids) } } label: { CommandLabel(title: "Compare with base", icon: .compare) }
                        if model.hasHead {
                            Button { model.withFileMenu(menuSnapshot) { model.diff(paths: ids, staged: staged, alternate: NSEvent.modifierFlags.contains(.shift)) } } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(model.busy || model.confirmingQuit)
                        }
                        Divider()
                    }
                    if selected.count == 2, selected.allSatisfy({ !model.submodules.contains($0.path) }) {
                        Button { model.fileAction(.compareTwo, snapshot: menuSnapshot) } label: { CommandLabel(title: "Compare two files", icon: .compare) }
                            .disabled(model.busy || model.confirmingQuit)
                        Divider()
                    }
                    if menuSnapshot.offersRevert {
                        Button { model.withFileMenu(menuSnapshot) { model.revertFiles(selected) } } label: { CommandLabel(title: "Revert", icon: .revert) }
                    }
                    if !selected.isEmpty && selected.allSatisfy({ ![FileState.untracked, .ignored].contains($0.state) && !model.submodules.contains($0.path) }) {
                        if let first = selected.first, model.restoreCopies[first.path] != nil {
                            Button { model.withFileMenu(menuSnapshot) { model.restoreNow(ids) } } label: { CommandLabel(title: "Restore", icon: .restore) }
                        } else {
                            Button { model.withFileMenu(menuSnapshot) { model.markForRestore(ids) } } label: { CommandLabel(title: "Restore after commit", icon: .restore) }
                        }
                    }
                    ForEach(model.lfsActions(selected), id: \.self) { action in
                        Button { model.withFileMenu(menuSnapshot) { model.setLFSLocked(ids, locked: action == .lock) } } label: { CommandLabel(title: action.rawValue, icon: action == .lock ? .lock : .unlock) }.disabled(model.busy || model.confirmingQuit)
                    }
                    if !selected.isEmpty, let mark = model.indexFlagFiles.first(where: { GitReferenceName.equal($0.id,selectionMark?.id) }) {
                        IndexFlagsMenu(files: flagFiles, selectionMark: mark) { action in model.withFileMenu(menuSnapshot) { model.setFlags(action, files: flagFiles, selectionMark: mark) } }
                    }
                    if !selected.isEmpty, selected.allSatisfy({ $0.state != .deleted }) {
                        Button { model.withFileMenu(menuSnapshot) { FileTransferClipboard.copy(selected.map { model.repository.root.appendingPathComponent($0.path) }) } } label: { CommandLabel(title: "Copy files", icon: .copy) }
                        Button { model.withFileMenu(menuSnapshot) { model.onCopyAdd(selected.map(\.path)) } } label: { CommandLabel(title: "Copy and Add…", icon: .add) }
                    }
                    Button { let urls = FileTransferClipboard.urls(); model.withFileMenu(menuSnapshot) { model.onPasteFiles(true, urls) } } label: { CommandLabel(title: "Paste Copy and Add…", icon: .copy) }
                    Button { let urls = FileTransferClipboard.urls(); model.withFileMenu(menuSnapshot) { model.onPasteFiles(false, urls) } } label: { CommandLabel(title: "Paste Move…", icon: .rename) }
                    if !selected.isEmpty, selected.allSatisfy({ ![FileState.untracked, .ignored, .deleted].contains($0.state) }) {
                        Button { model.withFileMenu(menuSnapshot) { model.onMove(selected.map(\.path)) } } label: { CommandLabel(title: "Move…", icon: .rename) }
                    }
                    if selected.count == 1, let entry = selected.first {
                        Divider()
                        if entry.state != .untracked && entry.state != .ignored {
                            Button { model.fileAction(.log, snapshot: menuSnapshot) } label: { CommandLabel(title: "Show log", icon: .log) }
                            if model.submodules.contains(entry.path) { Button { model.fileAction(.submoduleLog, snapshot: menuSnapshot) } label: { CommandLabel(title: "Show submodule log", icon: .log) } }
                            if entry.state != .deleted {
                                Button { model.withFileMenu(menuSnapshot) { model.onRename(entry.path) } } label: { CommandLabel(title: "Rename…", icon: .rename) }
                            }
                            if entry.originalPath != nil {
                                Button { model.fileAction(.oldNameLog, snapshot: menuSnapshot) } label: { CommandLabel(title: "Show log of old name", icon: .log) }
                            }
                            if menuSnapshot.commands.contains(.blame) {
                                Button { model.fileAction(.blame, snapshot: menuSnapshot) } label: { CommandLabel(title: "Blame", icon: .blame) }
                            }
                        }
                    }
                    if menuSnapshot.commands.contains(.export) {
                        Button { model.fileAction(.export, snapshot: menuSnapshot) } label: { CommandLabel(title: "Export…", icon: .export) }.disabled(model.busy || model.confirmingQuit)
                    }
                    if selected.count == 1 {
                        if menuSnapshot.commands.contains(.reveal) {
                            if menuSnapshot.commands.contains(.open) {
                                Button { model.fileAction(.editor, snapshot: menuSnapshot) } label: { CommandLabel(title: "View revision in alternative editor", icon: .editor) }.disabled(model.busy || model.confirmingQuit)
                                Button { model.fileAction(.open, snapshot: menuSnapshot) } label: { CommandLabel(title: "Open", icon: .open) }
                                Button { model.fileAction(.openWith, snapshot: menuSnapshot) } label: { CommandLabel(title: "Open With…", icon: .open) }
                            }
                            Button { model.fileAction(.reveal, snapshot: menuSnapshot) } label: { CommandLabel(title: "Reveal in Finder", icon: .explore) }
                        }
                    }
                    if !selected.isEmpty && selectionMark?.canDeleteFromStatusList == true {
                        Button { model.fileAction(.delete, snapshot: menuSnapshot, permanently: NSEvent.modifierFlags.contains(.shift)) } label: { CommandLabel(title: "Delete", icon: .remove) }.disabled(model.busy || model.confirmingQuit)
                    }
                    if menuSnapshot.offersIgnore {
                        Divider()
                        IgnoreSelectionMenu(paths: selected.map(\.path), action: { action, paths in model.withFileMenu(menuSnapshot) { model.onIgnore(action, paths) } })
                    }
                    if !selected.isEmpty {
                        Divider()
                        Menu {
                            ForEach(CommitWindowModel.CopyFileInformation.allCases, id: \.self) { information in
                                Button { model.withFileMenu(menuSnapshot) { model.copyFiles(selected, information: information, staged: staged) } } label: { CommandLabel(title: information.rawValue, icon: .copy) }
                            }
                        } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }
                    }
                    // The pinned upstream gate compares legacy status values to action
                    // bits: only a pure Added action (1) is excluded, not UNVER (0x80000000).
                    if !selected.isEmpty, let mark = selectionMark, !(mark.index == "A" && mark.worktree == " ") {
                        Divider()
                        if selected.contains(where: { model.changelists.name(for: $0.path) != nil }) {
                            Button("Remove from changelist") { model.withFileMenu(menuSnapshot) { model.moveToChangelist(selected.map(\.path), name: nil) } }
                        }
                        Menu("Move to changelist") {
                            Button("<new changelist>") { model.withFileMenu(menuSnapshot) { model.newChangelist(selected) } }
                            Divider()
                            Button(GitChangelists.ignored) { model.withFileMenu(menuSnapshot) { model.moveToChangelist(selected.map(\.path), name: GitChangelists.ignored) } }
                            let names = model.changelists.nameIdentities.filter { $0.rawValue != GitChangelists.ignored }
                            if !names.isEmpty {
                                Divider()
                                ForEach(names, id: \.self) { name in Button(name.rawValue) { model.withFileMenu(menuSnapshot) { model.moveToChangelist(selected.map(\.path), name: name.rawValue) } }.help(changelistNameHelp(name, names: names)).accessibilityLabel(changelistNameHelp(name, names: names)) }
                            }
                        }
                        Toggle("Keep changelists", isOn: Binding(get: { model.keepChangelists }, set: { model.saveKeepChangelists($0) }))
                    }
                }
            }
        } primaryAction: { nativeIDs in
            let requested = GitPathRowIdentity.paths(nativeIDs)
            let ids = requested.intersection(GitPathSet(entries.map(\.id)))
            model.selection = ids
            if ids.count == 1, let entry = model.entries.first(where: { ids.contains($0.id) }), entry.state == .conflicted { model.onResolve(.editConflict, [entry.path]) }
            else { model.compare(paths: ids) }
        }
        .background(CommitFileInteraction(rows: rows, configureRefresh: {dropTargets.set($0,for:focusKey);model.fileListRefresh.attach($0)},preferences:model.colorPreferences, visibleColumns: Set(model.visibleFileColumns), availableColumns: model.availableFileColumns, columnText: { entry, column in
            String(StatusListClipboard.text([entry], root: model.repository.root, statistics: statistics, copy: .column(column), metadata: model.fileMetadata, lfsOwners: model.lfsOwners).dropLast())
        }, savedOrder: model.fileColumns.order, savedWidths: model.fileColumns.widths, saveLayout: { model.saveFileColumnLayout(order: $0, widths: $1) }, setColumnVisible: { model.setFileColumn($0, visible: $1) }, resetColumns: { choose, accepted in model.requestResetFileColumns(choose: choose, onAccepted: accepted) }, focusedPath: focus, enabled: !model.busy && !model.confirmingQuit, delete: { model.deleteFiles($0, selectionMark: $1, permanently: $2) }, copy: { model.copyFileText($0, statistics: statistics, copy: $1 ? .pathsAndStatus : .relativePaths) }, copyColumn: { model.copyFileText($0, statistics: statistics, copy: .column($1)) }, toggleCheck: { files, mark in
            let next = model.stagingEnabled ? model.stagingState(mark) != .on : !model.checked.contains(mark.id)
            model.setFileChecked(mark, files: files, highlighted: GitPathSet(files.map(\.id)), checked: next)
        }))
        .onDrop(of: [UTType.fileURL], delegate: CommitFileDropDelegate(model: model, targets: dropTargets, key: focusKey))
        .onChange(of: model.selection) { ids in
            let files = ids.intersection(GitPathSet(entries.map(\.id)))
            if files.count == 1 && NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty { focus.wrappedValue = files.first }
        }
    }
    @ViewBuilder private func lineCount(_ row: StatusListRow, statistics: GitPathMap<CommitFile>, selected: some Sequence<String>, added: Bool) -> some View { let selected = GitPathSet(selected);
        if let entry = row.entry {
            let count: Int? = added ? statistics[entry.path]?.added : statistics[entry.path]?.removed
            let label = count.map { String($0) } ?? "–"
            Text(label).foregroundStyle(entry.statusTextColor(selected: selected.contains(entry.id), preferences: model.colorPreferences))
        } else { groupRule }
    }
    private var groupRule: some View { Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1) }
    func checkButton(_ title: String, enabled: Bool = true, action: @escaping (Bool) -> Void) -> some View { Button(title) {action(!NSEvent.modifierFlags.contains(.shift))}.buttonStyle(.plain).foregroundStyle(enabled ? Color.blue : Color.secondary).disabled(!enabled).help(title == "None" ? "Uncheck all files. Shift-click checks all files." : "Check matching files. Shift-click unchecks matching files.") }
}

/// Keep the source destination/issue bands on one line when they fit. At the
/// minimum window width, place issue controls below without duplicating fields
/// or losing their focus/selection identity during a resize.
struct CommitDestinationLayout:Layout {
    private func sizes(_ subviews:Subviews) -> [CGSize] { subviews.map { $0.sizeThatFits(.unspecified) } }
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) -> CGSize {
        let values = sizes(subviews), width = proposal.width ?? values.reduce(0) { $0 + $1.width } + 12
        guard values.count == 2 else { return CGSize(width:width,height:24) }
        let wrapped = values[1].width > 0 && values[0].width + values[1].width + 12 > width
        return CGSize(width:width,height:wrapped ? values[0].height + values[1].height + 6 : max(values[0].height,values[1].height))
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        let values = sizes(subviews); guard values.count == 2 else { return }
        let wrapped = values[1].width > 0 && values[0].width + values[1].width + 12 > bounds.width
        subviews[0].place(at:CGPoint(x:bounds.minX,y:bounds.minY),proposal:.init(width:min(bounds.width,values[0].width),height:values[0].height))
        subviews[1].place(at:CGPoint(x:max(bounds.minX,bounds.maxX - values[1].width),y:wrapped ? bounds.minY + values[0].height + 6 : bounds.minY),proposal:.init(width:min(bounds.width,values[1].width),height:values[1].height))
    }
}
struct CommitDestinationLabel:NSViewRepresentable {
    let branch:String
    func makeNSView(context:Context) -> NSTextField {
        let field = NSTextField(labelWithString:branch)
        field.isSelectable = true; field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        field.setAccessibilityLabel("Commit destination"); field.identifier = .init("Commit destination")
        return field
    }
    func updateNSView(_ field:NSTextField,context:Context) {
        field.stringValue = branch; field.toolTip = branch; field.textColor = .linkColor
    }
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
    let state: NSControl.StateValue
    let enabled: Bool
    var inclusion = false
    let change: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(change: change) }
    func makeNSView(context: Context) -> NSButton {
        let button = StageButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = !inclusion
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.change = change
        context.coordinator.nextChecked = state != .on
        button.allowsMixedState = !inclusion
        button.state = state
        button.isEnabled=enabled && context.environment.isEnabled && entry.state != .conflicted
        button.setAccessibilityLabel((inclusion ? "Include " : "Stage ") + entry.path)
        button.toolTip = inclusion ? "Include this file in the commit" : state != .off ? "Click to change staging; a mixed state stages the remaining working-tree changes." : "Click to stage the current file contents."
    }
    static func dismantleNSView(_ button:NSButton,coordinator:Coordinator) {
        button.isEnabled = false;button.target = nil;button.action = nil;coordinator.change = { _ in }
    }
    final class Coordinator: NSObject {
        var change: (Bool) -> Void
        // A mixed native checkbox can advance through NSCell's mixed state
        // before dispatch. Derive the requested operation from the Git snapshot.
        var nextChecked = true
        init(change: @escaping (Bool) -> Void) { self.change = change }
        @objc func clicked(_ sender: NSButton) { guard sender.isEnabled else {return};change(nextChecked) }
    }
    private final class StageButton: NSButton {
        override func setNextState() { state = state == .on ? .off : .on }
    }
}

enum CommitPostAction: String, CaseIterable, Hashable {
    case svnDCommit, push, pull, recommit, createTag
    var title: String { switch self { case .svnDCommit: return "SVN DCommit…"; case .push: return "Push…"; case .pull: return "Pull…"; case .recommit: return "ReCommit"; case .createTag: return "Create Tag…" } }
    var icon: MenuIcon { switch self { case .svnDCommit: return .commit; case .push: return .push; case .pull: return .pull; case .recommit: return .commit; case .createTag: return .tag } }
}
@MainActor final class CommitProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let action: CommitWindowModel.CompletionAction
    let staging: Bool
    let paths: GitPathSet
    let options: CommitOptions
    let cancellation = OperationCancellation()
    let cancellable: Bool
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private var outputState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { outputState.presentation }
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
    init(repository: GitRepository, action: CommitWindowModel.CompletionAction, staging: Bool, paths: GitPathSet, options: CommitOptions, preferences: UserDefaults, cancellable: Bool) {
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
        RepositoryWindowTitles.set(window, repository: model.repository.root, dialog: "Commit progress", preferences: model.presentationPreferences); window.minSize = NSSize(width: 620,height: 340); window.isReleasedWhenClosed = false
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
            HStack { if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }; Text(model.busy ? model.cancelling ? "Cancelling…" : "Committing…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Commit failed").foregroundStyle(model.busy ? Color.primary : model.success ? .green : .red); Spacer() }
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
        .gitDockProgress(.command(busy: model.busy, success: model.success, waiting: model.confirmingCancellation, percentage: model.percentage))
    }
}

/// Native commands belong to the active Commit owner, independently of the
/// repository selected in the main workspace. Static menu shapes survive tracking.
@MainActor final class CommitCommandMenu:NSObject,NSMenuItemValidation,NSMenuDelegate {
    enum Command:String,CaseIterable {
        case current="Current commit action",commit="Commit",recommit="ReCommit",push="Commit & Push"
        case refresh="Refresh",focus="Focus commit message",history="Recent messages…",hash="Pick commit hash…",message="Pick commit message…",pasteFiles="Paste file list",signOff="Add Signed-off-by"
        case all="All",none="None",unversioned="Unversioned",versioned="Versioned",added="Added",deleted="Deleted",modified="Modified",files="Files",submodules="Submodules"
        case staging="Staging support (EXPERIMENTAL)",showUnversioned="Show Unversioned Files",whole="Show Whole Project",messageOnly="Message only",amend="Amend Last Commit"
        case patch="View Patch",partialStage="Partial Staging",partialUnstage="Partial Unstaging",help="Commit Help"
    }
    private final class Invocation {let command:Command,epoch:UUID;init(_ command:Command,_ epoch:UUID){self.command=command;self.epoch=epoch}}
    private weak var owner:CommitWindowController?
    private weak var installedMenu:NSMenu?
    private var root:NSMenuItem?,items=[NSMenuItem](),epoch=UUID(),retired=false,queued=false
    private var trackedMenus=Set<ObjectIdentifier>()
    private var observations=[AnyCancellable]()
    var applicationMenu:()->NSMenu? = {NSApp.mainMenu}
    var keyWindow:()->NSWindow? = {NSApp.keyWindow}
    init(owner:CommitWindowController) {
        self.owner=owner;super.init()
        observations.append(owner.model.objectWillChange.sink { [weak self] _ in self?.schedule() })
        observations.append(NotificationCenter.default.publisher(for:NSApplication.didUpdateNotification).sink { [weak self] _ in self?.schedule() })
    }
    private var active:Bool {!retired && owner?.model.messageFocusAvailable==true && keyWindow() === owner?.window}
    private var ready:Bool {active && owner?.commandsAvailable==true}
    private func schedule() {
        guard !retired,!queued else {return};queued=true
        DispatchQueue.main.async { [weak self] in guard let self else {return};self.queued=false;if self.active {self.install();self.refresh()} }
    }
    func install() {
        guard active,trackedMenus.isEmpty,let main=applicationMenu() else {return}
        if installedMenu === main,root?.menu === main {refresh();return}
        remove();installedMenu=main
        for item in main.items where item.identifier?.rawValue=="TurtleGit.Commit.Commands" {main.removeItem(item)}
        let root=NSMenuItem(title:"Commit",action:nil,keyEquivalent:"");root.identifier = .init("TurtleGit.Commit.Commands")
        let menu=NSMenu(title:"Commit");menu.delegate=self;root.submenu=menu;self.root=root
        func append(_ commands:[Command],to menu:NSMenu) {
            for command in commands {
                let binding=shortcut(command),item=NSMenuItem(title:command.rawValue,action:#selector(invoke(_:)),keyEquivalent:binding?.0 ?? "")
                item.keyEquivalentModifierMask=binding?.1 ?? [];item.target=self;item.representedObject=Invocation(command,epoch)
                item.image=icon(command).contextImage(defaults:owner?.presentationPreferences ?? .standard)
                menu.addItem(item);items.append(item)
            }
        }
        func group(_ title:String,_ commands:[Command]) {let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");let child=NSMenu(title:title);child.delegate=self;item.submenu=child;menu.addItem(item);append(commands,to:child)}
        append([.current],to:menu);group("Commit actions",[.commit,.recommit,.push]);menu.addItem(.separator())
        group("Check files",[.all,.none,.unversioned,.versioned,.added,.deleted,.modified,.files,.submodules])
        group("Message",[.focus,.history,.hash,.message,.pasteFiles,.signOff])
        group("Options",[.staging,.showUnversioned,.whole,.messageOnly,.amend])
        append([.patch,.partialStage,.partialUnstage,.refresh,.help],to:menu)
        let index=main.items.firstIndex(where:{["Window","Help"].contains($0.title)}) ?? main.numberOfItems
        main.insertItem(root,at:index);refresh()
    }
    func remove() {epoch=UUID();if let root,let menu=root.menu {menu.removeItem(root)};root=nil;installedMenu=nil;items=[]}
    func retire() {remove();retired=true;observations=[];owner=nil}
    func menuWillOpen(_ menu:NSMenu) {trackedMenus.insert(ObjectIdentifier(menu));refresh()}
    func menuDidClose(_ menu:NSMenu) {trackedMenus.remove(ObjectIdentifier(menu));schedule()}
    func menuNeedsUpdate(_ menu:NSMenu) {refresh()}
    private func attached(_ item:NSMenuItem)->Bool {
        guard let main=installedMenu,main === applicationMenu(),root?.menu === main else {return false}
        var menu=item.menu
        while let current=menu {if current === main {return true};menu=current.supermenu}
        return false
    }
    private func predicate(_ command:Command,_ entry:StatusEntry)->Bool {
        guard let model=owner?.model else {return false}
        switch command {
        case .unversioned:return entry.state == .untracked
        case .versioned:return entry.state != .untracked
        case .added:return entry.state == .added
        case .deleted:return entry.state == .deleted
        case .modified:return entry.state == .modified
        case .files:return !model.submodules.contains(entry.path)
        case .submodules:return model.submodules.contains(entry.path)
        default:return true
        }
    }
    private func enabled(_ command:Command)->Bool {
        guard ready,let owner else {return false};let model=owner.model
        switch command {
        case .current,.commit:return model.canCommit
        case .recommit,.push:return model.canCommit && model.replaySplit==nil && model.historyCombine==nil
        case .all,.none,.unversioned,.versioned,.added,.deleted,.modified,.files,.submodules:return !model.messageOnly && model.visibleEntries.contains{predicate(command,$0)}
        case .history:return model.messageHistory?.entries.isEmpty==false && owner.messageEditor() != nil
        case .hash,.message,.pasteFiles:return owner.messageEditor() != nil
        case .whole:return !model.scopePaths.isEmpty
        case .amend:return model.hasHead && model.operation==nil && model.replaySplit==nil && model.historyCombine==nil
        case .patch:return !model.stagingEnabled
        case .partialStage,.partialUnstage:return model.stagingEnabled && !model.selection.isEmpty
        default:return true
        }
    }
    private func checked(_ command:Command)->Bool {
        guard let model=owner?.model else {return false}
        switch command {
        case .commit:return model.currentCompletionAction == .commit
        case .recommit:return model.currentCompletionAction == .recommit
        case .push:return model.currentCompletionAction == .push
        case .staging:return model.stagingEnabled
        case .showUnversioned:return model.showUnversioned
        case .whole:return model.showWholeProject
        case .messageOnly:return model.messageOnly
        case .amend:return model.amend
        case .patch:return model.viewingPatch
        case .partialStage:return model.partialMode==false
        case .partialUnstage:return model.partialMode==true
        default:return false
        }
    }
    private func refresh() {
        for item in items {guard let invocation=item.representedObject as? Invocation else {continue};let command=invocation.command;item.isEnabled=attached(item) && enabled(command);item.state=checked(command) ? .on:.off;if command == .current {item.title=owner?.model.currentCompletionAction.rawValue ?? command.rawValue}}
    }
    func validateMenuItem(_ item:NSMenuItem)->Bool {guard let invocation=item.representedObject as? Invocation else {return false};return invocation.epoch==epoch && attached(item) && enabled(invocation.command)}
    @objc private func invoke(_ item:NSMenuItem) {
        guard validateMenuItem(item),let invocation=item.representedObject as? Invocation else {return}
        perform(invocation.command);refresh()
    }
    private func perform(_ command:Command) {
        guard enabled(command),let owner else {return};let model=owner.model
        switch command {
        case .current:model.commitCurrentAction()
        case .commit:model.commit(.commit)
        case .recommit:model.commit(.recommit)
        case .push:model.commit(.push)
        case .refresh:model.reload()
        case .focus:model.focusMessage()
        case .history,.hash,.message,.pasteFiles:owner.messageEditor()?.performCommitMenuCommand(command)
        case .signOff:model.addSignOff()
        case .all,.none,.unversioned,.versioned,.added,.deleted,.modified,.files,.submodules:
            let shift=NSEvent.modifierFlags.contains(.shift),value=command == .none ? shift:!shift
            model.check({self.predicate(command,$0)},checking:value)
        case .staging:model.setStagingEnabled(!model.stagingEnabled)
        case .showUnversioned:model.setShowUnversioned(!model.showUnversioned)
        case .whole:model.showWholeProject.toggle()
        case .messageOnly:model.messageOnly.toggle()
        case .amend:model.amend.toggle()
        case .patch:model.showViewPatch()
        case .partialStage:model.showPartial(false)
        case .partialUnstage:model.showPartial(true)
        case .help:TurtleGitHelp.show(.commit)
        }
    }
    func performKeyEquivalent(_ event:NSEvent)->Bool {
        guard active else {return false};install()
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.keyCode==96,flags.isEmpty {if enabled(.refresh) {perform(.refresh)};return true}
        if [36,76].contains(event.keyCode),flags == .control {if enabled(.current) {perform(.current)};return true}
        guard let text=event.charactersIgnoringModifiers?.lowercased() else {return false}
        for item in items {guard let invocation=item.representedObject as? Invocation,let binding=shortcut(invocation.command),binding.0.lowercased()==text,binding.1==flags,attached(item) else {continue};if enabled(invocation.command) {invoke(item)};return true}
        return false
    }
    private func shortcut(_ command:Command)->(String,NSEvent.ModifierFlags)? {
        switch command {
        case .current:return ("\r",.command)
        case .recommit:return ("\r",[.command,.option])
        case .push:return ("\r",[.command,.shift])
        case .refresh:return (String(UnicodeScalar(NSF5FunctionKey)!),[])
        default:return nil
        }
    }
    private func icon(_ command:Command)->MenuIcon {
        switch command {
        case .push:return .push
        case .current,.commit,.recommit,.amend,.signOff:return .commit
        case .refresh:return .refresh
        case .focus,.messageOnly:return .editor
        case .history,.hash,.message:return .log
        case .pasteFiles:return .copy
        case .help:return .help
        case .patch,.partialStage,.partialUnstage:return .patch
        case .whole:return .repositoryBrowser
        case .none:return .revert
        default:return .add
        }
    }
}
