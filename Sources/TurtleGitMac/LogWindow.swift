import AppKit
import SwiftUI
import Combine
import TurtleGitCore
import UniformTypeIdentifiers

/// Native persistence for the filter fields currently implemented in Log.
private enum LogSearchSelection {
    static let all: HistorySearchFields = [.subject, .messages, .authors, .emails, .revisions, .referenceNames, .notes, .tagInfo, .paths, .bugIDs]
    static func load(defaults: UserDefaults = .standard) -> HistorySearchFields {
        guard let stored = defaults.object(forKey: "SelectedLogFilters") as? NSNumber, stored.intValue >= 0 else { return all }
        return HistorySearchFields(rawValue: stored.intValue).intersection(all)
    }
}

struct PreparedFileComparisonMark {
    let path: String
    let revision: String
    var workingAccess: WorkingComparisonAccess? = nil
    var isDirectory = false
    func label(for path: String) -> String {
        if let workingAccess { return workingAccess.file.path }
        if revision.isEmpty { return GitReferenceName.equal(self.path, path) ? "Working tree" : RepositoryBrowserGitPath.display(key:self.path) + ":Working tree" }
        return GitReferenceName.equal(self.path, path) ? revision : RepositoryBrowserGitPath.display(key:self.path) + ":" + String(revision.prefix(8))
    }
}

enum HistoricalOpenAction { case open, openWith, alternativeEditor }

/// Native counterpart of PatchViewDlg's sticky edge and parent frame handling.
enum LogPatchPlacement {
    static let gap: CGFloat = 8
    static func initial(parent: NSRect, width: CGFloat, screens: [NSRect]) -> NSRect {
        let right = NSRect(x: parent.maxX + gap, y: parent.minY, width: width, height: parent.height)
        let left = NSRect(x: parent.minX - width - gap, y: parent.minY, width: width, height: parent.height)
        if screens.contains(where: { $0.contains(right) }) { return right }
        if screens.contains(where: { $0.contains(left) }) { return left }
        guard let screen = screens.max(by: { $0.intersection(parent).area < $1.intersection(parent).area }) else { return right }
        let size = NSSize(width: min(width, screen.width), height: min(parent.height, screen.height))
        return NSRect(x: min(max(right.minX, screen.minX), screen.maxX - size.width),
                      y: min(max(parent.minY, screen.minY), screen.maxY - size.height), width: size.width, height: size.height)
    }
    static func snap(preview: NSRect, parent: NSRect) -> NSRect? {
        var result = preview
        let right = abs(preview.minX - parent.maxX - gap), left = abs(preview.maxX - parent.minX + gap)
        guard min(right, left) < 5 else { return nil }
        result.origin.x = right <= left ? parent.maxX + gap : parent.minX - preview.width - gap
        return result
    }
    static func follow(preview: NSRect, oldParent: NSRect, newParent: NSRect, minimumHeight: CGFloat) -> NSRect? {
        let right = abs(preview.minX - oldParent.maxX - gap) < 1
        let left = abs(preview.maxX - oldParent.minX + gap) < 1
        guard right || left else { return nil }
        let bottomAligned = abs(preview.minY - oldParent.minY) < 1, topAligned = abs(preview.maxY - oldParent.maxY) < 1
        let deltaY = newParent.minY - oldParent.minY
        var bottom = bottomAligned ? newParent.minY : preview.minY + deltaY
        let top = topAligned ? newParent.maxY : preview.maxY + deltaY
        if top - bottom < minimumHeight { bottom = top - minimumHeight }
        return NSRect(x: right ? newParent.maxX + gap : newParent.minX - preview.width - gap,
                      y: bottom, width: preview.width, height: max(minimumHeight, top - bottom))
    }
}

private extension NSRect { var area: CGFloat { isNull ? 0 : width * height } }
private enum LogSubmoduleHistoryFailure: LocalizedError {
    case uninitialized, unavailableRevision
    var errorDescription: String? {
        switch self {
        case .uninitialized: return "The submodule is not initialized. Initialize its working checkout to show its history."
        case .unavailableRevision: return "The selected gitlink revision is unavailable in the child repository. Update the submodule to show that revision."
        }
    }
}

@MainActor enum HistoricalPreviewFiles {
    private static var previews: [URL: HistoricalFilePreview] = [:]
    static func retain(_ preview: HistoricalFilePreview) { previews[preview.file] = preview }
    static func discard(_ file: URL) { previews.removeValue(forKey: file)?.discard() }
    static func discardAll() { for preview in previews.values { preview.discard() }; previews.removeAll() }
}

/// Route the source Ctrl-F gesture as native Command-F, including table focus.
final class LogHistoryWindow: NSWindow {
    var logMinimumContentSize=NSSize.zero {
        didSet {super.contentMinSize=minimum(super.contentMinSize,logMinimumContentSize);super.minSize=minimum(super.minSize,logMinimumFrameSize)}
    }
    var logMinimumFrameSize:NSSize {
        get {frameRect(forContentRect:NSRect(origin:.zero,size:logMinimumContentSize)).size}
        set {logMinimumContentSize=contentRect(forFrameRect:NSRect(origin:.zero,size:newValue)).size}
    }
    private func minimum(_ value:NSSize,_ floor:NSSize)->NSSize {.init(width:max(value.width,floor.width),height:max(value.height,floor.height))}
    override var contentMinSize:NSSize {
        get {minimum(super.contentMinSize,logMinimumContentSize)}
        set {super.contentMinSize=minimum(newValue,logMinimumContentSize)}
    }
    override var minSize:NSSize {
        get {minimum(super.minSize,logMinimumFrameSize)}
        set {super.minSize=minimum(newValue,logMinimumFrameSize)}
    }
    var find: () -> Void = {}
    var blocksInteraction: () -> Bool = { false }
    var commandKeyWindow: () -> NSWindow? = { NSApp.keyWindow }
    var navigationCommand: (NSEvent) -> Bool = { _ in false }
    var sourceCommand: (NSEvent) -> Bool = { _ in false }
    private func routeSourceCommand(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, commandKeyWindow() === self, event.window === self else { return false }
        return sourceCommand(event)
    }
    private func routeNavigation(_ event:NSEvent) -> Bool {
        guard commandKeyWindow() === self,event.window === self,
              (firstResponder as? NSTextView)?.isEditable != true,
              (firstResponder as? NSTextView)?.isFieldEditor != true else {return false}
        return navigationCommand(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if blocksInteraction() { return true }
        if routeSourceCommand(event) { return true }
        if routeNavigation(event) {return true}
        if let table=firstResponder as? HistoryTableView,table.performRevisionReturn(with:event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if blocksInteraction(), [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel].contains(event.type) { return }
        if event.type == .keyDown, routeSourceCommand(event) { return }
        if event.type == .otherMouseUp,routeNavigation(event) {return}
        super.sendEvent(event)
    }
}

/// Owns the entire deferred panel/preview/Launch Services handoff. Closing a
/// window cancels undispatched work; an accepted launch keeps its Quit lifetime
/// and grants until the receiving application has acknowledged the handoff.
@MainActor final class LogDocumentOpenSession {
    private(set) static var activeRequests = 0
    let cancellation = OperationCancellation()
    private let model: LogWindowModel
    private let generation: Int
    private let selection: UUID
    private let editor: AlternativeEditorPreferences
    private let permissions: [RepositoryAccessLease]
    private let panels: OwnedFilePanelSession
    private var finished = false
    private let activity: UUID
    var defaultApplication: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    var launch: ExternalDocumentApplication.Launch?
    var chooseApplication: ((NSOpenPanel) async -> URL?)?
    var preparePreview: (ComparisonFileContent, OperationCancellation) async throws -> HistoricalFilePreview = { content, token in
        try await Task.detached { try token.check(); return try HistoricalFilePreview.create(content) }.value
    }
    init(model: LogWindowModel, preferences: UserDefaults, permissions: [RepositoryAccessLease], panels: OwnedFilePanelSession,editor:AlternativeEditorPreferences? = nil) {
        self.model = model; generation = model.generation; selection = model.fileSelectionGeneration
        self.editor = editor ?? .load(from: preferences); self.permissions = permissions; self.panels = panels
        activity=model.beginFileNavigationActivity(); Self.activeRequests += 1
    }
    var current: Bool { !finished && !cancellation.isCancelled && !model.isInvalidated && !model.confirmingQuit && model.generation == generation && model.fileSelectionGeneration == selection }
    func retire() { cancellation.cancel(); panels.cancel() }
    private func finish() {
        guard !finished else { return }; finished = true; Self.activeRequests -= 1
        model.endFileNavigationActivity(activity)
    }
    func run(content: ComparisonFileContent?, workingFile: URL?, action: HistoricalOpenAction) async {
        defer { finish(); withExtendedLifetime(permissions) {} }
        var preview: HistoricalFilePreview?, dispatched = false
        do {
            await Task.yield(); try cancellation.check(); guard current else { return }
            var application: URL?
            if action == .openWith {
                let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"
                panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
                if let chooseApplication { application = await chooseApplication(panel) }
                else { application = await panels.choose(panel) }
                guard current, application != nil else { return }
            }
            let applicationGrant = application.map { RepositoryAccessLease(url: $0) }
            defer { withExtendedLifetime(applicationGrant) {} }
            guard !GitRuntime.isAppStoreBuild || application == nil || applicationGrant?.hasSecurityScope == true else { throw ExternalDocumentApplication.Failure.programPermission }
            let file: URL
            if let content {
                let prepared = try await preparePreview(content, cancellation); preview = prepared; file = prepared.file
            } else if let workingFile {
                try model.validateWorkingFileAccess(workingFile); file = workingFile
            } else { throw RevisionComparisonFailure.selection }
            try cancellation.check(); guard current else { preview?.discard(); return }
            if action != .alternativeEditor {
                guard let selected = application ?? defaultApplication(file) else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not open the file. Choose an application using Open With."])
                }
                application = selected
            }
            if let preview { HistoricalPreviewFiles.retain(preview) }
            // A receiving app may consume the input before Launch Services sends
            // its callback, even if that callback later reports a failure.
            dispatched = true
            if action == .alternativeEditor {
                try await AlternativeEditor.openDocument(file, settings: editor, permissions: permissions, cancellation: cancellation, launch: launch)
            } else if let application {
                var program = DiffToolProgram(); program.enabled = true; program.applicationPath = application.path
                try await ExternalDocumentApplication.open(file: file, program: program, arguments: [], nativeDocumentOpen: true,
                    permissions: permissions, cancellation: cancellation, requiresProgramScope: false, launch: launch)
            }
        } catch {
            if !dispatched { preview?.discard() }
            if current { model.error = error.localizedDescription }
        }
    }
}

@MainActor final class LogWindowController: NSWindowController, NSWindowDelegate {
    private(set) lazy var filePanels = OwnedFilePanelSession(window: window)
    var chooseFileDestination: ((NSSavePanel) async -> URL?)?
    private var exportFailureAlert: NSAlert?
    private func retireExportFailureAlert() {
        guard let alert=exportFailureAlert else{return};exportFailureAlert=nil
        if let parent=alert.window.sheetParent {parent.endSheet(alert.window,returnCode:.abort)}
        alert.window.orderOut(nil);alert.window.close()
    }
    private(set) var documentOpen: LogDocumentOpenSession?
    var configureDocumentOpen: (LogDocumentOpenSession) -> Void = { _ in }
    private(set) static var activeReferencePickers = 0
    private var startReferenceRequest: UUID?
    private(set) var startReferencePicker: ReferenceBrowserWindowController?
    var configureStartReferencePicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var presentStartReferencePicker: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    var makeStartReferencePicker: (GitRepository, RepositoryAccessLease?, String, UserDefaults, @escaping (String?) -> Void) -> ReferenceBrowserWindowController = { repository, access, initial, preferences, choose in
        ReferenceBrowserWindowController(repository: repository, access: access, initial: initial, preferences: preferences, pickMultiple: true, allowsRangeSelection: true, onChoose: choose)
    }

    let model: LogWindowModel
    private let findAccess: RepositoryAccessLease?
    private let findPreferences: UserDefaults
    private var findAvailability: AnyCancellable?
    private var notePresenter: CommitNotePresenter?
    var noteEditor: InputWindowController? { notePresenter?.editor }
    private(set) var find: RevisionGraphFindController?
    private(set) var ordering: LogOrderingWindowController?
    private(set) var containingReferences: [UUID: CommitContainingReferencesWindowController] = [:]
    private(set) var patchPreviewWindow: PatchWindowController?
    private var previousPatchParentFrame: NSRect?
    private var positioningPatch = false
    var onPullAfterLFSLock: () -> Void = {}
    var onLFSProgressLog: (String) -> Void = { _ in }
    private(set) var lfsOperation: LFSFileOperationController?
    private var closingLog = false
    private let commandProgressScope = CommandProgressContext.current
    var makeLFSOperation: (GitRepository, RepositoryAccessLease?, UserDefaults) -> LFSFileOperationController = {
        LFSFileOperationController(repository: $0, access: $1, defaults: $2)
    }
    var onClosed: () -> Void = {}
    private var selectionCompletion: ((LogEntry?) -> Void)?
    private var multipleSelectionCompletion: (([LogEntry]?) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, onChooseMultiple: (([LogEntry]?) -> Void)? = nil, onChoose: ((LogEntry?) -> Void)? = nil, labelDefaults: UserDefaults = .standard, savesColumnLayout: Bool = true, savesGeometry: Bool = true, initialRevision: String? = nil, historyRegexExecutable: URL? = nil, historyFileCache: HistoryFileCache = HistoryFileCache(), loadsImmediately: Bool = true, contextMenuPolicy: HistoryContextMenuPolicy = .log) {
        findAccess = access; findPreferences = labelDefaults
        model = LogWindowModel(repository: repository, access: access, selecting: onChoose != nil || onChooseMultiple != nil, selectingMultiple: onChooseMultiple != nil, labelDefaults: labelDefaults, historyRegexExecutable: historyRegexExecutable, historyFileCache: historyFileCache)
        model.contextMenuPolicy = contextMenuPolicy
        selectionCompletion = onChoose; multipleSelectionCompletion = onChooseMultiple
        model.endRevision = initialRevision
        let window = LogHistoryWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Log Messages", preferences: labelDefaults)
        window.logMinimumFrameSize = NSSize(width: 1080, height: 700)
        window.isReleasedWhenClosed = false
        let host=NSHostingController(rootView: LogDialog(model: model, savesColumnLayout: savesColumnLayout).disabled(model.findBlocked || model.orderingBlocked || model.referencePickerBlocked || model.confirmingQuit || model.resettingRevisionColumns).defaultAppStorage(labelDefaults))
        host.sizingOptions=[];window.contentViewController=host
        super.init(window: window)
        model.window = window
        window.find = { [weak self] in self?.showFind() }
        window.navigationCommand = { [weak model] event in model?.handleNavigation(event) ?? false }
        window.sourceCommand = { [weak self] event in self?.handleSourceCommand(event) ?? false }
        window.blocksInteraction = { [weak model] in model?.findBlocked == true || model?.orderingBlocked == true || model?.referencePickerBlocked == true || model?.confirmingQuit == true }
        findAvailability = model.$busy.sink { [weak self] _ in DispatchQueue.main.async { self?.find?.updateAvailability() } }
        notePresenter = CommitNotePresenter(parent: window, model: model, preferences: labelDefaults)
        model.onShowOrdering = { [weak self] in self?.showOrdering() }
        model.onBrowseStartReference = { [weak self] in self?.showStartReferencePicker() }
        model.onShowContainingReferences = { [weak self] hash in self?.showContainingReferences(hash) }
        model.onFindReferenceRefresh = { [weak self] in self?.find?.loadReferences() }
        model.onPatchPreviewVisibility = { [weak self] visible in self?.setPatchPreviewVisible(visible) }
        model.onPatchPreviewContent = { [weak self] bytes in self?.patchPreviewWindow?.model.setReadOnlyDiff(bytes) }
        model.onWorkingLFSOperation = CommandProgressContext.capture(commandProgressScope) { [weak self] paths, locked in
            guard let self, !self.closingLog, !self.model.isInvalidated, let owner = self.window,
                  owner.attachedSheet == nil, self.lfsOperation == nil else { return false }
            let progress = self.makeLFSOperation(repository, access, labelDefaults)
            progress.model.onProgressLog = CommandProgressContext.capture(self.commandProgressScope) { [weak self] path in
                guard let self, !self.closingLog, !self.model.isInvalidated else { return }
                self.onLFSProgressLog(path)
            }
            progress.model.onPullAfterLock = CommandProgressContext.capture(self.commandProgressScope) { [weak self] in
                guard let self, !self.closingLog, !self.model.isInvalidated else { return }
                self.onPullAfterLFSLock()
            }
            progress.onClosed = CommandProgressContext.capture(self.commandProgressScope) { [weak self, weak progress] in
                guard let self, let progress, self.lfsOperation === progress else { return }
                // Forced owner closure retires the child immediately, but the
                // accepted batch still owns its permissions until Git drains.
                if progress.model.busy || progress.model.progressActionBusy {
                    Task { @MainActor [self, progress] in
                        while progress.model.busy || progress.model.progressActionBusy { try? await Task.sleep(nanoseconds: 5_000_000) }
                        self.finishWorkingLFS(progress)
                    }
                } else { self.finishWorkingLFS(progress) }
            }
            self.lfsOperation = progress
            guard progress.present(owner: owner, paths: paths, locked: locked) else {
                self.lfsOperation = nil; progress.close(); return false
            }
            return true
        }
        model.confirmWorkingFlags = { action in confirmIndexFlags(action) }
        model.confirmWorkingDelete = { count, permanently in
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = permanently ? "Permanently delete the selected paths?" : "Move the selected paths to Trash?"
            alert.informativeText = "\(count) selected item(s). Their exact index entries will also be removed." + (permanently ? " This cannot be undone." : " Files moved to Trash can be recovered in Finder.")
            alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
            return alert.runModal() == .alertSecondButtonReturn
        }
        model.handleHistoricalRevertFailure = { message in
            let alert = NSAlert(); alert.messageText = "Could not revert file"; alert.informativeText = message
            alert.addButton(withTitle: "Ignore"); alert.addButton(withTitle: "Abort")
            return alert.runModal() == .alertFirstButtonReturn
        }
        model.showHistoricalRevertResult = { message in
            let alert = NSAlert(); alert.messageText = "Revert files"; alert.informativeText = message
            alert.addButton(withTitle: "OK"); alert.runModal()
        }
        window.delegate = self
        window.setContentSize(NSSize(width: 1120, height: 780))
        window.center()
        model.close = { [weak self] in
            guard let self else { return }
            if self.model.selecting { self.finishSelection(nil) } else { self.window?.performClose(nil) }
        }
        model.confirmReferenceDeletion = { [weak window] request in
            guard let window, window.attachedSheet == nil else { return .abort }
            return await HistoryReferenceDeletionPresentation.confirm(request, parent: window)
        }
        model.sshSettings.present = { [weak window] prompt in
            guard let window, window.attachedSheet == nil, let child = prompt.window else { return false }
            window.makeFirstResponder(nil); window.beginSheet(child); return true
        }
        model.acknowledgeReferenceDeletionFailure = { [weak window] message in
            guard let window, window.attachedSheet == nil else { return }
            await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.alertStyle = .critical; alert.messageText = "Could not delete reference."; alert.informativeText = message; alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window) { _ in continuation.resume() }
            }
        }
        model.confirmRevert = { [weak self] request in
            guard let window = self?.window, window.attachedSheet == nil else { return false }
            return await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.messageText = "Revert the selected commit(s)?"; alert.alertStyle = .warning
                if let parent = request.mainline { alert.informativeText = self?.model.parentChoices(for: request.revision).first(where: { $0.number == parent })?.title ?? "Parent \(parent)" }
                alert.addButton(withTitle: "Yes").keyEquivalent = ""
                let no = alert.addButton(withTitle: "No"); no.keyEquivalent = "\r"
                alert.window.defaultButtonCell = no.cell as? NSButtonCell
                alert.beginSheetModal(for: window) { response in continuation.resume(returning: response == .alertFirstButtonReturn) }
            }
        }
        model.offerRevertCommit = { [weak self] in
            guard let window = self?.window, window.attachedSheet == nil else { return false }
            return await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.messageText = "Revision(s) reverted. All changes are integrated into your working tree now."
                alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Commit")
                alert.beginSheetModal(for: window) { response in continuation.resume(returning: response == .alertSecondButtonReturn) }
            }
        }
        model.finishSelection = { [weak self] revision in self?.finishSelection(revision) }
        model.finishMultipleSelection = { [weak self] revisions in self?.finishMultipleSelection(revisions) }
        model.cancelFileChoice = { [weak self] in self?.filePanels.cancel(); self?.documentOpen?.retire();self?.retireExportFailureAlert() }
        model.cancelFileOpen = { [weak self] in self?.documentOpen?.retire() }
        model.presentHistoricalSave = { [weak self] content, short in
            // Let the originating context-menu tracking finish before presenting AppKit UI.
            guard let self else{return};let current=self.model.captureFileNavigationOwner()
            DispatchQueue.main.async { [weak self] in guard current() else{return};self?.saveHistoricalFile(content, short: short) }
        }
        model.presentHistoricalOpen = { [weak self] content, action in
            self?.openDocument(content: content, action: action)
        }
        model.presentHistoricalExport = { [weak self] revision, files in
            guard let self else{return}
            let backend=self.model.historicalExportBackend,current=self.model.captureFileNavigationOwner()
            DispatchQueue.main.async { [weak self] in guard current() else{return};self?.chooseHistoricalExport(revision: revision, files: files,backend:backend) }
        }
        model.presentWorkingSave = { [weak self] path in
            DispatchQueue.main.async { [weak self] in self?.chooseWorkingCopy(paths: [path], save: true) }
        }
        model.presentWorkingExport = { [weak self] paths in
            DispatchQueue.main.async { [weak self] in self?.chooseWorkingCopy(paths: paths, save: false) }
        }
        model.presentWorkingOpen = { [weak self] file, action in
            self?.openDocument(workingFile: file, action: action)
        }
        model.confirmExportFailure = { [weak self] message in
            guard let self,let window = self.window,!self.model.isInvalidated,!self.model.confirmingQuit,self.exportFailureAlert==nil,window.attachedSheet==nil else { return false }
            let alert=NSAlert();self.exportFailureAlert=alert
            alert.messageText="Could not export historical file";alert.informativeText=message;alert.alertStyle = .warning
            alert.addButton(withTitle:"Ignore");alert.addButton(withTitle:"Abort")
            let answer=await withCheckedContinuation { continuation in
                alert.beginSheetModal(for:window) {continuation.resume(returning:$0)}
            }
            // The export and a requested owner Close retain the real sheet
            // until AppKit releases it, rather than treating its reply as drain.
            while alert.window.sheetParent === window || window.attachedSheet === alert.window {
                try? await Task.sleep(nanoseconds:5_000_000)
            }
            if self.exportFailureAlert === alert {self.exportFailureAlert=nil}
            return !self.model.isInvalidated && !self.model.confirmingQuit && answer == .alertFirstButtonReturn
        }
        if loadsImmediately { model.reload() }

        if savesGeometry { DialogGeometry.attach(window, identifier: "LogWindowController") }
    }
    /// Source Log accelerators stay with this window. Native text editing and
    /// marked input keep their own Control/Option commands and Escape handling.
    func handleSourceCommand(_ event: NSEvent) -> Bool {
        guard let window = window as? LogHistoryWindow, event.window === window,
              window.commandKeyWindow() === window, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let text = window.firstResponder as? NSTextView
        if text?.hasMarkedText() == true { return false }
        let editing = text?.isEditable == true || text?.isFieldEditor == true
        let find = event.keyCode == 99 && flags.isEmpty || key == "f" && (flags == .command || flags == .control)
        let refresh = event.keyCode == 96 && (flags.isEmpty || flags == .control || flags == .shift) || key == "r" && flags == .command
        let focus = key == "l" && (flags == .command || flags == .control) || key == "d" && flags == .option
        let selectFilter = key == "e" && flags == .control
        if find {
            if editing && flags == .control { return false }
            guard model.canUseSourceCommands else { return true }; window.find(); return true
        }
        if refresh { model.refreshFromSourceCommand(); return true }
        if focus || selectFilter {
            // Cmd-L is the explicit native focus alias. Control-E/Control-L and
            // Option-D remain text editing/Unicode input while editing a field.
            if editing && !(key == "l" && flags == .command) { return false }
            guard model.canUseSourceCommands else { return true }
            _ = LogFilterField.focusHistory(in: window, selectAll: selectFilter); return true
        }
        if event.keyCode == 53 && flags.isEmpty {
            guard !editing else { return false }
            guard model.canUseSourceCommands else { return true }
            if model.clearHistoryFilterFromSourceCommand() { _ = LogFilterField.focusHistory(in: window, selectAll: false) }
            else { model.close() }
            return true
        }
        let copying = key == "c" && (flags == .command || flags == .control) || event.keyCode == 114 && flags == .control
        guard copying, !editing else { return false }
        guard (window.firstResponder is HistoryTableView || window.firstResponder is LogMessageTextView ? model.canFollowMessageLink : model.canInspectHistory) else { return true }
        if let message = text as? LogMessageTextView { message.copy(nil) }
        else if window.firstResponder is HistoryTableView { model.copyDetails() }
        else if window.firstResponder is NSTableView { model.copyChangedFileIDs(Array(model.selectedFiles)) }
        else { model.copyDetails() }
        return true
    }
    private func chooseFile(_ panel: NSSavePanel, accepted: @escaping (URL) -> Void) {
        guard model.canInspectHistory, window?.attachedSheet == nil else { return }
        let selection=model.fileSelectionGeneration, generation=model.generation
        let activity=model.beginFileNavigationActivity()
        Task { [self] in
            let target: URL?
            if let chooseFileDestination {target=await chooseFileDestination(panel)}
            else {target=await filePanels.choose(panel)}
            model.endFileNavigationActivity(activity)
            guard !model.isInvalidated,!model.confirmingQuit,generation==model.generation,
                  selection == model.fileSelectionGeneration, let target else { return }
            accepted(target)
        }
    }
    private func chooseHistoricalExport(revision: String, files: [CommitFile],backend:GitLibGit2Configuration?) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.title = "Export selected files"; panel.prompt = "Export"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        chooseFile(panel) { [weak model] folder in
            model?.exportHistoricalFiles(revision: revision, files: files, to: folder,backend:backend)
        }
    }
    private func chooseWorkingCopy(paths: [String], save: Bool) {
        guard let window, window.attachedSheet == nil, !model.busy, !model.isInvalidated else { return }
        let panel: NSSavePanel
        if save {
            let savePanel = NSSavePanel(); savePanel.title = "Save As"
            let source = model.repository.root.appendingPathComponent(paths[0])
            savePanel.nameFieldStringValue = source.lastPathComponent
            savePanel.directoryURL = source.deletingLastPathComponent()
            savePanel.allowsOtherFileTypes = true; panel = savePanel
        } else {
            let openPanel = NSOpenPanel(); openPanel.title = "Export selected files"; openPanel.prompt = "Export"
            openPanel.canChooseFiles = false; openPanel.canChooseDirectories = true
            openPanel.allowsMultipleSelection = false; panel = openPanel
        }
        panel.canCreateDirectories = true
        chooseFile(panel) { [weak model] target in
            model?.copyWorkingFiles(paths, to: target, save: save)
        }
    }
    private func openDocument(content: ComparisonFileContent? = nil, workingFile: URL? = nil, action: HistoricalOpenAction) {
        guard let window, window.attachedSheet == nil, model.canInspectHistory, documentOpen == nil else { return }
        let operation = LogDocumentOpenSession(model: model, preferences: findPreferences,
            permissions: findAccess.map { [$0] } ?? [], panels: filePanels,editor:content == nil ? nil:model.materializationEditorSettings)
        configureDocumentOpen(operation); documentOpen = operation
        Task { [weak self, operation] in
            await operation.run(content: content, workingFile: workingFile, action: action)
            if self?.documentOpen === operation { self?.documentOpen = nil }
        }
    }
    private func saveHistoricalFile(_ content: ComparisonFileContent, short: String) {
        guard let window, window.attachedSheet == nil else { return }
        let leaf:String
        do{leaf=try HistoricalFileDeliveryName.leaf(for:content)}catch{model.error=error.localizedDescription;return}
        let name = leaf as NSString
        let ext = name.pathExtension
        let panel = NSSavePanel(); panel.title = "Save file at revision " + short
        panel.nameFieldStringValue = name.deletingPathExtension + "-" + short + (ext.isEmpty ? "" : "." + ext)
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]; panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.directoryURL = (try? RepositoryBrowserGitPath(key:content.path).isRepresentable)==true ? model.repository.root.appendingPathComponent(content.path).deletingLastPathComponent():model.repository.root
        chooseFile(panel) { [weak model] url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                if GitRuntime.isAppStoreBuild && !scoped { throw RepositoryAccessFailure.securityScopeUnavailable }
                try content.bytes.write(to: url, options: .atomic)
            } catch { model?.error = error.localizedDescription }
        }
    }
    private func finishSelection(_ revision: LogEntry?) {
        guard !model.unifiedViewerBusy else { return }
        if multipleSelectionCompletion != nil { finishMultipleSelection(nil); return }
        guard let completion = selectionCompletion else { return }; selectionCompletion = nil
        if let window { window.sheetParent?.endSheet(window); window.close() }
        completion(revision)
    }
    private func finishMultipleSelection(_ revisions: [LogEntry]?) {
        guard !model.unifiedViewerBusy, let completion = multipleSelectionCompletion else { return }
        multipleSelectionCompletion = nil
        if let window { window.sheetParent?.endSheet(window); window.close() }
        completion(revisions)
    }
    private var canFind: Bool {
        !model.isInvalidated && !model.busy && !model.jumping && !model.loadingNote && !model.savingNote && model.noteRequest == nil && !model.copyingDetails && !model.unifiedViewerBusy && !model.findBlocked && !model.orderingBlocked && !model.referencePickerBlocked && window?.attachedSheet == nil
    }
    func showFind(regexExecutable: URL? = nil) {
        guard canFind, let parent = window else { return }
        if let find { find.window?.makeKey(); return }
        let child = RevisionGraphFindController(repository: model.repository, access: findAccess, preferences: findPreferences, regexExecutable: regexExecutable)
        find = child
        child.logSnapshot = { [weak model] in model?.entries ?? [] }
        child.searchIndex = { [weak model] in model?.findSearchIndex ?? 0 }
        child.didFindIndex = { [weak model] in model?.findSearchIndex = $0 }
        child.logFiles = { [weak model] in
            guard let model,model.fileReadBackendIdentity == NativeDiffBackendIdentity(model.repository.capturingDiffBackend(preferences:model.colorPreferences).libgit2Configuration),let hash = model.selectedWorkingTree ? "" : model.revision?.hash else { return [:] }
            return model.files.isEmpty ? [:] : [hash: model.files]
        }
        child.logDateSettings = .load(defaults: findPreferences)
        child.canSearch = { [weak self] in self?.canFind == true }
        child.navigate = { [weak model] hash, select in
            guard let model, !model.isInvalidated, model.entries.contains(where: { $0.hash == hash }) else { return }
            if select { model.select([hash]) }
            model.scrollRevision = hash; model.scrollRequest += 1
        }
        child.modalChanged = { [weak model, weak child] in
            model?.findBlocked = child?.acknowledgingFailure == true || child?.window?.attachedSheet != nil
            child?.updateAvailability()
        }
        child.onClosed = { [weak self, weak parent] in
            if let window = self?.find?.window { parent?.removeChildWindow(window) }
            self?.find = nil; self?.model.findBlocked = false
        }
        if let window = child.window {
            window.alphaValue = parent.alphaValue; window.appearance = parent.appearance
            parent.addChildWindow(window, ordered: .above); window.center(); window.orderFront(nil); window.makeFirstResponder(child.searchBox)
        }
        child.updateAvailability(); child.loadReferences()
    }
    func showOrdering() {
        guard canFind, !hasBlockingReferenceChild, ordering == nil, let parent = window else { return }
        let child = LogOrderingWindowController(preferences: findPreferences)
        ordering = child; model.orderingBlocked = true
        child.window?.alphaValue = parent.alphaValue; child.window?.appearance = parent.appearance
        child.completion = { [weak self] value in
            guard let self else { return }
            self.ordering = nil; self.model.orderingBlocked = false
            if value != nil, !self.model.isInvalidated { self.model.reload() }
        }
        parent.makeFirstResponder(nil)
        if let sheet = child.window { parent.beginSheet(sheet); sheet.makeFirstResponder(child.ordering) }
    }
    func showContainingReferences(_ hash: String) {
        guard canFind, !hash.isEmpty, let parent = window else { return }
        let id = UUID(), child = CommitContainingReferencesWindowController(repository: model.repository, access: findAccess, revision: hash, preferences: findPreferences)
        child.onLog = { [weak model] name, select, range in model?.onContainingLog?(name, select, range) }
        child.onBrowse = model.onBrowseRepository; child.onCompare = model.onCompare; child.onUnified = model.onUnifiedDiff
        child.onNavigate = { [weak model] hash, select in
            guard let model, !model.isInvalidated, !model.busy, !model.orderingBlocked else { return }
            if model.entries.contains(where: { $0.hash == hash }) {
                if select { model.select([hash]) } else { model.highlightedRevision = hash }
                model.scrollRevision = hash; model.scrollRequest += 1
            } else { model.navigationNotice = "The reference is not visible in the current log." }
        }
        child.onClosed = { [weak self, weak child, weak parent] in
            if let window = child?.window { parent?.removeChildWindow(window) }
            self?.containingReferences.removeValue(forKey: id)
        }
        containingReferences[id] = child
        if let window = child.window { window.alphaValue = parent.alphaValue; window.appearance = parent.appearance; parent.addChildWindow(window, ordered: .above); window.center(); window.orderFront(nil); window.makeFirstResponder(child.revision) }
        child.refresh()
    }
    func showStartReferencePicker() {
        guard model.canChangeStartReference, !hasBlockingReferenceChild, let owner = window, owner.attachedSheet == nil, startReferencePicker == nil else { return }
        let request = UUID(); startReferenceRequest = request; model.referencePickerBlocked = true; Self.activeReferencePickers += 1
        let child = makeStartReferencePicker(model.repository, findAccess, model.referenceExpression, findPreferences) { [weak self] value in
            guard let self, self.startReferenceRequest == request else { return }
            self.finishStartReferencePicker(request)
            if let value, !self.model.isInvalidated { self.model.chooseStartReference(value, remember: true) }
        }
        startReferencePicker = child; model.configureStartReferenceBrowser(child.model); configureStartReferencePicker(child.model)
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.startReferencePicker === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            // Accepted value is delivered after windowWillClose; keep its request until that callback.
            self.startReferencePicker = nil
        }
        guard let window = child.window, presentStartReferencePicker(owner, window) else {
            finishStartReferencePicker(request); child.abandonPresentation(); return
        }
        child.model.load()
    }
    private func finishStartReferencePicker(_ request: UUID) {
        guard startReferenceRequest == request else { return }
        startReferenceRequest = nil; startReferencePicker = nil; model.referencePickerBlocked = false; Self.activeReferencePickers -= 1
    }
    private func retireStartReferencePicker() {
        guard let request = startReferenceRequest else { return }
        let child = startReferencePicker
        finishStartReferencePicker(request); child?.abandonPresentation()
    }
    var hasBlockingReferenceChild: Bool { containingReferences.values.contains { $0.hasBlockingChild } }
    private func finishWorkingLFS(_ progress: LFSFileOperationController) {
        guard lfsOperation === progress else { return }
        lfsOperation = nil
        // Server changes may have completed before a forced owner close.
        // Refresh repository peers even when this Log has already retired.
        model.onRevisionChanged(progress.model.information)
        guard !closingLog, !model.isInvalidated else { return }
        model.busy = false
        model.requestRepositoryRefresh()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A document handoff without an attached chooser can retire its visual
        // owner immediately. windowWillClose cancels it and retains the actual
        // preview/launch worker and grants until acknowledgement/drain. File
        // reads and owned panels keep their separate deferred-close contract.
        let retiringDocument=documentOpen != nil && sender.attachedSheet == nil && filePanels.currentPanel == nil
        if !retiringDocument,model.cancelFileNavigationRead(closeAfter:true) { return false }
        if model.cancelWorkingLFSRead(closeAfter: true) { return false }
        if model.cancelFollowedComparison(closeAfter:true) { return false }
        if model.cancelWorkingCommandRead(closeAfter:true) { return false }
        if model.cancelStartReferenceRead() { return false }
        if model.cancelIntegrationRead(closeAfter:true) { return false }
        guard !model.confirmingQuit,!model.resettingRevisionColumns,!model.referencePickerBlocked, (!model.busy || model.loadingHistory || documentOpen != nil), !model.unifiedViewerBusy, !model.findBlocked, !model.orderingBlocked, !hasBlockingReferenceChild, sender.attachedSheet == nil else { return false }
        if model.selecting { finishSelection(nil); return false }; return true
    }
    func windowWillClose(_ notification: Notification) {
        closingLog = true
        lfsOperation?.close()
        model.saveLogViewPreferences(); model.savePaneLayout()
        documentOpen?.retire(); filePanels.retire()
        window?.makeFirstResponder(nil)
        retireStartReferencePicker()
        notePresenter?.close()
        let ordered = ordering; ordering = nil; ordered?.completion = { _ in }; ordered?.close(); model.orderingBlocked = false
        let references = Array(containingReferences.values); containingReferences.removeAll(); references.forEach { $0.close() }
        find?.close(); find = nil; model.findBlocked = false
        let completion = selectionCompletion; selectionCompletion = nil
        let multiple = multipleSelectionCompletion; multipleSelectionCompletion = nil
        model.unifiedWindow?.close(); model.invalidate()
        if let window, let child = window.attachedSheet { window.endSheet(child, returnCode: .abort); child.close() }
        // AppKit can retain a closed window (for example through its last event).
        // Retire its hosting tree now so it cannot retain repository permissions.
        window?.contentViewController = nil
        completion?(nil);multiple?(nil)
        let closed=onClosed;onClosed={}
        if model.noteWorkPending || model.revisionColumnWorkPending || model.workingLFSReadPending || model.historyProjectionWorkPending || model.pendingHistoryLoads > 0 || model.fileNavigationReadPending || lfsOperation != nil {
            Task{@MainActor [self] in while model.noteWorkPending || model.revisionColumnWorkPending || model.workingLFSReadPending || model.historyProjectionWorkPending || model.pendingHistoryLoads > 0 || model.fileNavigationReadPending || lfsOperation != nil{try? await Task.sleep(nanoseconds:5_000_000)};closed()}
        }else{closed()}
    }
    private func setPatchPreviewVisible(_ visible: Bool) {
        if !visible {
            previousPatchParentFrame = nil
            let owned = patchPreviewWindow; patchPreviewWindow = nil
            owned?.onClosed = {}; owned?.close(); return
        }
        guard patchPreviewWindow == nil, let window else { return }
        let child = PatchWindowController(repository: model.repository, access: nil)
        child.model.readOnly = true; child.model.refreshAvailable = false
        child.model.comparisonTitle = "Log Patch"; child.model.readOnlyInformation = "Patch follows the selected revision and changed files."
        child.model.setReadOnlyDiff(model.patchPreviewData)
        child.window?.title = "Log Patch – TurtleGit"
        child.onClosed = { [weak self] in self?.patchPreviewWindow = nil; self?.model.patchPreviewClosed() }
        child.onMoved = { [weak self] in self?.snapPatchPreview() }
        if let preview = child.window {
            positioningPatch = true
            preview.setFrame(LogPatchPlacement.initial(parent: window.frame, width: preview.frame.width, screens: NSScreen.screens.map(\.visibleFrame)), display: false)
            positioningPatch = false
            if window.isVisible && !window.isMiniaturized { preview.order(.above, relativeTo: window.windowNumber) }
        }
        patchPreviewWindow = child
        previousPatchParentFrame = window.frame
    }
    private func snapPatchPreview() {
        guard !positioningPatch, let parent = window, let preview = patchPreviewWindow?.window,
              let frame = LogPatchPlacement.snap(preview: preview.frame, parent: parent.frame), frame != preview.frame else { return }
        positioningPatch = true; preview.setFrame(frame, display: false); positioningPatch = false
    }
    private func followPatchPreview() {
        guard let parent = window, let preview = patchPreviewWindow?.window, let previous = previousPatchParentFrame else { return }
        previousPatchParentFrame = parent.frame
        guard previous != parent.frame,
              let frame = LogPatchPlacement.follow(preview: preview.frame, oldParent: previous, newParent: parent.frame, minimumHeight: preview.minSize.height) else { return }
        positioningPatch = true; preview.setFrame(frame, display: false); positioningPatch = false
    }
    func windowDidMove(_ notification: Notification) { followPatchPreview() }
    func windowDidResize(_ notification: Notification) { followPatchPreview() }
    func windowWillMiniaturize(_ notification: Notification) { patchPreviewWindow?.window?.orderOut(nil) }
    func windowDidDeminiaturize(_ notification: Notification) { showPatchWithoutActivation() }
    func windowDidBecomeKey(_ notification: Notification) { showPatchWithoutActivation() }
    private func showPatchWithoutActivation() {
        guard let parent = window, parent.isVisible, !parent.isMiniaturized, model.patchPreviewVisible else { return }
        patchPreviewWindow?.window?.order(.above, relativeTo: parent.windowNumber)
    }
    override func showWindow(_ sender: Any?) { super.showWindow(sender); showPatchWithoutActivation() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

enum LogIntegrationCommand { case merge, rebase }
/// Capture the source's preferred ref once; a moved ref must not silently choose
/// a different label or fall back to a hash while preparation is running.
struct LogIntegrationPreparation {
    let hash:String
    let reference:String?
    let revision:String
    var canonicalRevision:String { reference ?? revision }
    init(command:LogIntegrationCommand,entry:LogEntry,pointed:RevisionReference? = nil) {
        hash = entry.hash
        let chosen:RevisionReference?
        if command == .merge { chosen = pointed ?? entry.references.first }
        else { chosen = entry.references.first { $0.name.hasPrefix("refs/heads/") } ?? entry.references.first }
        reference = chosen?.name
        if command == .rebase, let name = chosen?.name, name.hasPrefix("refs/heads/") { revision = String(name.dropFirst("refs/heads/".count)) }
        else { revision = chosen?.name ?? entry.hash }
    }
    func read(repository:GitRepository,cancellation:OperationCancellation) async throws -> String {
        try cancellation.check()
        guard try await !repository.isBare(cancellation:cancellation) else { throw LogIntegrationFailure.worktree }
        let merging = try await repository.logMergeActive(cancellation:cancellation)
        let rebasing = try await repository.rebaseState(cancellation:cancellation).active
        guard !merging, !rebasing else { throw LogIntegrationFailure.active }
        guard let head=try await repository.revisionLookup("HEAD",requirement:.commit,cancellation:cancellation).objectID else{throw GitHistoricalLookupFailure.revision}
        guard head != hash else { throw LogIntegrationFailure.head }
        if let reference {
            let resolved = try await repository.revisionLookup(reference,requirement:.commit,cancellation:cancellation)
            guard resolved.objectID == hash else { throw LogIntegrationFailure.stale }
        }
        try cancellation.check(); return revision
    }
}
enum LogBisectCommand: CaseIterable {
    case start, good, bad, skip, reset
    var operation: BisectOperation? { switch self { case .start: return nil; case .good: return .good; case .bad: return .bad; case .skip: return .skip; case .reset: return .reset } }
    var title: String { "Bisect " + (self == .start ? "start…" : operation!.rawValue) }
    var icon: MenuIcon { operation?.icon ?? .bisect }
}
struct LogBisectRequest {
    let good: String?
    let bad: String?
    let operation: BisectOperation?
    let revisions: [String]
}
private enum LogBisectFailure: LocalizedError {
    case marked
    var errorDescription: String? { "The selected commit is already marked by Bisect. Refresh the Log." }
}
private enum LogWorkingCommandFailure: LocalizedError {
    case unavailable
    var errorDescription: String? { "This command is no longer available. Refresh the Log." }
}
private enum LogIntegrationFailure: LocalizedError {
    case worktree, head, active, stale
    var errorDescription: String? {
        switch self {
        case .stale: return "The selected reference changed. Refresh the Log and try again."
        case .worktree: return "This operation requires a working tree."
        case .head: return "The selected revision is already HEAD. Refresh the Log."
        case .active: return "Finish or abort the active Merge or Rebase before starting another operation."
        }
    }
}

/// Source progress and error policy use the original row count, including the
/// working-tree placeholder. Only nonempty commit IDs are handed to Git.
struct LogRevertSelection {
    let rows:[LogEntry]
    let mainline:Int?
    var commits:[LogEntry] {rows.filter{!$0.hash.isEmpty}}
    var multiple:Bool {rows.count>1}
}

enum LogRevisionCommand: String, Identifiable {
    case branch = "Create branch at this version…"
    case tag = "Create tag at this version…"
    case checkout = "Switch/Checkout to this…"
    case push = "Push…"
    case reset = "Reset current branch to this…"
    case cherryPick = "Cherry Pick this commit…"
    case revert = "Revert change by this commit"
    var id: String { rawValue }
}

struct LogCommandRequest: Identifiable {
    let id = UUID()
    let command: LogRevisionCommand
    let revision: LogEntry
    var mainline: Int? = nil
}

@MainActor final class LogWindowModel: ObservableObject {
    private(set) static var activeHistoryDeletions = 0
    private(set) static var activeHistoryLoads = 0
    private(set) var pendingHistoryLoads = 0
    private(set) static var activeFileOpenReads = 0
    private var fileOpenRead: OperationCancellation? {
        didSet {
            // History already owns busy while streaming. A separate file read
            // must still retire captured menu receipts through its own lifetime.
            if oldValue !== fileOpenRead { fileMenuGeneration = UUID();fileDragEpoch=UUID() }
        }
    }
    private(set) static var activeFileNavigationActivities = 0
    private var fileNavigationActivities = Set<UUID>()
    var fileNavigationReadPending: Bool { fileOpenRead != nil || !fileNavigationActivities.isEmpty }
    @discardableResult func beginFileNavigationActivity() -> UUID {
        let id=UUID();fileNavigationActivities.insert(id);Self.activeFileNavigationActivities += 1
        fileMenuGeneration=UUID();fileDragEpoch=UUID();busy=true
        return id
    }
    func endFileNavigationActivity(_ id:UUID) {
        guard fileNavigationActivities.remove(id) != nil else{return}
        Self.activeFileNavigationActivities -= 1;fileMenuGeneration=UUID()
        if !isInvalidated {busy=loadingHistory || fileNavigationReadPending || !unifiedSessions.isEmpty || followedSession != nil}
        finishPendingFileNavigationClose()
    }
    private var closeAfterFileNavigationRead = false
    @discardableResult func cancelFileNavigationRead(closeAfter: Bool = false) -> Bool {
        guard fileNavigationReadPending else{return false}
        closeAfterFileNavigationRead = closeAfterFileNavigationRead || closeAfter
        fileMenuGeneration=UUID();fileOpenRead?.cancel();cancelFileChoice();return true
    }
    private func finishPendingFileNavigationClose() {
        guard closeAfterFileNavigationRead,!fileNavigationReadPending else{return}
        closeAfterFileNavigationRead=false
        if !isInvalidated {window?.performClose(nil)}
    }
    private(set) static var activeActionReads = 0
    private var combineSelectionReads:[UUID:OperationCancellation]=[:]
    func validateCombineSelection(_ entries:[LogEntry],offset:Int,head:String,token:OperationCancellation) async throws {
        let identity=UUID();combineSelectionReads[identity]=token
        defer { combineSelectionReads.removeValue(forKey:identity) }
        guard !isInvalidated else { throw OperationCancellationFailure.cancelled }
        try await HistoryCombineSelectionReader.validate(repository:repository.capturingDiffBackend(preferences:labelDefaults),access:access,entries:entries,offset:offset,head:head,token:token)
    }
    let repository: GitRepository
    private(set) var materializationEditorSettings:AlternativeEditorPreferences?
    var captureMaterializationBackend:(()->GitLibGit2Configuration)?
    private(set) var historicalExportBackend:GitLibGit2Configuration?
    private func materializationBackend()->GitLibGit2Configuration {captureMaterializationBackend?() ?? .load(from:labelDefaults)}
    let sshSettings: SSHTransportSettings
    private var deletionCancellation: OperationCancellation?
    let selecting: Bool
    let selectingMultiple: Bool
    // Keep the security-scoped grant alive if the main repository window changes.
    private let access: RepositoryAccessLease?
    var repositoryAccess: RepositoryAccessLease? { access }
    private var statisticsWindow: StatisticsWindowController?
    // Upstream CGitLogListBase retains the index across Find close/reopen and reload.
    var findSearchIndex = 0
    var onFindReferenceRefresh: (() -> Void)?
    @Published var confirmingQuit = false { didSet { if confirmingQuit != oldValue { fileMenuGeneration=UUID();fileDragEpoch=UUID();retireLogControlMenus(); if confirmingQuit { retireRevisionColumns?() } } } }
    @Published private(set) var resettingRevisionColumns=false
    private(set) var revisionColumnWorkPending=false
    var retireRevisionColumns:(()->Void)?
    var presentRevisionColumnQuestion:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Void = {window,alert,reply in alert.beginSheetModal(for:window,completionHandler:reply)}
    func revisionColumnQuestionStarted(){revisionColumnWorkPending=true;resettingRevisionColumns=true}
    func revisionColumnQuestionFinished(){revisionColumnWorkPending=false;resettingRevisionColumns=false}
    @Published var findBlocked = false { didSet { if findBlocked != oldValue { retireLogControlMenus() } } }
    @Published var orderingBlocked = false { didSet { if orderingBlocked != oldValue { retireLogControlMenus() } } }
    private(set) var historyProjectionEpoch = UUID()
    private(set) var revisionTableContentEpoch = UUID(), revisionGraphEpoch = UUID()
    @Published var entries: [LogEntry] = [] { didSet { historyProjectionEpoch = UUID(); revisionTableContentEpoch = UUID() } }
    // IsSelectionContinuous compares the displayed and raw walk counts. Search,
    // graph compression and rollups may leave adjacent visible rows with gaps.
    private var historySourceRowCount: Int? { didSet { if oldValue != historySourceRowCount { historyProjectionEpoch = UUID() } } }
    var historyHasHiddenRows: Bool { historySourceRowCount.map { $0 != entries.count } ?? false }
    @Published var revisionActions: [String: LogRevisionActions] = [:] { didSet { revisionTableContentEpoch = UUID() } }
    @Published var actionFailures = Set<String>() { didSet { revisionTableContentEpoch = UUID() } }
    private var actionQueue: [LogEntry] = []
    private var actionCancellation: OperationCancellation?
    private var activeActionHashes=Set<String>()
    private var actionGeneration = 0
    var loadingActions: Bool { actionCancellation != nil }
    @Published var parentMetadata: [String: [LogParentChoice]] = [:]
    private(set) var parentMetadataBackendIdentity:String?
    @Published var mergeActive = false
    @Published var conflictRebase = false
    @Published var bisectActive = false
    @Published private(set) var bisectGoodTerm = "good" { didSet { revisionTableContentEpoch = UUID() } }
    @Published private(set) var bisectBadTerm = "bad" { didSet { revisionTableContentEpoch = UUID() } }
    @Published var hasStash = false
    @Published private(set) var hasGitSVN = false
    @Published private(set) var svnRevisions: [String: String] = [:] { didSet { revisionTableContentEpoch = UUID() } }
    @Published var hasSubmodules = false
    /// Install an owned snapshot for shared-list consumers without replacing
    /// their rows with an ordinary Log history walk.
    func installEmbeddedHistoryContext(_ metadata: FinderRepositoryMetadata, currentBranch: String, referenceContext: HistoryReferenceContext, bisectTerms: HistoryBisectTerms) {
        guard !isInvalidated else { return }
        bare = metadata.bare; mergeActive = metadata.mergeActive; bisectActive = metadata.bisectActive
        hasGitSVN = metadata.hasGitSVN; hasStash = metadata.hasStash; hasSubmodules = metadata.hasSubmoduleConfig; workingHasLFS = metadata.hasLFS
        self.currentBranch = currentBranch; self.referenceContext = referenceContext
        bisectGoodTerm = bisectTerms.good; bisectBadTerm = bisectTerms.bad
    }
    var onWorkingCommand: ((RepositoryAction) -> Void)?
    private(set) static var activeWorkingCommandReads=0
    private var workingCommandCancellation:OperationCancellation?
    private var closeAfterWorkingCommandRead=false
    @discardableResult func cancelWorkingCommandRead(closeAfter:Bool=false)->Bool {
        guard let token=workingCommandCancellation else { return false }
        closeAfterWorkingCommandRead = closeAfterWorkingCommandRead || closeAfter
        token.cancel();return true
    }
    private func workingCommandAllowed(_ action: RepositoryAction, working: Bool, stashRow: Bool, bare: Bool, merging: Bool, stash: Bool, submodules: Bool) -> Bool {
        switch action {
        case .commit,.clean: return working && !bare
        case .mergeAbort: return working && !bare && merging
        case .stash: return working && !bare && !merging
        case .stashPop: return (working || stashRow) && !bare && stash
        case .stashList: return (working || stashRow) && stash
        case .pull: return working && !bare && !merging
        case .fetch: return working && !bare
        case .submoduleUpdate: return working && !bare && submodules
        default: return false
        }
    }
    func workingCommandAvailable(_ action: RepositoryAction) -> Bool {
        workingCommandAllowed(action, working: selectedWorkingTree, stashRow: selectedIsStash, bare: bare, merging: mergeActive, stash: hasStash, submodules: hasSubmodules)
    }
    func canWorkingCommand(_ action: RepositoryAction) -> Bool {
        workingCommandAvailable(action) && onWorkingCommand != nil && canStartHistoryTransport && !referencePickerBlocked && workingCommandCancellation==nil
    }
    func requestWorkingCommand(_ action: RepositoryAction) {
        guard canWorkingCommand(action) else { return }
        let selection = selected, request = generation, working = selectedWorkingTree, stashRow = selectedIsStash
        let token=OperationCancellation();workingCommandCancellation=token;closeAfterWorkingCommandRead=false
        Self.activeWorkingCommandReads += 1
        busy = true; error = nil
        Task {
            defer {
                Self.activeWorkingCommandReads -= 1;withExtendedLifetime(access) {}
                if workingCommandCancellation === token {
                    workingCommandCancellation=nil;busy=false
                    let shouldClose=closeAfterWorkingCommandRead;closeAfterWorkingCommandRead=false
                    if shouldClose,!isInvalidated { close() }
                }
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let fresh = try await repository.finderMetadata(cancellation:token)
                guard request == generation,selection == selected,!isInvalidated,!token.isCancelled else { return }
                bare=fresh.bare;mergeActive=fresh.mergeActive;hasStash=fresh.hasStash;hasSubmodules=fresh.hasSubmoduleConfig;hasGitSVN=fresh.hasGitSVN
                guard workingCommandAllowed(action, working: working, stashRow: stashRow, bare: fresh.bare, merging: fresh.mergeActive, stash: fresh.hasStash, submodules: fresh.hasSubmoduleConfig) else { throw LogWorkingCommandFailure.unavailable }
                busy = false; onWorkingCommand?(action)
            } catch { if request == generation,!isInvalidated,!token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    @Published var showWorkingTree = true
    @Published var showUnversionedFiles = true
    @Published private(set) var workingTreeSnapshot: WorkingTreeHistory?
    @Published private(set) var workingIndexFiles: [WorkingTreeFile] = []
    @Published private(set) var workingHasLFS = false
    private var workingSubmodules = GitPathSet()
    var selectedWorkingTree: Bool { selected == [""] && workingTreeSnapshot != nil }
    var includesWorkingTree: Bool { selected.contains("") && workingTreeSnapshot != nil }
    func updateWorkingFiles() {
        guard selectedWorkingTree, let snapshot = workingTreeSnapshot else { return }
        let tracked = GitPathSet(snapshot.files.map(\.path))
        let ignored = workingIndexFiles.filter { ($0.assumeUnchanged || $0.skipWorktree) && !tracked.contains($0.id) }.map {
            CommitFile(path: $0.id, oldPath: nil, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: workingSubmodules.contains($0.id))
        }
        files = snapshot.files + ignored + (showUnversionedFiles ? snapshot.unversioned.filter { !tracked.contains($0.path) } : [])
    }
    static let changedFileColumnsKey="Log.ChangedFileColumns"
    @Published var changedFileColumns:StatusListColumnSettings { didSet { fileMenuGeneration = UUID();fileDragEpoch=UUID() } }
    @Published private(set) var changedFileSort=[LogChangedFileSort(column:.path)] { didSet { fileMenuGeneration = UUID();fileDragEpoch=UUID() } }
    @Published var focusedChangedFile:String? {
        didSet {
            if oldValue.map { GitReferenceName($0) } != focusedChangedFile.map { GitReferenceName($0) } {
                if let focusedChangedFile, selectedFileIDs.contains(focusedChangedFile) { fileSelectionMark = focusedChangedFile }
                invalidateFileSelection(includingDrag:false)
            }
        }
    }
    @Published private(set) var resettingChangedFileColumns=false
    private var changedFileColumnRequest=UUID()
    var canChangeFileColumns:Bool { !isInvalidated && !busy && !resettingChangedFileColumns && window?.attachedSheet == nil }
    @discardableResult func saveChangedFileLayout(order:[StatusListColumn],widths:[StatusListColumn:Double])->Bool {
        guard canChangeFileColumns else { return false }
        let allowed=Set(StatusListColumn.defaultColumns)
        let next=StatusListColumnSettings(visible:changedFileColumns.visible.intersection(allowed),order:order,widths:widths.filter {allowed.contains($0.key)})
        if next != changedFileColumns {changedFileColumns=next;next.save(to:labelDefaults,key:Self.changedFileColumnsKey)}
        return true
    }
    func setChangedFileColumn(_ column:StatusListColumn,visible:Bool) {
        guard canChangeFileColumns,StatusListColumn.defaultColumns.contains(column),column != .path else {return}
        if visible {changedFileColumns.visible.insert(column)} else {changedFileColumns.visible.remove(column)}
        changedFileColumns.save(to:labelDefaults,key:Self.changedFileColumnsKey)
    }
    func setChangedFileSort(_ sort:[LogChangedFileSort]) {
        guard !busy,!isInvalidated,!resettingChangedFileColumns else {return}
        changedFileSort=sort.isEmpty ? [LogChangedFileSort(column:.path)]:sort
    }
    func resetChangedFileColumns(choose:@escaping () async -> Bool,accepted:@escaping ()->Void) {
        guard canChangeFileColumns else {return}
        let request=UUID();changedFileColumnRequest=request;resettingChangedFileColumns=true
        Task { [weak self] in
            guard let self else {return}
            let yes=await choose()
            guard !self.isInvalidated,self.changedFileColumnRequest == request else {return}
            self.resettingChangedFileColumns=false
            guard yes,!self.busy else {return}
            self.changedFileColumns=StatusListColumnSettings();self.changedFileColumns.save(to:self.labelDefaults,key:Self.changedFileColumnsKey);accepted()
        }
    }
    func changedFileIcon(_ file:CommitFile)->NSImage? {
        let state:FileState=file.action == "?" ? .untracked:file.action == "!" ? .ignored:file.action == "U" ? .conflicted:file.action.hasPrefix("D") ? .deleted:file.action.hasPrefix("A") ? .added:.modified
        return state.icon.image()
    }
    func changedFileText(_ file:CommitFile,column:StatusListColumn)->String {
        switch column {
        case .path:return StatusListClipboard.displayedPath(file,abbreviate:labelDefaults.bool(forKey:"AbbreviateRenamings"))
        case .fileExtension:return StatusListClipboard.fileExtension(file.path,isDirectory:file.isSubmodule)
        case .status:return FileListLabels.caption(fileStatus(file))
        case .added:return file.addedText
        case .removed:return file.removedText
        default:return ""
        }
    }
    func copyChangedFileIDs(_ ids:[String],status:Bool=false,column:StatusListColumn?=nil) {
        guard canInspectHistory else {return}
        let ids=GitPathSet(ids),chosen=fileTableRows.compactMap(\.file).filter {ids.contains($0.id)}
        guard !chosen.isEmpty else {return}
        let text=chosen.map {file in
            if let column {return changedFileText(file,column:column)}
            return status ? RepositoryBrowserGitPath.display(key:file.path) + "\t" + fileStatus(file):RepositoryBrowserGitPath.display(key:file.path)
        }.joined(separator:"\r\n")
        copy(text)
    }
    @Published var currentBranch = ""
    var onExportRevision: ((String) -> Void)?
    var canExportRevision: Bool { revision != nil && canStartHistoryTransport && onExportRevision != nil }
    var resetAvailable:Bool { revision != nil && !bare && !selectedIsStash }
    func requestExport() {
        guard canExportRevision, let revision else { return }
        onExportRevision?(revision.references.first { $0.name.hasPrefix("refs/tags/") }?.name ?? revision.hash)
    }
    var onMergeRevision: ((String) -> Void)?
    var onRebaseRevision: ((String) -> Void)?
    var onPreparedRebase: ((LogIntegrationPreparation) -> Void)?
    var onCombineRevisions: (([LogEntry], Int, String) -> Void)?
    var onRevertRevisions: (([LogEntry], Int?) -> Void)?
    var onPreparedRevert:((LogRevertSelection)->Void)?
    func revertCaptured(_ entries:[LogEntry],mainline:Int?,selectedRows:[LogEntry]? = nil) {
        guard !isInvalidated,!busy,!bare,!mergeActive,!jumping,!loadingNote,!savingNote,noteRequest==nil,
              !findBlocked,!orderingBlocked,!copyingDetails,!unifiedViewerBusy,window?.attachedSheet==nil,
              !entries.isEmpty,onRevertRevisions != nil || onPreparedRevert != nil else{return}
        let selection=LogRevertSelection(rows:selectedRows ?? entries,mainline:mainline)
        guard selection.commits.map(\.hash)==entries.map(\.hash),selection.rows.filter({$0.hash.isEmpty}).count<=1 else{return}
        if !selection.multiple {
            guard let entry=selection.commits.first,!entry.parents.isEmpty,!entry.references.contains(where:{$0.name=="refs/stash"}) else{return}
            if entry.parents.count>1 {guard let mainline,(1...entry.parents.count).contains(mainline) else{return}}
            else if mainline != nil {return}
        } else if mainline != nil {return}
        if let onPreparedRevert {onPreparedRevert(selection)}
        else {onRevertRevisions?(selection.commits,mainline)}
    }
    /// Embedded replay lists can contain two occurrences of the same commit.
    /// Ordinary Log keeps its hash-based selection contract.
    var embeddedSelectionCount: Int?
    var occurrenceSelectionCount: Int { embeddedSelectionCount ?? selected.count }
    private var bisectRead: OperationCancellation?
    var onBisect: ((LogBisectRequest) -> Void)?
    func bisectAvailable(_ command: LogBisectCommand) -> Bool {
        if selectedWorkingTree { return !bare && bisectActive && command != .start }
        if includesWorkingTree { return !bare && bisectActive && command == .skip }
        if command == .reset { return false }
        let chosen = revisions
        guard !bare, !chosen.isEmpty, chosen.count == occurrenceSelectionCount, let first = chosen.first, !first.hash.isEmpty else { return false }
        if command == .start { return chosen.count == 2 && !bisectActive && !mergeActive && !isStash(first) }
        return bisectActive && !first.references.contains { $0.name.hasPrefix("refs/bisect/") } && (command == .skip || chosen.count == 1)
    }
    func canBisect(_ command: LogBisectCommand) -> Bool {
        !isInvalidated && !confirmingQuit && bisectAvailable(command) && onBisect != nil && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil && !copyingDetails
    }
    func requestBisect(_ command: LogBisectCommand) {
        guard canBisect(command) else { return }
        let chosen = revisions, selection = selected, request = generation, projection = historyProjectionEpoch, count = occurrenceSelectionCount
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        let cancellation = OperationCancellation(); bisectRead = cancellation
        busy = true; error = nil; Self.activeActionReads += 1
        Task {
            defer {
                Self.activeActionReads -= 1; withExtendedLifetime(access) {}
                if bisectRead === cancellation { bisectRead = nil; busy = false }
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                guard try await !repository.isBare(cancellation: cancellation) else { throw BisectFailure.workingTree }
                let state = try await repository.bisectState(cancellation: cancellation)
                let handoff: LogBisectRequest
                if command == .start {
                    guard !state.active, try await !repository.logMergeActive(cancellation: cancellation) else { throw BisectFailure.active }
                    // Upstream uses the first reference, otherwise the hash. A
                    // moved reference falls back to the selected commit.
                    func preset(_ entry: LogEntry) async throws -> String {
                        guard let ref = entry.references.first?.name else { return entry.hash }
                        let result = try await repository.revisionLookup(ref,requirement:.commit,cancellation:cancellation)
                        return result.objectID == entry.hash ? ref : entry.hash
                    }
                    let bad = try await preset(chosen[0]), good = try await preset(chosen[1])
                    handoff = LogBisectRequest(good: good, bad: bad, operation: nil, revisions: [])
                } else {
                    guard state.active else { throw BisectFailure.inactive }
                    if !selection.contains(""), let first = chosen.first {
                        let marks = try await repository.run(["for-each-ref", "--points-at", first.hash, "--format=%(refname)", "refs/bisect/"], cancellation: cancellation).text
                        guard marks.isEmpty else { throw LogBisectFailure.marked }
                    }
                    handoff = LogBisectRequest(good: nil, bad: nil, operation: command.operation, revisions: chosen.map(\.hash))
                }
                guard !isInvalidated, !confirmingQuit, !cancellation.isCancelled, generation == request, historyProjectionEpoch == projection, selected == selection, occurrenceSelectionCount == count else { return }
                busy = false; onBisect?(handoff)
            } catch { if !isInvalidated, !cancellation.isCancelled, generation == request, historyProjectionEpoch == projection { self.error = error.localizedDescription } }
        }
    }
    var confirmRevert: (LogCommandRequest) async -> Bool = { _ in false }
    var offerRevertCommit: () async -> Bool = { false }
    var onCommit: () -> Void = {}
    var onRevisionChanged: (String) -> Void = { _ in }
    func parentChoices(for entry: LogEntry) -> [LogParentChoice] {
        parentMetadata[entry.hash] ?? entry.parents.enumerated().map { LogParentChoice(number: $0.offset + 1, hash: $0.element) }
    }
    var revertAvailable: Bool { revision != nil && !bare && !mergeActive && !selectedIsStash && revision?.parents.isEmpty == false }
    var canRevertRevision: Bool { revertAvailable && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil }
    @Published var graph: [CommitGraphRow] = [] { didSet { revisionGraphEpoch = UUID() } }
    @Published var selected = Set<String>() { didSet { if selected != oldValue { invalidateFileSelection(); retireLogControlMenus() } } }
    @Published var files: [CommitFile] = [] { didSet { invalidateFileSelection() } }
    @Published var fileGroups: [LogFileGroup] = [] { didSet { invalidateFileSelection() } }
    private var selectedFileIDs = GitPathSet()
    /// ASCII identities at the SwiftUI boundary; Git IDs retain their UTF-8 bytes,
    /// including parent-group prefixes, in every command and shared table probe.
    @Published var nativeFileSelection = Set<String>() {
        didSet {
            guard nativeFileSelection != oldValue else { return }
            let valid = GitPathRowIdentity.paths(nativeFileSelection).intersection(visibleFiles.map(\.id))
            let added = valid.subtracting(selectedFileIDs)
            selectedFileIDs = valid
            if added.count == 1 { fileSelectionMark = added.first }
            else if fileSelectionMark.map({ !valid.contains($0) }) ?? true { fileSelectionMark = visibleFiles.first { valid.contains($0.id) }?.id }
            let encoded = Set(valid.map(GitPathRowIdentity.encode))
            if nativeFileSelection != encoded { nativeFileSelection = encoded }
            invalidateFileSelection(includingDrag:false); refreshPatchPreview()
        }
    }
    var selectedFiles: GitPathSet {
        get { selectedFileIDs }
        set { let ids = Set(newValue.map(GitPathRowIdentity.encode)); if nativeFileSelection != ids { nativeFileSelection = ids } }
    }
    private(set) var fileSelectionMark: String? {
        didSet { if oldValue.map { GitReferenceName($0) } != fileSelectionMark.map { GitReferenceName($0) } { invalidateFileSelection(includingDrag:false) } }
    }
    private(set) var fileSelectionGeneration = UUID()
    private var preservingHistoryFileNavigationOwner = false
    private var fileNavigationOwnerEpoch = UUID()
    private var fileMenuGeneration = UUID() {
        didSet { if !preservingHistoryFileNavigationOwner { fileNavigationOwnerEpoch=UUID() } }
    }
    private var fileDragEpoch = UUID()
    private func invalidateFileSelection(includingDrag:Bool=true) { cancelFileOpen(); fileOpenRead?.cancel(); fileSelectionGeneration = UUID(); fileMenuGeneration = UUID();if includingDrag{fileDragEpoch=UUID()} }
    func markedFile(_ ids: some Sequence<String>) -> CommitFile? {
        let ids = GitPathSet(ids)
        if let fileSelectionMark, ids.contains(fileSelectionMark), let file = visibleFiles.first(where: { GitReferenceName.equal($0.id, fileSelectionMark) }) { return file }
        return visibleFiles.first { ids.contains($0.id) }
    }
    func fileMenuSnapshot(_ ids: GitPathSet) -> LogFileMenuSnapshot {
        LogFileMenuSnapshot(owner: self, menuGeneration: fileMenuGeneration, selectionGeneration: fileSelectionGeneration, ids: ids, visible: visibleFiles)
    }
    /// A child comparison owns the accepted file rows rather than the current
    /// history projection. Appends are harmless; a different revision, file
    /// selection, setting/action epoch or owner retires the pending read. Its
    /// own warning sheet is deliberately outside this receipt's admission gate.
    func captureFileNavigationOwner() -> () -> Bool {
        let request=generation, selection=selected, fileRequest=fileSelectionGeneration
        let ownerEpoch=fileNavigationOwnerEpoch, selectedIDs=selectedFiles
        let records=files.enumerated().compactMap { selectedIDs.contains($0.element.id) ? ($0.offset,$0.element):nil }
        return { [weak self] in
            guard let self,!self.isInvalidated,!self.confirmingQuit,
                  self.generation==request,self.selected==selection,
                  self.fileSelectionGeneration==fileRequest,self.fileNavigationOwnerEpoch==ownerEpoch,
                  self.selectedFiles==selectedIDs,
                  !self.jumping,!self.loadingNote,!self.savingNote,self.noteRequest==nil,
                  !self.findBlocked,!self.orderingBlocked,!self.referencePickerBlocked,!self.copyingDetails,
                  !self.unifiedViewerBusy,self.unifiedSessions.isEmpty,self.followedSession==nil,
                  !self.fileNavigationReadPending,(!self.busy || self.loadingHistory) else{return false}
            return records.allSatisfy {self.files.indices.contains($0.0) && self.files[$0.0]==$0.1}
        }
    }
    func withFileMenu(_ snapshot: LogFileMenuSnapshot, consume:Bool=true, inspection:Bool=false, action: () -> Void) {
        guard snapshot.owner === self, !snapshot.consumed, !isInvalidated, (inspection ? canInspectHistory : !busy), !jumping, !loadingNote, !savingNote,
              !findBlocked, !orderingBlocked, !referencePickerBlocked, !copyingDetails, !unifiedViewerBusy,
              noteRequest == nil, window?.attachedSheet == nil, !resettingChangedFileColumns,
              snapshot.menuGeneration == fileMenuGeneration, snapshot.selectionGeneration == fileSelectionGeneration,
              snapshot.visible == visibleFiles, !snapshot.ids.isEmpty,
              snapshot.ids.isSubset(of: GitPathSet(visibleFiles.map(\.id))) else { return }
        if consume {snapshot.consumed = true}
        action()
    }
    /// Parent groups describe a selected commit's changes, so their files
    /// still export the selected child hash. A combined multi-commit list has
    /// no single source revision and is deliberately not a drag source.
    func fileDragProvider(_ snapshot:LogFileMenuSnapshot)->NSItemProvider? {
        guard !confirmingQuit,NSApp.modalWindow==nil,(selectedWorkingTree ? pendingHistoryLoads==0 : canInspectHistory),!fileNavigationReadPending,combineSelectionReads.isEmpty,(!selectedWorkingTree || hasRepresentableFilePaths(snapshot.ids)) else{return nil}
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        var provider:NSItemProvider?
        withFileMenu(snapshot,consume:false,inspection:!selectedWorkingTree) {
            let source:ComparisonRevision
            if selectedWorkingTree {source = .workingTree}
            else if let revision {source = .revision(revision.hash)}
            else {return}
            let files=fileTableRows.compactMap(\.file).filter {snapshot.ids.contains($0.id)}
            guard let plan=try? FileListDragPlan(root:repository.root,revision:source,files:files,backend:materializationBackend()),!plan.items.isEmpty else{return}
            provider=FileListDrag.provider(repository:repository,access:access,plan:plan,itemAt:0)
        }
        return provider
    }
    /// Capture the actual highlighted native row IDs, in their displayed order.
    /// Merge-parent groups share the selected child object; a combined selection
    /// has no single materialization revision and is not silently guessed.
    var fileDragGeneration:UUID? { (selectedWorkingTree ? !isInvalidated && !busy && !confirmingQuit : canInspectHistory) ? fileDragEpoch:nil }
    func captureFileDrag(_ orderedIDs:[String])->LogFileListDrag? {
        guard !confirmingQuit,NSApp.modalWindow==nil,(selectedWorkingTree ? pendingHistoryLoads==0 : canInspectHistory),!fileNavigationReadPending,
              combineSelectionReads.isEmpty,!orderedIDs.isEmpty,(!selectedWorkingTree || hasRepresentableFilePaths(orderedIDs)),
              GitPathSet(orderedIDs).count==orderedIDs.count,
              orderedIDs.allSatisfy({selectedFiles.contains($0)}) else{return nil}
        let rows=fileTableRows,lookup=GitPathMap(uniqueKeysWithValues:rows.compactMap { row in row.file.map{(row.rawID,$0)} })
        let files=orderedIDs.compactMap{lookup[$0]}
        guard files.count==orderedIDs.count else{return nil}
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        var drag:LogFileListDrag?
        withFileMenu(fileMenuSnapshot(GitPathSet(orderedIDs)),consume:false,inspection:!selectedWorkingTree) {
            let source:ComparisonRevision
            if selectedWorkingTree {source = .workingTree}
            else if let revision {source = .revision(revision.hash)}
            else{return}
            drag=LogFileListDrag(repository:repository,access:access,files:files,revision:source,backend:materializationBackend())
        }
        return drag
    }
    private var lastImportedWorkingMark: UUID?
    @Published var comparisonMark: PreparedFileComparisonMark? { didSet { fileMenuGeneration = UUID() } }
    @Published var allBranches = false
    @Published private(set) var referenceScope = HistoryReferenceScope.current
    @Published private(set) var startRevisions: [String] = []
    @Published private(set) var fetchHeadRevision: String?
    @Published private(set) var recentReferences: [String] = []
    @Published var referencePickerBlocked = false {
        didSet { if referencePickerBlocked != oldValue { retireLogControlMenus() }; if !referencePickerBlocked { scheduleRepositoryRefresh() } }
    }
    var onBrowseStartReference: () -> Void = {}
    var configureStartReferenceBrowser: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var savePaneLayout: () -> Void = {}
    func saveLogViewPreferences() {
        guard !isInvalidated else { return }
        HistoryReferenceScopePreference.save(effectiveReferenceScope, root: repository.root, defaults: labelDefaults)
    }
    private(set) var logControlsEpoch = UUID() {
        didSet { if !preservingHistoryFileNavigationOwner { fileNavigationOwnerEpoch=UUID() } }
    }
    func retireLogControlMenus() { logControlsEpoch = UUID() }
    var canChangeLogControls: Bool {
        canChangeStartReference && !resettingChangedFileColumns
    }
    func toggleWorkingTreeDisplay() {
        guard canChangeLogControls, canShowWorkingTree else { return }
        showWorkingTree.toggle(); reload()
    }
    func withLogControls(_ receipt: LogControlMenuReceipt, action: () -> Void) {
        guard receipt.owner === self, !receipt.used, canChangeLogControls,
              receipt.epoch == logControlsEpoch, receipt.generation == contextMenuGeneration,
              receipt.projection == historyProjectionEpoch, receipt.selection == selected else { return }
        receipt.used = true; retireLogControlMenus(); action()
    }
    private var startReferenceCancellation: OperationCancellation?
    private(set) static var activeReferenceReads = 0
    var canChangeStartReference: Bool { !isInvalidated && !confirmingQuit && NSApp.modalWindow == nil && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil && !copyingDetails && !unifiedViewerBusy && !findBlocked && !orderingBlocked && !referencePickerBlocked && window?.attachedSheet == nil }
    var effectiveReferenceScope: HistoryReferenceScope { allBranches ? .all : referenceScope }
    var referenceExpression: String { revisionRange?.expression ?? endRevision ?? (startRevisions.isEmpty ? "HEAD" : startRevisions.joined(separator: " ")) }
    var startReferenceTitle: String {
        if effectiveReferenceScope != .current { return effectiveReferenceScope.title }
        if referenceExpression == "HEAD" { return currentBranch.isEmpty ? "No branch" : currentBranch }
        if startRevisions.isEmpty, revisionRange == nil { return HistoryReferenceLabel.shortName(referenceExpression).text }
        return referenceExpression
    }
    func chooseStartReference(_ expression: String, remember: Bool = false) {
        guard canChangeStartReference, let selection = HistoryReferenceSelection(expression: expression) else { return }
        retireLogControlMenus()
        allBranches = false; referenceScope = .current; startRevisions = []
        switch selection {
        case .range(let range): revisionRange = range; endRevision = nil
        case .tips(let names): revisionRange = nil; endRevision = names.count == 1 ? names[0] : nil; startRevisions = names.count > 1 ? names : []
        }
        if remember { recentReferences = HistoryReferenceRecents(root: repository.root, defaults: labelDefaults).add(expression) }
        reload()
    }
    func chooseReferenceScope(_ scope: HistoryReferenceScope, persistImmediately: Bool = false) {
        guard canChangeStartReference, scope == .current || !historyWalk.followRenames else { return }
        // The source keeps GetRange() while a reference-set mask is active.
        // Turning All branches off returns to that range rather than HEAD.
        referenceScope = scope; allBranches = scope == .all
        if persistImmediately { saveLogViewPreferences() }
        reload()
    }
    func browseStartReference() { guard canChangeStartReference else { return }; onBrowseStartReference() }
    @discardableResult func cancelStartReferenceRead() -> Bool {
        guard let token = startReferenceCancellation else { return false }; token.cancel(); return true
    }
    func chooseFetchHead() {
        guard canChangeStartReference, fetchHeadRevision != nil else { return }
        let token = OperationCancellation(); startReferenceCancellation = token; busy = true; Self.activeReferenceReads += 1
        Task {
            defer { Self.activeReferenceReads -= 1; withExtendedLifetime(access) {}; if startReferenceCancellation === token { startReferenceCancellation = nil; busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let refs = try await repository.historyStartReferences(cancellation: token)
                guard !isInvalidated, startReferenceCancellation === token, !token.isCancelled else { return }
                startReferenceCancellation = nil; busy = false; fetchHeadRevision = refs.fetchHead
                if let hash = refs.fetchHead { chooseStartReference(hash) }
            } catch { if !isInvalidated, startReferenceCancellation === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    @Published private(set) var historyWalk = HistoryWalkOptions()
    @Published private(set) var rollupInfo: [String: HistoryRollupInfo] = [:] { didSet { revisionTableContentEpoch = UUID() } }
    private var rollupStates: [String: HistoryRollupChoice] = [:]
    private var historyFilterActive = false
    private let historyRegexExecutable: URL?
    var canToggleRollup: Bool { !busy && !isInvalidated && !historyFilterActive && historyWalk.graphMode != .labeled && revision != nil && rollupInfo[revision!.hash] != nil }
    var rollupTitle: String { revision.flatMap { rollupInfo[$0.hash] }?.collapsed == true ? "Expand" : "Collapse" }
    func toggleRollup() {
        guard canToggleRollup, let revision, let info = rollupInfo[revision.hash] else { return }
        info.toggled(in: &rollupStates, hash: revision.hash); reload()
    }

    @Published private(set) var referenceVisibility = HistoryReferenceVisibility.all
    @Published private(set) var showGravatar = false
    let gravatar: LogGravatar
    private var gravatarDefaultsKey: String { "LogDialog.ShowGravatar." + repository.root.standardizedFileURL.path }
    func toggleGravatar() {
        guard !busy, !isInvalidated else { return }
        retireLogControlMenus()
        showGravatar.toggle(); labelDefaults.set(showGravatar, forKey: gravatarDefaultsKey)
        refreshGravatar()
    }
    private func refreshGravatar() {
        if showGravatar, !isInvalidated, let revision { gravatar.load(email: revision.email) }
        else { gravatar.clear() }
    }

    private let includeWorkingTreeChanges: Bool
    let fullCommitMessageOnLogLine: Bool
    let drawTagsBranchesOnRightSide: Bool, symbolizeRefNames: Bool
    @Published var referenceContext = HistoryReferenceContext()
    @Published private(set) var referenceDescriptions: [GitReferenceName: String] = [:]
    private var referenceDescriptionRead: OperationCancellation?
    private var referenceDescriptionHover: (hash: String, name: String)?
    var readReferenceDescriptions: ((OperationCancellation) async throws -> [GitReferenceName: String])?
    func referenceTooltip(hash: String, name: String?, fallback: String?) -> String? {
        guard !isInvalidated, let entry = entries.first(where: { $0.hash == hash }) else { return nil }
        let reference = name.flatMap { name in entry.references.first { GitReferenceName.equal($0.name, name) } }
        return HistoryReferenceTooltip.text(reference: reference, descriptions: referenceDescriptions,
            fallback: fallback, descriptionTitle: String(localized: "Description"))
    }
    func hoverReference(hash: String, name: String?) {
        guard !isInvalidated, !busy, !confirmingQuit, window?.attachedSheet == nil else { cancelReferenceDescriptionRead(); return }
        guard let name, let entry = entries.first(where: { $0.hash == hash }),
              visibleReferenceLabels(for: entry).contains(where: { GitReferenceName.equal($0.reference.name, name) && $0.kind == .localBranch }) else { cancelReferenceDescriptionRead(); return }
        if let hover = referenceDescriptionHover, hover.hash == hash, GitReferenceName.equal(hover.name, name), referenceDescriptionRead != nil { return }
        cancelReferenceDescriptionRead()
        referenceDescriptionHover = (hash, name)
        let token = OperationCancellation(), request = generation, reader = readReferenceDescriptions
        referenceDescriptionRead = token; Self.activeReferenceReads += 1
        Task {
            defer { Self.activeReferenceReads -= 1; withExtendedLifetime(access) {}; if referenceDescriptionRead === token { referenceDescriptionRead = nil } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let descriptions: [GitReferenceName: String]
                if let reader { descriptions = try await reader(token) }
                else { descriptions = try await repository.historyBranchDescriptions(cancellation: token) }
                guard !isInvalidated, !confirmingQuit, !token.isCancelled, generation == request,
                      referenceDescriptionRead === token, let hover = referenceDescriptionHover,
                      hover.hash == hash, GitReferenceName.equal(hover.name, name),
                      entries.contains(where: { $0.hash == hash && $0.references.contains(where: { GitReferenceName.equal($0.name, name) }) }) else { return }
                if !HistoryReferenceTooltip.equalDescriptions(referenceDescriptions, descriptions) { referenceDescriptions = descriptions }
            } catch {
                // Source starts with a fresh empty map for each request; a
                // failed config read must not keep a previously cached description.
                if !isInvalidated, !confirmingQuit, !token.isCancelled, generation == request,
                   referenceDescriptionRead === token { referenceDescriptions = [:] }
            }
        }
    }
    private func cancelReferenceDescriptionRead() {
        referenceDescriptionRead?.cancel(); referenceDescriptionRead = nil; referenceDescriptionHover = nil
    }
    private var loadedHighlightFields: HistorySearchFields = LogSearchSelection.all
    var canShowWorkingTree: Bool { includeWorkingTreeChanges && !selecting && !bare }
    private let includeBoundaryCommits: Bool
    private let labelDefaults: UserDefaults
    private var labelDefaultsKey: String { "LogDialog.ReferenceVisibility." + repository.root.standardizedFileURL.path }
    func visibleReferenceLabels(for entry: LogEntry) -> [HistoryReferenceLabel] { referenceContext.labels(entry.references, visibility: referenceVisibility, symbolize: symbolizeRefNames, terms: HistoryBisectTerms(good: bisectGoodTerm, bad: bisectBadTerm)) }
    func shouldHighlightMessage(_ entry: LogEntry) -> Bool {
        let labels = visibleReferenceLabels(for: entry)
        if !entry.references.isEmpty && labels.isEmpty { return false }
        let fields: HistorySearchFields = !labels.isEmpty && !fullCommitMessageOnLogLine ? .subject : [.subject, .messages]
        return !loadedHighlightFields.intersection(fields).isEmpty
    }
    func visibleReferences(for entry: LogEntry) -> [RevisionReference] { entry.references.filter { referenceVisibility.shows($0) } }
    func toggleHistoryLabel(_ command: HistoryLabelCommand) {
        guard !busy, !isInvalidated else { return }
        retireLogControlMenus()
        if referenceVisibility.contains(command.flag) { referenceVisibility.remove(command.flag) }
        else { referenceVisibility.insert(command.flag) }
        labelDefaults.set(referenceVisibility.rawValue, forKey: labelDefaultsKey)
        if historyWalk.graphMode != .all || !rollupStates.isEmpty { reload() }
    }
    @Published private(set) var canFollowRenames = false
    func canToggleHistoryWalk(_ command: HistoryWalkCommand) -> Bool {
        !busy && !isInvalidated && (command != .followRenames || canFollowRenames)
    }
    func toggleHistoryWalk(_ command: HistoryWalkCommand) {
        guard canToggleHistoryWalk(command) else { return }
        retireLogControlMenus()
        historyWalk.toggle(command)
        if historyWalk.followRenames { allBranches = false; referenceScope = .current; showWholeProject = false }
        reload()
    }
    @Published var endRevision: String? {
        didSet { if let endRevision, endRevision != "HEAD" { referenceScope = .current; allBranches = false } }
    }
    @Published var revisionRange: HistoryRevisionRange? {
        didSet { if revisionRange != nil { referenceScope = .current; allBranches = false } }
    }
    @Published var historyPaths: [String] = []
    @Published var showWholeProject = true
    var canChangeWholeProject: Bool { !busy && canEditPathFilter && !historyPaths.isEmpty && !historyWalk.followRenames }
    func setWholeProject(_ enabled: Bool) {
        guard canChangeWholeProject, enabled != showWholeProject else { return }
        showWholeProject = enabled
        HistoryWholeProjectPreference.save(enabled, root: repository.root, defaults: labelDefaults)
        updatePathScopeTitle()
        reload()
    }
    private func updatePathScopeTitle() {
        let location = RepositoryPresentationSettings.scopedLocation(repository: repository.root, paths: historyPaths.map { RepositoryBrowserGitPath.display(key:$0) }, wholeProject: showWholeProject)
        let scope = revisionRange.map { " " + $0.expression } ?? endRevision.map { " at " + $0.prefix(7) } ?? ""
        RepositoryWindowTitles.set(window, repository: repository.root, location: location, dialog: "Log Messages" + scope, preferences: labelDefaults)
    }
    @Published private(set) var unrelatedPathMode = HistoryUnrelatedPathMode.gray
    @Published private(set) var pathScopes: [HistoryPathScope] = []
    func unrelatedFile(_ file: CommitFile) -> Bool {
        !showWholeProject && !pathScopes.isEmpty && file.action != "?" && !pathScopes.contains { $0.contains(file) }
    }
    func grayFile(_ file: CommitFile) -> Bool { unrelatedPathMode == .gray && unrelatedFile(file) }
    func toggleUnrelatedPaths(_ mode: HistoryUnrelatedPathMode) {
        guard !busy, !isInvalidated, mode != .all else { return }
        retireLogControlMenus()
        invalidateFileSelection(); unrelatedPathMode.toggle(mode)
        selectedFiles.formIntersection(GitPathSet(visibleFiles.map(\.id)))
        if fileSelectionMark.map({ !selectedFiles.contains($0) }) == true { fileSelectionMark = visibleFiles.first { selectedFiles.contains($0.id) }?.id }
    }
    func toggleUnversionedFiles() {
        guard !busy, !isInvalidated else { return }
        retireLogControlMenus()
        showUnversionedFiles.toggle(); labelDefaults.set(showUnversionedFiles, forKey: "AddBeforeCommit"); updateWorkingFiles()
        selectedFiles.formIntersection(GitPathSet(visibleFiles.map(\.id)))
    }
    var colorPreferences: UserDefaults { labelDefaults }
    func fileForeground(_ file: CommitFile, selected: Bool) -> Color {
        file.statusTextColor(selected: selected, gray: grayFile(file), preferences: labelDefaults)
    }
    typealias HistoryProjection = (entries: [LogEntry], graph: [CommitGraphRow], rollups: [String: HistoryRollupInfo])
    struct HistoryProjectionInput: Sendable {
        let entries: [LogEntry]
        let walk: HistoryWalkOptions
        let references: HistoryReferenceVisibility
        let rollupStates: [String: HistoryRollupChoice]
        let cancellation: OperationCancellation
        let isFinal: Bool
    }
    var readHistoryProjection: @Sendable (HistoryProjectionInput) throws -> HistoryProjection = { input in
        try CommitGraph.project(input.entries, walk: input.walk, references: input.references,
                                rollupStates: input.rollupStates, cancellation: input.cancellation)
    }
    private struct HistoryProjectionJob {
        let input: HistoryProjectionInput
        let generation: Int
        let historyCancellation: OperationCancellation
        let reply: CheckedContinuation<HistoryProjection, Error>?
    }
    private var pendingHistoryProjection: HistoryProjectionJob?
    private var historyProjectionTask: Task<Void, Never>?
    private var historyProjectionCancellation: OperationCancellation?
    private var finalProjectionGeneration: Int?
    private var acceptedProjectionCount = 0
    private(set) static var activeHistoryProjectionWorkers = 0
    var historyProjectionWorkPending: Bool { historyProjectionTask != nil || pendingHistoryProjection != nil }
    private func retireHistoryProjections() {
        historyProjectionCancellation?.cancel()
        pendingHistoryProjection?.input.cancellation.cancel()
        pendingHistoryProjection?.reply?.resume(throwing: OperationCancellationFailure.cancelled)
        pendingHistoryProjection = nil
        finalProjectionGeneration = nil; acceptedProjectionCount = 0
    }
    private func enqueueHistoryProjection(_ job: HistoryProjectionJob) {
        pendingHistoryProjection?.input.cancellation.cancel()
        pendingHistoryProjection?.reply?.resume(throwing: OperationCancellationFailure.cancelled)
        pendingHistoryProjection = job
        // One worker must drain before its replacement starts. Cancellation is
        // cooperative through graph traversal, never an unowned detached task.
        historyProjectionCancellation?.cancel()
        guard historyProjectionTask == nil else { return }
        historyProjectionTask = Task { [self, access] in
            defer { historyProjectionTask = nil; historyProjectionCancellation = nil; withExtendedLifetime(access) {} }
            while let current = pendingHistoryProjection {
                pendingHistoryProjection = nil
                historyProjectionCancellation = current.input.cancellation
                let compute = readHistoryProjection, input = current.input
                Self.activeHistoryProjectionWorkers += 1
                let projectionBegan = ProcessInfo.processInfo.systemUptime
                NativeDialogStartupTrace.mark("log.projection.started", count: input.entries.count)
                let outcome: Result<HistoryProjection, Error>
                do { outcome = .success(try await Task.detached(priority: .userInitiated) { try compute(input) }.value) }
                catch { outcome = .failure(error) }
                Self.activeHistoryProjectionWorkers -= 1
                NativeDialogStartupTrace.mark("log.projection.settled", began: projectionBegan, count: input.entries.count)
                historyProjectionCancellation = nil
                let live = current.generation == generation && historyCancellation === current.historyCancellation &&
                    !isInvalidated && !current.historyCancellation.isCancelled && !input.cancellation.isCancelled
                if !live {
                    current.reply?.resume(throwing: OperationCancellationFailure.cancelled)
                    continue
                }
                switch outcome {
                case .success(let projection):
                    if let reply = current.reply { reply.resume(returning: projection) }
                    else if finalProjectionGeneration != current.generation, input.entries.count >= acceptedProjectionCount {
                        acceptedProjectionCount = input.entries.count
                        entries = projection.entries; graph = projection.graph; rollupInfo = projection.rollups
                        // A refresh can retain a highlighted immutable hash
                        // without another native selection notification. Bind
                        // its file read to this load as soon as that shown row
                        // arrives, rather than exposing old details until EOF.
                        if detailHistoryGeneration != current.generation,
                           prefixDetailBindingGeneration != current.generation,
                           let revision,!revision.hash.isEmpty {
                            prefixDetailBindingGeneration=current.generation
                            select(selected,mark:selectionMark,recordNavigation:false)
                        }
                        searchHighlights = [:]; historySourceRowCount = input.entries.count
                    }
                case .failure(let error):
                    if let reply = current.reply { reply.resume(throwing: error) }
                    else if !(error is OperationCancellationFailure), !input.cancellation.isCancelled { self.error = error.localizedDescription }
                }
            }
        }
    }
    private func finalHistoryProjection(_ rows: [LogEntry], request: Int, cancellation: OperationCancellation,
        walk: HistoryWalkOptions, references: HistoryReferenceVisibility, states: [String: HistoryRollupChoice]) async throws -> HistoryProjection {
        try cancellation.check()
        guard request == generation, historyCancellation === cancellation, !isInvalidated else { throw OperationCancellationFailure.cancelled }
        finalProjectionGeneration = request
        return try await withCheckedThrowingContinuation { reply in
            let input = HistoryProjectionInput(entries: rows, walk: walk, references: references, rollupStates: states,
                                               cancellation: OperationCancellation(), isFinal: true)
            enqueueHistoryProjection(.init(input: input, generation: request, historyCancellation: cancellation, reply: reply))
        }
    }
    private var detailCancellation: OperationCancellation?
    private var historyCancellation: OperationCancellation?
    private struct HistoryRestore {
        let entries: [LogEntry], graph: [CommitGraphRow], rollups: [String: HistoryRollupInfo]
        let highlights: [String: [String: [NSRange]]]
        let sourceRowCount: Int?
        let selected: Set<String>, mark: String?
    }
    private var detailHistoryGeneration: Int?
    private var prefixDetailBindingGeneration: Int?
    private var historyRestore: HistoryRestore?
    private var provisionalHistory: [LogEntry] = []
    private var nextHistoryPublication = 128
    private func restoreHistorySnapshot() {
        retireHistoryProjections()
        if let snapshot = historyRestore {
            let available = Set(snapshot.entries.map(\.hash))
            let keepsCurrent = !selected.isEmpty && selected.isSubset(of: available)
            let restoredSelection = keepsCurrent ? selected : snapshot.selected.intersection(available)
            let restoredMark = keepsCurrent ? selectionMark : snapshot.mark
            entries = snapshot.entries; graph = snapshot.graph; rollupInfo = snapshot.rollups
            searchHighlights = snapshot.highlights; historySourceRowCount = snapshot.sourceRowCount
            selected = restoredSelection; selectionMark = restoredMark.flatMap { restoredSelection.contains($0) ? $0 : nil }
        }
        historyRestore = nil; provisionalHistory = []; nextHistoryPublication = 128
    }
    private func publishHistoryBatch(_ batch: [LogEntry], request: Int, cancellation: OperationCancellation, walk: HistoryWalkOptions, references: HistoryReferenceVisibility, states: [String: HistoryRollupChoice]) {
        guard request == generation, historyCancellation === cancellation, !isInvalidated, !cancellation.isCancelled,
              finalProjectionGeneration != request else { return }
        provisionalHistory += batch
        guard provisionalHistory.count == batch.count || provisionalHistory.count >= nextHistoryPublication else { return }
        // Doubling prefixes bounds cumulative graph work to a small multiple of
        // the walk length instead of rebuilding it for every arriving chunk.
        nextHistoryPublication = max(128, provisionalHistory.count * 2)
        let input = HistoryProjectionInput(entries: provisionalHistory, walk: walk, references: references, rollupStates: states,
                                           cancellation: OperationCancellation(), isFinal: false)
        enqueueHistoryProjection(.init(input: input, generation: request, historyCancellation: cancellation, reply: nil))
    }
    @Published private(set) var loadedRevisionCount = 0
    var loadingHistory: Bool { historyCancellation != nil }
    @Published var issueProperties = IssueTrackerProperties()
    @Published var search = ""
    @Published var searchFields = LogSearchSelection.load()
    @Published var searchRegex = UserDefaults.standard.bool(forKey: "UseRegexFilter")
    @Published var searchCaseSensitive = UserDefaults.standard.bool(forKey: "FilterCaseSensitively")
    @Published private(set) var searchFilterError: String?
    @Published private(set) var pathFilterDraft = ""
    static private(set) var activeFilterValidations = 0
    private var searchFilterTask: Task<Void, Never>?
    private var searchFilterCancellation: OperationCancellation?
    private var searchFilterGeneration = 0
    private var pathFilterTask: Task<Void, Never>?
    private var pathFilterGeneration = 0
    var readSearchValidation: ((String, Bool, OperationCancellation) async throws -> Bool)?
    var canEditPathFilter: Bool { !isInvalidated && !confirmingQuit && !fileNavigationReadPending && !referencePickerBlocked && !findBlocked && !orderingBlocked && unifiedSessions.isEmpty && followedSession == nil && window?.attachedSheet == nil }
    var canEditLogFilters: Bool { canEditPathFilter && (!busy || loadingHistory) }
    var canUseSourceCommands: Bool {
        !isInvalidated && !confirmingQuit && (!busy || loadingHistory) && !jumping && !loadingNote && !savingNote && noteRequest == nil &&
            !findBlocked && !orderingBlocked && !referencePickerBlocked && !copyingDetails && !unifiedViewerBusy && unifiedSessions.isEmpty && followedSession == nil && !fileNavigationReadPending && window?.attachedSheet == nil && NSApp.modalWindow == nil
    }
    /// Explicit Refresh clears the history filter in CLogDlg::Refresh(true).
    /// Background/selection refreshes continue to call reload() and retain it.
    func refreshFromSourceCommand() {
        guard canUseSourceCommands else { return }
        cancelSearchFilter(); searchFilterError = nil; search = ""; reload()
    }
    @discardableResult func clearHistoryFilterFromSourceCommand() -> Bool {
        guard canUseSourceCommands, !search.isEmpty || !appliedMessageSearch.query.isEmpty else { return false }
        refreshFromSourceCommand(); return true
    }
    func editSearch(_ text: String, submit: Bool = false) {
        guard canEditLogFilters else { return }
        search = text; scheduleSearchFilter(immediate: submit || text.isEmpty, validateRegex: !submit)
    }
    func submitSearch() { guard canEditLogFilters else { return }; scheduleSearchFilter(immediate: true, validateRegex: false) }
    private func cancelSearchFilter() {
        searchFilterGeneration += 1; searchFilterTask?.cancel(); searchFilterTask = nil
        searchFilterCancellation?.cancel(); searchFilterCancellation = nil
    }
    private func scheduleSearchFilter(immediate: Bool = false, validateRegex: Bool = true) {
        cancelSearchFilter(); searchFilterError = nil
        let request = searchFilterGeneration, text = search, regex = searchRegex, sensitive = searchCaseSensitive
        let token = OperationCancellation(); searchFilterCancellation = token
        searchFilterTask = Task { [weak self] in
            defer { if let self, request == searchFilterGeneration { searchFilterTask = nil; searchFilterCancellation = nil } }
            do {
                if !immediate { try await Task.sleep(nanoseconds: 1_000_000_000) }
                // A timer must not replace a Git mutation or an owned sheet.
                while let owner = self, !owner.isInvalidated, !owner.canEditLogFilters {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard let self, !isInvalidated, request == searchFilterGeneration, !Task.isCancelled else { return }
                if regex && !text.isEmpty && validateRegex {
                    Self.activeFilterValidations += 1
                    let valid: Bool
                    do {
                        defer { Self.activeFilterValidations -= 1 }
                        if let readSearchValidation { valid = try await readSearchValidation(text, sensitive, token) }
                        else {
                            let executable = historyRegexExecutable
                            valid = try await Task.detached(priority: .userInitiated) {
                                try IssueRegexRuntime.validateLogPattern(text, caseSensitive: sensitive, executable: executable, cancellation: token)
                            }.value
                        }
                    }
                    guard !isInvalidated, request == searchFilterGeneration, !token.isCancelled else { return }
                    guard valid else { searchFilterError = "Invalid regular expression"; return }
                }
                while !isInvalidated, request == searchFilterGeneration, !canEditLogFilters {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard request == searchFilterGeneration, !token.isCancelled, canEditLogFilters else { return }
                reload()
            } catch {
                guard let self, !isInvalidated, request == searchFilterGeneration, !token.isCancelled, !Task.isCancelled else { return }
                searchFilterError = error.localizedDescription
            }
        }
    }
    func editPathFilter(_ text: String, submit: Bool = false) {
        guard canEditPathFilter else { return }
        pathFilterGeneration += 1; pathFilterTask?.cancel(); pathFilterTask = nil; pathFilterDraft = text
        if submit || text.isEmpty { filterPaths = text; return }
        let request = pathFilterGeneration
        pathFilterTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                while let owner = self, !owner.isInvalidated, !owner.canEditPathFilter {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch { return }
            guard let self, canEditPathFilter, request == pathFilterGeneration else { return }
            filterPaths = text; pathFilterTask = nil
        }
    }
    static private(set) var activeNoteReads = 0
    static private(set) var activeNoteSaves = 0
    var readNote: ((String, OperationCancellation) async throws -> (CommitNoteSnapshot, ProjectDialogSettings))?
    var writeNote:((CommitNoteSnapshot,String,OperationCancellation)async throws->String)?
    var prepareNoteIdentity:((OperationCancellation)async throws->Bool)?
    var noteIdentitySession:NoteIdentitySession?
    private(set) var noteOperationRepository:GitRepository?
    var noteAccess:RepositoryAccessLease? {access}
    private var noteReadWorkers=0
    private var noteSaveCancellation:OperationCancellation?
    @Published var noteCompletionWarning:String?
    @Published var noteWarningPending=false
    var noteWorkPending:Bool {noteReadWorkers>0 || savingNote || noteWarningPending || noteIdentitySession?.hasPendingWork==true}

    var onShowNote: ((CommitNoteSnapshot, ProjectDialogSettings) -> Void)?
    private(set) var noteIssueProperties = IssueTrackerProperties()
    @Published var noteRequest: CommitNoteSnapshot?
    @Published var noteText = ""
    @Published var noteError: String?
    @Published var loadingNote = false
    @Published var savingNote = false
    private var noteCancellation: OperationCancellation?
    private var noteGeneration = 0
    var selectedIsStash: Bool {
        guard let revision else { return false }
        return isStash(revision)
    }
    private func isStash(_ revision: LogEntry) -> Bool {
        if revision.references.contains(where: { $0.name == "refs/stash" }) { return true }
        if let index = entries.firstIndex(where: { $0.hash == revision.hash }), index > 0 {
            let previous = entries[index - 1]
            if previous.references.contains(where: { $0.name == "refs/stash" }), previous.parents.count == 2, previous.parents[1] == revision.hash { return true }
        }
        return false
    }
    var cherryPickSelection: [LogEntry] { entries.filter { selected.contains($0.hash) } }
    var cherryPickAvailable: Bool {
        let chosen = cherryPickSelection
        return !includesWorkingTree && !chosen.isEmpty && chosen.count == selected.count && !bare && !mergeActive && chosen.first?.isHead == false
    }
    var canCherryPick: Bool { cherryPickAvailable && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil && onCherryPick != nil }
    func requestCherryPick() {
        guard canCherryPick else { return }
        onCherryPick?(cherryPickSelection.map(\.hash))
    }
    var integrationAvailable: Bool { !isInvalidated && revision != nil && revision?.isHead == false && !bare && !mergeActive && !selectedIsStash }
    func canIntegrate(_ command: LogIntegrationCommand) -> Bool {
        integrationAvailable && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil && !copyingDetails && !referencePickerBlocked && !orderingBlocked && !findBlocked && (command == .merge ? onMergeRevision != nil : onRebaseRevision != nil || onPreparedRebase != nil)
    }
    func integrationTitle(_ command: LogIntegrationCommand) -> String {
        let branch = currentBranch.isEmpty ? "HEAD" : currentBranch
        return command == .merge ? "Merge to \"\(branch)\"…" : "Rebase \"\(branch)\" onto this…"
    }
    private(set) var acceptedNavigationRepository:GitRepository?
    private var integrationCancellation:OperationCancellation?
    private var closeAfterIntegrationRead = false
    var readIntegration:((LogIntegrationPreparation,OperationCancellation) async throws -> String)?
    @discardableResult func cancelIntegrationRead(closeAfter:Bool = false) -> Bool {
        guard let token = integrationCancellation else { return false }
        closeAfterIntegrationRead = closeAfterIntegrationRead || closeAfter; token.cancel(); return true
    }
    func requestIntegration(_ command:LogIntegrationCommand,target:LogReferenceMenuTarget? = nil) {
        guard canIntegrate(command), integrationCancellation == nil, let chosen = revision else { return }
        let pointed:RevisionReference?
        if let target { guard command == .merge, let reference = reference(for:target) else { return }; pointed = reference }
        else { pointed = nil }
        let preparation = LogIntegrationPreparation(command:command,entry:chosen,pointed:pointed)
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        acceptedNavigationRepository=repository
        let request = generation, selection = selected, token = OperationCancellation()
        integrationCancellation = token; closeAfterIntegrationRead = false
        busy = true; error = nil; Self.activeReferenceReads += 1
        Task {
            defer {
                Self.activeReferenceReads -= 1; withExtendedLifetime(access) {}
                if integrationCancellation === token {
                    integrationCancellation = nil; busy = false
                    let shouldClose = closeAfterIntegrationRead; closeAfterIntegrationRead = false
                    if shouldClose, !isInvalidated { close() }
                }
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let destination:String
                if let readIntegration { destination = try await readIntegration(preparation,token) }
                else { destination = try await preparation.read(repository:repository,cancellation:token) }
                guard !isInvalidated, !confirmingQuit, request == generation, selected == selection, integrationCancellation === token, !token.isCancelled else { return }
                if let target, reference(for:target) == nil { throw LogIntegrationFailure.stale }
                // Release this read before a child callback starts another owned
                // load; the old defer must not clear that newer busy state.
                integrationCancellation = nil; busy = false
                if command == .merge { onMergeRevision?(destination) }
                else if let onPreparedRebase { onPreparedRebase(preparation) }
                else { onRebaseRevision?(destination) }
            } catch {
                if !isInvalidated, request == generation, integrationCancellation === token, !token.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    var canEditNotes: Bool { !isInvalidated && !confirmingQuit && !noteWarningPending && revision != nil && !busy && !jumping && !loadingNote && !savingNote && !noteWarningPending && noteRequest == nil && !selectedIsStash }
    var canSaveNote: Bool { !savingNote && noteRequest?.accepts(noteText) == true }
    private func cancelNoteRead() {
        noteCancellation?.cancel();noteIdentitySession?.cancel(); noteCancellation = nil; loadingNote = false; noteGeneration += 1
    }
    func editNotes() {
        guard canEditNotes, let revision else { return }
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        noteOperationRepository=repository
        cancelNoteRead(); noteIssueProperties = IssueTrackerProperties(); let token = OperationCancellation(); noteCancellation = token
        let request = noteGeneration; loadingNote = true; error = nil
        Self.activeNoteReads += 1;noteReadWorkers += 1
        Task { [self,access] in
            defer { Self.activeNoteReads -= 1;noteReadWorkers -= 1;withExtendedLifetime(access){} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let identityReady:Bool
                if let prepareNoteIdentity {identityReady=try await prepareNoteIdentity(token)}else{identityReady=try await repository.replayUserIdentity(cancellation:token).complete}
                guard !isInvalidated,request==noteGeneration,noteCancellation === token,!token.isCancelled else{return}
                guard identityReady else{noteCancellation=nil;loadingNote=false;return}
                let note: CommitNoteSnapshot, settings: ProjectDialogSettings
                if let readNote { (note, settings) = try await readNote(revision.hash, token) }
                else {
                    note = try await repository.editableCommitNote(revision: revision.hash, cancellation: token)
                    settings = try await repository.projectDialogSettings(source: .effective, cancellation: token)
                    let properties = try await repository.issueTrackerProperties(cancellation: token)
                    guard !isInvalidated, request == noteGeneration,!token.isCancelled else { return }
                    noteIssueProperties = properties
                }
                guard !isInvalidated, request == noteGeneration,!token.isCancelled else { return }
                noteCancellation = nil; loadingNote = false; noteText = note.text; noteError = nil; noteRequest = note
                onShowNote?(note, settings)
            } catch {
                guard request == noteGeneration else { return }
                noteCancellation = nil; loadingNote = false
                if !token.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func cancelPendingNoteRead() { cancelNoteRead() }
    func cancelNote() { guard !savingNote else { return }; noteRequest = nil; noteText = ""; noteError = nil }
    private func beginNoteSave(_ note:CommitNoteSnapshot,text:String,token:OperationCancellation)->Bool {
        guard !isInvalidated,!confirmingQuit,!savingNote,!token.isCancelled,noteRequest.map({GitReferenceName.equal($0.revision,note.revision) && GitReferenceName.equal($0.notesRef,note.notesRef) && $0.text.utf8.elementsEqual(note.text.utf8) && $0.minimumLength==note.minimumLength})==true,note.accepts(text) else{return false}
        savingNote=true;busy=true;noteError=nil;noteSaveCancellation=token;Self.activeNoteSaves += 1
        return true
    }
    func saveNote() {
        guard canSaveNote,let note=noteRequest else{return}
        let text=noteText,token=OperationCancellation()
        guard beginNoteSave(note,text:text,token:token) else{return}
        Task {
            do {try await persistNote(note,text:text,cancellation:token);if !isInvalidated{cancelNote()}}
            catch {if !isInvalidated{noteError=error.localizedDescription}}
        }
    }
    func saveNoteText(_ note:CommitNoteSnapshot,text:String,cancellation:OperationCancellation?=nil)async throws {
        let token=cancellation ?? OperationCancellation()
        guard beginNoteSave(note,text:text,token:token) else{throw CommitNoteFailure.invalidText}
        try await persistNote(note,text:text,cancellation:token)
    }
    private func persistNote(_ note:CommitNoteSnapshot,text:String,cancellation token:OperationCancellation)async throws {
        let repository=noteOperationRepository ?? self.repository.capturingDiffBackend(preferences:labelDefaults)
        defer{savingNote=false;busy=false;Self.activeNoteSaves -= 1;if noteSaveCancellation === token{noteSaveCancellation=nil};withExtendedLifetime(access){}}
        guard !isInvalidated else{throw OperationCancellationFailure.cancelled}
        try token.check()
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true){throw RepositoryAccessFailure.securityScopeUnavailable}
        do {
            let display:String
            if let writeNote{display=try await writeNote(note,text,token)}else{display=try await repository.saveCommitNote(note,text:text,cancellation:token)}
            guard !isInvalidated,noteSaveCancellation === token else{return}
            if let index=entries.firstIndex(where:{$0.hash==note.revision}){entries[index].notes=display}
            DispatchQueue.main.async{ [weak self] in
                guard let self,!self.isInvalidated else{return};self.onRevisionChanged("Saved note for "+note.revision)
            }
        } catch let failure as CommitNoteFailure {
            if case .savedButRefreshFailed = failure,!isInvalidated {
                noteCompletionWarning=failure.localizedDescription
                onRevisionChanged(failure.localizedDescription)
            }
            throw failure
        }
    }
    @Published var jumpKind = HistoryJumpKind.authorEmail
    @Published var jumping = false
    @Published var searchHighlights: [String: [String: [NSRange]]] = [:]
    @Published var highlightedRevision: String?
    @Published var scrollRevision: String?
    @Published var scrollRequest = 0
    @Published var navigationNotice: String?
    var selectionNavigation = HistorySelectionNavigation()
    private(set) var selectionMark: String?
    var canNavigateLog: Bool { canFollowMessageLink && jumpAlert == nil }
    func chooseJumpKind(_ kind:HistoryJumpKind) { guard canNavigateLog else{return};jumpKind=kind }
    func canJump(up:Bool)->Bool {
        guard canNavigateLog else{return false}
        if jumpKind == .selectionHistory {return canMoveHistory(up:up)}
        guard !includesWorkingTree,!selected.isEmpty,let first=entries.first,!selected.contains(first.hash) else{return false}
        // Do not scan all candidate ancestry/labels on every view update. The
        // captured jump operation resolves candidates and reports no more hits.
        if !up && (jumpKind == .parent1 || jumpKind == .parent2) {
            let parent=jumpKind == .parent2 ? 1:0
            return entries.first(where:{selected.contains($0.hash)}).map{$0.parents.count>parent} ?? false
        }
        return true
    }
    func canMoveHistory(up:Bool) -> Bool {
        canNavigateLog && !selectionNavigation.hashes.isEmpty && (up ? selectionNavigation.location > 0:selectionNavigation.location + 1 < selectionNavigation.hashes.count)
    }
    func moveSelectionHistory(up:Bool,selectTarget:Bool) {
        guard canNavigateLog else {return}
        highlightedRevision = nil;navigationNotice = nil
        guard let hash = selectionNavigation.move(up:up) else {return}
        guard entries.contains(where:{$0.hash == hash}) else {navigationNotice = "The revision \(hash) is not visible in the current log.";return}
        if selectTarget {select([hash],recordNavigation:false)} else {highlightedRevision = hash}
        scrollRevision = hash;scrollRequest += 1
    }
    func pasteGitHash() {
        guard canNavigateLog,let text = clipboard.string(forType:.string)?.trimmingCharacters(in:.whitespacesAndNewlines),
              text.count >= HistoryMessageOptions(defaults:labelDefaults).minimumHashLength,text.count <= 40,
              text.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}),
              let current = selectionMark.flatMap({selected.contains($0) ? $0:nil}) ?? entries.first(where:{selected.contains($0.hash)})?.hash else {return}
        guard let hash = HistoryMessageHash.target(prefix:text,hashes:entries.map(\.hash),current:current) else {showJumpNotFound();return}
        select([hash]);scrollRevision = hash;scrollRequest += 1
    }
    func handleNavigation(_ event:NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.type == .otherMouseUp,[3,4].contains(event.buttonNumber),flags.isEmpty || flags == .shift {
            moveSelectionHistory(up:event.buttonNumber == 3,selectTarget:flags.isEmpty);return true
        }
        guard event.type == .keyDown else {return false}
        if [123,124].contains(event.keyCode),flags == .option || flags == [.option,.shift] {
            moveSelectionHistory(up:event.keyCode == 123,selectTarget:!flags.contains(.shift));return true
        }
        if flags == .command || flags == [.command,.shift],let key = event.charactersIgnoringModifiers,["[", "]", "{", "}"].contains(key) {
            moveSelectionHistory(up:key == "[" || key == "{",selectTarget:!flags.contains(.shift));return true
        }
        if [125,126].contains(event.keyCode),flags == .option {
            if canNavigateLog {jump(up:event.keyCode == 126)};return true
        }
        if event.keyCode == 9,flags == .control || flags == .command {pasteGitHash();return true}
        if event.keyCode == 114,flags == .shift {pasteGitHash();return true}
        return false
    }
    private var jumpCancellation: OperationCancellation?
    private var jumpGeneration = 0
    private func cancelJump() {
        jumpCancellation?.cancel(); jumpCancellation = nil; jumping = false; jumpGeneration += 1
    }
    func jump(up: Bool) {
        guard canNavigateLog else { return }
        if jumpKind == .selectionHistory {moveSelectionHistory(up:up,selectTarget:false);return}
        guard !includesWorkingTree else {return}
        let repository = self.repository.capturingDiffBackend(preferences:labelDefaults)
        // Candidate indices follow the displayed source list, including its working-tree row.
        let snapshot = entries, selection = selected, kind = jumpKind
        guard kind.candidates(entries: snapshot, selected: selection, up: up) != nil else { return }
        select([])
        let token = OperationCancellation(); jumpCancellation = token; let request = jumpGeneration
        jumping = true; Self.activeActionReads += 1
        Task {
            defer { Self.activeActionReads -= 1; withExtendedLifetime(access) {} }
            do {
                let index = try await repository.historyJump(entries: snapshot, selected: selection, kind: kind, up: up, cancellation: token)
                guard request == jumpGeneration else { return }
                jumpCancellation = nil; jumping = false
                if let index { let hash = snapshot[index].hash; select([hash]); scrollRevision = hash; scrollRequest += 1 }
                else { showJumpNotFound() }
            } catch {
                guard request == jumpGeneration else { return }
                jumpCancellation = nil; jumping = false
                if !token.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    private var jumpAlert: NSAlert?
    private func showJumpNotFound() {
        guard !isInvalidated, jumpAlert == nil, !labelDefaults.bool(forKey: "NoJumpNotFoundWarning") else { return }
        guard let window, window.attachedSheet == nil else { navigationNotice = "No more revisions found."; return }
        let alert = NSAlert(); alert.messageText = "No more revisions found."; alert.alertStyle = .informational
        alert.addButton(withTitle: "OK"); alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not show this message again"
        jumpAlert = alert
        alert.beginSheetModal(for: window) { [weak self] _ in
            guard let self, !self.isInvalidated, self.jumpAlert === alert else { return }; self.jumpAlert = nil
            if alert.suppressionButton?.state == .on { self.labelDefaults.set(true, forKey: "NoJumpNotFoundWarning") }
        }
    }
    @Published var filterPaths = "" { didSet {
        invalidateFileSelection()
        pathFilterDraft = filterPaths
        let visible = GitPathSet(visibleFiles.map(\.id)), retained = selectedFiles.intersection(visible)
        if fileSelectionMark.map({ !retained.contains($0) }) == true { fileSelectionMark = visibleFiles.first { retained.contains($0.id) }?.id }
        if focusedChangedFile.map({ !visible.contains($0) }) == true { focusedChangedFile = nil }
        if retained != selectedFiles { selectedFiles = retained } else { refreshPatchPreview() }
    } }
    @Published var from = Date(timeIntervalSince1970: 0)
    @Published var to = Date()
    @Published private(set) var historyLimit = HistoryLimitScope()
    @Published var configureHistoryDefaults = false
    private var initializedHistoryLimit = false
    var useDates: Bool {
        get { historyLimit.scale == .selectedDate || historyLimit.until != nil }
        set {
            if newValue { historyLimit.scale = .selectedDate; historyLimit.from = HistoryLimitScope.startOfDay(from); historyLimit.until = HistoryLimitScope.endOfDay(to) }
            else { historyLimit.from = nil; historyLimit.until = nil; if historyLimit.scale != .commits { historyLimit.scale = .noLimit } }
        }
    }
    var historyLimitTitle: String { historyLimit.scale.requiresNumber ? historyLimit.scale.title(number: historyLimit.number) : "From:" }
    var defaultHistoryLimitScale: HistoryLimitScale { HistoryLimitDefaults.load(defaults: labelDefaults).scale }
    func chooseHistoryLimit(_ scale: HistoryLimitScale) {
        guard canChangeLogControls else { return }; initializedHistoryLimit = true; historyLimit.scale = scale
        if scale == .noLimit { labelDefaults.removeObject(forKey: HistoryLimitDefaults.fromDateKey(root: repository.root)) }
        reload()
    }
    func changeHistoryFrom(_ date: Date) {
        guard canChangeLogControls else {return}
        let selected = HistoryLimitScope.startOfDay(min(Self.boundedHistoryDate(date),to))
        guard historyLimit.from != selected else{return};initializedHistoryLimit = true
        from = selected; historyLimit.from = selected; historyLimit.scale = .selectedDate
        if defaultHistoryLimitScale == .selectedDate { HistoryLimitDefaults.saveFrom(historyLimit.from!, root: repository.root, defaults: labelDefaults) }
        reload()
    }
    func changeHistoryTo(_ date: Date) {
        guard canChangeLogControls else {return}
        let selected = HistoryLimitScope.endOfDay(max(Self.boundedHistoryDate(date),from))
        guard historyLimit.until != selected else{return};initializedHistoryLimit = true
        to = selected; historyLimit.until = selected; reload()
    }
    static var maximumHistoryDate:Date {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone = .current
        return calendar.date(from:DateComponents(year:2100,month:1,day:2,hour:23,minute:59,second:59)) ?? Date(timeIntervalSince1970:4_102_617_599)
    }
    private static func boundedHistoryDate(_ date:Date)->Date {min(max(date,Date(timeIntervalSince1970:0)),maximumHistoryDate)}
    @Published var busy = false {
        didSet { if busy != oldValue { fileMenuGeneration = UUID();if !preservingHistoryFileNavigationOwner {fileDragEpoch=UUID()}; retireLogControlMenus() }; if !busy { scheduleRepositoryRefresh() } }
    }
    private var pendingRepositoryRefresh = false
    private var repositoryRefreshTask: Task<Void, Never>?
    /// Repository completions coalesce while an action/history read is active.
    /// Defer to the next main-actor turn so view updates never start a reload.
    func requestRepositoryRefresh() {
        guard !isInvalidated else { return }
        pendingRepositoryRefresh = true
        scheduleRepositoryRefresh()
    }
    private func scheduleRepositoryRefresh() {
        guard pendingRepositoryRefresh, !busy, !referencePickerBlocked, !isInvalidated, repositoryRefreshTask == nil else { return }
        repositoryRefreshTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.repositoryRefreshTask = nil
            guard self.pendingRepositoryRefresh, !self.busy, !self.referencePickerBlocked, !self.isInvalidated else { return }
            self.pendingRepositoryRefresh = false
            self.reload()
        }
    }
    private func cancelRepositoryRefresh() {
        pendingRepositoryRefresh = false
        repositoryRefreshTask?.cancel(); repositoryRefreshTask = nil
    }
    @Published var bare = true
    @Published var error: String?
    private var unifiedSessions: [UUID: FileListComparisonSession] = [:]
    private var followedSession: FileListComparisonSession?
    private var closeAfterFollowedRead = false
    @discardableResult func cancelFollowedComparison(closeAfter: Bool = false) -> Bool {
        guard let followedSession else { return false }
        closeAfterFollowedRead = closeAfterFollowedRead || closeAfter; followedSession.cancel(); return true
    }
    private var followedPath: String? { historyWalk.followRenames && !showWholeProject && historyPaths.count == 1 ? historyPaths.first : nil }
    private func compareFollowed(from: ComparisonRevision, to: ComparisonRevision, parentOf: String? = nil) {
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        guard canInspectHistory, let path = followedPath, let onFollowedFileComparison else { return }
        if from == .workingTree || to == .workingTree {guard (try? RepositoryBrowserGitPath(key:path).isRepresentable)==true else{error=RepositoryBrowserWindowModel.rawPathReason;return}}
        let rows = entries, selected = self.selected, request = generation, detail = detailGeneration
        let session = FileListComparisonSession(window: window, preferences: labelDefaults)
        followedSession = session; busy = true; error = nil
        Task {
            defer {
                if followedSession === session {
                    followedSession = nil
                    if !loadingHistory, unifiedSessions.isEmpty { busy = false }
                    let shouldClose = closeAfterFollowedRead; closeAfterFollowedRead = false
                    if shouldClose && !isInvalidated { close() }
                }
                withExtendedLifetime(access) {}
            }
            do {
                try await session.run(selectedCount: 1) { [self] token in
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let snapshot = try await repository.followedHistoryComparison(path: path, entries: rows, from: from, to: to, parentOf: parentOf, cancellation: token)
                    guard !isInvalidated, generation == request, detailGeneration == detail, self.selected == selected,
                          followedPath.map({ GitReferenceName.equal($0, path) }) == true, !token.isCancelled else { return }
                    acceptedNavigationRepository=repository
                    ComparisonToolInvocation.$alternate.withValue(session.alternateTool) { onFollowedFileComparison(snapshot, token) }
                }
            } catch { if !isInvalidated, generation == request, detailGeneration == detail, !session.cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    var unifiedWindow: PatchWindowController?
    @Published private(set) var patchPreviewVisible = false
    @Published private(set) var patchPreviewData = Data()
    @Published private(set) var patchPreviewLoading = false
    @Published private(set) var patchPreviewError: String?
    @Published private(set) var patchPreferenceSaving = false
    @Published private(set) var patchPreferenceError: String?
    var onPatchPreviewVisibility: ((Bool) -> Void)?
    var onPatchPreviewContent: ((Data) -> Void)?
    var readPatchPreview: ((LogEntry, [CommitFile]?, OperationCancellation) async throws -> Data)?
    private var patchPreviewCancellation: OperationCancellation?
    private var patchPreviewTask: Task<Void, Never>?
    private var patchPreviewGeneration = 0
    private var patchPreviewPreferenceLoaded = false
    private var patchPreferenceTask: Task<Void, Never>?
    private var patchPreferenceGeneration = 0
    func setPatchPreview(_ visible: Bool) {
        guard !busy, !isInvalidated, visible != patchPreviewVisible else { return }
        retireLogControlMenus()
        changePatchPreview(visible)
    }
    func patchPreviewClosed() {
        guard !isInvalidated, patchPreviewVisible else { return }
        changePatchPreview(false)
    }
    private func changePatchPreview(_ visible: Bool) {
        patchPreviewPreferenceLoaded = true; patchPreviewVisible = visible
        onPatchPreviewVisibility?(visible); refreshPatchPreview()
        patchPreferenceGeneration += 1
        let request = patchPreferenceGeneration, previous = patchPreferenceTask
        patchPreferenceSaving = true; patchPreferenceError = nil
        // Preserve intent order even when rapid toggles enqueue several writes.
        // Persistence never controls whether this session's viewer opens/closes.
        patchPreferenceTask = Task {
            await previous?.value
            do { _ = try await repository.run(["config", "--local", "tgit.logshowpatch", visible ? "true" : "false"]) }
            catch {
                if request == patchPreferenceGeneration, !isInvalidated { patchPreferenceError = error.localizedDescription }
            }
            if request == patchPreferenceGeneration { patchPreferenceSaving = false; patchPreferenceTask = nil }
        }
    }
    private func cancelPatchPreview() {
        patchPreviewGeneration += 1; patchPreviewCancellation?.cancel(); patchPreviewCancellation = nil
        patchPreviewTask?.cancel(); patchPreviewTask = nil; patchPreviewLoading = false
    }
    func refreshPatchPreview() {
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        cancelPatchPreview()
        guard patchPreviewVisible, !isInvalidated else { return }
        patchPreviewData = Data(); patchPreviewError = nil; onPatchPreviewContent?(Data())
        guard selected.count == 1, let entry = selectedWorkingTree ? workingTreeSnapshot?.entry : revision else { return }
        let selection = selected, fileSelection = selectedFiles, request = patchPreviewGeneration
        let chosen = selectedFiles.isEmpty ? nil : visibleFiles.filter { selectedFiles.contains($0.id) }
        let cancellation = OperationCancellation(); patchPreviewCancellation = cancellation; patchPreviewLoading = true
        patchPreviewTask = Task {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
                let bytes: Data
                if let readPatchPreview { bytes = try await readPatchPreview(entry, chosen, cancellation) }
                else { bytes = try await repository.logPatchPreviewData(entry, files: chosen, cancellation: cancellation) }
                guard !Task.isCancelled, request == patchPreviewGeneration, selection == selected, fileSelection == selectedFiles, patchPreviewVisible, !isInvalidated else { return }
                patchPreviewData = bytes; onPatchPreviewContent?(bytes)
            } catch { if request == patchPreviewGeneration, !isInvalidated, !cancellation.isCancelled { patchPreviewError = error.localizedDescription } }
            if request == patchPreviewGeneration { patchPreviewLoading = false; patchPreviewCancellation = nil; patchPreviewTask = nil }
        }
    }
    var unifiedViewerBusy: Bool { unifiedWindow?.model.busy == true || unifiedWindow?.window?.attachedSheet != nil }
    @Published var commandRequest: LogCommandRequest?
    fileprivate var generation = 0
    var messageLoadGeneration: Int { generation }
    var contextMenuGeneration:Int { generation }
    private(set) var isInvalidated = false
    private var detailGeneration = 0
    private let showBranchRevisionNumber: Bool
    @Published private(set) var branchRevisionNumber: String?
    @Published private(set) var describedRevision: String?
    private let fileCache: HistoryFileCache?
    private let describeOptions: HistoryDescribeOptions
    private let asteriskLogPrefix: Bool
    private var clipboardCancellation: OperationCancellation?
    private var clipboardGeneration = 0
    @Published var copyingDetails = false
    var clipboard = NSPasteboard.general
    var onCreateReference: (Bool, String) -> Void = { _, _ in }
    var onPush: (String) -> Void = { _ in }
    var onHistoryPush: ((String, Bool) -> Void)?
    var onHistoryPull: (() -> Void)?
    var onShowHistory: ((String) -> Void)?
    var onShowHistoryRange: ((HistoryRevisionRange) -> Void)?
    var onCommitChangeSets: ((CommitChangeSetComparison) -> Void)?
    var onHistorySVNDCommit: (() -> Void)?
    @Published var contextMenuPolicy: HistoryContextMenuPolicy = .log
    func historyLogAvailable(extended:Bool)->Bool {
        guard let revision else { return false }
        return contextMenuPolicy.showsLog(hasReferences: !revision.references.isEmpty, isStash: selectedIsStash, extended: extended)
    }
    func historyPushAvailable(extended:Bool)->Bool {
        guard let revision else { return false }
        return (!selectedIsStash && revision.references.contains { $0.name.hasPrefix("refs/heads/") || $0.name.hasPrefix("refs/tags/") }) || extended
    }
    func showHistory(extended:Bool) {
        guard canStartHistoryTransport,historyLogAvailable(extended:extended),let revision else { return }
        onShowHistory?(revision.hash)
    }
    var selectedHistoryRanges: [HistoryRevisionRange] {
        let chosen=revisions
        guard !includesWorkingTree,selected.count==2,chosen.count==2 else { return [] }
        return [HistoryRevisionRange(from:chosen[1].hash,to:chosen[0].hash),
                HistoryRevisionRange(from:chosen[0].hash,to:chosen[1].hash),
                HistoryRevisionRange(from:chosen[1].hash,to:chosen[0].hash,kind:.symmetricDifference)]
    }
    func showHistoryRange(_ range:HistoryRevisionRange) {
        guard canStartHistoryTransport,selectedHistoryRanges.contains(range) else { return }
        onShowHistoryRange?(range)
    }
    var continuousHistorySelection: Bool {
        let indices = entries.indices.filter { selected.contains(entries[$0].hash) }
        guard !indices.isEmpty, indices.count == selected.count else { return false }
        return indices.count == 1 || (!historyHasHiddenRows && indices.last! - indices.first! + 1 == indices.count)
    }
    var continuousRevisionSelection: Bool { !includesWorkingTree && continuousHistorySelection }
    var canCompareRevisionSelection: Bool {
        let count=revisions.count
        return selected.count==count && (count==1 || count==2 || continuousRevisionSelection)
    }
    func compareChangeSets(alternate:Bool = false) {
        guard canStartHistoryTransport,!includesWorkingTree,occurrenceSelectionCount==2,revisions.count==2,onCommitChangeSets != nil else { return }
        let chosen=revisions,request=generation,selection=selected,count=occurrenceSelectionCount,projection=historyProjectionEpoch
        let id=UUID(),session=FileListComparisonSession(window:window,preferences:labelDefaults,alternateTool:alternate)
        unifiedSessions[id]=session;busy=true;error=nil
        Task {
            defer { unifiedSessions.removeValue(forKey:id);if request==generation { busy=false };withExtendedLifetime(access) {} }
            do {
                try await session.run(selectedCount:0) { [self] token in
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let comparison=try await repository.commitChangeSets(first:chosen[0].hash,second:chosen[1].hash,cancellation:token)
                    guard request==generation,historyProjectionEpoch==projection,occurrenceSelectionCount==count,selection==selected,!isInvalidated,!token.isCancelled else { return }
                    onCommitChangeSets?(comparison)
                }
            } catch { if request==generation,historyProjectionEpoch==projection,occurrenceSelectionCount==count,selection==selected,!isInvalidated,!session.cancellation.isCancelled { self.error=error.localizedDescription } }
        }
    }
    func svnDCommitFromHistory(extended:Bool) {
        guard canStartHistoryTransport,!bare,hasGitSVN,historyPushAvailable(extended:extended) else { return }
        onHistorySVNDCommit?()
    }
    var canInspectHistory: Bool {
        !isInvalidated && !confirmingQuit && (!busy || loadingHistory) && !jumping && !loadingNote && !savingNote && noteRequest == nil &&
            !findBlocked && !orderingBlocked && !referencePickerBlocked && !copyingDetails && !unifiedViewerBusy && unifiedSessions.isEmpty && followedSession == nil && !fileNavigationReadPending &&
            window?.attachedSheet == nil && NSApp.modalWindow == nil
    }
    private var canStartHistoryTransport: Bool {
        !isInvalidated && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil &&
        !findBlocked && !orderingBlocked && !copyingDetails && !unifiedViewerBusy && window?.attachedSheet == nil
    }
    func pushCaptured(_ entry: LogEntry, pointedName: String?) {
        guard canStartHistoryTransport, !entry.hash.isEmpty else { return }
        if let pointedName, !entry.references.contains(where: { $0.name == pointedName }) { return }
        let explicit = pointedName.flatMap { $0.hasPrefix("refs/remotes/") ? nil : $0 }
        let target = explicit ?? entry.references.first { $0.name.hasPrefix("refs/heads/") }?.name ??
            entry.references.first { $0.name.hasPrefix("refs/tags/") }?.name ?? entry.hash
        let revision = GitReferenceName.removingSuffix("^{}", from: target) ?? target
        if let onHistoryPush { onHistoryPush(revision, explicit == nil) } else { onPush(revision) }
    }
    func pullFromHistory() {
        guard canStartHistoryTransport, !bare, !mergeActive else { return }
        onHistoryPull?()
    }
    var onCheckout: (String) -> Void = { _ in }
    var onSwitchBranch: ((String) -> Void)?
    var confirmReferenceDeletion: (HistoryReferenceDeletion) async -> HistoryReferenceDeleteChoice = { _ in .abort }
    var acknowledgeReferenceDeletionFailure: (String) async -> Void = { _ in }

    var onCherryPick: (([String]) -> Void)?
    var onBrowseRepository: ((String) -> Void)?
    var onShowOrdering: (() -> Void)?
    var onShowContainingReferences: ((String) -> Void)?
    var onContainingLog: ((String?, Bool, HistoryRevisionRange?) -> Void)?
    var onFormatPatch: ((FormatPatchPreset) -> Void)?
    var formatPatchPreset: FormatPatchPreset? {
        guard !includesWorkingTree else { return nil }
        return FormatPatchPreset.logSelection(orderedHashes: entries.filter { !$0.hash.isEmpty }.map(\.hash), selected: selected, hasHiddenRows: historyHasHiddenRows)
    }
    var onReset: (String) -> Void = { _ in }
    var onFollowedFileComparison: ((RevisionComparisonSnapshot, OperationCancellation) -> Void)?
    var onCompare: ((ComparisonRevision, ComparisonRevision) -> Void)?
    var onUnifiedDiff: ((Data, Bool) async throws -> Void)?
    var cancelFileChoice: () -> Void = {}
    var cancelFileOpen: () -> Void = {}
    var presentHistoricalSave: (ComparisonFileContent, String) -> Void = { _, _ in }
    var presentHistoricalOpen: (ComparisonFileContent, HistoricalOpenAction) -> Void = { _, _ in }
    var presentHistoricalExport: (String, [CommitFile]) -> Void = { _, _ in }
    var presentWorkingSave: (String) -> Void = { _ in }
    var presentWorkingExport: ([String]) -> Void = { _ in }
    var presentWorkingOpen: (URL, HistoricalOpenAction) -> Void = { _, _ in }
    var confirmExportFailure: (String) async -> Bool = { _ in false }
    weak var window: NSWindow?
    var onFileLog: ((String, String?) -> Void)?
    var onBlame: ((String, String) -> Void)?
    var onConflictAction: ((RepositoryAction, [String]) -> Void)?
    var onPreparedFileCompare: ((PreparedFileComparisonMark, PreparedFileComparisonMark) -> Void)?
    var onFilePairCompare: ((String, [CommitFile]) -> Void)?
    var onWorkingFiles: ((RepositoryAction, [String]) -> Void)?
    var onWorkingFilePairCompare: (([String]) -> Void)?
    var onFileCompare: ((ComparisonRevision, ComparisonRevision, [String]) -> Void)?
    var onFileComparisons: (([(ComparisonRevision, ComparisonRevision, [String])]) -> Void)?
    var close: () -> Void = {}
    var finishSelection: (LogEntry?) -> Void = { _ in }
    var finishMultipleSelection: ([LogEntry]?) -> Void = { _ in }
    var revisions: [LogEntry] { entries.filter { !$0.hash.isEmpty && selected.contains($0.hash) } }
    var revision: LogEntry? { selected.count == 1 && revisions.count == 1 ? revisions.first : nil }
    var hidesTooManyFiles: Bool { AdvancedListBehavior(defaults: labelDefaults).hidesFileList(count: files.count) }
    var visibleFiles: [CommitFile] {
        guard !hidesTooManyFiles else { return [] }
        let filter = HistoryFileFilter(filterPaths)
        return files.filter { (unrelatedPathMode != .hide || !unrelatedFile($0)) && filter.matches($0) }
    }
    var information: HistoryInformation { .init(entries: entries, selected: selected, files: files, selectedFiles: selectedFiles, visibleFileIDs: GitPathSet(visibleFiles.map(\.id))) }
    @Published private(set) var appliedMessageSearch = HistoryMessageOptions()
    private(set) var messageLinkGeneration = UUID()
    var canFollowMessageLink: Bool {
        !isInvalidated && !confirmingQuit && !busy && !jumping && !findBlocked && !orderingBlocked && !referencePickerBlocked && !loadingNote && !savingNote && noteRequest == nil && !copyingDetails && !unifiedViewerBusy && window?.attachedSheet == nil
    }
    func followMessageHash(_ prefix: String) {
        guard canFollowMessageLink, let revision else { return }
        guard let target = HistoryMessageHash.target(prefix: prefix, hashes: entries.map(\.hash), current: revision.hash) else { showJumpNotFound(); return }
        select([target]); scrollRevision = target; scrollRequest += 1
    }
    var messageDocument: HistoryMessageDocument {
        if selectedWorkingTree, let snapshot = workingTreeSnapshot { return .init(plain: "Working tree changes\n" + snapshot.entry.message + (snapshot.entry.parents.first.map { "\nHEAD: " + $0 } ?? "")) }
        guard let revision else { return .init(plain: selected.isEmpty ? "Select a revision to see its commit message and changed files." : "\(selected.count) revisions selected.") }
        return .init(hash: revision.hash, branchNumber: branchRevisionNumber, describe: describedRevision,
                     subject: revision.historySubject, body: revision.historyBody, notes: revision.notes,
                     tagInfo: HistoryDateSettings.load(defaults: labelDefaults).tagInfo(revision.tagInfo), asterisk: asteriskLogPrefix)
    }
    var message: String { messageDocument.text }
    init(repository: GitRepository, access: RepositoryAccessLease?, selecting: Bool = false, selectingMultiple: Bool = false, labelDefaults: UserDefaults = .standard, gravatar: LogGravatar? = nil, historyRegexExecutable: URL? = nil, historyFileCache: HistoryFileCache = HistoryFileCache()) {
        changedFileColumns = .load(from:labelDefaults,key:Self.changedFileColumnsKey)
        fileCache = (labelDefaults.object(forKey: "EnableLogCache") as? Bool ?? true) ? historyFileCache : nil
        describeOptions = .load(defaults: labelDefaults)
        asteriskLogPrefix = labelDefaults.object(forKey: "AsteriskLogPrefix") == nil || labelDefaults.bool(forKey: "AsteriskLogPrefix")
        let limits = HistoryLimitDefaults.load(defaults: labelDefaults)
        self.historyLimit = HistoryLimitScope(defaults: limits, from: limits.scale == .selectedDate ? HistoryLimitDefaults.savedFrom(root: repository.root, defaults: labelDefaults) : nil)
        self.fullCommitMessageOnLogLine = labelDefaults.bool(forKey: "FullCommitMessageOnLogLine")
        self.drawTagsBranchesOnRightSide = labelDefaults.bool(forKey: "DrawTagsBranchesOnRightSide")
        self.symbolizeRefNames = labelDefaults.bool(forKey: "SymbolizeRefNames")
        self.includeWorkingTreeChanges = labelDefaults.object(forKey: "LogIncludeWorkingTreeChanges") == nil || labelDefaults.bool(forKey: "LogIncludeWorkingTreeChanges")
        self.includeBoundaryCommits = labelDefaults.bool(forKey: "LogIncludeBoundaryCommits")
        self.historyRegexExecutable = historyRegexExecutable
        self.searchFields = LogSearchSelection.load(defaults: labelDefaults)
        self.searchRegex = labelDefaults.bool(forKey: "UseRegexFilter")
        self.searchCaseSensitive = labelDefaults.bool(forKey: "FilterCaseSensitively")
        self.showWholeProject = HistoryWholeProjectPreference.load(root: repository.root, defaults: labelDefaults)
        self.showBranchRevisionNumber = labelDefaults.bool(forKey: "ShowBranchRevisionNumber")
        self.gravatar = gravatar ?? LogGravatar(defaults: labelDefaults)
        sshSettings = SSHTransportSettings(repository: repository); sshSettings.enabled = sshSettings.available
        self.repository = repository; self.access = access; self.selecting = selecting; self.selectingMultiple = selectingMultiple; self.labelDefaults = labelDefaults; showWorkingTree = includeWorkingTreeChanges && !selecting
        showGravatar = labelDefaults.object(forKey: gravatarDefaultsKey) == nil ? labelDefaults.bool(forKey: "EnableGravatar") : labelDefaults.bool(forKey: gravatarDefaultsKey)
        referenceScope = HistoryReferenceScopePreference.load(root: repository.root, defaults: labelDefaults)
        allBranches = referenceScope == .all
        recentReferences = HistoryReferenceRecents(root: repository.root, defaults: labelDefaults).entries
        showUnversionedFiles = labelDefaults.object(forKey: "AddBeforeCommit") == nil || labelDefaults.bool(forKey: "AddBeforeCommit")
        if let stored = labelDefaults.object(forKey: labelDefaultsKey) as? NSNumber, stored.intValue >= 0 {
            referenceVisibility = HistoryReferenceVisibility(rawValue: stored.intValue).intersection(.all).union([.stash, .bisect])
        }
    }
    func applyCommandLine(_ invocation: PrimaryCommandInvocation, paths: [String], selectedRevision: String?) {
        guard !isInvalidated, !busy || loadingHistory else { return }
        historyPaths = paths.contains(".") ? [] : paths; showWholeProject = historyPaths.isEmpty
        historyWalk.followRenames = false
        referenceScope = .current; allBranches = false; startRevisions = []; revisionRange = nil; endRevision = nil
        if let selectedRevision { selected = [selectedRevision] }
        if let expression = invocation.historyExpression, let selection = HistoryReferenceSelection(expression: expression) {
            referenceScope = .current; allBranches = false; startRevisions = []
            switch selection {
            case .range(let range): revisionRange = range; endRevision = nil
            case .tips(let names): revisionRange = nil; endRevision = names.count == 1 ? names[0] : nil; startRevisions = names.count > 1 ? names : []
            }
        }
        if let limit = invocation.historyLimit { historyLimit = limit; initializedHistoryLimit = true }
        // Configure directly before the requested reload; do not persist launch
        // presets or schedule competing debounced reads as if the user typed.
        if let fields = invocation.searchFields { searchFields = fields }
        if let regex = invocation.searchRegex { searchRegex = regex }
        if let search = invocation.search { self.search = search }
    }
    func selectSearchFields(_ fields: HistorySearchFields) {
        guard canEditLogFilters else { return }
        searchFields = fields.intersection(LogSearchSelection.all)
        labelDefaults.set(searchFields.rawValue, forKey: "SelectedLogFilters")
        if !search.isEmpty { scheduleSearchFilter() }
    }
    func toggleSearchFields() { selectSearchFields(LogSearchSelection.all.subtracting(searchFields)) }
    func selectAllSearchFields() { selectSearchFields(LogSearchSelection.all) }
    func setSearchRegex(_ enabled: Bool) {
        guard canEditLogFilters else { return }
        searchRegex = enabled
        labelDefaults.set(enabled, forKey: "UseRegexFilter")
        if !search.isEmpty { scheduleSearchFilter() }
    }
    func setSearchCaseSensitive(_ enabled: Bool) {
        guard canEditLogFilters else { return }
        searchCaseSensitive = enabled
        labelDefaults.set(enabled, forKey: "FilterCaseSensitively")
        if !search.isEmpty { scheduleSearchFilter() }
    }
    var canAcceptSelection: Bool { !busy && (selectingMultiple ? !selected.isEmpty && entries.filter { selected.contains($0.hash) }.count == selected.count : revision != nil) }
    func accept() {
        if selecting {
            guard canAcceptSelection else { return }
            if selectingMultiple { finishMultipleSelection(entries.filter { selected.contains($0.hash) }) }
            else if let revision { finishSelection(revision) }
        }
        else { close() }
    }
    func setPathScope(_ paths: [String]) {
        guard !isInvalidated, !referencePickerBlocked, !busy || loadingHistory else { return }
        let scope = paths.contains(".") ? [] : paths
        let whole = HistoryWholeProjectPreference.load(root: repository.root, defaults: labelDefaults)
        guard historyPaths.map({ GitReferenceName($0) }) != scope.map({ GitReferenceName($0) }) || showWholeProject != whole else { return }
        historyWalk.followRenames = false; canFollowRenames = false
        historyPaths = scope; showWholeProject = whole; updatePathScopeTitle(); reload()
    }
    func canReuseForRange(_ range: HistoryRevisionRange, paths:[String] = []) -> Bool {
        guard let current = revisionRange else { return false }
        return !isInvalidated && !confirmingQuit && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil && !unifiedViewerBusy && !copyingDetails &&
        current.kind == range.kind && GitReferenceName.equal(current.from, range.from) && GitReferenceName.equal(current.to, range.to) &&
        endRevision == nil && historyPaths.map({ GitReferenceName($0) }) == paths.map({ GitReferenceName($0) }) && showWholeProject == paths.isEmpty && startRevisions.isEmpty && effectiveReferenceScope == .current
    }
    func configureWholeProjectScope() {
        historyWalk.followRenames = false; canFollowRenames = false
        historyPaths = []; showWholeProject = true
    }
    private func cancelActionReads() {
        actionCancellation?.cancel(); actionCancellation = nil
        actionQueue = []; activeActionHashes = []; actionGeneration += 1
    }
    private var actionBackendIdentity:NativeDiffBackendIdentity?
    private(set) var fileReadBackendIdentity:NativeDiffBackendIdentity?
    func requestActions(_ entry: LogEntry) {
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        let identity=NativeDiffBackendIdentity(repository.libgit2Configuration)
        if actionBackendIdentity != identity {cancelActionReads();revisionActions=[:];actionFailures=[];actionBackendIdentity=identity}
        if entry.hash.isEmpty { if revisionActions[""] == nil, let snapshot = workingTreeSnapshot { revisionActions[""] = .classify(snapshot.files) }; return }
        guard (!busy || loadingHistory), !isInvalidated, revisionActions[entry.hash] == nil, !actionFailures.contains(entry.hash),
            !activeActionHashes.contains(entry.hash), !actionQueue.contains(where: { $0.hash == entry.hash }) else { return }
        actionQueue.append(entry)
        guard actionCancellation == nil else { return }
        let cancellation = OperationCancellation(); actionCancellation = cancellation
        let request = actionGeneration
        Self.activeActionReads += 1
        Task {
            defer { Self.activeActionReads -= 1;withExtendedLifetime(access) {} }
            // Coalesce the cells requested during this main-actor update.
            await Task.yield()
            while request == actionGeneration && !actionQueue.isEmpty && !cancellation.isCancelled {
                let batch=Array(actionQueue.prefix(64));actionQueue.removeFirst(batch.count)
                activeActionHashes=Set(batch.map(\.hash))
                do {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let actions=try await repository.revisionActions(in:batch,cancellation:cancellation)
                    guard request == actionGeneration,!cancellation.isCancelled,!isInvalidated else { return }
                    revisionActions.merge(actions) { _,new in new }
                } catch {
                    guard request == actionGeneration else { return }
                    if !cancellation.isCancelled { actionFailures.formUnion(batch.map(\.hash)) }
                }
                activeActionHashes=[]
            }
            if request == actionGeneration { actionCancellation=nil;activeActionHashes=[] }
        }
    }
    var canShowStatistics:Bool {canChangeLogControls && entries.contains{!$0.hash.isEmpty}}
    func showStatistics() {
        guard canShowStatistics else { return }
        if let statisticsWindow,statisticsWindow.canReuse { statisticsWindow.showWindow(nil); statisticsWindow.window?.makeKeyAndOrderFront(nil); return }
        let controller = StatisticsWindowController(repository: repository, access: access, entries: entries.filter{!$0.hash.isEmpty}, defaults: labelDefaults)
        controller.onClosed = { [weak self,weak controller] in
            guard let self,let controller,self.statisticsWindow === controller else{return}
            self.statisticsWindow=nil
        }
        statisticsWindow = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
    }
    func invalidate() {
        retireRevisionColumns?()
        noteSaveCancellation?.cancel();noteIdentitySession?.retire()
        bisectRead?.cancel(); bisectRead = nil
        cancelReferenceDescriptionRead()
        retireLogControlMenus()
        cancelFileChoice(); invalidateFileSelection();closeAfterFileNavigationRead=false
        messageLinkGeneration = UUID()
        if let jumpAlert, let parent = jumpAlert.window.sheetParent { parent.endSheet(jumpAlert.window, returnCode: .abort) }; jumpAlert = nil
        cancelSearchFilter(); pathFilterGeneration += 1; pathFilterTask?.cancel(); pathFilterTask = nil
        followedSession?.cancel();closeAfterFollowedRead=false
        integrationCancellation?.cancel(); closeAfterIntegrationRead = false
        workingCommandCancellation?.cancel();closeAfterWorkingCommandRead=false
        workingLFSCancellation?.cancel();closeAfterWorkingLFSRead=false
        changedFileColumnRequest=UUID();resettingChangedFileColumns=false;focusedChangedFile=nil
        combineSelectionReads.values.forEach {$0.cancel()};combineSelectionReads.removeAll()
        startReferenceCancellation?.cancel(); startReferenceCancellation = nil
        unifiedSessions.values.forEach { $0.cancel() }; if !unifiedSessions.isEmpty { busy = false }
        statisticsWindow?.model.cancel(); statisticsWindow?.close(); statisticsWindow = nil
        restoreHistorySnapshot()
        isInvalidated = true; gravatar.clear()
        if let deletionCancellation { deletionCancellation.cancel(); self.deletionCancellation = nil; busy = false }
        cancelPatchPreview(); onPatchPreviewVisibility?(false)
        cancelRepositoryRefresh()
        cancelNoteRead()
        cancelJump()
        cancelActionReads()
        cancelClipboardRead()
        detailCancellation?.cancel(); detailCancellation = nil
        if loadingHistory { historyCancellation?.cancel(); historyCancellation = nil; busy = false }
        generation += 1; detailGeneration += 1
    }
    func reload() {
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        guard !isInvalidated, !referencePickerBlocked, unifiedSessions.isEmpty, followedSession == nil, !fileNavigationReadPending, !busy || loadingHistory else { return }
        cancelReferenceDescriptionRead()
        cancelSearchFilter()
        restoreHistorySnapshot()
        historyRestore = HistoryRestore(entries: entries, graph: graph, rollups: rollupInfo, highlights: searchHighlights, sourceRowCount: historySourceRowCount, selected: selected, mark: selectionMark)
        detailHistoryGeneration = nil
        onFindReferenceRefresh?()
        cancelPatchPreview()
        cancelRepositoryRefresh()
        isInvalidated = false
        cancelNoteRead()
        cancelJump(); highlightedRevision = nil; scrollRevision = nil
        cancelActionReads(); actionFailures = []
        detailCancellation?.cancel(); detailCancellation = nil; detailGeneration += 1
        historyCancellation?.cancel()
        let cancellation = OperationCancellation(); historyCancellation = cancellation
        if !initializedHistoryLimit {
            initializedHistoryLimit = true
            if (endRevision != nil || revisionRange != nil) && historyLimit.scale != .commits { historyLimit.scale = .noLimit }
        }
        cancelClipboardRead()
        generation += 1; let request = generation
        var options = HistoryOptions(); options.endRevision = effectiveReferenceScope == .current ? endRevision:nil; options.revisionRange = effectiveReferenceScope == .current ? revisionRange:nil; options.allBranches = allBranches; options.referenceScope = referenceScope; options.startRevisions = effectiveReferenceScope == .current ? startRevisions:[]; options.search = search; options.searchFields = searchFields; options.searchCaseSensitive = searchCaseSensitive; options.searchRegex = searchRegex
        options.useMailmap = labelDefaults.usesMailmap
        options.ordering = HistoryOrdering.load(defaults: labelDefaults)
        options.walk = historyWalk; options.regexExecutable = historyRegexExecutable
        options.includeBoundaryCommits = includeBoundaryCommits
        options.retainFilteredRows = true
        let referenceVisibility = referenceVisibility, rollupStates = rollupStates
        let scope = historyPaths
        if !showWholeProject { options.paths = historyPaths }
        historyLimit.apply(to: &options)
        busy = true; loadedRevisionCount = 0; Self.activeHistoryLoads += 1; pendingHistoryLoads += 1
        Task {
            defer { Self.activeHistoryLoads -= 1; pendingHistoryLoads -= 1; withExtendedLifetime(access) {} }
            do {
                let bare = try await repository.run(["rev-parse", "--is-bare-repository"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) == "true"
                let mergeActive = try await repository.logMergeActive(cancellation: cancellation)
                let metadata = try await repository.finderMetadata(cancellation:cancellation), bisectActive = metadata.bisectActive
                let bisect = bisectActive ? try await repository.bisectState(cancellation:cancellation) : nil
                let conflictRebase: Bool
                if bare { conflictRebase = false } else { conflictRebase = try await repository.conflictIsRebase(cancellation:cancellation) }
                let referenceContext = try await repository.historyReferenceContext(cancellation: cancellation)
                let referenceDescriptions = try await repository.historyBranchDescriptions(cancellation: cancellation)
                let startReferences = try await repository.historyStartReferences(cancellation: cancellation)
                let currentBranch = startReferences.branch
                let issueProperties = try await repository.issueTrackerProperties(cancellation: cancellation)
                let followAllowed = try await repository.canFollowHistory(paths: scope, revision: options.revisionRange?.to ?? options.endRevision ?? options.startRevisions.first, cancellation: cancellation)
                let pathScopes = try await repository.historyPathScopes(paths: scope, revision: options.revisionRange?.to ?? options.endRevision ?? options.startRevisions.first, cancellation: cancellation)
                let showPatch = patchPreviewPreferenceLoaded ? patchPreviewVisible : try await repository.run(["config", "--bool", "--get", "tgit.logshowpatch"], successfulExitCodes: 0...1, cancellation: cancellation).text.trimmingCharacters(in: .newlines) == "true"
                guard request == generation, !cancellation.isCancelled, !isInvalidated else { return }
                self.bare = bare; self.mergeActive = mergeActive; self.bisectActive = bisectActive
                self.bisectGoodTerm = bisect?.goodTerm ?? "good"; self.bisectBadTerm = bisect?.badTerm ?? "bad"
                self.currentBranch = currentBranch; self.fetchHeadRevision = startReferences.fetchHead
                self.issueProperties = issueProperties; self.conflictRebase = conflictRebase
                self.hasStash = metadata.hasStash; self.hasSubmodules = metadata.hasSubmoduleConfig
                self.hasGitSVN = metadata.hasGitSVN; self.workingHasLFS = metadata.hasLFS
                self.referenceContext = referenceContext; self.referenceDescriptions = referenceDescriptions
                let progressWalk = options.walk
                var result = try await repository.history(options: options, cancellation: cancellation, issueProperties: issueProperties, onProgress: { [weak self] count in
                    Task { @MainActor in
                        guard let self, request == self.generation, self.loadingHistory, !self.isInvalidated, !cancellation.isCancelled else { return }
                        self.loadedRevisionCount = max(self.loadedRevisionCount, count)
                    }
                }, onBatch: { [weak self] batch in
                    DispatchQueue.main.async { self?.publishHistoryBatch(batch, request:request, cancellation:cancellation, walk:progressWalk, references:referenceVisibility, states:rollupStates) }
                })
                let svnMessages = result.map { $0.historySubject + "\n" + $0.historyBody }
                let svnExecutable = options.regexExecutable
                let svnValues = metadata.hasGitSVN ? try await Task.detached {
                    try IssueRegexRuntime.svnRevisions(svnMessages, executable: svnExecutable, cancellation: cancellation)
                }.value : []
                let svnRevisions = Dictionary(uniqueKeysWithValues: zip(result.map(\.hash), svnValues))
                let working = showWorkingTree && includeWorkingTreeChanges && !selecting && !bare ? try await repository.workingTreeHistory(cancellation: cancellation) : nil
                let indexFiles = working == nil ? [] : try await repository.workingTreeStatus(refreshIndex:false,cancellation:cancellation)
                let submodules = working == nil ? GitPathSet() : GitPathSet(try await repository.submodulePathNames(cancellation:cancellation).map(\.rawValue))
                if let working { result.insert(working.entry, at: 0) }
                guard request == generation else { return }
                let sourceRows = result
                let dates = try await Task.detached(priority: .userInitiated) {
                    let formatter = ISO8601DateFormatter()
                    var first: Date?, last: Date?
                    for (index, entry) in sourceRows.enumerated() {
                        if index % 64 == 0 { try cancellation.check() }
                        guard let date = formatter.date(from: entry.committerDate.isEmpty ? entry.date : entry.committerDate) else { continue }
                        first = first.map { min($0, date) } ?? date; last = last.map { max($0, date) } ?? date
                    }
                    try cancellation.check(); return (first, last)
                }.value
                guard request == generation, historyCancellation === cancellation, !isInvalidated, !cancellation.isCancelled else { return }
                let selectedFrom = historyLimit.scale.rawValue >= HistoryLimitScale.selectedDate.rawValue ? historyLimit.from.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil } : nil
                if let first = selectedFrom ?? dates.0 { from = first }
                if let last = historyLimit.until ?? dates.1 { to = last }
                self.bare = bare; self.mergeActive = mergeActive; self.bisectActive = bisectActive; self.bisectGoodTerm = bisect?.goodTerm ?? "good"; self.bisectBadTerm = bisect?.badTerm ?? "bad"; self.currentBranch = currentBranch; self.fetchHeadRevision = startReferences.fetchHead; self.issueProperties = issueProperties
                self.conflictRebase = conflictRebase
                hasStash = metadata.hasStash; hasSubmodules = metadata.hasSubmoduleConfig; hasGitSVN = metadata.hasGitSVN; workingHasLFS = metadata.hasLFS; self.svnRevisions = svnRevisions
                canFollowRenames = followAllowed
                self.pathScopes = pathScopes
                if !patchPreviewPreferenceLoaded {
                    patchPreviewPreferenceLoaded = true
                    if patchPreviewVisible != showPatch { patchPreviewVisible = showPatch; onPatchPreviewVisibility?(showPatch) }
                }
                let filterActive = try await Task.detached { try HistorySearchActivity.isActive(options.search, regex: options.searchRegex, caseSensitive: options.searchCaseSensitive, executable: options.regexExecutable, cancellation: cancellation) }.value
                guard request == generation else { return }
                let projection = try await finalHistoryProjection(result, request: request, cancellation: cancellation,
                    walk: options.walk, references: referenceVisibility, states: rollupStates)
                guard request == generation, historyCancellation === cancellation, !cancellation.isCancelled, !isInvalidated else { return }
                self.referenceContext = referenceContext
                self.referenceDescriptions = referenceDescriptions
                let highlightEntries = projection.entries
                let fullMessage = fullCommitMessageOnLogLine
                let highlights = try await Task.detached {
                    guard filterActive else { return [String: [String: [NSRange]]]() }
                    var labeledHashes = Set<String>()
                    for (index, entry) in highlightEntries.enumerated() {
                        if index % 64 == 0 { try cancellation.check() }
                        if entry.references.contains(where: { referenceVisibility.shows($0) }) { labeledHashes.insert(entry.hash) }
                    }
                    return try LogSearchHighlights.prepare(highlightEntries, query: options.search, regex: options.searchRegex, caseSensitive: options.searchCaseSensitive, fields: options.searchFields, fullMessage: fullMessage, labeled: labeledHashes, executable: options.regexExecutable, cancellation: cancellation, applyLabelGates: false)
                }.value
                guard request == generation else { return }
                loadedHighlightFields = options.searchFields
                searchHighlights = highlights
                historyFilterActive = filterActive; rollupInfo = projection.rollups
                historySourceRowCount = result.count
                entries = projection.entries; graph = projection.graph
                result = projection.entries
                workingTreeSnapshot = working; workingIndexFiles = indexFiles; workingSubmodules = submodules
                if let working { revisionActions[""] = .classify(working.files) } else { revisionActions.removeValue(forKey: "") }
                let hashes = Set(result.map(\.hash)); revisionActions = revisionActions.filter { hashes.contains($0.key) }
                parentMetadata = parentMetadata.filter { hashes.contains($0.key) }
                let priorSelection = selected
                selected.formIntersection(Set(result.map(\.hash)))
                if selected.isEmpty, let first = result.first { selected = [first.hash] }
                historyRestore = nil; provisionalHistory = []; nextHistoryPublication = 128
                var messageSearch = HistoryMessageOptions(defaults: labelDefaults)
                messageSearch.query = options.search; messageSearch.fields = options.searchFields
                messageSearch.regex = options.searchRegex; messageSearch.caseSensitive = options.searchCaseSensitive
                appliedMessageSearch = messageSearch
                // Completing the independent history stream must not cancel
                // an already accepted child file comparison. Native menu and
                // control receipts still retire normally at this settlement.
                preservingHistoryFileNavigationOwner=true
                historyCancellation = nil; busy = !unifiedSessions.isEmpty || followedSession != nil || fileNavigationReadPending
                preservingHistoryFileNavigationOwner=false
                if selected != priorSelection || detailHistoryGeneration != generation { select(selected) }
            } catch {
                if request == generation {
                    detailCancellation?.cancel(); detailCancellation = nil; detailGeneration += 1
                    restoreHistorySnapshot(); historyCancellation = nil
                    if !cancellation.isCancelled { self.error = error.localizedDescription }
                    busy = !unifiedSessions.isEmpty || followedSession != nil || fileNavigationReadPending
                    if !isInvalidated { select(selected, mark: selectionMark, recordNavigation: false) }
                }
            }
        }
    }
    func select(_ hashes: Set<String>,mark:String? = nil,recordNavigation:Bool = true) {
        guard !isInvalidated else{return}
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        let identity=(try? repository.singleCommitBackendIdentity()) ?? "single-commit-unavailable"
        if parentMetadataBackendIdentity != identity {parentMetadata=[:];parentMetadataBackendIdentity=identity}
        selectionMark = mark.flatMap {hashes.contains($0) ? $0:nil} ?? selectionMark.flatMap {hashes.contains($0) ? $0:nil} ?? entries.first(where:{hashes.contains($0.hash)})?.hash
        messageLinkGeneration = UUID()
        if hashes != selected { cancelWorkingCommandRead(); cancelFollowedComparison(); cancelIntegrationRead() }
        cancelNoteRead()
        cancelJump(); highlightedRevision = nil
        if recordNavigation {
            for entry in entries where !entry.hash.isEmpty && hashes.contains(entry.hash) { selectionNavigation.add(entry.hash) }
        }
        cancelClipboardRead()
        detailCancellation?.cancel(); detailCancellation = nil
        fileReadBackendIdentity=NativeDiffBackendIdentity(repository.libgit2Configuration)
        detailHistoryGeneration = generation
        selected = hashes; branchRevisionNumber = nil; describedRevision = nil; refreshGravatar(); selectedFiles = []; fileSelectionMark = nil;focusedChangedFile=nil; files = []; fileGroups = []
        detailGeneration += 1; let request = detailGeneration
        if selectedWorkingTree { updateWorkingFiles(); return }
        guard let revision else { return }
        let cancellation = OperationCancellation(); detailCancellation = cancellation
        Self.activeActionReads += 1
        let detailsBegan = ProcessInfo.processInfo.systemUptime
        Task {
            defer {Self.activeActionReads -= 1;withExtendedLifetime(access){}}
            do {
                if revision.parents.count > 1 {
                    let groups = try await repository.logFileGroups(in: revision, cache: fileCache, cancellation: cancellation)
                    guard request == detailGeneration else { return }
                    fileGroups = groups
                    files = groups.flatMap { group in group.files.map { $0.inParentGroup(group.id) } }
                } else {
                    let result = try await repository.files(in: revision, cache: fileCache, cancellation: cancellation)
                    guard request == detailGeneration else { return }
                    files = result
                }
                if !revision.parents.isEmpty {
                    let choices = try? await repository.logParentChoices(revision, cancellation: cancellation)
                    guard request == detailGeneration else { return }
                    if let choices { parentMetadata[revision.hash] = choices }
                }
                if showBranchRevisionNumber, let index = entries.firstIndex(where: { $0.hash == revision.hash }), graph.indices.contains(index), graph[index].column == 0 {
                    do {
                        let number = try await repository.branchRevisionNumber(revision.hash, cancellation: cancellation)
                        guard request == detailGeneration else { return }
                        branchRevisionNumber = number
                    } catch {
                        guard request == detailGeneration else { return }
                        if !cancellation.isCancelled { self.error = "Could not get rev count\n" + error.localizedDescription }
                    }
                }
                if describeOptions.enabled {
                    let description = try? await repository.describeHistoryCommit(revision.hash, options: describeOptions, cancellation: cancellation)
                    guard request == detailGeneration, !cancellation.isCancelled, !isInvalidated else { return }
                    describedRevision = description
                }
                detailCancellation = nil; refreshPatchPreview()
                NativeDialogStartupTrace.mark("log.selection.details.ready", began: detailsBegan, count: files.count)
            } catch { if request == detailGeneration { detailCancellation = nil; detailHistoryGeneration = nil; if !cancellation.isCancelled { self.error = error.localizedDescription } } }
        }
    }
    func request(_ command: LogRevisionCommand, mainline: Int? = nil) {
        if command == .cherryPick { requestCherryPick(); return }
        guard canStartHistoryTransport, let revision else { return }
        guard command != .reset || resetAvailable else { return }
        guard ![LogRevisionCommand.branch,.tag].contains(command) || !selectedIsStash else { return }
        guard !bare || ![LogRevisionCommand.checkout, .cherryPick, .revert].contains(command) else { return }
        if command == .revert {
            guard canRevertRevision else { return }
            if revision.parents.count > 1 { guard let mainline, (1...revision.parents.count).contains(mainline) else { return } }
            else if mainline != nil { return }
            let request = LogCommandRequest(command: command, revision: revision, mainline: mainline)
            busy = true
            Task {
                let accepted = await confirmRevert(request)
                busy = false
                if accepted { execute(request, value: "") }
            }
            return
        }
        if command == .branch || command == .tag { onCreateReference(command == .tag, revision.hash); return }
        if command == .push { onPush(revision.hash); return }
        if command == .checkout { onCheckout(revision.hash); return }
        if command == .reset { onReset(revision.hash); return }
        commandRequest = LogCommandRequest(command: command, revision: revision)
    }
    func reference(for target: LogReferenceMenuTarget) -> RevisionReference? {
        guard !isInvalidated, let revision, revision.hash == target.revisionHash else { return nil }
        return revision.references.first { $0.name.utf8.elementsEqual(target.name.utf8) }
    }
    func requestReference(_ command: LogRevisionCommand, target: LogReferenceMenuTarget?) {
        guard !isInvalidated else { return }
        guard !busy, let revision else { return }
        let pointed: RevisionReference?
        if let target { guard let reference = reference(for: target) else { return }; pointed = reference }
        else { pointed = nil }
        if command == .push { onPush(pointed?.name ?? revision.hash); return }
        guard [.checkout, .branch, .tag].contains(command), !selectedIsStash else { return }
        let remote = revision.references.first { $0.name.utf8.starts(with: "refs/remotes/".utf8) }?.name
        if command == .checkout, !bare { onCheckout(pointed?.name ?? remote ?? revision.hash) }
        if command == .branch {
            let pointedRemote = pointed.flatMap { $0.name.utf8.starts(with: "refs/remotes/".utf8) ? $0.name : nil }
            onCreateReference(false, pointedRemote ?? remote ?? revision.hash)
        }
        if command == .tag { onCreateReference(true, remote ?? revision.hash) }
    }
    func switchBranchCandidates(target: LogReferenceMenuTarget?) -> [RevisionReference] {
        guard !isInvalidated, !bare, !selectedIsStash, let revision else { return [] }
        let references: [RevisionReference]
        if let target { guard let reference = reference(for: target) else { return [] }; references = [reference] }
        else { references = revision.references }
        return references.filter { $0.name.utf8.starts(with: "refs/heads/".utf8) && !$0.isCurrent }
    }
    func switchBranch(target: LogReferenceMenuTarget) {
        guard !busy, switchBranchCandidates(target: target).count == 1 else { return }
        onSwitchBranch?(target.name)
    }
    func deletionCandidates(target: LogReferenceMenuTarget?) -> [RevisionReference] {
        guard !isInvalidated, let revision else { return [] }
        if let target { guard let ref = reference(for: target), !ref.isCurrent else { return [] }; return [ref] }
        return revision.references.filter { !$0.isCurrent }
    }
    func deleteReferences(_ targets: [LogReferenceMenuTarget]) {
        guard !isInvalidated, !busy, !targets.isEmpty, let chosen = revision,
              targets.allSatisfy({ deletionCandidates(target: $0).count == 1 }) else { return }
        let repository = self.repository.capturingDiffBackend(preferences: labelDefaults)
        let request = generation, cancellation = OperationCancellation(), factory = sshSettings.capture()
        deletionCancellation = cancellation; busy = true; error = nil; Self.activeHistoryDeletions += 1
        Task {
            defer { Self.activeHistoryDeletions -= 1 }
            let coordinator = factory?(); defer { coordinator?.close() }
            var refresh = false
            defer { if deletionCancellation === cancellation { deletionCancellation = nil; busy = false; if refresh && !isInvalidated { reload() } } }
            for target in targets {
                guard !isInvalidated, !cancellation.isCancelled, generation == request, revision?.hash == chosen.hash else { break }
                var choice = HistoryReferenceDeleteChoice.abort
                do {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let snapshot = try await repository.prepareHistoryReferenceDeletion(target.name, cancellation: cancellation)
                    let resolved = try await repository.revisionLookup(snapshot.name,requirement:.commit,cancellation:cancellation).objectID
                    guard resolved == target.revisionHash else { throw HistoryReferenceDeletionFailure.changed }
                    choice = await confirmReferenceDeletion(snapshot)
                    guard choice != .abort, !isInvalidated, !cancellation.isCancelled, generation == request, revision?.hash == chosen.hash else { break }
                    _ = try await repository.deleteHistoryReference(snapshot, choice: choice, cancellation: cancellation, prepareTransport: coordinator?.preparation); refresh = true
                } catch {
                    if isInvalidated || cancellation.isCancelled { break }
                    self.error = error.localizedDescription
                    await acknowledgeReferenceDeletionFailure(error.localizedDescription)
                    // Upstream remote-push/stash paths return true after reporting
                    // failures; ordinary/local remote deletion aborts All.
                    if [.remoteAndLocal, .stashAll, .stashOne].contains(choice) { refresh = true }
                    else { break }
                }
            }
        }
    }
    func copyReferenceNames(target: LogReferenceMenuTarget?) {
        guard !busy, !isInvalidated, let revision else { return }
        if let target {
            guard let reference = reference(for: target) else { return }
            var name = reference.name
            if let tag = GitReferenceName.removingPrefix("refs/tags/", from: name) {
                name = GitReferenceName.removingSuffix("^{}", from: tag) ?? tag
            } else {
                name = GitReferenceName.removingPrefix("refs/heads/", from: name) ?? GitReferenceName.removingPrefix("refs/", from: name) ?? name
                name = String(name.reversed().drop(while: { $0.isWhitespace }).reversed())
            }
            copy(name)
        } else {
            copy(revision.references.map { reference in
                let name = reference.name
                return (name.hasPrefix("refs/tags/") && name.hasSuffix("^{}") ? String(name.dropLast(3)) : name) + "\r\n"
            }.joined())
        }
    }
    func execute(_ request: LogCommandRequest, value: String) {
        guard !busy else { return }
        if bare && [LogRevisionCommand.checkout, .cherryPick, .revert].contains(request.command) {
            error = "This operation requires a working tree."; return
        }
        let hash = request.revision.hash
        var args: [String]
        switch request.command {
        case .branch: commandRequest = nil; onCreateReference(false, hash); return
        case .tag: commandRequest = nil; onCreateReference(true, hash); return
        case .push: commandRequest = nil; onPush(hash); return
        case .checkout: commandRequest = nil; onCheckout(hash); return
        case .reset: commandRequest = nil; onReset(hash); return
        case .cherryPick: commandRequest = nil; requestCherryPick(); return
        case .revert: args = ["revert", "--no-commit", hash]
        }
        let revertBackend:GitLibGit2Configuration? = request.command == .revert ? .load(from:labelDefaults):nil
        commandRequest = nil; busy = true
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result: GitResult
                if request.command == .revert { result = try await repository.revertLogRevision(revision: hash, mainline: request.mainline,backend:revertBackend) }
                else { result = try await repository.run(args) }
                onRevisionChanged(result.text)
                if request.command == .revert {
                    let commit = await offerRevertCommit()
                    busy = false
                    if commit { onCommit() }
                } else { busy = false }
                reload()
            } catch { self.error = error.localizedDescription; onRevisionChanged(error.localizedDescription); busy = false; reload() }
        }
    }
    private func cancelClipboardRead() {
        clipboardCancellation?.cancel(); clipboardCancellation = nil
        clipboardGeneration += 1; copyingDetails = false
    }
    func copy(_ text: String) {
        cancelClipboardRead()
        clipboard.clearContents(); clipboard.setString(text, forType: .string)
    }
    func diff(workingTree: Bool = false, path: String? = nil, alternate: Bool = false, mode:LogRevisionDiffMode = .firstParent) {
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        guard canInspectHistory, !workingTree || !bare else { return }
        if includesWorkingTree { workingTreeDiff(path: path, alternate: alternate); return }
        let revisions = self.revisions
        guard (1...2).contains(revisions.count) else { return }
        let scope=path.map { [$0] } ?? (showWholeProject ? [] : historyPaths)
        let followed = path == nil ? followedPath : nil, followedRows = entries
        let request = generation, selection = selected, detail = detailGeneration
        let id = UUID(), session = FileListComparisonSession(window: window, preferences: labelDefaults, alternateTool:alternate)
        unifiedSessions[id] = session; busy = true
        Task {
            defer { unifiedSessions.removeValue(forKey: id); if request == generation, !loadingHistory, unifiedSessions.isEmpty { busy = false }; withExtendedLifetime(access) {} }
            do {
                try await session.run(selectedCount: 0) { [self] token in
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let bytes: Data
                    if let path = followed, !workingTree || revisions.count == 1 {
                        let first = revisions[0]
                        let from: ComparisonRevision = workingTree ? .revision(first.hash) : revisions.count == 2 ? .revision(revisions[1].hash) : {
                            if case .parent(let number) = mode, number > 0, number <= first.parents.count { return .revision(first.parents[number - 1]) }
                            return first.parents.first.map { .revision($0) } ?? .emptyTree
                        }()
                        let to: ComparisonRevision = workingTree ? .workingTree : .revision(first.hash)
                        if [.allParents, .combined, .extraMergeChanges].contains(mode), !workingTree, revisions.count == 1 {
                            let names = try await repository.followedHistoryPaths(path: path, entries: followedRows, through: [first.hash], cancellation: token)
                            var paths = [try names.path(at: .revision(first.hash))]
                            for parent in first.parents {
                                let pair = try await repository.followedHistoryComparison(path: path, entries: followedRows, from: .revision(parent), to: .revision(first.hash), parentOf: first.hash, cancellation: token)
                                paths += pair.files.compactMap(\.oldPath)
                            }
                            bytes = try await repository.revisionDiffData(first, paths: Array(Set(paths)), mode: mode, cancellation: token)
                        } else {
                            let snapshot = try await repository.followedHistoryComparison(path: path, entries: followedRows, from: from, to: to, parentOf: !workingTree && revisions.count == 1 ? first.hash : nil, cancellation: token)
                            bytes = try await repository.revisionComparisonPatchData(snapshot, cancellation: token)
                        }
                    } else if revisions.count == 2, !workingTree {
                        var args = ["diff", "--no-ext-diff", "--no-color", revisions[1].hash, revisions[0].hash, "--"]
                        args += scope
                        bytes = try await repository.unifiedDiffData(arguments:args,cancellation:token)
                    } else { bytes = try await repository.revisionDiffData(revisions[0], paths:scope, workingTree:workingTree, mode:mode, cancellation:token) }
                    guard request == generation, detailGeneration == detail, selection == selected, !isInvalidated, !token.isCancelled else { return }
                    if mode == .extraMergeChanges, String(decoding:bytes,as:UTF8.self).split(separator:"\n").count <= 1 {
                        navigationNotice="No extra changes after merge.";return
                    }
                    if let onUnifiedDiff { try await onUnifiedDiff(bytes, alternate) }
                    else if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: labelDefaults, title: "Selected revision changes", permissions: access.map { [$0] } ?? [], cancellation: token) {
                        guard request == generation, detailGeneration == detail, selection == selected, !isInvalidated, !token.isCancelled else { return }
                        unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: "Selected revision changes", preferences: labelDefaults, onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
                }
            } catch { if request == generation, detailGeneration == detail, selection == selected, !isInvalidated, !session.cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    var clipboardEntries:[LogEntry] {
        entries.filter{selected.contains($0.hash)}.map { entry in
            guard entry.hash.isEmpty,let tree=workingTreeSnapshot else{return entry}
            return LogEntry(hash:"",author:entry.author,date:entry.date,subject:entry.subject,parents:entry.parents,email:entry.email,message:tree.entry.subject+"\n"+tree.entry.message)
        }
    }
    func copyDetails(includePaths: Bool = true) {
        let chosen=clipboardEntries,working=workingTreeSnapshot;guard !chosen.isEmpty else{return}
        let dateSettings = HistoryDateSettings.load(defaults:labelDefaults)
        cancelClipboardRead()
        let cancellation = OperationCancellation(); clipboardCancellation = cancellation
        let request = clipboardGeneration
        copyingDetails = true; error = nil
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                var text = ""
                for entry in chosen {
                    guard request == clipboardGeneration else { return }
                    if entry.hash.isEmpty,let working {
                        var detail="Revision: \(entry.hash)\nAuthor: \(entry.author) <\(entry.email)>\nDate: \(dateSettings.format(entry.date))\nMessage:\n\(entry.message)\n"
                        if includePaths {
                            detail+="----\n"
                            for file in working.files {detail+=file.status+": "+file.path+(file.oldPath.map{" (from "+$0+")"} ?? "")+"\n"}
                        }
                        text+=detail+"\n";continue
                    }
                    text += try await repository.commitLogText(revision: entry.hash, includePaths: includePaths, cancellation: cancellation, dateSettings: dateSettings, useMailmap: labelDefaults.usesMailmap)
                }
                guard request == clipboardGeneration else { return }
                copy(text)
            } catch {
                if request == clipboardGeneration { clipboardCancellation = nil; if !cancellation.isCancelled { self.error = error.localizedDescription }; copyingDetails = false }
            }
        }
    }
    enum CopyFileInformation: String, CaseIterable {
        case fullPaths = "Full paths", relativePaths = "Relative paths", names = "File/folder names", all = "Copy all information to clipboard"
    }
    func canCopyFiles(_ ids: some Sequence<String>) -> Bool {
        let ids = GitPathSet(ids)
        return canInspectHistory && visibleFiles.contains { ids.contains($0.id) }
    }
    func copyFiles(_ ids: some Sequence<String>, information: CopyFileInformation) {
        let ids = GitPathSet(ids)
        guard canCopyFiles(ids) else { return }
        let selected = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }
        let kind: StatusListCopy
        switch information {
        case .fullPaths: kind = .fullPaths
        case .relativePaths: kind = .relativePaths
        case .names: kind = .names
        case .all: kind = .all
        }
        let statuses = GitPathMap(uniqueKeysWithValues: selected.map { ($0.id, fileStatus($0)) })
        copy(StatusListClipboard.text(selected, root: repository.root, statuses: statuses, copy: kind, label:FileListLabels.caption))
    }
    func fileLog(_ ids: some Sequence<String>, oldName: Bool = false) {
        guard canInspectHistory else{return}
        let ids = GitPathSet(ids)
        acceptedNavigationRepository=repository.capturingDiffBackend(preferences:labelDefaults)
        if selectedWorkingTree, ids.count == 1, let file = visibleFiles.first(where: { ids.contains($0.id) }), file.action != "?", let onFileLog {
            onFileLog(oldName ? file.oldPath ?? file.path : file.path, nil); return
        }
        guard canInspectHistory, let onFileLog, let revision, ids.count == 1,
              let file = visibleFiles.first(where: { ids.contains($0.id) }) else { return }
        if oldName {
            guard let path = file.oldPath else { return }; onFileLog(path, file.isPathRepresentable ? nil:revision.hash)
        } else { onFileLog(file.path, revision.hash) }
    }
    var onSubmoduleFileLog: ((URL, String?) -> Void)?
    func canShowSubmoduleFileLog(_ ids: some Sequence<String>) -> Bool {
        let ids = GitPathSet(ids)
        guard hasRepresentableFilePaths(ids) else { return false }
        return canInspectHistory && !bare && onSubmoduleFileLog != nil && ids.count == 1 && visibleFiles.contains { ids.contains($0.id) && $0.isSubmodule && $0.action != "?" }
    }
    func showSubmoduleFileLog(_ ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard requireNativeFilePaths(ids) else { return }
        guard canShowSubmoduleFileLog(ids), let file = visibleFiles.first(where: { ids.contains($0.id) }) else { return }
        let request = generation, selection = selected, fileSelection = selectedFiles
        let fileRequest = fileSelectionGeneration
        let working = selectedWorkingTree, revision = self.revision
        let pinRevision = labelDefaults.object(forKey: "LogSubmoduleShowRevision") == nil || labelDefaults.bool(forKey: "LogSubmoduleShowRevision")
        let repository = self.repository.capturingDiffBackend(preferences:labelDefaults)
        let token = OperationCancellation(); fileOpenRead = token; Self.activeFileOpenReads += 1
        busy = true
        Task {
            defer { Self.activeFileOpenReads -= 1; withExtendedLifetime(access) {}; finishFileOpenRead(token,generation:request) }
            do {
                try validateWorkingFileAccess(repository.root.appendingPathComponent(file.path))
                if working {
                    guard let fresh = try await repository.workingTreeHistory(cancellation:token), fresh.files.contains(where: { GitReferenceName.equal($0.path, file.path) && $0.isSubmodule && $0.action == file.action }) else { throw RevisionComparisonFailure.selection }
                } else {
                    guard let revision else { throw RevisionComparisonFailure.selection }
                    let groups = try await repository.logFileGroups(in: revision,cancellation:token)
                    guard let group = groups.first(where: { $0.id == (file.parentIndex ?? 0) }), group.files.contains(where: { GitReferenceName.equal($0.path, file.path) && $0.isSubmodule && $0.action == file.action }) else { throw RevisionComparisonFailure.selection }
                }
                let child = try await repository.submoduleWorkingRepository(path:file.path,cancellation:token)
                let checkout=child.root
                try validateWorkingFileAccess(checkout)
                let endRevision: String?
                if !working && !file.action.hasPrefix("D") && pinRevision {
                    guard let revision else {throw RevisionComparisonFailure.selection}
                    endRevision = try await repository.submoduleLogRevision(path:file.path,revision:revision.hash,cancellation:token)
                } else { endRevision = nil }
                guard request == generation, fileRequest == fileSelectionGeneration, selection == selected, fileSelection == selectedFiles, !isInvalidated,!confirmingQuit,!token.isCancelled else { return }
                acceptedNavigationRepository=child
                finishFileOpenRead(token,generation:request); onSubmoduleFileLog?(checkout, endRevision)
            } catch { if request == generation, fileRequest == fileSelectionGeneration, selection == selected, fileSelection == selectedFiles, !isInvalidated,!confirmingQuit,!token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    /// History keys may be opaque byte names. Native filesystem and mutation
    /// adapters still require a real text path; never reinterpret the display.
    func hasRepresentableFilePaths(_ ids: some Sequence<String>) -> Bool {
        let ids=GitPathSet(ids)
        let chosen=visibleFiles.filter { ids.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy { file in
            (try? RepositoryBrowserGitPath(key:file.path).isRepresentable)==true &&
            (file.oldPath.map { (try? RepositoryBrowserGitPath(key:$0).isRepresentable)==true } ?? true)
        }
    }
    @discardableResult private func requireNativeFilePaths(_ ids: some Sequence<String>) -> Bool {
        let ids=GitPathSet(ids)
        guard !isInvalidated,!confirmingQuit,!ids.isEmpty,ids.isSubset(of:GitPathSet(visibleFiles.map(\.id))) else{return false}
        guard hasRepresentableFilePaths(ids) else {
            error=RepositoryBrowserWindowModel.rawPathReason;return false
        }
        return true
    }
    @discardableResult private func requireHistoricalFilePaths(_ ids:some Sequence<String>) -> Bool {
        let ids=GitPathSet(ids)
        guard !isInvalidated,!confirmingQuit,!ids.isEmpty,ids.isSubset(of:GitPathSet(visibleFiles.map(\.id))) else{return false}
        return !selectedWorkingTree || requireNativeFilePaths(ids)
    }
    func canBlameFile(_ ids: some Sequence<String>) -> Bool {
        let ids = GitPathSet(ids)
        guard canInspectHistory, onBlame != nil, ids.count == 1,
              let file = visibleFiles.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return false }
        if selectedWorkingTree { return hasRepresentableFilePaths(ids) && !bare && workingTreeSnapshot?.entry.parents.first != nil && file.action != "?" && !file.action.hasPrefix("A") }
        return revision != nil
    }
    func workingConflictPaths(_ ids: some Sequence<String>) -> [String] {
        let ids = GitPathSet(ids)
        guard selectedWorkingTree, !bare else { return [] }
        return visibleFiles.filter { ids.contains($0.id) && $0.action.hasPrefix("U") }.map(\.path)
    }
    func canWorkingConflict(_ action: RepositoryAction, ids: some Sequence<String>) -> Bool {
        let ids = GitPathSet(ids)
        guard hasRepresentableFilePaths(ids) else { return false }
        guard !busy, !isInvalidated, onConflictAction != nil, !workingConflictPaths(ids).isEmpty else { return false }
        return action == .editConflict ? ids.count == 1 : action.resolveChoice != nil
    }
    func requestWorkingConflict(_ action: RepositoryAction, ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard requireNativeFilePaths(ids) else { return }
        guard canWorkingConflict(action, ids: ids), let onConflictAction else { return }
        let paths = workingConflictPaths(ids), selection = selected, request = generation, rebase = conflictRebase
        let fileRequest = fileSelectionGeneration
        busy = true
        Task {
            defer { busy = false }
            do {
                for path in paths { try validateWorkingFileAccess(repository.root.appendingPathComponent(path)) }
                let fresh = try await repository.conflicts(paths: paths)
                guard GitPathSet(fresh.map(\.path)) == GitPathSet(paths) else { throw ResolveFailure.stale }
                if action == .resolveMine || action == .resolveTheirs {
                    guard try await repository.conflictIsRebase() == rebase else { throw ResolveFailure.stale }
                }
                guard !isInvalidated, request == generation, fileRequest == fileSelectionGeneration, selected == selection else { return }
                busy = false; onConflictAction(action, paths)
            } catch { if !isInvalidated, request == generation, fileRequest == fileSelectionGeneration, selected == selection { self.error = error.localizedDescription } }
        }
    }
    func primaryFileAction(_ ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        if canWorkingConflict(.editConflict, ids: ids) { requestWorkingConflict(.editConflict, ids: ids) }
        else { compareFiles(ids) }
    }
    var prepareWorkingBlameLeaf:(URL,OperationCancellation) async throws -> Void = {file,token in
        try await Task.detached {try BlameDocumentLocation.validateWorkingLeaf(file,cancellation:token)}.value
    }
    func blameFile(_ ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard canBlameFile(ids), let onBlame, let file = visibleFiles.first(where: { ids.contains($0.id) }) else { return }
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        acceptedNavigationRepository=repository
        if !selectedWorkingTree { if let revision { onBlame(file.path, revision.hash) }; return }
        let request = generation, selection = selected
        let fileRequest = fileSelectionGeneration
        let token = OperationCancellation()
        fileOpenRead = token; busy = true; Self.activeFileOpenReads += 1
        let controls = logControlsEpoch,prepareLeaf=prepareWorkingBlameLeaf
        Task {
            defer { Self.activeFileOpenReads -= 1; finishFileOpenRead(token, generation: request); withExtendedLifetime(access) {} }
            do {
                // Blame attributes HEAD's blob, including a symlink's target
                // text, rather than opening or authorizing its disk target.
                let location = try BlameDocumentLocation.lexicalFile(root: repository.root, path: file.path)
                try validateWorkingFileAccess(location.deletingLastPathComponent())
                try await prepareLeaf(location,token)
                try token.check()
                let content = try await repository.historicalFile(revision: "HEAD", path: file.path, cancellation: token)
                guard ["100644", "100755", "120000"].contains(content.mode ?? ""), case .revision(let hash) = content.revision else { throw GitBlameFailure.unsupported }
                guard !isInvalidated, !confirmingQuit, !token.isCancelled, controls == logControlsEpoch, request == generation, fileRequest == fileSelectionGeneration, selected == selection else { return }
                finishFileOpenRead(token, generation: request); onBlame(file.path, hash)
            } catch { if !isInvalidated, !confirmingQuit, !token.isCancelled, controls == logControlsEpoch, request == generation, fileRequest == fileSelectionGeneration, selected == selection { self.error = error.localizedDescription } }
        }
    }
    func chooseHistoricalExport(_ ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard requireNativeFilePaths(ids) else { return }
        guard (selectedWorkingTree ? !busy : canInspectHistory), !isInvalidated, selectedWorkingTree || revision != nil, window?.attachedSheet == nil else { return }
        let chosen = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }
        guard chosen.contains(where: { !$0.isSubmodule && !$0.action.hasPrefix("D") }) else { return }
        if selectedWorkingTree { presentWorkingExport(chosen.filter { !$0.isSubmodule && !$0.action.hasPrefix("D") }.map(\.path)) }
        else if let revision { historicalExportBackend=materializationBackend();presentHistoricalExport(revision.hash, chosen) }
    }
    func exportHistoricalFiles(revision: String, files: [CommitFile], to folder: URL,backend:GitLibGit2Configuration? = nil) {
        guard canInspectHistory else { return }
        guard files.allSatisfy(\.isPathRepresentable) else{error=RepositoryBrowserWindowModel.rawPathReason;return}
        let captured=backend ?? materializationBackend(),token=OperationCancellation(),request=generation
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        fileOpenRead=token;busy=true;Self.activeFileOpenReads += 1
        Task { [self,access] in
            defer {Self.activeFileOpenReads -= 1;finishFileOpenRead(token,generation:request);withExtendedLifetime(access){}}
            let scoped=folder.startAccessingSecurityScopedResource()
            defer {if scoped {folder.stopAccessingSecurityScopedResource()}}
            do {
                try token.check()
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true || !scoped) {throw RepositoryAccessFailure.securityScopeUnavailable}
                let export=try await repository.prepareHistoricalExport(revision:revision,files:files,to:folder,cancellation:token,backend:captured)
                for path in export.paths {
                    guard !isInvalidated,!confirmingQuit,request==generation,!token.isCancelled else {break}
                    do {try await repository.exportHistoricalFile(export,path:path,cancellation:token)}
                    catch {
                        guard !isInvalidated,!confirmingQuit,request==generation,!token.isCancelled else {break}
                        let message=["File: "+path,"Revision: "+export.revision,"Destination: "+folder.appendingPathComponent(path).path,"",error.localizedDescription].joined(separator:"\n")
                        guard await confirmExportFailure(message),!isInvalidated,!confirmingQuit,request==generation,!token.isCancelled else {break}
                    }
                }
            } catch {if !isInvalidated,!confirmingQuit,request==generation,!token.isCancelled {self.error=error.localizedDescription}}
        }
    }
    func saveHistoricalFile(_ ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard requireHistoricalFilePaths(ids) else { return }
        if selectedWorkingTree {
            guard !busy, !isInvalidated, !bare, ids.count == 1, window?.attachedSheet == nil,
                  let file = visibleFiles.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
            presentWorkingSave(file.path); return
        }
        guard canInspectHistory,let revision, ids.count == 1, let window, window.attachedSheet == nil,
              let file = files.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
        let request = generation, fileRequest = fileSelectionGeneration
        let backend=materializationBackend(),token=OperationCancellation()
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        fileOpenRead=token;busy=true;Self.activeFileOpenReads += 1
        Task {
            defer {Self.activeFileOpenReads -= 1;finishFileOpenRead(token,generation:request);withExtendedLifetime(access){}}
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let content = try await repository.materializedHistoricalFile(revision: revision.hash, path: file.path,cancellation:token,backend:backend)
                guard case .revision(let hash) = content.revision else { throw RevisionComparisonFailure.range }
                let short = try await repository.run(["rev-parse", "--short", hash],cancellation:token).text.trimmingCharacters(in: .newlines)
                guard !isInvalidated,!confirmingQuit,!token.isCancelled,request == generation,fileRequest == fileSelectionGeneration else {return}
                finishFileOpenRead(token,generation:request); presentHistoricalSave(content, short)
            } catch { if !isInvalidated,!confirmingQuit,!token.isCancelled,request == generation,fileRequest == fileSelectionGeneration {self.error=error.localizedDescription} }
        }
    }
    private func finishFileOpenRead(_ token: OperationCancellation, generation request: Int) {
        if fileOpenRead === token {
            fileOpenRead = nil
            if request == generation && !isInvalidated { busy = loadingHistory || fileNavigationReadPending || !unifiedSessions.isEmpty || followedSession != nil }
            finishPendingFileNavigationClose()
        }
    }
    func openHistoricalFile(_ ids: some Sequence<String>, action: HistoricalOpenAction) {
        let ids = GitPathSet(ids)
        guard requireHistoricalFilePaths(ids) else { return }
        if selectedWorkingTree { openWorkingFile(ids, action: action); return }
        guard canInspectHistory, let revision, ids.count == 1, let window, window.attachedSheet == nil,
              let file = files.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
        let request = generation, fileRequest = fileSelectionGeneration, token = OperationCancellation(),backend=materializationBackend()
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        materializationEditorSettings = .load(from:labelDefaults)
        fileOpenRead = token; busy = true; Self.activeFileOpenReads += 1
        Task {
            defer { Self.activeFileOpenReads -= 1; finishFileOpenRead(token, generation: request); withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let content = try await repository.materializedHistoricalFile(revision: revision.hash, path: file.path, cancellation: token,backend:backend)
                try token.check()
                guard !isInvalidated,!confirmingQuit, request == generation, fileRequest == fileSelectionGeneration else { return }
                finishFileOpenRead(token, generation: request); presentHistoricalOpen(content, action)
            } catch { if !isInvalidated, !token.isCancelled, request == generation, fileRequest == fileSelectionGeneration { self.error = error.localizedDescription } }
        }
    }
    func validateWorkingFileAccess(_ file: URL) throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true || access?.contains(file) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func openWorkingFile(_ ids: some Sequence<String>, action: HistoricalOpenAction) {
        let ids = GitPathSet(ids)
        guard requireNativeFilePaths(ids) else { return }
        guard !busy, !isInvalidated, !bare, ids.count == 1, window?.attachedSheet == nil,
              let file = visibleFiles.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
        let request = generation, selection = selected, fileRequest = fileSelectionGeneration, token = OperationCancellation()
        fileOpenRead = token; busy = true; Self.activeFileOpenReads += 1
        Task {
            defer { Self.activeFileOpenReads -= 1; finishFileOpenRead(token, generation: request); withExtendedLifetime(access) {} }
            do {
                try token.check(); try validateWorkingFileAccess(repository.root.appendingPathComponent(file.path))
                let location = try await repository.workingFileOpenLocation(path: file.path, cancellation: token)
                try token.check()
                guard !isInvalidated, request == generation, fileRequest == fileSelectionGeneration, selection == selected else { return }
                try validateWorkingFileAccess(location)
                finishFileOpenRead(token, generation: request); presentWorkingOpen(location, action)
            } catch { if !isInvalidated, !token.isCancelled, request == generation, fileRequest == fileSelectionGeneration { self.error = error.localizedDescription } }
        }
    }
    func copyWorkingFiles(_ paths: [String], to target: URL, save: Bool) {
        guard !busy, !isInvalidated, !bare, !paths.isEmpty, !save || paths.count == 1 else { return }
        guard paths.allSatisfy({(try? RepositoryBrowserGitPath(key:$0).isRepresentable)==true}) else{error=RepositoryBrowserWindowModel.rawPathReason;return}
        busy = true
        Task {
            let scoped = target.startAccessingSecurityScopedResource()
            defer { if scoped { target.stopAccessingSecurityScopedResource() }; busy = false }
            do {
                for path in paths { try validateWorkingFileAccess(repository.root.appendingPathComponent(path)) }
                if GitRuntime.isAppStoreBuild && !scoped { throw RepositoryAccessFailure.securityScopeUnavailable }
                if save { try await repository.saveWorkingFile(path: paths[0], to: target) }
                else { _ = try await repository.exportWorkingFiles(paths: paths, to: target) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func importWorkingComparisonMark(_ access: WorkingComparisonAccess?) {
        guard let access, access.mark.id != lastImportedWorkingMark else { return }
        lastImportedWorkingMark = access.mark.id
        comparisonMark = PreparedFileComparisonMark(path: access.file.path, revision: "", workingAccess: access)
    }
    func markForComparison(_ ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard requireHistoricalFilePaths(ids) else { return }
        guard canInspectHistory, selectedWorkingTree || revision != nil, ids.count == 1, let file = visibleFiles.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
        comparisonMark = PreparedFileComparisonMark(path: file.path, revision: selectedWorkingTree ? "" : revision!.hash)
    }
    func canCompareMarkedFile(_ ids:some Sequence<String>) -> Bool {
        guard let mark=comparisonMark else{return false}
        if selectedWorkingTree || mark.workingAccess != nil || mark.revision.isEmpty{return hasRepresentableFilePaths(ids) && (try? RepositoryBrowserGitPath(key:mark.path).isRepresentable)==true}
        return true
    }
    func compareWithMarkedFile(_ ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard requireHistoricalFilePaths(ids) else { return }
        guard canInspectHistory, selectedWorkingTree || revision != nil, let comparisonMark, let onPreparedFileCompare, ids.count == 1,
              let file = visibleFiles.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
        if comparisonMark.workingAccess != nil || comparisonMark.revision.isEmpty || selectedWorkingTree {
            guard requireNativeFilePaths(ids),(try? RepositoryBrowserGitPath(key:comparisonMark.path).isRepresentable)==true else{return}
        }
        let current = PreparedFileComparisonMark(path: file.path, revision: selectedWorkingTree ? "" : revision!.hash)
        acceptedNavigationRepository=repository.capturingDiffBackend(preferences:labelDefaults)
        onPreparedFileCompare(comparisonMark, current)
    }
    func revealFile(_ ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard requireNativeFilePaths(ids) else { return }
        guard !busy, !bare, ids.count == 1, let file = files.first(where: { ids.contains($0.id) }), !file.action.hasPrefix("D") else { return }
        let request = generation, fileRequest = fileSelectionGeneration
        busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let destination = try await repository.fileRevealDestination(path: file.path)
                guard !isInvalidated, request == generation, fileRequest == fileSelectionGeneration else { return }
                switch destination {
                case .select(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
                case .openDirectory(let url): if !NSWorkspace.shared.open(url) { self.error = "Could not open the file's containing folder in Finder." }
                }
            } catch { if !isInvalidated, request == generation, fileRequest == fileSelectionGeneration { self.error = error.localizedDescription } }
        }
    }
    @Published private(set) var historicalRevertTrash: [URL] = []
    @Published private(set) var workingDeleteTrash: [URL] = []
    @Published private(set) var workingDeleteResult: WorkingFileDeleteResult?
    var confirmWorkingDelete: (Int, Bool) async -> Bool = { _, _ in false }
    func canDeleteWorkingFiles(_ ids: some Sequence<String>, keyboard: Bool = false) -> Bool {
        let ids = GitPathSet(ids)
        guard hasRepresentableFilePaths(ids) else { return false }
        guard !busy, !isInvalidated, !bare, selectedWorkingTree,
              let file = markedFile(ids),
              let mark = workingIndexFiles.first(where: { GitReferenceName.equal($0.id, file.path) }) else { return false }
        return keyboard ? mark.entry.canDeleteWithKeyboard : mark.entry.canDeleteFromStatusList
    }
    func deleteWorkingFiles(_ ids: some Sequence<String>, permanently: Bool = false, keyboard: Bool = false) {
        let ids = GitPathSet(ids)
        guard requireNativeFilePaths(ids) else { return }
        guard canDeleteWorkingFiles(ids, keyboard: keyboard) else { return }
        let chosen = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }
        let rows = chosen.compactMap { file in workingIndexFiles.first { GitReferenceName.equal($0.id, file.path) }?.entry }
        guard rows.count == chosen.count, let marked = markedFile(ids), let mark = rows.first(where: { GitReferenceName.equal($0.path, marked.path) }) else { return }
        let request = generation, selection = selected, fileSelection = selectedFiles
        let fileRequest = fileSelectionGeneration
        workingDeleteTrash = []; workingDeleteResult = nil; busy = true
        Task {
            defer { busy = false }
            guard request == generation, fileRequest == fileSelectionGeneration, selection == selected, fileSelection == selectedFiles, !isInvalidated,
                  await confirmWorkingDelete(rows.count, permanently),
                  request == generation, fileRequest == fileSelectionGeneration, selection == selected, fileSelection == selectedFiles, !isInvalidated else { return }
            do {
                for row in rows { try validateWorkingFileAccess(repository.root.appendingPathComponent(row.path)) }
                let result = try await repository.deleteWorkingFiles(rows, selectionMark: mark, permanently: permanently)
                workingDeleteResult = result; workingDeleteTrash = result.trashedFiles
                onRevisionChanged("\(rows.count) item(s) deleted."); requestRepositoryRefresh()
            } catch {
                if let failure = error as? WorkingFileDeleteFailure {
                    workingDeleteTrash = failure.trashedFiles
                    if !failure.removedPaths.isEmpty { onRevisionChanged(failure.localizedDescription); requestRepositoryRefresh() }
                }
                if request == generation, fileRequest == fileSelectionGeneration, selection == selected, fileSelection == selectedFiles, !isInvalidated { self.error = error.localizedDescription }
            }
        }
    }
    var onIgnoreFiles: ((RepositoryAction, [String]) -> Void)?
    func canIgnoreFiles(_ ids: some Sequence<String>) -> Bool {
        let ids = GitPathSet(ids)
        guard hasRepresentableFilePaths(ids) else { return false }
        guard !busy, !isInvalidated, !bare, onIgnoreFiles != nil,
              let mark = markedFile(ids) else { return false }
        return mark.action == "?" || mark.action.hasPrefix("D")
    }
    func requestIgnoreFiles(_ ids: some Sequence<String>, mask: Bool = false, folder: Bool = false) {
        let ids = GitPathSet(ids)
        guard requireNativeFilePaths(ids) else { return }
        guard canIgnoreFiles(ids) else { return }
        let chosen = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }
        var paths = chosen.map(\.path)
        if folder {
            guard chosen.count == 1 else { return }
            let parent = (paths[0] as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != "." else { return }
            paths = [parent]
        }
        do { _ = try IgnoreOptions(paths: paths, mask: mask) }
        catch { self.error = error.localizedDescription; return }
        let request = generation, selection = selected, fileSelection = selectedFiles
        let fileRequest = fileSelectionGeneration
        let working = selectedWorkingTree, revision = self.revision
        let ignorePaths = paths
        busy = true
        Task {
            defer { busy = false }
            do {
                for path in ignorePaths { try validateWorkingFileAccess(repository.root.appendingPathComponent(path)) }
                let available: [CommitFile]
                if working {
                    guard let fresh = try await repository.workingTreeHistory() else { throw RevisionComparisonFailure.selection }
                    available = fresh.files + fresh.unversioned
                } else {
                    guard let revision else { throw RevisionComparisonFailure.selection }
                    available = try await repository.logFileGroups(in: revision).flatMap { group in group.files.map { $0.inParentGroup(group.id) } }
                }
                guard chosen.allSatisfy({ file in available.contains { GitReferenceName.equal($0.path, file.path) && $0.oldPath.map { GitReferenceName($0) } == file.oldPath.map { GitReferenceName($0) } && $0.action == file.action && (working || $0.parentIndex == (file.parentIndex ?? 0)) } }) else { throw RevisionComparisonFailure.selection }
                guard request == generation, fileRequest == fileSelectionGeneration, selection == selected, fileSelection == selectedFiles, !isInvalidated else { return }
                busy = false; onIgnoreFiles?(mask ? .ignoreMask : .ignore, ignorePaths)
            } catch { if request == generation, fileRequest == fileSelectionGeneration, selection == selected, fileSelection == selectedFiles, !isInvalidated { self.error = error.localizedDescription } }
        }
    }
    var handleHistoricalRevertFailure: (String) async -> Bool = { _ in false }
    var showHistoricalRevertResult: (String) -> Void = { _ in }
    func canRevertHistoricalFiles(_ ids: some Sequence<String>, parent: Bool) -> Bool {
        let ids = GitPathSet(ids)
        guard hasRepresentableFilePaths(ids) else { return false }
        guard !busy, !isInvalidated, !bare, !selectedWorkingTree, let revision,
              let marked = markedFile(ids) else { return false }
        return parent ? revision.parents.indices.contains(marked.parentIndex ?? 0) : !marked.action.hasPrefix("D")
    }
    func revertHistoricalFiles(_ ids: some Sequence<String>, parent: Bool) {
        let ids = GitPathSet(ids)
        guard requireNativeFilePaths(ids) else { return }
        guard canRevertHistoricalFiles(ids, parent: parent), let revision else { return }
        let chosen = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }
        let request = generation, selection = selected, fileSelection = selectedFiles
        let fileRequest = fileSelectionGeneration
        historicalRevertTrash = []; busy = true
        Task {
            var restored: [String: Int] = [:], failures = 0
            let recycle = UserDefaults.standard.object(forKey: "RevertWithRecycleBin") == nil || UserDefaults.standard.bool(forKey: "RevertWithRecycleBin")
            for file in chosen {
                guard request == generation, fileRequest == fileSelectionGeneration, selection == selected, fileSelection == selectedFiles, !isInvalidated else { break }
                do {
                    try validateWorkingFileAccess(repository.root.appendingPathComponent(file.oldPath ?? file.path))
                    let targets = try await repository.prepareLogFileRevert(revision, files: [file], parent: parent)
                    guard request == generation, fileRequest == fileSelectionGeneration, selection == selected, fileSelection == selectedFiles, !isInvalidated else { break }
                    for target in targets {
                        historicalRevertTrash += try await repository.revertLogFile(target, recycle: recycle)
                        restored[target.revision, default: 0] += 1
                    }
                } catch {
                    if let failure = error as? WorkingFileRevertFailure { historicalRevertTrash += failure.trashedFiles }
                    failures += 1
                    guard request == generation, fileRequest == fileSelectionGeneration, selection == selected, !isInvalidated else { break }
                    if !(await handleHistoricalRevertFailure(file.path + "\n\n" + error.localizedDescription)) { break }
                }
            }
            if !restored.isEmpty || !historicalRevertTrash.isEmpty {
                onRevisionChanged("Historical files reverted"); requestRepositoryRefresh()
            }
            busy = false
            guard request == generation, fileRequest == fileSelectionGeneration, selection == selected, fileSelection == selectedFiles, !isInvalidated else { return }
            let message = restored.keys.sorted().map { "\(restored[$0]!) file(s) reverted to \($0)." }.joined(separator: "\n")
            showHistoricalRevertResult(message + (failures == 0 ? "" : "\n\(failures) file(s) failed."))
        }
    }
    // Log's allowed column mask excludes LFS ownership. Match the source's
    // hidden-owner menu: both commands, without fetching the server lock list.
    var onWorkingLFSOperation: (([String], Bool) -> Bool)?
    private var workingLFSCancellation: OperationCancellation?
    private var closeAfterWorkingLFSRead = false
    private(set) static var activeWorkingLFSReads = 0
    var workingLFSReadPending: Bool { workingLFSCancellation != nil }
    var readWorkingLFSSelection: (([String], OperationCancellation) async throws -> [WorkingTreeFile])?
    private func eligibleWorkingLFSEntries(_ chosen: [CommitFile], index: [WorkingTreeFile], hasLFS: Bool, submodules: GitPathSet) -> Bool {
        guard !chosen.isEmpty, chosen.allSatisfy({ $0.action != "?" && !$0.isSubmodule }) else { return false }
        let entries = chosen.compactMap { file in index.first { GitReferenceName.equal($0.id, file.path) }?.entry }
        guard entries.count == chosen.count, entries.allSatisfy({ $0.state != .untracked && $0.state != .ignored }) else { return false }
        return LFSLockingSelection.isAvailable(entries, hasLFS: hasLFS, root: repository.root, directories: submodules)
    }
    func workingLFSActions(_ ids: some Sequence<String>) -> [LFSLockMenuAction] {
        let ids = GitPathSet(ids)
        guard selectedWorkingTree, !bare, hasRepresentableFilePaths(ids) else { return [] }
        let chosen = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }
        guard chosen.count == ids.count, eligibleWorkingLFSEntries(chosen, index: workingIndexFiles, hasLFS: workingHasLFS, submodules: workingSubmodules) else { return [] }
        return [.lock, .unlock]
    }
    func canWorkingLFS(_ ids: some Sequence<String>, locked: Bool) -> Bool {
        canStartHistoryTransport && !confirmingQuit && !referencePickerBlocked && !resettingRevisionColumns &&
        onWorkingLFSOperation != nil && workingLFSCancellation == nil && workingLFSActions(ids).contains(locked ? .lock : .unlock)
    }
    @discardableResult func cancelWorkingLFSRead(closeAfter: Bool = false) -> Bool {
        guard let token = workingLFSCancellation else { return false }
        closeAfterWorkingLFSRead = closeAfterWorkingLFSRead || closeAfter
        token.cancel(); return true
    }
    func setWorkingLFSLocked(_ ids: some Sequence<String>, locked: Bool) {
        let ids = GitPathSet(ids)
        guard requireNativeFilePaths(ids), canWorkingLFS(ids, locked: locked) else { return }
        let chosen = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }
        let paths = chosen.map(\.path)
        let request = generation, selection = selected, fileRequest = fileSelectionGeneration
        let token = OperationCancellation()
        workingLFSCancellation = token; busy = true; error = nil
        Self.activeWorkingLFSReads += 1; Self.activeActionReads += 1
        Task {
            defer {
                Self.activeWorkingLFSReads -= 1; Self.activeActionReads -= 1
                if workingLFSCancellation === token {
                    workingLFSCancellation = nil
                    let closing = closeAfterWorkingLFSRead; closeAfterWorkingLFSRead = false
                    if closing, !isInvalidated { busy = false; window?.performClose(nil) }
                }
                withExtendedLifetime(access) {}
            }
            do {
                for path in paths { try validateWorkingFileAccess(repository.root.appendingPathComponent(path)) }
                let fresh: [WorkingTreeFile]
                if let readWorkingLFSSelection { fresh = try await readWorkingLFSSelection(paths, token) }
                else { fresh = try await repository.workingTreeStatus(refreshIndex: false, cancellation: token) }
                let hasLFS = try await repository.hasLFS(cancellation: token)
                let submodules = GitPathSet(try await repository.submodulePathNames(cancellation: token).map(\.rawValue))
                try token.check()
                guard request == generation, selection == selected, fileRequest == fileSelectionGeneration, !isInvalidated, !confirmingQuit,
                      !closeAfterWorkingLFSRead, window?.attachedSheet == nil else { busy = false; return }
                guard eligibleWorkingLFSEntries(chosen, index: fresh, hasLFS: hasLFS, submodules: submodules) else { throw RevisionComparisonFailure.selection }
                // The controller accepts exact captured paths and owns busy
                // through operation drain and result review, including retries.
                if onWorkingLFSOperation?(paths, locked) != true { busy = false }
            } catch {
                if request == generation, !isInvalidated {
                    busy = false
                    if !token.isCancelled { self.error = error.localizedDescription }
                }
            }
        }
    }
    var confirmWorkingFlags: (IndexFlagAction) async -> Bool = { _ in false }
    func workingFlagMark(_ ids: some Sequence<String>) -> WorkingTreeFile? {
        let ids = GitPathSet(ids)
        guard selectedWorkingTree, let file = markedFile(ids) else { return nil }
        return workingIndexFiles.first { GitReferenceName.equal($0.id, file.path) }
    }
    func canWorkingFlag(_ action: IndexFlagAction, ids: some Sequence<String>) -> Bool {
        let ids = GitPathSet(ids)
        guard !busy, !isInvalidated, !bare, let mark = workingFlagMark(ids) else { return false }
        return action.isAvailable(for: [mark])
    }
    func setWorkingFlag(_ action: IndexFlagAction, ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard requireNativeFilePaths(ids) else{return}
        guard canWorkingFlag(action, ids: ids), let mark = workingFlagMark(ids) else { return }
        let paths = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }.map(\.path)
        let request = generation, selection = selected
        let fileRequest = fileSelectionGeneration
        busy = true
        Task {
            defer { busy = false }
            guard await confirmWorkingFlags(action), request == generation, fileRequest == fileSelectionGeneration, selection == selected, !isInvalidated else { return }
            do {
                for path in paths { try validateWorkingFileAccess(repository.root.appendingPathComponent(path)) }
                try await repository.setIndexFlags(action, paths: paths, markedPath: mark.id)
                onRevisionChanged(action.rawValue); requestRepositoryRefresh()
            } catch {
                if let partial = error as? IndexFlagPartialFailure, !partial.updatedPaths.isEmpty { onRevisionChanged(partial.localizedDescription); requestRepositoryRefresh() }
                if request == generation, fileRequest == fileSelectionGeneration, !isInvalidated { self.error = error.localizedDescription }
            }
        }
    }
    func fileStatus(_ file: CommitFile) -> String {
        if selectedWorkingTree, let flags = workingIndexFiles.first(where: { GitReferenceName.equal($0.id, file.path) }), flags.assumeUnchanged || flags.skipWorktree { return flags.status }
        return file.status
    }
    var onWorkingAdd: (([String], WorkingFileAddMode) -> Void)?
    func canWorkingAdd(_ ids: some Sequence<String>, mode: WorkingFileAddMode = .normal) -> Bool {
        let ids = GitPathSet(ids)
        guard hasRepresentableFilePaths(ids) else { return false }
        guard !busy, !isInvalidated, !bare, selectedWorkingTree,
              onWorkingAdd != nil || mode == .normal && onWorkingFiles != nil,
              let mark = markedFile(ids), mark.action == "?" || workingFlagMark(ids)?.entry.hasUnversionedCopy == true else { return false }
        if mode == .normal { return true }
        guard !mark.isSubmodule, let type = try? FileManager.default.attributesOfItem(atPath: repository.root.appendingPathComponent(mark.path).path)[.type] as? FileAttributeType else { return false }
        return type != .typeDirectory
    }
    func requestWorkingAdd(_ ids: some Sequence<String>, mode: WorkingFileAddMode = .normal) {
        let ids = GitPathSet(ids)
        guard requireNativeFilePaths(ids) else { return }
        guard canWorkingAdd(ids, mode: mode), let mark = markedFile(ids) else { return }
        let paths = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }.map(\.path)
        let request = generation, selection = selected, fileSelection = selectedFiles
        let fileRequest = fileSelectionGeneration
        busy = true
        Task {
            defer { busy = false }
            do {
                for path in paths { try validateWorkingFileAccess(repository.root.appendingPathComponent(path)) }
                guard let fresh = try await repository.workingTreeHistory() else { throw RevisionComparisonFailure.selection }
                let available = fresh.files + fresh.unversioned
                guard GitPathSet(paths).isSubset(of: GitPathSet(available.map(\.path))), fresh.unversioned.contains(where: { GitReferenceName.equal($0.path, mark.path) }) else { throw RevisionComparisonFailure.selection }
                if mode != .normal, try await !repository.addSelectionIsFiles([mark.path]) { throw RevisionComparisonFailure.selection }
                guard request == generation, fileRequest == fileSelectionGeneration, selection == selected, fileSelection == selectedFiles, !isInvalidated else { return }
                busy = false
                if let onWorkingAdd { onWorkingAdd(paths, mode) }
                else if mode == .normal { onWorkingFiles?(.add, paths) }
            } catch { if request == generation, fileRequest == fileSelectionGeneration, selection == selected, fileSelection == selectedFiles, !isInvalidated { self.error = error.localizedDescription } }
        }
    }
    func canWorkingFiles(_ action: RepositoryAction, ids: some Sequence<String>) -> Bool {
        let ids = GitPathSet(ids)
        guard hasRepresentableFilePaths(ids) else { return false }
        if action == .add { return canWorkingAdd(ids) }
        guard !busy, !isInvalidated, !bare, selectedWorkingTree, onWorkingFiles != nil else { return false }
        let chosen = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return false }
        if action == .revert { return chosen.contains { $0.action != "?" } }
        if action == .commit, let mark = workingFlagMark(ids), mark.assumeUnchanged || mark.skipWorktree { return false }
        return action == .commit
    }
    func requestWorkingFiles(_ action: RepositoryAction, ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard requireNativeFilePaths(ids) else { return }
        if action == .add { requestWorkingAdd(ids); return }
        guard canWorkingFiles(action, ids: ids), let onWorkingFiles else { return }
        let paths = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) && (action != .revert || $0.action != "?") }.map(\.path)
        let request = generation, selection = selected
        let fileRequest = fileSelectionGeneration
        busy = true
        Task {
            defer { busy = false }
            do {
                for path in paths { try validateWorkingFileAccess(repository.root.appendingPathComponent(path)) }
                guard let fresh = try await repository.workingTreeHistory() else { throw RevisionComparisonFailure.selection }
                let available = fresh.files + fresh.unversioned
                guard GitPathSet(paths).isSubset(of: GitPathSet(available.map(\.path))) else { throw RevisionComparisonFailure.selection }
                guard request == generation, fileRequest == fileSelectionGeneration, selection == selected, !isInvalidated else { return }
                busy = false; onWorkingFiles(action, paths)
            } catch { if request == generation, fileRequest == fileSelectionGeneration, selection == selected, !isInvalidated { self.error = error.localizedDescription } }
        }
    }
    func selectedFileDiff(_ ids: some Sequence<String>, alternate: Bool = false) {
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        let ids = GitPathSet(ids)
        guard requireHistoricalFilePaths(ids) else { return }
        guard canInspectHistory, selectedWorkingTree || revision != nil else { return }
        let working = selectedWorkingTree, revision = self.revision
        let chosen = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }
        guard !chosen.isEmpty, !working || workingTreeSnapshot?.entry.parents.first != nil && chosen.allSatisfy({ $0.action != "?" }) else { return }
        let request = generation, selection = selected
        let fileRequest = fileSelectionGeneration
        let id = UUID(), session = FileListComparisonSession(window: window, preferences: labelDefaults)
        unifiedSessions[id] = session; busy = true
        Task {
            defer { unifiedSessions.removeValue(forKey: id); if request == generation, !loadingHistory, unifiedSessions.isEmpty { busy = false }; withExtendedLifetime(access) {} }
            do {
                try await session.run(selectedCount: 0) { [self] token in
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let bytes: Data
                    if working { bytes = try await repository.workingTreeFileDiffData(files: chosen, cancellation: token) }
                    else if let revision { bytes = try await repository.revisionFileDiffData(revision, files: chosen, cancellation: token) }
                    else { return }
                    guard request == generation, fileRequest == fileSelectionGeneration, selection == selected, !isInvalidated, !token.isCancelled else { return }
                    if let onUnifiedDiff { try await onUnifiedDiff(bytes, alternate) }
                    else if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: labelDefaults, title: working ? "Selected working-tree changes" : "Selected revision changes", permissions: access.map { [$0] } ?? [], cancellation: token) {
                        guard request == generation, fileRequest == fileSelectionGeneration, selection == selected, !isInvalidated, !token.isCancelled else { return }
                        unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: working ? "Selected working-tree changes" : "Selected revision changes", preferences: labelDefaults, onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
                }
            } catch { if request == generation, fileRequest == fileSelectionGeneration, selection == selected, !isInvalidated, !session.cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func canCompareFilePair(_ ids: some Sequence<String>) -> Bool {
        let ids = GitPathSet(ids)
        guard !selectedWorkingTree || hasRepresentableFilePaths(ids) else { return false }
        let chosen = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }
        return chosen.count == 2 && !GitReferenceName.equal(chosen[0].path, chosen[1].path) && chosen.allSatisfy { !$0.isSubmodule }
    }
    func compareFilePair(_ ids: some Sequence<String>) {
        let ids = GitPathSet(ids)
        guard requireHistoricalFilePaths(ids) else { return }
        guard canInspectHistory, canCompareFilePair(ids) else{return}
        acceptedNavigationRepository=repository.capturingDiffBackend(preferences:labelDefaults)
        if selectedWorkingTree {
            guard !bare, canCompareFilePair(ids), let onWorkingFilePairCompare else { return }
            onWorkingFilePairCompare(fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }.map(\.path)); return
        }
        guard let revision, let onFilePairCompare else { return }
        let chosen = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }
        guard chosen.count == 2, chosen.allSatisfy({ !$0.isSubmodule }) else { return }
        onFilePairCompare(revision.hash, chosen)
    }
    func fileParentComparisonTitle(_ ids: some Sequence<String>) -> String? {
        let ids = GitPathSet(ids)
        guard !selectedWorkingTree, let revision else { return nil }
        let index = markedFile(ids)?.parentIndex ?? 0
        guard let parent = parentChoices(for: revision).first(where: { $0.number == index + 1 }) else { return nil }
        return "Compare parent with working tree: " + parent.title
    }
    func canCompareFilesWithParent(_ ids: some Sequence<String>) -> Bool {
        let ids = GitPathSet(ids)
        guard hasRepresentableFilePaths(ids) else { return false }
        return canInspectHistory && !bare && !selectedWorkingTree && revision?.parents.first != nil && (onFileCompare != nil || onFileComparisons != nil) && visibleFiles.contains { ids.contains($0.id) }
    }
    func compareFiles(_ ids: some Sequence<String>, workingTree: Bool = false, parentWorkingTree: Bool = false) {
        let ids = GitPathSet(ids)
        guard requireHistoricalFilePaths(ids) else { return }
        if workingTree || parentWorkingTree {guard requireNativeFilePaths(ids) else{return}}
        guard canInspectHistory, onFileCompare != nil || onFileComparisons != nil else { return }
        let chosen = fileTableRows.compactMap(\.file).filter { ids.contains($0.id) }; guard !chosen.isEmpty else { return }
        var requests: [(ComparisonRevision, ComparisonRevision, [String])] = []
        if selectedWorkingTree {
            guard !workingTree, !parentWorkingTree, let snapshot = workingTreeSnapshot else { return }
            requests = [(snapshot.entry.parents.first.map { .revision($0) } ?? .emptyTree, .workingTree, chosen.map(\.path))]
        } else {
            guard let revision, !(workingTree || parentWorkingTree) || !bare else { return }
            if parentWorkingTree { guard canCompareFilesWithParent(ids) else { return } }
            for index in Set(chosen.map { $0.parentIndex ?? 0 }).sorted() {
                let parent = revision.parents.indices.contains(index) ? ComparisonRevision.revision(revision.parents[index]) : .emptyTree
                requests.append((workingTree ? .revision(revision.hash) : parent, workingTree || parentWorkingTree ? .workingTree : .revision(revision.hash), chosen.filter { ($0.parentIndex ?? 0) == index }.map(\.path)))
            }
        }
        acceptedNavigationRepository=repository.capturingDiffBackend(preferences:labelDefaults)
        if let onFileComparisons { onFileComparisons(requests) }
        else { for (from, to, paths) in requests { onFileCompare?(from, to, paths) } }
    }
    func doubleClickRevision() {
        guard labelDefaults.bool(forKey: "DiffByDoubleClickInLog"), canInspectHistory,
              let chosen = entries.first(where: { selected.contains($0.hash) }) else { return }
        guard let parent = chosen.parents.first else {
            let message = "No previous version."
            if let window, window.attachedSheet == nil {
                let alert = NSAlert(); alert.messageText = message; alert.alertStyle = .informational
                alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
            } else { navigationNotice = message }
            return
        }
        guard !chosen.hash.isEmpty || !bare else { return }
        if followedPath != nil, onFollowedFileComparison != nil {
            compareFollowed(from: .revision(parent), to: chosen.hash.isEmpty ? .workingTree : .revision(chosen.hash), parentOf: chosen.hash.isEmpty ? nil : chosen.hash)
        } else { onCompare?(.revision(parent), chosen.hash.isEmpty ? .workingTree : .revision(chosen.hash)) }
    }
    func compare(workingTree: Bool = false, parent:Int? = nil) {
        guard canInspectHistory, !workingTree || !bare else { return }
        let from: ComparisonRevision, to: ComparisonRevision, previousOf: String?
        if includesWorkingTree, !workingTree, selected.count <= 2 || continuousHistorySelection {
            let base = revisions.last?.hash ?? workingTreeSnapshot?.entry.parents.first
            from = base.map { .revision($0) } ?? .emptyTree; to = .workingTree; previousOf = nil
        } else {
            let chosen = revisions
            guard canCompareRevisionSelection, !workingTree || chosen.count == 1 else { return }
            if let parent {
                guard chosen.count == 1, !workingTree, parent > 0, parent <= chosen[0].parents.count else { return }
                from = .revision(chosen[0].parents[parent - 1]); to = .revision(chosen[0].hash); previousOf = chosen[0].hash
            } else if workingTree { from = .revision(chosen[0].hash); to = .workingTree; previousOf = nil }
            else if chosen.count >= 2 { from = .revision(chosen.last!.hash); to = .revision(chosen[0].hash); previousOf = nil }
            else { from = chosen[0].parents.first.map { .revision($0) } ?? .emptyTree; to = .revision(chosen[0].hash); previousOf = chosen[0].hash }
        }
        if followedPath != nil, onFollowedFileComparison != nil { compareFollowed(from: from, to: to, parentOf: previousOf) }
        else { onCompare?(from, to) }
    }
    private func workingTreeDiff(path: String?, alternate: Bool) {
        let repository=self.repository.capturingDiffBackend(preferences:labelDefaults)
        guard selected.count <= 2, let base = revisions.first?.hash ?? workingTreeSnapshot?.entry.parents.first else { return }
        let request = generation, selection = selected, detail = detailGeneration
        let followed = path == nil ? followedPath : nil, rows = entries
        let scope = path.map { [$0] } ?? (showWholeProject ? [] : historyPaths)
        let id = UUID(), session = FileListComparisonSession(window: window, preferences: labelDefaults)
        unifiedSessions[id] = session; busy = true
        Task {
            defer { unifiedSessions.removeValue(forKey: id); if request == generation { busy = false }; withExtendedLifetime(access) {} }
            do {
                try await session.run(selectedCount: 0) { [self] token in
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let bytes: Data
                    if let followed {
                        let snapshot = try await repository.followedHistoryComparison(path: followed, entries: rows, from: .revision(base), to: .workingTree, cancellation: token)
                        bytes = try await repository.revisionComparisonPatchData(snapshot, cancellation: token)
                    } else {
                        let args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", base, "--"] + scope
                        bytes = try await repository.unifiedDiffData(arguments:args,cancellation:token)
                    }
                    guard request == generation, detailGeneration == detail, selection == selected, !isInvalidated, !token.isCancelled else { return }
                    if let onUnifiedDiff { try await onUnifiedDiff(bytes, alternate) }
                    else if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: labelDefaults, title: "Working tree changes", permissions: access.map { [$0] } ?? [], cancellation: token) {
                        guard request == generation, detailGeneration == detail, selection == selected, !isInvalidated, !token.isCancelled else { return }
                        unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: "Working tree changes", preferences: labelDefaults, onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
                }
            } catch { if request == generation, detailGeneration == detail, selection == selected, !isInvalidated, !session.cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

@MainActor final class LogFileMenuSnapshot {
    fileprivate weak var owner: LogWindowModel?
    fileprivate let menuGeneration: UUID, selectionGeneration: UUID
    let ids: GitPathSet
    fileprivate let visible: [CommitFile]
    fileprivate var consumed = false
    fileprivate init(owner: LogWindowModel, menuGeneration: UUID, selectionGeneration: UUID, ids: GitPathSet, visible: [CommitFile]) {
        self.owner = owner; self.menuGeneration = menuGeneration; self.selectionGeneration = selectionGeneration; self.ids = ids; self.visible = visible
    }
}

struct LogFileTableRow: Identifiable {
    let rawID: String
    var id: String { GitPathRowIdentity.encode(rawID) }
    let file: CommitFile?
    let header: String?
    var status=""
    var statusEntry:StatusEntry? { file.flatMap {StatusEntry.parse(Data((" M " + $0.path + "\0").utf8)).first} }
}
struct LogChangedFileSort:SortComparator {
    let column:StatusListColumn
    var order:SortOrder = .forward
    func compare(_ lhs:LogFileTableRow,_ rhs:LogFileTableRow)->ComparisonResult {
        guard let a=lhs.file,let b=rhs.file,let ea=lhs.statusEntry,let eb=rhs.statusEntry else {return .orderedSame}
        var result:ComparisonResult
        if column == .status {
            result=lhs.status.compare(rhs.status,options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))
            if result == .orderedSame {result=StatusListSorting.compare(ea,eb,column:.path)}
        } else {result=StatusListSorting.compare(ea,eb,column:column,lhsStatistics:a,rhsStatistics:b,lhsDirectory:a.isSubmodule,rhsDirectory:b.isSubmodule)}
        return order == .forward ? result:result == .orderedAscending ? .orderedDescending:result == .orderedDescending ? .orderedAscending:.orderedSame
    }
}

extension LogWindowModel {
    private func sortedChangedFiles(_ files:[CommitFile])->[LogFileTableRow] {
        files.map {LogFileTableRow(rawID:$0.id,file:$0,header:nil,status:fileStatus($0))}.sorted {a,b in
            for comparator in changedFileSort {let result=comparator.compare(a,b);if result != .orderedSame {return result == .orderedAscending}}
            return a.rawID.utf8.lexicographicallyPrecedes(b.rawID.utf8)
        }
    }
    var fileTableRows: [LogFileTableRow] {
        guard !hidesTooManyFiles else { return [] }
        guard !selectedWorkingTree, !fileGroups.isEmpty else {
            return sortedChangedFiles(visibleFiles)
        }
        return fileGroups.flatMap { group -> [LogFileTableRow] in
            let visible = visibleFiles.filter { $0.parentIndex == group.id }
            if (!filterPaths.isEmpty || unrelatedPathMode == .hide) && visible.isEmpty { return [] }
            let title = "Diff with parent \(group.id + 1): " + (group.parent.map { String($0.prefix(8)) } ?? "Empty tree")
            return [LogFileTableRow(rawID: "\0header\(group.id)", file: nil, header: title)] + sortedChangedFiles(visible)
        }
    }
    var fileTableSelection: Binding<Set<String>> {
        Binding(get: { self.nativeFileSelection }, set: { self.nativeFileSelection = $0 })
    }
}

struct LogDialog: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: LogWindowModel
    var savesColumnLayout = true
    @AppStorage("LogDateFormat") private var shortDate = true
    @AppStorage("RelativeTimes") private var relativeTimes = false
    @AppStorage("UseSystemLocaleForDates") private var useSystemLocale = true
    var body: some View {
        VStack(spacing: 8) {
            DialogCommandRows(spacing:6) {
                LogControlMenuButton(model: model, kind: .reference).frame(minWidth: 125, idealWidth: 135, maxWidth: 145)
                LogControlMenuButton(model: model, kind: .limit).fixedSize()
                LogHistoryDatePicker(model: model, from: true).fixedSize()
                HStack(spacing:4) {
                    Text("To:")
                    LogHistoryDatePicker(model: model, from: false).fixedSize()
                }
                LogFilterField(model: model).frame(minWidth:140,idealWidth:180).layoutValue(key:DialogCommandRows.Flexible.self,value:true)
                HStack(spacing:6) {
                Picker("Jump", selection: Binding(get:{model.jumpKind},set:model.chooseJumpKind)) {
                    ForEach(HistoryJumpKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 150).disabled(!model.canNavigateLog).help("Jump to revision · Option-Left/Right goes Back/Forward")
                .contextMenu { TurtleGitContextMenu {
                    Button {model.moveSelectionHistory(up:true,selectTarget:true)} label: {CommandLabel(title:"Back",icon:.jumpUp)}.disabled(!model.canMoveHistory(up:true))
                    Button {model.moveSelectionHistory(up:false,selectTarget:true)} label: {CommandLabel(title:"Forward",icon:.jumpDown)}.disabled(!model.canMoveHistory(up:false))
                    Divider()
                    Button {model.moveSelectionHistory(up:true,selectTarget:false)} label: {CommandLabel(title:"Back without selecting",icon:.jumpUp)}.disabled(!model.canMoveHistory(up:true))
                    Button {model.moveSelectionHistory(up:false,selectTarget:false)} label: {CommandLabel(title:"Forward without selecting",icon:.jumpDown)}.disabled(!model.canMoveHistory(up:false))
                    Divider()
                    Button {model.pasteGitHash()} label: {CommandLabel(title:"Go to copied commit hash",icon:.copy)}.disabled(!model.canNavigateLog)
                } }
                Button { model.jump(up: true) } label: { CommandLabel(title: "", icon: .jumpUp) }.help("Jump up").accessibilityLabel("Jump up").disabled(!model.canJump(up:true))
                Button { model.jump(up: false) } label: { CommandLabel(title: "", icon: .jumpDown) }.help("Jump down").accessibilityLabel("Jump down").disabled(!model.canJump(up:false))
                }

            }.font(.system(size: 12))
            VSplitView {
                RevisionTable(model: model, savesColumnLayout: savesColumnLayout).frame(minHeight: 200, idealHeight: 350)
                HStack(alignment: .top, spacing: 0) {
                    LogMessageView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.showGravatar { LogGravatarView(loader: model.gravatar) }
                }.frame(minHeight: 110, idealHeight: 150)
                    .onChange(of: shortDate) { _ in model.objectWillChange.send() }
                    .onChange(of: relativeTimes) { _ in model.objectWillChange.send() }
                    .onChange(of: useSystemLocale) { _ in model.objectWillChange.send() }
                Table(of:LogFileTableRow.self,selection:$model.nativeFileSelection,sortOrder:Binding(get:{model.changedFileSort},set:model.setChangedFileSort)) {
                    TableColumn("Path",sortUsing:LogChangedFileSort(column:.path)) { row in
                        if let header = row.header {
                            Text(header).fontWeight(.semibold).foregroundStyle(Color.accentColor).accessibilityAddTraits(.isHeader)
                        } else if let file = row.file {
                            HStack(spacing:4) { if let icon=model.changedFileIcon(file) {Image(nsImage:icon)};Text(model.changedFileText(file,column:.path)).background(NativeListSelectionLabelMarker()) }.foregroundStyle(model.fileForeground(file, selected: model.selectedFiles.contains(file.id))).repositoryFileHelp(repository: model.repository.root, path: file.path, detail: file.oldPath.map { "Renamed from " + RepositoryBrowserGitPath.display(key:$0) } ?? "", preferences: model.colorPreferences)
                        }
                    }.width(min: 260, ideal: 460)
                    TableColumn("Extension",sortUsing:LogChangedFileSort(column:.fileExtension)) { row in Text(row.file.map { StatusListClipboard.fileExtension($0.path, isDirectory: $0.isSubmodule) } ?? "").foregroundStyle(row.file.map { model.fileForeground($0, selected: model.selectedFiles.contains(row.rawID)) } ?? .primary) }.width(80)
                    TableColumn("Status",sortUsing:LogChangedFileSort(column:.status)) { row in Text(FileListLabels.caption(row.file.map(model.fileStatus) ?? "")).foregroundStyle(row.file.map { model.fileForeground($0, selected: model.selectedFiles.contains(row.rawID)) } ?? .primary) }.width(95)
                    TableColumn("Lines added",sortUsing:LogChangedFileSort(column:.added)) { row in Text(row.file?.addedText ?? "").foregroundStyle(row.file.map { model.fileForeground($0, selected: model.selectedFiles.contains(row.rawID)) } ?? .primary) }.width(90)
                    TableColumn("Lines removed",sortUsing:LogChangedFileSort(column:.removed)) { row in Text(row.file?.removedText ?? "").foregroundStyle(row.file.map { model.fileForeground($0, selected: model.selectedFiles.contains(row.rawID)) } ?? .primary) }.width(105)
                } rows: {
                    ForEach(model.fileTableRows) {row in
                        TableRow(row)
                    }
                }.tableStyle(.bordered(alternatesRowBackgrounds:false)).fileListFont().frame(minHeight: 130, idealHeight: 180)
                .background(LogFileDragInteraction(model:model,rows:model.fileTableRows))
                .background(CommitFileInteraction(rows:model.fileTableRows.map {row in
                    if let title=row.header {return .group(.changelist(title))}
                    return row.statusEntry.map(StatusListRow.file) ?? .group(.changelist(""))
                },leadingColumnCount:0,keyboardDeleteEnabled:model.selectedWorkingTree,nativeColumns:StatusListColumn.defaultColumns,
                    rowTexts:model.fileTableRows.map {row in Dictionary(uniqueKeysWithValues:StatusListColumn.defaultColumns.map {column in (column,row.file.map {file in model.changedFileText(file,column:column)} ?? "")})},
                    itemIDs:model.fileTableRows.map(\.rawID),copyIDs:{model.copyChangedFileIDs($0,status:$1)},copyColumnIDs:{model.copyChangedFileIDs($0,column:$1)},
                    preferences:model.colorPreferences,visibleColumns:model.changedFileColumns.visible,availableColumns:Set(StatusListColumn.defaultColumns),columnText:{_,_ in ""},
                    savedOrder:model.changedFileColumns.order,savedWidths:model.changedFileColumns.widths,saveLayout:{model.saveChangedFileLayout(order:$0,widths:$1)},
                    setColumnVisible:model.setChangedFileColumn,resetColumns:{model.resetChangedFileColumns(choose:$0,accepted:$1)},focusedPath:$model.focusedChangedFile,
                    enabled:model.canInspectHistory && !model.resettingChangedFileColumns,delete:{_,_,permanent in model.deleteWorkingFiles(model.selectedFiles,permanently:permanent,keyboard:true)},
                    copy:{_,_ in},copyColumn:{_,_ in},toggleCheck:{_,_ in}))
                .overlay { if model.hidesTooManyFiles { Text("Too many files to display.").foregroundStyle(.secondary).allowsHitTesting(false) } }
                .onDeleteCommand { model.deleteWorkingFiles(model.selectedFiles, permanently: NSEvent.modifierFlags.contains(.shift), keyboard: true) }
                .contextMenu(forSelectionType: String.self) { ids in
                    TurtleGitContextMenu {
                        fileContextActions(GitPathRowIdentity.paths(ids))
                    }
                } primaryAction: { ids in
                    let paths = GitPathRowIdentity.paths(ids); model.selectedFiles = paths; model.primaryFileAction(paths)
                }
            }
            .background(LogPaneLayoutBridge(model: model))
            Text(model.information.text).font(.system(size: 11)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).help(model.information.text)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show Whole Project", isOn: Binding(get: { model.showWholeProject }, set: model.setWholeProject)).toggleStyle(.checkbox).disabled(!model.canChangeWholeProject)
                        .help(model.historyPaths.map { RepositoryBrowserGitPath.display(key:$0) }.joined(separator: "\n"))
                LogReferenceScopeCheckbox(model: model, scope: model.effectiveReferenceScope, enabled: model.canChangeStartReference && !model.historyWalk.followRenames) { model.chooseReferenceScope($0 ? .all : .current, persistImmediately: true) }

                }.frame(width: 220, alignment: .leading)
                LogFilterField(model: model, kind: .paths).frame(minWidth: 180, maxWidth: .infinity)
                Button("Help") { TurtleGitHelp.show(.log) }
            }
            VStack(alignment:.leading,spacing:4) {
                if model.busy && !model.loadingHistory { ProgressView().controlSize(.small) }
                if model.patchPreviewLoading { ProgressView("Reading patch…").controlSize(.small) }
                if let error = model.patchPreviewError { Text(error).foregroundStyle(.red).font(.caption) }
                if let error = model.patchPreferenceError { Text("Could not remember View Patch: " + error).foregroundStyle(.red).font(.caption) }
                if model.loadingNote { ProgressView("Reading notes…").controlSize(.small) }
                if model.copyingDetails { ProgressView("Reading log details for clipboard…").controlSize(.small) }
            }.frame(maxWidth:.infinity,alignment:.leading)
            HStack {
                Button("Refresh") { model.refreshFromSourceCommand() }.disabled(!model.canUseSourceCommands)
                if model.loadingHistory {
                    HStack(spacing:8) {
                        ProgressView().controlSize(.small)
                        Text("Read \(model.loadedRevisionCount) revisions…").font(.caption).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("Log.HistoryLoading")
                } else {
                    Button("Statistics") { model.showStatistics() }.disabled(!model.canShowStatistics)
                    LogControlMenuButton(model: model, kind: .walk).fixedSize()
                    LogControlMenuButton(model: model, kind: .view).fixedSize()
                }
                Spacer()
                Button("OK") { model.accept() }.disabled(model.selecting && !model.canAcceptSelection).keyboardShortcut(.defaultAction)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
            }
        }.padding(12).frame(minWidth: 1040, minHeight: 650)
        .disabled(model.resettingRevisionColumns)
        .alert("Git operation failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Log navigation", isPresented: Binding(get: { model.navigationNotice != nil }, set: { if !$0 { model.navigationNotice = nil } })) {
            Button("OK") { model.navigationNotice = nil }
        } message: { Text(model.navigationNotice ?? "") }
        .sheet(isPresented: $model.configureHistoryDefaults) { HistoryLimitSettings(defaults: model.colorPreferences, onClose: { model.configureHistoryDefaults = false }).frame(width: 440).padding(20) }
        .sheet(item: $model.commandRequest) { request in LogRevisionDialog(model: model, request: request) }

    }
    @ViewBuilder private func fileContextActions(_ ids: GitPathSet) -> some View {
        let snapshot = model.fileMenuSnapshot(ids)
        if !model.hasRepresentableFilePaths(ids) {
            if !model.selectedWorkingTree {
                Button { model.withFileMenu(snapshot, inspection: true) { model.compareFiles(ids) } } label: { CommandLabel(title:"Compare with base",icon:.compare) }.disabled(!model.canInspectHistory || model.revision == nil || model.onFileCompare == nil && model.onFileComparisons == nil)
                Button { model.withFileMenu(snapshot, inspection: true) { model.selectedFileDiff(ids,alternate:NSEvent.modifierFlags.contains(.shift)) } } label: { CommandLabel(title:"Show changes as unified diff",icon:.unifiedDiff) }.disabled(!model.canInspectHistory || model.revision == nil)
                if model.canCompareFilePair(ids) {
                    Button { model.withFileMenu(snapshot, inspection: true) { model.compareFilePair(ids) } } label: { CommandLabel(title:"Compare two files",icon:.compare) }.disabled(!model.canInspectHistory || model.onFilePairCompare == nil)
                }
                if ids.count == 1,let file=model.visibleFiles.first(where:{ids.contains($0.id)}),!file.isSubmodule,!file.action.hasPrefix("D") {
                    historicalFileActions(ids,snapshot:snapshot)
                    preparedComparisonActions(ids,file:file,snapshot:snapshot)
                }
                Divider()
            }
            if ids.count == 1, let file=model.visibleFiles.first(where:{ids.contains($0.id)}) {
                Button { model.withFileMenu(snapshot, inspection: true) { model.fileLog(ids) } } label: { CommandLabel(title:"Show log",icon:.log) }.disabled(!model.canInspectHistory || model.onFileLog == nil)
                if file.oldPath != nil {
                    Button { model.withFileMenu(snapshot, inspection: true) { model.fileLog(ids,oldName:true) } } label: { CommandLabel(title:"Show log of old name",icon:.log) }.disabled(!model.canInspectHistory || model.onFileLog == nil)
                }
                if !file.isSubmodule && !file.action.hasPrefix("D") {
                    Button { model.withFileMenu(snapshot, inspection: true) { model.blameFile(ids) } } label: { CommandLabel(title:"Blame",icon:.blame) }.disabled(!model.canBlameFile(ids))
                }
            }
            Divider()
            Button { model.withFileMenu(snapshot, inspection: true) { model.copyChangedFileIDs(Array(ids)) } } label: { CommandLabel(title:"Copy displayed names (escaped)",icon:.copy) }.disabled(!model.canCopyFiles(ids))
            Button(RepositoryBrowserWindowModel.rawPathReason) {}.disabled(true)
        } else {
        if model.selectedWorkingTree {
            if model.markedFile(ids)?.action == "?" || model.workingFlagMark(ids)?.entry.hasUnversionedCopy == true {
                Button { model.withFileMenu(snapshot) { model.requestWorkingFiles(.add, ids: ids) } } label: { CommandLabel(title: "Add", icon: .add) }.disabled(!model.canWorkingFiles(.add, ids: ids))
                if NSEvent.modifierFlags.contains(.shift) {
                    ForEach([WorkingFileAddMode.executable, .symlink], id: \.self) { mode in
                        if model.canWorkingAdd(ids, mode: mode) {
                            Button { model.withFileMenu(snapshot) { model.requestWorkingAdd(ids, mode: mode) } } label: { CommandLabel(title: mode.rawValue, icon: .add) }
                        }
                    }
                }
            }
            Button { model.withFileMenu(snapshot) { model.requestWorkingFiles(.commit, ids: ids) } } label: { CommandLabel(title: "Commit…", icon: .commit) }.disabled(!model.canWorkingFiles(.commit, ids: ids))
            if model.visibleFiles.contains(where: { ids.contains($0.id) && $0.action != "?" }) {
                Button { model.withFileMenu(snapshot) { model.requestWorkingFiles(.revert, ids: ids) } } label: { CommandLabel(title: "Revert…", icon: .revert) }.disabled(!model.canWorkingFiles(.revert, ids: ids))
            }
            if let mark = model.workingFlagMark(ids) {
                IndexFlagsMenu(files: model.workingIndexFiles.filter { ids.contains($0.id) }, selectionMark: mark) { action in model.withFileMenu(snapshot) { model.setWorkingFlag(action, ids: ids) } }.disabled(model.busy || model.isInvalidated || model.bare)
            }
            ForEach(model.workingLFSActions(ids), id: \.self) { action in
                Button { model.withFileMenu(snapshot) { model.setWorkingLFSLocked(ids, locked: action == .lock) } } label: {
                    CommandLabel(title: action.rawValue, icon: action == .lock ? .lock : .unlock)
                }.disabled(!model.canWorkingLFS(ids, locked: action == .lock))
            }
            Divider()
        }
        let conflicts = model.workingConflictPaths(ids)
        if !conflicts.isEmpty {
            ResolveSelectionMenu(paths: conflicts, rebase: model.conflictRebase, canEdit: ids.count == 1) { action, _ in model.withFileMenu(snapshot) { model.requestWorkingConflict(action, ids: ids) } }
                .disabled(model.busy || model.isInvalidated || model.onConflictAction == nil)
            Divider()
        }
        Button { model.withFileMenu(snapshot, inspection: true) { model.compareFiles(ids) } } label: { CommandLabel(title: "Compare with base", icon: .compare) }.disabled(ids.isEmpty || model.onFileCompare == nil || !model.canInspectHistory)
        Button { model.withFileMenu(snapshot, inspection: true) { model.selectedFileDiff(ids, alternate: NSEvent.modifierFlags.contains(.shift)) } } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(ids.isEmpty || !model.canInspectHistory || (model.selectedWorkingTree ? model.workingTreeSnapshot?.entry.parents.first == nil || model.visibleFiles.contains { ids.contains($0.id) && $0.action == "?" } : model.revision == nil))
        Button { model.withFileMenu(snapshot, inspection: true) { model.compareFiles(ids, workingTree: true) } } label: { CommandLabel(title: "Compare with working tree", icon: .compare) }.disabled(ids.isEmpty || model.selectedWorkingTree || model.bare || model.onFileCompare == nil || !model.canInspectHistory)
        if !model.bare, let title = model.fileParentComparisonTitle(ids) {
            Button { model.withFileMenu(snapshot, inspection: true) { model.compareFiles(ids, parentWorkingTree: true) } } label: { CommandLabel(title: title, icon: .compare) }.disabled(!model.canCompareFilesWithParent(ids))
        }
        if model.canCompareFilePair(ids) {
            Button { model.withFileMenu(snapshot, inspection: true) { model.compareFilePair(ids) } } label: { CommandLabel(title: "Compare two files", icon: .compare) }.disabled(!model.canInspectHistory || (model.selectedWorkingTree ? model.onWorkingFilePairCompare == nil || model.bare : model.revision == nil || model.onFilePairCompare == nil))
        }
        if !model.selectedWorkingTree && !model.bare {
            if model.canRevertHistoricalFiles(ids, parent: false) || model.busy {
                Button { model.withFileMenu(snapshot) { model.revertHistoricalFiles(ids, parent: false) } } label: { CommandLabel(title: "Revert to this revision", icon: .revert) }.disabled(!model.canRevertHistoricalFiles(ids, parent: false))
            }
            if let parentTitle = model.fileParentComparisonTitle(ids) {
                Button { model.withFileMenu(snapshot) { model.revertHistoricalFiles(ids, parent: true) } } label: { CommandLabel(title: parentTitle.replacingOccurrences(of: "Compare parent with working tree", with: "Revert to parent revision"), icon: .revert) }.disabled(!model.canRevertHistoricalFiles(ids, parent: true))
            }
        }
        Divider()
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }) {
            Button { model.withFileMenu(snapshot, inspection: true) { model.fileLog(ids) } } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(!model.canInspectHistory || model.onFileLog == nil || model.selectedWorkingTree && file.action == "?")
            if file.isSubmodule && !model.bare {
                Button { model.withFileMenu(snapshot, inspection: true) { model.showSubmoduleFileLog(ids) } } label: { CommandLabel(title: "Show submodule log", icon: .log) }.disabled(!model.canShowSubmoduleFileLog(ids))
            }
            if file.oldPath != nil {
                Button { model.withFileMenu(snapshot, inspection: true) { model.fileLog(ids, oldName: true) } } label: { CommandLabel(title: "Show log of old name", icon: .log) }.disabled(!model.canInspectHistory || model.onFileLog == nil)
            }
            if !file.isSubmodule && !file.action.hasPrefix("D") {
                Button { model.withFileMenu(snapshot, inspection: true) { model.blameFile(ids) } } label: { CommandLabel(title: "Blame", icon: .blame) }.disabled(!model.canBlameFile(ids))
            }
            Divider()
        }
        Button { model.withFileMenu(snapshot, inspection: true) { model.chooseHistoricalExport(ids) } } label: { CommandLabel(title: "Export…", icon: .export) }
            .disabled((model.selectedWorkingTree ? model.busy : !model.canInspectHistory) || !model.selectedWorkingTree && model.revision == nil || !model.visibleFiles.contains(where: { ids.contains($0.id) && !$0.isSubmodule && !$0.action.hasPrefix("D") }))
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }), !file.isSubmodule && !file.action.hasPrefix("D") {
            historicalFileActions(ids, snapshot: snapshot)
        }
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }), !file.action.hasPrefix("D"), !model.bare {
            Button { model.withFileMenu(snapshot) { model.revealFile(ids) } } label: { CommandLabel(title: "Reveal in Finder", icon: .explore) }.disabled(model.busy)
        }
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") {
            preparedComparisonActions(ids, file: file, snapshot: snapshot)
        }
        if model.canDeleteWorkingFiles(ids) {
            Button { model.withFileMenu(snapshot) { model.deleteWorkingFiles(ids, permanently: NSEvent.modifierFlags.contains(.shift)) } } label: { CommandLabel(title: "Delete", icon: .remove) }
        }
        if model.canIgnoreFiles(ids) {
            let paths = model.visibleFiles.filter { ids.contains($0.id) }.map(\.path)
            IgnoreSelectionMenu(paths: paths) { action, selected in
                model.withFileMenu(snapshot) { model.requestIgnoreFiles(ids, mask: action.ignoresByExtension, folder: GitPathSet(selected) != GitPathSet(paths)) }
            }
        }
        Menu {
            ForEach(LogWindowModel.CopyFileInformation.allCases, id: \.self) { information in
                Button { model.withFileMenu(snapshot, inspection: true) { model.copyFiles(ids, information: information) } } label: { CommandLabel(title: information.rawValue, icon: .copy) }
            }
        } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }.disabled(!model.canCopyFiles(ids))
        }
    }
    @ViewBuilder private func preparedComparisonActions(_ ids: GitPathSet, file: CommitFile, snapshot: LogFileMenuSnapshot) -> some View {
        Divider()
        Button { model.withFileMenu(snapshot, inspection: true) { model.markForComparison(ids) } } label: { CommandLabel(title: "Mark for comparison", icon: .compare) }.disabled(!model.canInspectHistory || !model.selectedWorkingTree && model.revision == nil)
        if let mark = model.comparisonMark {
            Button { model.withFileMenu(snapshot, inspection: true) { model.compareWithMarkedFile(ids) } } label: { CommandLabel(title: "Compare with " + mark.label(for: file.path), icon: .compare, localized: false) }.disabled(!model.canInspectHistory || !model.selectedWorkingTree && model.revision == nil || model.onPreparedFileCompare == nil || !model.canCompareMarkedFile(ids))
        }
    }
    @ViewBuilder private func historicalFileActions(_ ids: GitPathSet, snapshot: LogFileMenuSnapshot) -> some View {
        let unavailable = (model.selectedWorkingTree ? model.busy : !model.canInspectHistory) || !model.selectedWorkingTree && model.revision == nil
        Button { model.withFileMenu(snapshot, inspection: true) { model.saveHistoricalFile(ids) } } label: { CommandLabel(title: model.selectedWorkingTree ? "Save As…" : "Save revision to…", icon: .saveAs) }.disabled(unavailable)
        Button { model.withFileMenu(snapshot, inspection: true) { model.openHistoricalFile(ids, action: .alternativeEditor) } } label: { CommandLabel(title: model.selectedWorkingTree ? "View in alternative editor" : "View revision in alternative editor", icon: .editor) }.disabled(unavailable)
        Button { model.withFileMenu(snapshot, inspection: true) { model.openHistoricalFile(ids, action: .open) } } label: { CommandLabel(title: "Open", icon: .open) }.disabled(unavailable)
        Button { model.withFileMenu(snapshot, inspection: true) { model.openHistoricalFile(ids, action: .openWith) } } label: { CommandLabel(title: "Open With…", icon: .open) }.disabled(unavailable)
    }

}

@MainActor final class LogControlMenuReceipt {
    weak var owner: LogWindowModel?
    let epoch: UUID, projection: UUID, generation: Int, selection: Set<String>
    var used = false
    init(_ model: LogWindowModel) {
        owner = model; epoch = model.logControlsEpoch; projection = model.historyProjectionEpoch
        generation = model.contextMenuGeneration; selection = model.selected
    }
}

enum LogControlMenuKind: String { case reference, limit, walk, view }

/// An item retains its own target because NSMenuItem.target is weak. Every leaf
/// in a popup shares one receipt, including nested label choices and recents.
@MainActor final class LogControlMenuItem: NSMenuItem {
    private let invokeBody: () -> Void
    init(title: String, invoke: @escaping () -> Void) {
        invokeBody = invoke
        super.init(title: title, action: #selector(invokeCaptured), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func invokeCaptured() { guard isEnabled else { return }; invokeBody() }
}

@MainActor enum LogControlMenus {
    static func make(model: LogWindowModel, kind: LogControlMenuKind) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let receipt = LogControlMenuReceipt(model)
        @discardableResult func item(_ title: String, icon: MenuIcon, checked: Bool? = nil, enabled: Bool = true, localized: Bool = true, in target: NSMenu? = nil, action: @escaping (LogWindowModel) -> Void) -> NSMenuItem {
            let entry = LogControlMenuItem(title: localized ? NSLocalizedString(title, comment: ""):title) { [weak model] in
                guard let model else { return }
                model.withLogControls(receipt) { action(model) }
            }
            entry.image = icon.contextImage(defaults: model.colorPreferences)
            entry.isEnabled = enabled && model.canChangeLogControls
            if let checked { entry.state = checked ? .on:.off }
            (target ?? menu).addItem(entry); return entry
        }
        switch kind {
        case .reference:
            item("Browse references…", icon: .branch) { $0.browseStartReference() }
            let head = model.currentBranch.isEmpty ? "HEAD":"HEAD → \"" + model.currentBranch + "\""
            item(head, icon: .branch, localized: false) { $0.chooseStartReference("HEAD") }
            item("FETCH_HEAD", icon: .fetch, enabled: model.fetchHeadRevision != nil, localized: false) { $0.chooseFetchHead() }
            for scope in [HistoryReferenceScope.all,.basic,.local] {
                item(scope == .all ? "All":scope.title, icon: .log, enabled: !model.historyWalk.followRenames) { $0.chooseReferenceScope(scope) }
            }
            if !model.recentReferences.isEmpty {
                menu.addItem(.separator())
                for reference in model.recentReferences {
                    let title = reference.count > 150 ? String(reference.prefix(150)) + "…":reference
                    item(title, icon: .log, localized: false) { $0.chooseStartReference(reference,remember: true) }.toolTip = reference
                }
            }
        case .limit:
            item("No limitation", icon: .log, checked: model.historyLimit.scale == .noLimit) { $0.chooseHistoryLimit(.noLimit) }
            let scale = model.defaultHistoryLimitScale
            if scale.requiresNumber && model.historyLimit.number > 0 {
                menu.addItem(.separator())
                item(scale.title(number:model.historyLimit.number), icon:.log, checked:model.historyLimit.scale == scale, localized:false) { $0.chooseHistoryLimit(scale) }
            }
            menu.addItem(.separator())
            item("Configure default", icon:.settings) { $0.configureHistoryDefaults = true }
        case .walk:
            for command in [HistoryWalkCommand.firstParent,.noMerges,.followRenames,.fullHistory] {
                item(command.rawValue, icon: .log, checked: model.historyWalk.contains(command), enabled: model.canToggleHistoryWalk(command)) { $0.toggleHistoryWalk(command) }
            }
            menu.addItem(.separator())
            for command in [HistoryWalkCommand.compressed,.labeled] {
                item(command.rawValue, icon: .revisionGraph, checked: model.historyWalk.contains(command), enabled: model.canToggleHistoryWalk(command)) { $0.toggleHistoryWalk(command) }
            }
        case .view:
            item("Hide Unrelated Changed Paths", icon: .status, checked: model.unrelatedPathMode == .hide) { $0.toggleUnrelatedPaths(.hide) }
            item("Gray Unrelated Changed Paths", icon: .status, checked: model.unrelatedPathMode == .gray) { $0.toggleUnrelatedPaths(.gray) }
            menu.addItem(.separator())
            item("Show Unversioned Files", icon: .add, checked: model.showUnversionedFiles) { $0.toggleUnversionedFiles() }
            menu.addItem(.separator())
            let labels = NSMenu(); labels.autoenablesItems = false
            let parent = NSMenuItem(title: NSLocalizedString("Labels",comment:""), action: nil, keyEquivalent: "")
            parent.image = MenuIcon.tag.contextImage(defaults:model.colorPreferences); parent.submenu = labels; parent.isEnabled = model.canChangeLogControls; menu.addItem(parent)
            for command in HistoryLabelCommand.allCases {
                item(command.rawValue, icon: command == .tags ? .tag:.branch, checked: model.referenceVisibility.contains(command.flag), in: labels) { $0.toggleHistoryLabel(command) }
            }
            menu.addItem(.separator())
            item("Gravatar", icon: .log, checked: model.showGravatar) { $0.toggleGravatar() }
            item("View Patch", icon: .unifiedDiff, checked: model.patchPreviewVisible) { $0.setPatchPreview(!$0.patchPreviewVisible) }
            if !model.selecting && !model.bare {
                menu.addItem(.separator())
                item("Show Working Tree Changes", icon: .status, checked: model.showWorkingTree, enabled: model.canShowWorkingTree) { $0.toggleWorkingTreeDisplay() }
            }
        }
        return menu
    }
}

@MainActor final class LogControlButton: NSButton {
    var buildMenu: (() -> NSMenu?)?
    var primary: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? { buildMenu?() }
    @objc func activateControl() {
        guard isEnabled else { return }
        if let primary { primary(); return }
        guard let menu = buildMenu?() else { return }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:bounds.maxY+3),in:self)
    }
}
struct LogControlMenuButton: NSViewRepresentable {
    @ObservedObject var model: LogWindowModel
    let kind: LogControlMenuKind
    func makeNSView(context: Context) -> LogControlButton {
        let button = LogControlButton(); button.target = button; button.action = #selector(LogControlButton.activateControl)
        button.setButtonType(.momentaryPushIn); button.font = .systemFont(ofSize:12)
        button.bezelStyle = kind == .reference ? .inline:.rounded; button.isBordered = kind != .reference
        button.alignment = kind == .reference ? .left:.center; button.lineBreakMode = .byTruncatingMiddle
        if kind != .reference { button.image = NSImage(systemSymbolName:"chevron.down",accessibilityDescription:nil); button.imagePosition = .imageTrailing; button.imageHugsTitle = true }
        button.setContentHuggingPriority(.required,for:.vertical)
        return button
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LogControlButton, context: Context) -> CGSize? {
        let size = nsView.fittingSize
        return CGSize(width:kind == .reference ? min(proposal.width ?? size.width,size.width):size.width+12,height:size.height)
    }
    func updateNSView(_ button: LogControlButton, context: Context) {
        button.identifier = .init("Log.Control." + kind.rawValue)
        switch kind {
        case .reference:
            button.title = model.startReferenceTitle; button.toolTip = model.referenceExpression
            button.contentTintColor = .linkColor; button.setAccessibilityLabel("Start reference: " + model.startReferenceTitle)
            button.primary = { [weak model] in model?.browseStartReference() }
        case .limit:
            button.title = model.historyLimitTitle == "From:" ? NSLocalizedString("From:",comment:""):model.historyLimitTitle
            button.setAccessibilityLabel(button.title); button.toolTip = NSLocalizedString("History limitation",comment:""); button.primary = nil
        case .walk:
            button.title = (model.historyWalk.isActive ? "✓ ":"") + NSLocalizedString("Walk Behavior",comment:"")
            button.setAccessibilityLabel(NSLocalizedString("Walk Behavior",comment:"")); button.primary = nil
        case .view:
            button.title = NSLocalizedString("View",comment:""); button.setAccessibilityLabel(button.title); button.primary = nil
        }
        button.isEnabled = model.canChangeLogControls
        button.buildMenu = { [weak model] in model.map { LogControlMenus.make(model:$0,kind:kind) } }
    }
    static func dismantleNSView(_ button: LogControlButton, coordinator: ()) {
        button.isEnabled = false; button.buildMenu = nil; button.primary = nil; button.target = nil; button.action = nil
    }
}

/// From's context menu is the source date control's limitation menu; the
/// visible From button exposes the same commands to keyboard/accessibility users.
@MainActor final class LogDateControl: NSDatePicker {
    var buildMenu:(()->NSMenu?)?
    override func menu(for event:NSEvent)->NSMenu? {buildMenu?() ?? super.menu(for:event)}
}
struct LogHistoryDatePicker:NSViewRepresentable {
    @ObservedObject var model:LogWindowModel
    let from:Bool
    func makeCoordinator()->Coordinator {Coordinator(model:model,from:from)}
    func makeNSView(context:Context)->LogDateControl {
        let picker=LogDateControl();picker.datePickerStyle = .textFieldAndStepper;picker.datePickerElements = .yearMonthDay
        picker.datePickerMode = .single;picker.font = .systemFont(ofSize:12);picker.isBezeled=true;picker.drawsBackground=true
        picker.target=context.coordinator;picker.action=#selector(Coordinator.changed(_:))
        picker.setContentHuggingPriority(.required,for:.horizontal)
        return picker
    }
    func updateNSView(_ picker:LogDateControl,context:Context) {
        context.coordinator.model=model;context.coordinator.from=from
        picker.identifier = .init(from ? "Log.Date.From":"Log.Date.To")
        picker.minDate=Date(timeIntervalSince1970:0);picker.maxDate=LogWindowModel.maximumHistoryDate
        let value=from ? model.from:model.to
        if picker.dateValue != value {picker.dateValue=value};picker.isEnabled=model.canChangeLogControls
        picker.setAccessibilityLabel(NSLocalizedString(from ? "From:":"To:",comment:""))
        if from {picker.buildMenu={ [weak model] in model.map{LogControlMenus.make(model:$0,kind:.limit)} }} else {picker.buildMenu=nil}
    }
    static func dismantleNSView(_ picker:LogDateControl,coordinator:Coordinator) {
        picker.isEnabled=false;picker.target=nil;picker.action=nil;picker.buildMenu=nil;coordinator.model=nil
    }
    @MainActor final class Coordinator:NSObject {
        weak var model:LogWindowModel?
        var from:Bool
        init(model:LogWindowModel,from:Bool){self.model=model;self.from=from}
        @objc func changed(_ sender:NSDatePicker){
            guard let model,model.canChangeLogControls else{return}
            if from {model.changeHistoryFrom(sender.dateValue)} else {model.changeHistoryTo(sender.dateValue)}
        }
    }
}

/// Attach to the existing SwiftUI VSplitView's AppKit split; keep its delegate,
/// dragging and keyboard/accessibility implementation. Restore only once after
/// real bounds exist and persist only on owner close, as SaveSplitterPos does.
struct LogPaneLayoutBridge: NSViewRepresentable {
    @ObservedObject var model: LogWindowModel
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) {
        probe.model = model
        model.savePaneLayout = { [weak probe] in probe?.save() }
        probe.scheduleBinding()
    }
    static func dismantleNSView(_ probe: Probe, coordinator: ()) { probe.retire() }
    @MainActor final class Probe: NSView {
        weak var model: LogWindowModel?
        private(set) weak var split: NSSplitView?
        private(set) var restored = false
        private var observer: NSObjectProtocol?
        private var queued = false, retired = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleBinding() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleBinding() }
        func scheduleBinding() {
            guard !retired, !queued else { return }; queued = true
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.queued = false; self.bindAndRestore() }
        }
        private func findSplit(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView, !split.isVertical, split.arrangedSubviews.count == 3 { return split }
            for child in view.subviews { if let split = findSplit(child) { return split } }
            return nil
        }
        private func bindAndRestore() {
            guard !retired, let model, !model.isInvalidated, let root = window?.contentView else { return }
            if split == nil, let found = findSplit(root) {
                split = found; found.identifier = .init("Log.Panes")
                observer = NotificationCenter.default.addObserver(forName:NSSplitView.didResizeSubviewsNotification,object:found,queue:.main) { [weak self] _ in DispatchQueue.main.async { self?.restoreIfNeeded() } }
            }
            restoreIfNeeded()
        }
        private func restoreIfNeeded() {
            guard !retired, !restored, let model, !model.isInvalidated, let split, split.bounds.height > 0 else { return }
            let available = Double(split.bounds.height - split.dividerThickness*2)
            guard available >= HistoryPaneLayout.minimumHeights.reduce(0,+) else { return }
            restored = true
            guard let layout = HistoryPaneLayout.load(defaults:model.colorPreferences) else { return }
            let heights = layout.heights(available:available)
            split.setPosition(heights[0],ofDividerAt:0)
            split.setPosition(heights[0] + Double(split.dividerThickness) + heights[1],ofDividerAt:1)
        }
        func save() {
            guard !retired, let model, !model.isInvalidated, let window, !window.isMiniaturized, let split,
                  split.arrangedSubviews.count == 3,
                  let layout = HistoryPaneLayout(heights:split.arrangedSubviews.map { Double($0.frame.height) }) else { return }
            layout.save(defaults:model.colorPreferences)
        }
        func retire() {
            retired = true
            if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil; split = nil
        }
    }
}

/// Native settings checkbox with the same two-way preference binding as the Dialogs page.
struct LogPreferenceCheckbox: NSViewRepresentable {
    let title: String
    @Binding var value: Bool
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        NSButton(checkboxWithTitle: NSLocalizedString(title, comment: ""), target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = NSLocalizedString(title, comment: ""); button.state = value ? .on : .off; button.isEnabled = enabled
        context.coordinator.change = { value = $0 }
    }
    final class Coordinator: NSObject {
        var change: (Bool) -> Void = { _ in }
        @objc func clicked(_ sender: NSButton) { change(sender.state == .on) }
    }
}

/// Source's editable URL presets, retaining custom values in a native combo box.
struct SettingsEditableChoices: NSViewRepresentable {
    @Binding var value: String
    let choices: [String]
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox(); combo.isEditable = true; combo.completes = true
        combo.addItems(withObjectValues:choices); combo.delegate = context.coordinator
        return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.change = { value = $0 }; combo.isEnabled = enabled
        if combo.stringValue != value { combo.stringValue = value }
        if combo.objectValues.compactMap({ $0 as? String }) != choices { combo.removeAllItems(); combo.addItems(withObjectValues:choices) }
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) { if let combo = notification.object as? NSComboBox { change(combo.stringValue) } }
        func comboBoxSelectionDidChange(_ notification: Notification) { if let combo = notification.object as? NSComboBox, let value = combo.objectValueOfSelectedItem as? String { change(value) } }
    }
}

struct LogDialogSettings: View {
    private let defaults: UserDefaults
    static let gravatarChoices = ["https://gravatar.com/avatar/%HASH%"] +
        ["mm", "identicon", "monsterid", "wavatar", "retro", "blank"].map { "https://gravatar.com/avatar/%HASH%?d=" + $0 }
    @State private var showBranchRevisionNumber: Bool
    @State private var diffByDoubleClick: Bool
    @State private var enableGravatar: Bool
    @State private var gravatarURL: String
    @State private var gravatarMD5: Bool
    @State private var shortDate: Bool
    @State private var relative: Bool
    @State private var useSystemLocale: Bool
    @State private var labelsOnRight: Bool
    @State private var symbolizeRefs: Bool
    @State private var enableLogCache: Bool
    @State private var fullMessage: Bool
    @State private var describeFirstParent: Bool
    @State private var describeLong: Bool
    @State private var describeSize: Int
    @State private var describeStrategy: Int
    @State private var showDescribe: Bool
    @State private var abbreviateRenamings: Bool
    @State private var asteriskPrefix: Bool
    @Environment(\.settingsTransaction) private var transaction
    @State private var original: [String: SettingsScalar] = [:]
    private var preferenceValues: [String: SettingsScalar] { [
        "ShowBranchRevisionNumber": .boolean(showBranchRevisionNumber),
        "DiffByDoubleClickInLog": .boolean(diffByDoubleClick),
        "EnableGravatar": .boolean(enableGravatar),
        "GravatarUrl": .string(gravatarURL),
        "GravatarUseMD5": .boolean(gravatarMD5),
        "LogDateFormat": .boolean(shortDate),
        "RelativeTimes": .boolean(relative),
        "UseSystemLocaleForDates": .boolean(useSystemLocale),
        "DrawTagsBranchesOnRightSide": .boolean(labelsOnRight),
        "SymbolizeRefNames": .boolean(symbolizeRefs),
        "AsteriskLogPrefix": .boolean(asteriskPrefix),
        "AbbreviateRenamings": .boolean(abbreviateRenamings),
        "ShowDescribe": .boolean(showDescribe),
        "DescribeStrategy": .integer(describeStrategy),
        "DescribeAbbreviatedSize": .integer(describeSize),
        "DescribeAlwaysLong": .boolean(describeLong),
        "DescribeOnlyFollowFirstParent": .boolean(describeFirstParent),
        "EnableLogCache": .boolean(enableLogCache),
        "FullCommitMessageOnLogLine": .boolean(fullMessage)
    ] }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _enableLogCache = State(initialValue: defaults.object(forKey: "EnableLogCache") as? Bool ?? true)
        _describeFirstParent = State(initialValue: (defaults.object(forKey: "DescribeOnlyFollowFirstParent") as? NSNumber)?.boolValue ?? false)
        _describeLong = State(initialValue: (defaults.object(forKey: "DescribeAlwaysLong") as? NSNumber)?.boolValue ?? false)
        _describeSize = State(initialValue: (defaults.object(forKey: "DescribeAbbreviatedSize") as? NSNumber)?.intValue ?? 7)
        _describeStrategy = State(initialValue: (defaults.object(forKey: "DescribeStrategy") as? NSNumber)?.intValue ?? 0)
        _showDescribe = State(initialValue: (defaults.object(forKey: "ShowDescribe") as? NSNumber)?.boolValue ?? false)
        _abbreviateRenamings = State(initialValue: (defaults.object(forKey: "AbbreviateRenamings") as? NSNumber)?.boolValue ?? false)
        _asteriskPrefix = State(initialValue: (defaults.object(forKey: "AsteriskLogPrefix") as? NSNumber)?.boolValue ?? true)
        _showBranchRevisionNumber = State(initialValue: (defaults.object(forKey: "ShowBranchRevisionNumber") as? NSNumber)?.boolValue ?? false)
        _diffByDoubleClick = State(initialValue: (defaults.object(forKey: "DiffByDoubleClickInLog") as? NSNumber)?.boolValue ?? false)
        _enableGravatar = State(initialValue: (defaults.object(forKey: "EnableGravatar") as? NSNumber)?.boolValue ?? false)
        _gravatarURL = State(initialValue: defaults.string(forKey: "GravatarUrl") ?? LogGravatarRequest.defaultTemplate)
        _gravatarMD5 = State(initialValue: (defaults.object(forKey: "GravatarUseMD5") as? NSNumber)?.boolValue ?? false)
        _shortDate = State(initialValue: (defaults.object(forKey: "LogDateFormat") as? NSNumber)?.boolValue ?? true)
        _relative = State(initialValue: (defaults.object(forKey: "RelativeTimes") as? NSNumber)?.boolValue ?? false)
        _useSystemLocale = State(initialValue: (defaults.object(forKey: "UseSystemLocaleForDates") as? NSNumber)?.boolValue ?? true)
        _labelsOnRight = State(initialValue: (defaults.object(forKey: "DrawTagsBranchesOnRightSide") as? NSNumber)?.boolValue ?? false)
        _symbolizeRefs = State(initialValue: (defaults.object(forKey: "SymbolizeRefNames") as? NSNumber)?.boolValue ?? false)
        _fullMessage = State(initialValue: (defaults.object(forKey: "FullCommitMessageOnLogLine") as? NSNumber)?.boolValue ?? false)
        _original = State(initialValue: [
            "EnableLogCache": .boolean(defaults.object(forKey: "EnableLogCache") as? Bool ?? true),
            "DescribeOnlyFollowFirstParent": .boolean((defaults.object(forKey: "DescribeOnlyFollowFirstParent") as? NSNumber)?.boolValue ?? false),
            "DescribeAlwaysLong": .boolean((defaults.object(forKey: "DescribeAlwaysLong") as? NSNumber)?.boolValue ?? false),
            "DescribeAbbreviatedSize": .integer((defaults.object(forKey: "DescribeAbbreviatedSize") as? NSNumber)?.intValue ?? 7),
            "DescribeStrategy": .integer((defaults.object(forKey: "DescribeStrategy") as? NSNumber)?.intValue ?? 0),
            "ShowDescribe": .boolean((defaults.object(forKey: "ShowDescribe") as? NSNumber)?.boolValue ?? false),
            "AbbreviateRenamings": .boolean((defaults.object(forKey: "AbbreviateRenamings") as? NSNumber)?.boolValue ?? false),
            "AsteriskLogPrefix": .boolean((defaults.object(forKey: "AsteriskLogPrefix") as? NSNumber)?.boolValue ?? true),
            "ShowBranchRevisionNumber": .boolean((defaults.object(forKey: "ShowBranchRevisionNumber") as? NSNumber)?.boolValue ?? false),
            "DiffByDoubleClickInLog": .boolean((defaults.object(forKey: "DiffByDoubleClickInLog") as? NSNumber)?.boolValue ?? false),
            "EnableGravatar": .boolean((defaults.object(forKey: "EnableGravatar") as? NSNumber)?.boolValue ?? false),
            "GravatarUrl": .string(defaults.string(forKey: "GravatarUrl") ?? LogGravatarRequest.defaultTemplate),
            "GravatarUseMD5": .boolean((defaults.object(forKey: "GravatarUseMD5") as? NSNumber)?.boolValue ?? false),
            "LogDateFormat": .boolean((defaults.object(forKey: "LogDateFormat") as? NSNumber)?.boolValue ?? true),
            "RelativeTimes": .boolean((defaults.object(forKey: "RelativeTimes") as? NSNumber)?.boolValue ?? false),
            "UseSystemLocaleForDates": .boolean((defaults.object(forKey: "UseSystemLocaleForDates") as? NSNumber)?.boolValue ?? true),
            "DrawTagsBranchesOnRightSide": .boolean((defaults.object(forKey: "DrawTagsBranchesOnRightSide") as? NSNumber)?.boolValue ?? false),
            "SymbolizeRefNames": .boolean((defaults.object(forKey: "SymbolizeRefNames") as? NSNumber)?.boolValue ?? false),
            "FullCommitMessageOnLogLine": .boolean((defaults.object(forKey: "FullCommitMessageOnLogLine") as? NSNumber)?.boolValue ?? false)
        ])
    }
    private func applyDraft() { preferenceValues.forEach { $0.value.save($0.key, defaults: defaults) }; original = preferenceValues }
    private func cancelDraft() {
        if case .boolean(let value) = original["EnableLogCache"] { enableLogCache = value }
        if case .boolean(let value) = original["DescribeOnlyFollowFirstParent"] { describeFirstParent = value }
        if case .boolean(let value) = original["DescribeAlwaysLong"] { describeLong = value }
        if case .integer(let value) = original["DescribeAbbreviatedSize"] { describeSize = value }
        if case .integer(let value) = original["DescribeStrategy"] { describeStrategy = value }
        if case .boolean(let value) = original["ShowDescribe"] { showDescribe = value }
        if case .boolean(let value) = original["AbbreviateRenamings"] { abbreviateRenamings = value }
        if case .boolean(let value) = original["AsteriskLogPrefix"] { asteriskPrefix = value }
        if case .boolean(let value) = original["ShowBranchRevisionNumber"] { showBranchRevisionNumber = value }
        if case .boolean(let value) = original["DiffByDoubleClickInLog"] { diffByDoubleClick = value }
        if case .boolean(let value) = original["EnableGravatar"] { enableGravatar = value }
        if case .string(let value) = original["GravatarUrl"] { gravatarURL = value }
        if case .boolean(let value) = original["GravatarUseMD5"] { gravatarMD5 = value }
        if case .boolean(let value) = original["LogDateFormat"] { shortDate = value }
        if case .boolean(let value) = original["RelativeTimes"] { relative = value }
        if case .boolean(let value) = original["UseSystemLocaleForDates"] { useSystemLocale = value }
        if case .boolean(let value) = original["DrawTagsBranchesOnRightSide"] { labelsOnRight = value }
        if case .boolean(let value) = original["SymbolizeRefNames"] { symbolizeRefs = value }
        if case .boolean(let value) = original["FullCommitMessageOnLogLine"] { fullMessage = value }
    }
    var body: some View {
        ScrollView { VStack(alignment: .leading) {
            GroupBox("Log messages") {
                VStack(alignment: .leading, spacing: 10) {
                    HistoryLimitSettings(defaults: defaults)
                    MessageEditorFontSettings(defaults: defaults)
                    Toggle("Can double-click in log list to compare with previous revision", isOn: $diffByDoubleClick)
                        .help("If checked, double-clicking on a revision in the log list compares it with the previous revision")
                    Toggle("Short date/time format in log messages", isOn: $shortDate)
                    HStack { Toggle("Relative Times in log", isOn: $relative); Toggle("Show asterisk log prefix", isOn: $asteriskPrefix) }
                    Toggle("Use system locale for date/time", isOn: $useSystemLocale)
                    Toggle("Abbreviate renamings", isOn: $abbreviateRenamings)
                    LogPreferenceCheckbox(title: "Symbolize ref names", value: $symbolizeRefs).fixedSize(horizontal: false, vertical: true)
                    LogPreferenceCheckbox(title: "Draw tag/branch labels on right side", value: $labelsOnRight).fixedSize(horizontal: false, vertical: true)
                    LogPreferenceCheckbox(title: "Display subject and body of commit messages", value: $fullMessage).fixedSize(horizontal: false, vertical: true)
                    Text("Reopen history windows to apply reference-label and full-message choices.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Enable log cache", isOn: $enableLogCache)
                    Toggle("Enable Gravatar", isOn: $enableGravatar).help("Enable showing Gravatar image in Log Dialog")
                    SettingsEditableChoices(value: $gravatarURL, choices: Self.gravatarChoices).frame(height: 24).help("Allow to use custom Gravatar URL; %HASH% is replaced by the author email hash")
                    Toggle("Use MD5 for Gravatar", isOn: $gravatarMD5).disabled(!enableGravatar)
                    Toggle("Display branch revision number", isOn: $showBranchRevisionNumber)
                        .help("Count first-parent revisions on the checked-out branch; this count is not guaranteed to be unique.")
                    GroupBox("Describe") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Show describe in log", isOn: $showDescribe)
                            Picker("Describe Strategy", selection: $describeStrategy) {
                                ForEach(HistoryDescribeStrategy.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                            }
                            HStack {
                                Text("Abbreviated size")
                                TextField("7", value: $describeSize, formatter: NumberFormatter()).frame(width: 70)
                                Toggle("Always show long format", isOn: $describeLong)
                            }
                            Toggle("Only follow first parent", isOn: $describeFirstParent)
                            if !(0...64).contains(describeSize) { Text("Enter a size from 0 to 64.").foregroundStyle(.red) }
                        }.padding(8)
                    }
                    Text("Reopen Log windows to apply asterisk and Describe preferences.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
        }.padding(20) }
        .onChange(of: preferenceValues) { _ in if transaction == nil { applyDraft() } }
        .settingsParticipant("dialogs", page: .dialogs, value: preferenceValues,
            modified: { preferenceValues != original }, validate: { (0...64).contains(describeSize) ? nil : "Enter a Describe abbreviated size from 0 to 64." }, apply: { applyDraft(); return true }, cancel: cancelDraft)
    }
}

@MainActor final class HistoryLimitSettingsModel: ObservableObject {
    @Published var scale: HistoryLimitScale
    @Published var numberText: String
    private var original: HistoryLimitDefaults
    private var originalText: String
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        let saved = HistoryLimitDefaults.load(defaults: defaults)
        let text = saved.scale.requiresNumber ? String(Int32(bitPattern: saved.number)) : ""
        self.defaults = defaults; original = saved
        scale = saved.scale; numberText = text; originalText = text
    }
    var modified: Bool { scale != original.scale || numberText != originalText }
    func choose(_ value: HistoryLimitScale) {
        scale = value
        if !value.requiresNumber { numberText = "" }
        else if numberText.isEmpty || HistoryLimitDefaults.signedNumber(numberText) == 0 { numberText = String(Int32(bitPattern: original.number)) }
    }
    func apply() { objectWillChange.send(); HistoryLimitDefaults.apply(scale: scale, numberText: numberText, defaults: defaults); original = .load(defaults: defaults); originalText = numberText }
    func cancel() { original = .load(defaults: defaults); scale = original.scale; numberText = scale.requiresNumber ? String(Int32(bitPattern: original.number)) : ""; originalText = numberText }
}
struct HistoryLimitSettings: View {
    @Environment(\.settingsTransaction) private var transaction
    @StateObject private var model: HistoryLimitSettingsModel
    private let onClose: (() -> Void)?
    init(defaults: UserDefaults = .standard, onClose: (() -> Void)? = nil) { _model = StateObject(wrappedValue: HistoryLimitSettingsModel(defaults: defaults)); self.onClose = onClose }
    init(model: HistoryLimitSettingsModel) { _model = StateObject(wrappedValue: model); onClose = nil }
    var body: some View {
        GroupBox("Default number of log messages") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Default limitation", selection: Binding(get: { model.scale }, set: { model.choose($0) })) {
                    ForEach(HistoryLimitScale.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("Number of", text: $model.numberText).disabled(!model.scale.requiresNumber)
                    .help("The number for Last N options. Should be greater than zero.")
                if transaction == nil { HStack {
                    StatusColorButton("Apply", action: { model.apply() }).frame(width: 70, height: 24).disabled(!model.modified)
                    StatusColorButton("Cancel", action: { model.cancel(); onClose?() }).frame(width: 70, height: 24)
                } }
            }.padding(8)
        }
        .onChange(of: model.scale) { _ in transaction?.notify() }
        .settingsParticipant("dialogs.limit", page: .dialogs, value: model.numberText, modified: { model.modified },
            apply: { model.apply(); return true }, cancel: model.cancel)
    }
}

/// Normal Log column labels/defaults from GitLogListBase and TortoiseLoglistCommon.
/// Rebase/ID replacement columns belong to the dedicated Rebase list.
private enum LogRevisionColumns {
    static let definitions: [(id: String, title: String, width: Double, visible: Bool)] = [
        ("graph", "Graph", 65, true), ("hash", "SHA-1", 92, false), ("actions", "Actions", 90, true),
        ("message", "Message", 420, true), ("author", "Author", 140, true),
        ("date", "Date", 170, true), ("email", "Email", 200, false),
        ("committer", "Commit Name", 140, false), ("committerEmail", "Commit Email", 200, false),
        ("committerDate", "Commit Date", 170, false), ("bugs", "Bug-ID", 110, true),
        ("svn", "SVN Rev", 100, true)
    ]
    static func visible(_ id: String, defaults: UserDefaults) -> Bool {
        guard let definition = definitions.first(where: { $0.id == id }) else { return false }
        return (defaults.object(forKey: "Log.Column.Visible." + id) as? NSNumber)?.boolValue ?? definition.visible
    }
}

struct RevisionTable: NSViewRepresentable {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: LogWindowModel
    var savesColumnLayout = true
    @AppStorage("LogFontForLogCtrl") private var useLogFont = false
    @AppStorage("LogFontName") private var fontName = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize = MessageEditorFont.defaultSize
    @AppStorage("LogDateFormat") private var shortDate = true
    @AppStorage("RelativeTimes") private var relativeTimes = false
    @AppStorage("UseSystemLocaleForDates") private var useSystemLocale = true
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = HistoryTableView()
        table.rowHeight = 24; table.intercellSpacing = NSSize(width: 4, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = !model.selecting || model.selectingMultiple; table.columnAutoresizingStyle = .noColumnAutoresizing
        for definition in LogRevisionColumns.definitions {
            let id = definition.id
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = NSLocalizedString(definition.title,comment:""); column.width = definition.width
            column.isHidden = (id != "graph" && !LogRevisionColumns.visible(id, defaults: model.colorPreferences)) || id == "graph" && model.historyWalk.followRenames || id == "bugs" && !model.issueProperties.showsBugIDColumn || id == "svn" && !model.hasGitSVN
            column.minWidth = id == "graph" ? 38 : 70; column.maxWidth = 10000; table.addTableColumn(column)
        }
        table.allowsColumnReordering = true; table.allowsColumnResizing = true
        context.coordinator.savesColumnLayout = savesColumnLayout
        if savesColumnLayout && model.colorPreferences === UserDefaults.standard && model.colorPreferences.object(forKey: "Log.Columns.Order") == nil {
            // Read the previous AppKit layout once; subsequent storage belongs
            // to the supplied dialog preferences, including private receivers.
            table.autosaveName = "TurtleGit.Log.RevisionColumns"; table.autosaveTableColumns = true
        }
        table.autosaveTableColumns = false
        let headerMenu = NSMenu(); headerMenu.delegate = context.coordinator
        let header=LogRevisionColumnHeader(frame:NSRect(x:0,y:0,width:table.bounds.width,height:max(23,table.headerView?.frame.height ?? 23)))
        header.makeMenu={ [weak coordinator=context.coordinator] in coordinator?.headerMenu }
        header.fitColumn={ [weak coordinator=context.coordinator] index,automatic in coordinator?.fitColumn(index,automatic:automatic) }
        table.headerView=header;header.menu=headerMenu;context.coordinator.headerMenu=headerMenu
        model.retireRevisionColumns={ [weak coordinator=context.coordinator] in coordinator?.retireColumnActions() }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClickRevision); table.target = context.coordinator
        table.menu = NSMenu(); table.menu?.delegate = context.coordinator
        context.coordinator.table = table
        table.onWindowChanged = { [weak coordinator = context.coordinator] in coordinator?.configureDateRefresh() }
        table.contextMenuAvailable={ [weak coordinator=context.coordinator] in
            guard let coordinator else { return false }
            return coordinator.revisionInputAvailable
        }
        table.onReturn={ [weak coordinator=context.coordinator,weak table] in
            guard let model=coordinator?.model,table?.contextMenuAvailable()==true,model.colorPreferences.bool(forKey:"DiffByDoubleClickInLog"),model.entries.contains(where:{model.selected.contains($0.hash)}) else { return false }
            model.doubleClickRevision();return true
        }
        context.coordinator.restoreColumns()
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder; scroll.documentView = table
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.model = model
        guard let table = coordinator.table else { return }
        coordinator.updating = true
        table.allowsMultipleSelection = !model.selecting || model.selectingMultiple
        let dateSettings = HistoryDateSettings(shortDate: shortDate, relative: relativeTimes, useSystemLocale: useSystemLocale)
        let colorsChanged = coordinator.colorRevision != statusColorUpdates.revision
        coordinator.colorRevision = statusColorUpdates.revision
        let datesChanged = coordinator.dateSettings != dateSettings; coordinator.dateSettings = dateSettings
        coordinator.configureDateRefresh()
        let font = useLogFont ? MessageEditorFont.resolve(name: fontName, size: fontSize) : nil
        let fontChanged = coordinator.logFont != font; coordinator.logFont = font
        table.rowHeight = font.map { max(24, ceil($0.ascender - $0.descender + $0.leading) + 4) } ?? 24
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("svn"))?.isHidden = !model.hasGitSVN || !LogRevisionColumns.visible("svn", defaults: model.colorPreferences)
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("bugs"))?.isHidden = !model.issueProperties.showsBugIDColumn || !LogRevisionColumns.visible("bugs", defaults: model.colorPreferences)
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("graph"))?.isHidden = model.historyWalk.followRenames
        let projectionChanged = coordinator.sizingProjection != model.historyProjectionEpoch
        let contentChanged = coordinator.contentEpoch != model.revisionTableContentEpoch
        let graphChanged = coordinator.graphEpoch != model.revisionGraphEpoch
        let previousRows = coordinator.renderedEntries
        coordinator.contentEpoch = model.revisionTableContentEpoch; coordinator.graphEpoch = model.revisionGraphEpoch
        coordinator.renderedEntries = model.entries
        if graphChanged { coordinator.graph = model.graph }
        let labelsChanged = coordinator.referenceVisibility != model.referenceVisibility || coordinator.referenceContext != model.referenceContext
        coordinator.referenceVisibility = model.referenceVisibility
        coordinator.referenceContext = model.referenceContext
        let searchHighlightsChanged = coordinator.searchHighlights != model.searchHighlights
        coordinator.searchHighlights = model.searchHighlights
        let highlightChanged = coordinator.highlightedRevision != model.highlightedRevision
        coordinator.highlightedRevision = model.highlightedRevision
        let sizingChanged=coordinator.sizingProjection != model.historyProjectionEpoch || graphChanged || datesChanged || labelsChanged || fontChanged || highlightChanged || coordinator.sizingFullMessage != model.fullCommitMessageOnLogLine || coordinator.sizingTagsRight != model.drawTagsBranchesOnRightSide
        coordinator.sizingProjection=model.historyProjectionEpoch;coordinator.sizingFullMessage=model.fullCommitMessageOnLogLine;coordinator.sizingTagsRight=model.drawTagsBranchesOnRightSide
        if sizingChanged || contentChanged || graphChanged || datesChanged || highlightChanged || searchHighlightsChanged || labelsChanged || fontChanged || colorsChanged {
            let appended = projectionChanged && !previousRows.isEmpty && previousRows.count < model.entries.count &&
                zip(previousRows, model.entries).allSatisfy { $0.hash == $1.hash }
            let sameRows = !projectionChanged || previousRows.count == model.entries.count &&
                zip(previousRows, model.entries).allSatisfy { $0.hash == $1.hash }
            if appended {
                table.insertRows(at: IndexSet(integersIn: previousRows.count..<model.entries.count), withAnimation: [])
            } else if !sameRows { table.reloadData() }
            // Existing rows' lanes/labels can change as parents arrive. Refresh
            // only the visible native cells; future cells use the new snapshot.
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound, visible.location < model.entries.count {
                let rows = IndexSet(integersIn: visible.location..<min(NSMaxRange(visible), model.entries.count))
                table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
            if sizingChanged { coordinator.fitAutomaticColumns(sampled: true) }
        }
        // AppKit can change its highlight before a refused notification, and
        // model selection may remain unchanged. Reconcile actual row indices,
        // rather than trusting only the last applied model selection receipt.
        if projectionChanged || coordinator.appliedSelection != model.selected || table.selectedRowIndexes != coordinator.appliedSelectionRows {
            let indices = IndexSet(model.entries.enumerated().compactMap { model.selected.contains($0.element.hash) ? $0.offset : nil })
            if table.selectedRowIndexes != indices { table.selectRowIndexes(indices, byExtendingSelection: false) }
            coordinator.appliedSelection = model.selected
            coordinator.appliedSelectionRows = indices
        }
        if coordinator.scrollRequest != model.scrollRequest {
            coordinator.scrollRequest = model.scrollRequest
            if let hash = model.scrollRevision, let row = model.entries.firstIndex(where: { $0.hash == hash }) { table.scrollRowToVisible(row) }
        }
        coordinator.renderedProjection = model.historyProjectionEpoch
        coordinator.updating = false
        // A refresh may retain the same hashes while cancelling pending reads.
        // Restart visible missing cells even when the row signature is unchanged.
        if table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("actions"))?.isHidden == false {
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                for row in visible.location..<min(NSMaxRange(visible), model.entries.count) { model.requestActions(model.entries[row]) }
            }
        }
    }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) {
        if let table=scroll.documentView as? HistoryTableView {
            table.onReturn=nil;table.onFind=nil;table.presentContextMenu=nil;table.contextMenuAvailable={false};table.onWindowChanged=nil
        }
        coordinator.retireDateRefresh();coordinator.retireColumnActions();coordinator.retired=true
        (coordinator.table?.headerView as? LogRevisionColumnHeader)?.retire()
        coordinator.table?.delegate=nil;coordinator.table?.dataSource=nil;coordinator.table?.target=nil
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: LogWindowModel
        weak var table: NSTableView?
        var headerMenu: NSMenu?
        private var columnReceipt:ColumnReceipt?
        private var columnQuestion:LogRevisionColumnQuestion?
        private var orderingTask:Task<Void,Never>?
        private var columnLayoutEpoch=UUID()
        var adjustedColumns=Set<String>()
        var retired=false
        private final class ColumnReceipt:NSObject {
            let valid:()->Bool
            var consumed=false
            init(valid:@escaping()->Bool){self.valid=valid}
            func take()->Bool {guard !consumed,valid() else{return false};consumed=true;return true}
        }
        private final class ColumnCommand:NSObject {
            let receipt:ColumnReceipt,id:String?
            init(_ receipt:ColumnReceipt,_ id:String?){self.receipt=receipt;self.id=id}
        }
        private func captureColumns()->ColumnReceipt? {
            guard columnCommandsAvailable,let table,let window=table.window else{return nil}
            let owner=model,projection=model.historyProjectionEpoch,controls=model.logControlsEpoch,layout=columnLayoutEpoch
            let generation=model.contextMenuGeneration,preferences=model.colorPreferences
            let svn=model.hasGitSVN,bugs=model.issueProperties.showsBugIDColumn,follow=model.historyWalk.followRenames
            return ColumnReceipt{[weak self,weak table,weak window] in
                guard let self,let table,let window else{return false}
                return self.model === owner && self.table === table && table.window === window && self.model.window === window && self.columnCommandsAvailable && owner.colorPreferences === preferences && owner.historyProjectionEpoch==projection && owner.logControlsEpoch==controls && owner.contextMenuGeneration==generation && self.columnLayoutEpoch==layout && owner.hasGitSVN==svn && owner.issueProperties.showsBugIDColumn==bugs && owner.historyWalk.followRenames==follow
            }
        }
        func retireColumnActions(){columnReceipt?.consumed=true;columnReceipt=nil;orderingTask?.cancel();orderingTask=nil;columnQuestion?.retire()}
        private var combineMenuTask: Task<Void, Never>?
        private var combineMenuCancellation: OperationCancellation?
        private var menuActionTarget:HistoryMenuActionTarget?
        private final class RevertTarget: NSObject {
            let entries:[LogEntry],mainline:Int?,selectedRows:[LogEntry]
            init(_ entries:[LogEntry],mainline:Int? = nil,selectedRows:[LogEntry]? = nil) {self.entries=entries;self.mainline=mainline;self.selectedRows=selectedRows ?? entries}
        }
        @objc func revertCaptured(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? RevertTarget else { return }
            model.revertCaptured(target.entries,mainline:target.mainline,selectedRows:target.selectedRows)
        }
        private final class CombineTarget: NSObject {
            let entries: [LogEntry], offset: Int, head: String, projection: UUID
            init(entries: [LogEntry], offset: Int, head: String, projection: UUID) { self.entries = entries; self.offset = offset; self.head = head; self.projection = projection }
        }
        @objc func combineRevisions(_ sender: NSMenuItem) {
            guard !model.isInvalidated, !model.busy, !model.findBlocked, !model.orderingBlocked, !model.mergeActive, !model.bare,
                  model.window?.attachedSheet == nil, model.continuousRevisionSelection, let target = sender.representedObject as? CombineTarget, target.projection == model.historyProjectionEpoch, model.revisions.map(\.hash) == target.entries.map(\.hash) else { return }
            model.onCombineRevisions?(target.entries, target.offset, target.head)
        }
        var updating = false
        var renderedEntries: [LogEntry] = []
        var renderedProjection: UUID?
        var revisionInputAvailable: Bool { selectionInputAvailable && renderedProjection == model.historyProjectionEpoch }
        // A progressive projection can be accepted before SwiftUI replaces the
        // native rows. Selection owns the displayed hash, not its old row index;
        // commands retain the stricter projection receipt above.
        var selectionInputAvailable: Bool { !retired && !updating && model.canInspectHistory }
        private func reconcileNativeSelection() {
            guard !retired,let table else{return}
            let indices=IndexSet(renderedEntries.enumerated().compactMap {model.selected.contains($0.element.hash) ? $0.offset:nil})
            guard table.selectedRowIndexes != indices else{return}
            let wasUpdating=updating;updating=true
            table.selectRowIndexes(indices,byExtendingSelection:false)
            updating=wasUpdating
        }
        func selectionShouldChange(in tableView:NSTableView)->Bool {
            updating || tableView === table && selectionInputAvailable
        }
        func tableView(_ tableView:NSTableView,shouldSelectRow row:Int)->Bool {
            if updating {return true}
            guard tableView === table,selectionInputAvailable,renderedEntries.indices.contains(row) else{return false}
            let hash=renderedEntries[row].hash
            return model.entries.contains {$0.hash==hash}
        }
        var contentEpoch: UUID?, graphEpoch: UUID?
        var appliedSelection = Set<String>()
        var appliedSelectionRows = IndexSet()
        var sizingProjection:UUID?
        var sizingFullMessage=false,sizingTagsRight=false
        var logFont: NSFont?
        var graph: [CommitGraphRow] = []
        var dateSettings = HistoryDateSettings.load()
        var searchHighlights: [String: [String: [NSRange]]] = [:]
        var highlightedRevision: String?
        var referenceVisibility = HistoryReferenceVisibility.all
        var referenceContext = HistoryReferenceContext()
        var scrollRequest = 0
        var colorRevision = -1
        private(set) var dateRefreshTimer:Timer?
        private var dateCloseObserver:NSObjectProtocol?
        private weak var dateWindow:NSWindow?
        private var dateRefreshRetired = false
        var dateNow:()->Date = Date.init
        init(model: LogWindowModel) { self.model = model }
        func configureDateRefresh() {
            guard !dateRefreshRetired, !model.isInvalidated, let window = table?.window else { return }
            if dateWindow !== window {
                if let dateCloseObserver { NotificationCenter.default.removeObserver(dateCloseObserver) }
                dateWindow = window
                dateCloseObserver = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.retireDateRefresh() }
                }
            }
            guard dateSettings.relative else { dateRefreshTimer?.invalidate(); dateRefreshTimer = nil; return }
            guard dateRefreshTimer == nil else { return }
            let timer = Timer(timeInterval:1,repeats:true) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; self.refreshDateCells(now:self.dateNow()) }
            }
            dateRefreshTimer = timer; RunLoop.main.add(timer,forMode:.common)
        }
        func refreshDateCells(now:Date) {
            guard !dateRefreshRetired, dateSettings.relative, !model.isInvalidated, !model.busy, !updating,
                  let table, let window = table.window, window.isVisible, !window.isMiniaturized else { return }
            let visible = table.rows(in:table.visibleRect); guard visible.location != NSNotFound else { return }
            for row in visible.location..<min(NSMaxRange(visible),model.entries.count) {
                let entry = model.entries[row]
                for (id,timestamp) in [("date",entry.date),("committerDate",entry.committerDate)] {
                    guard let column = table.tableColumn(withIdentifier:.init(id)), !column.isHidden,
                          let cell = table.view(atColumn:table.column(withIdentifier:.init(id)),row:row,makeIfNecessary:false) as? NSTableCellView,
                          let text = cell.textField else { continue }
                    let value = dateSettings.format(timestamp,now:now)
                    if text.stringValue != value { text.stringValue = value }
                    text.toolTip = dateSettings.format(timestamp,absolute:true)
                }
            }
        }
        func retireDateRefresh() {
            dateRefreshRetired = true; dateRefreshTimer?.invalidate(); dateRefreshTimer = nil
            if let dateCloseObserver { NotificationCenter.default.removeObserver(dateCloseObserver) }
            dateCloseObserver = nil; dateWindow = nil
        }
        deinit { dateRefreshTimer?.invalidate(); if let dateCloseObserver { NotificationCenter.default.removeObserver(dateCloseObserver) } }
        func tableView(_ tableView:NSTableView,didClick tableColumn:NSTableColumn) {
            orderingTask?.cancel()
            guard let receipt=captureColumns() else{return}
            orderingTask=Task{@MainActor [weak self] in
                do{try await Task.sleep(nanoseconds:10_000_000)}catch{return}
                guard let self,receipt.take() else{return};self.orderingTask=nil;self.model.onShowOrdering?()
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { renderedEntries.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard renderedEntries.indices.contains(row) else{return nil}
            let entry = renderedEntries[row]
            if column?.identifier.rawValue == "graph" {
                guard model.graph.indices.contains(row) else{return nil}
                let view = GraphCell(); view.parentCount = entry.parents.count; view.workingTree = entry.hash.isEmpty; view.graph = model.graph[row]; view.preferences = model.colorPreferences
                return view
            }
            if column?.identifier.rawValue == "actions" {
                model.requestActions(entry)
                let cell = NSTableCellView()
                let slots: [(LogRevisionActions, MenuIcon, String)] = [(.modified, .actionModified, "Modified"), (.added, .actionAdded, "Added/copied"), (.deleted, .actionDeleted, "Deleted"), (.replaced, .actionReplaced, "Replaced/renamed"), (.conflicted, .actionConflicted, "Conflicted")]
                var views: [NSView] = [], labels: [String] = []
                if let actions = model.revisionActions[entry.hash] {
                    for (flag, icon, title) in slots {
                        let view = NSImageView(); view.image = actions.contains(flag) ? icon.image() : nil
                        views.append(view); if actions.contains(flag) { labels.append(title) }
                    }
                    if labels.isEmpty { labels = ["No changed files"] }
                } else {
                    let failed = model.actionFailures.contains(entry.hash)
                    let view = NSImageView(); view.image = (failed ? MenuIcon.actionError : .actionFetching).image()
                    views = [view]; labels = [failed ? "Could not read changed files" : "Reading changed files"]
                }
                for view in views { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalToConstant: 16).isActive = true; view.heightAnchor.constraint(equalToConstant: 16).isActive = true }
                let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 0
                stack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stack)
                NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                cell.toolTip = labels.joined(separator: ", "); cell.setAccessibilityLabel(cell.toolTip)
                return cell
            }
            let text: NSTextField = column?.identifier.rawValue == "message" ? LogReferenceTextField(labelWithString: "") : NSTextField(labelWithString: "")
            if column?.identifier.rawValue == "message" {
                let painter = LogReferenceTextCell(textCell: "")
                painter.isEditable = false; painter.isSelectable = false; painter.isBordered = false; painter.drawsBackground = false
                text.cell = painter
            }
            text.lineBreakMode = .byTruncatingTail; text.maximumNumberOfLines = 1;text.cell?.usesSingleLineMode=true
            if let logFont { text.font = entry.isHead ? NSFontManager.shared.convert(logFont, toHaveTrait: .boldFontMask) : logFont }
            else { text.font = .systemFont(ofSize: 12, weight: entry.isHead ? .bold : .regular) }
            if model.highlightedRevision == entry.hash, let font = text.font {
                text.font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            switch column?.identifier.rawValue {
            case "hash":
                text.stringValue = entry.hash
                if logFont == nil {
                    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: entry.isHead ? .bold : .regular)
                    text.font = model.highlightedRevision == entry.hash ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
                }
            case "email": text.stringValue = entry.email
            case "committer": text.stringValue = entry.committer
            case "committerEmail": text.stringValue = entry.committerEmail
            case "committerDate": text.stringValue = dateSettings.format(entry.committerDate,now:dateNow())
            case "svn": text.stringValue = model.svnRevisions[entry.hash] ?? ""
            case "bugs": text.stringValue = entry.issueIDs
            case "author": text.stringValue = entry.author
            case "date": text.stringValue = dateSettings.format(entry.date,now:dateNow())
            default:
                let label = NSMutableAttributedString()
                let badges = NSMutableAttributedString()
                for badge in model.visibleReferenceLabels(for: entry) {
                    let reference = badge.reference
                    let color = LogPalette.native(LogColorRole.reference(reference, goodTerm: model.bisectGoodTerm, badTerm: model.bisectBadTerm), preferences: model.colorPreferences)
                    let foreground = NSColor(name: nil) { _ in LogPalette.foreground(background: color) }
                    let baseBadgeFont = logFont ?? NSFont.systemFont(ofSize: 11, weight: .medium)
                    let badgeFont = model.highlightedRevision == entry.hash ? NSFontManager.shared.convert(baseBadgeFont, toHaveTrait: .italicFontMask) : baseBadgeFont
                    let attributes: [NSAttributedString.Key: Any] = [.backgroundColor: color, .foregroundColor: foreground, .font: badgeFont]
                    let start = badges.length
                    badges.append(NSAttributedString(string: " ", attributes: attributes))
                    if badge.singleRemote {
                        let marker = NSMutableAttributedString(attachment: LogUpstreamMarker.attachment(foreground: foreground, font: badgeFont, isHead: entry.isHead))
                        marker.addAttributes(attributes, range: NSRange(location: 0, length: marker.length)); badges.append(marker)
                    }
                    badges.append(NSAttributedString(string: badge.text + " ", attributes: attributes))
                    let range = NSRange(location: start, length: badges.length - start)
                    badges.addAttribute(.logReference, value: LogReferenceStyle(badge, color: color), range: range)
                    // DrawTagBranch reserves eight points of text padding and eight
                    // additional points for an annotated tag's triangular end.
                    let space = (" " as NSString).size(withAttributes: [.font: badgeFont]).width
                    badges.addAttribute(.kern, value: 4 - space, range: NSRange(location: start, length: 1))
                    badges.addAttribute(.kern, value: 4 - space + (badge.kind == .annotatedTag ? 8 : 0), range: NSRange(location: badges.length - 1, length: 1))
                    badges.append(NSAttributedString(string: " "))
                    badges.addAttributes([.font: badgeFont, .kern: 1 - space], range: NSRange(location: badges.length - 1, length: 1))
                }
                let message = NSMutableAttributedString(string: entry.logLine(fullMessage: model.fullCommitMessageOnLogLine), attributes: [.font: text.font!])
                if model.shouldHighlightMessage(entry) { applySearchHighlights(message, hash: entry.hash, column: "message") }
                if model.drawTagsBranchesOnRightSide {
                    label.append(message)
                    if badges.length > 0 { label.append(NSAttributedString(string: " ", attributes: [.font: text.font!])); label.append(badges) }
                } else { label.append(badges); label.append(message) }
                text.attributedStringValue = label
            }
            if let column = column?.identifier.rawValue, column != "message", let ranges = searchHighlights[entry.hash]?[column], !ranges.isEmpty {
                let value = NSMutableAttributedString(string: text.stringValue, attributes: [.font: text.font!])
                applySearchHighlights(value, hash: entry.hash, column: column)
                text.attributedStringValue = value
            }
            if column?.identifier.rawValue == "message" { text.toolTip = !model.drawTagsBranchesOnRightSide && !entry.references.isEmpty ? entry.historySubject : nil }
            else if column?.identifier.rawValue == "date" { text.toolTip = dateSettings.relative ? dateSettings.format(entry.date, absolute: true) : nil }
            else if column?.identifier.rawValue == "committerDate" { text.toolTip = dateSettings.relative ? dateSettings.format(entry.committerDate, absolute: true) : nil }
            else { text.toolTip = entry.subject + "\n" + entry.hash }
            if let referenceField = text as? LogReferenceTextField {
                let hash = entry.hash, fallback = text.toolTip, historyTable = tableView as? HistoryTableView
                referenceField.configureAccessibility(message:entry.logLine(fullMessage:model.fullCommitMessageOnLogLine),
                    identity:"Log." + String(describing:ObjectIdentifier(model)) + "." + (hash.isEmpty ? "working-tree":hash),
                    revision:hash,label:column?.title ?? NSLocalizedString("Message",comment:"")) { [weak self,weak model,weak tableView] in
                        guard let self,let model,let tableView,!self.retired,!model.isInvalidated,self.model === model,
                            self.table === tableView,tableView.window === model.window,
                            self.renderedEntries.indices.contains(row),self.renderedEntries[row].hash==hash else{return false}
                        return tableView.tableColumn(withIdentifier:.init("message"))?.isHidden==false
                    }
                referenceField.tooltipForReference = { [weak model] name in model?.referenceTooltip(hash: hash, name: name, fallback: fallback) }
                referenceField.onHoverReference = { [weak model] name in model?.hoverReference(hash: hash, name: name) }
                referenceField.referenceInteractionAllowed = { [weak model, weak historyTable] in
                    guard let model, let historyTable else { return false }
                    return !model.confirmingQuit && historyTable.contextMenuAvailable() && historyTable.tableColumn(withIdentifier: .init("message"))?.isHidden == false && model.entries.contains { $0.hash == hash }
                }
                referenceField.onReferenceMenu = { [weak model, weak historyTable, weak referenceField] name, point in
                    guard let model, let historyTable, let referenceField,
                          let row = model.entries.firstIndex(where: { $0.hash == hash && $0.references.contains(where: { GitReferenceName.equal($0.name, name) }) }) else { return false }
                    return historyTable.showReferenceContextMenu(row: row, name: name, point: historyTable.convert(point, from: referenceField))
                }
            }
            let cell = NSTableCellView(); cell.addSubview(text); cell.textField = text
            text.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating,let table,(notification.object as? NSTableView) === table else{return}
            guard selectionInputAvailable else {reconcileNativeSelection();return}
            let available = Set(model.entries.map(\.hash))
            let hashes = Set(table.selectedRowIndexes.compactMap { renderedEntries.indices.contains($0) ? renderedEntries[$0].hash : nil }).intersection(available)
            // A removed/reordered projection must never reinterpret the old
            // native index as a different revision or erase a valid selection.
            guard table.selectedRowIndexes.isEmpty || !hashes.isEmpty else {reconcileNativeSelection();return}
            let mark = table.selectedRowIndexes.last(where: { renderedEntries.indices.contains($0) && hashes.contains(renderedEntries[$0].hash) && !model.selected.contains(renderedEntries[$0].hash) }).map { renderedEntries[$0].hash }
            if hashes != model.selected {
                model.select(hashes,mark:mark)
                NativeDialogStartupTrace.mark("log.selection.accepted", count: hashes.count)
            }
            reconcileNativeSelection()
        }
        private func applySearchHighlights(_ text: NSMutableAttributedString, hash: String, column: String) {
            for range in searchHighlights[hash]?[column] ?? [] where range.length > 0 && range.location >= 0 && NSMaxRange(range) <= text.length {
                text.addAttribute(.foregroundColor, value: LogPalette.native(.filterMatch, preferences: model.colorPreferences), range: range)
            }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            combineMenuTask?.cancel(); combineMenuTask = nil; combineMenuCancellation?.cancel(); combineMenuCancellation = nil
            menu.removeAllItems()
            if menu === headerMenu {
                menu.autoenablesItems = false
                columnReceipt?.consumed=true;columnReceipt=captureColumns()
                let reset=NSMenuItem(title:"Reset columns",action:#selector(columnCommand(_:)),keyEquivalent:"")
                reset.image=MenuIcon.reset.contextImage(defaults:model.colorPreferences);reset.target=self;reset.identifier = .init("Log.Columns.Reset");reset.isEnabled=columnReceipt != nil
                if let columnReceipt{reset.representedObject=ColumnCommand(columnReceipt,nil)}
                menu.addItem(reset);menu.addItem(.separator())
                for definition in LogRevisionColumns.definitions where definition.id != "graph" {
                    if definition.id=="bugs" && !model.issueProperties.showsBugIDColumn || definition.id=="svn" && !model.hasGitSVN {continue}
                    let item=NSMenuItem(title:definition.title,action:#selector(columnCommand(_:)),keyEquivalent:"")
                    item.image=MenuIcon.settingsDialogs.contextImage(defaults:model.colorPreferences)
                    item.target=self;item.identifier = .init("Log.Columns."+definition.id);item.isEnabled=columnReceipt != nil
                    if let columnReceipt{item.representedObject=ColumnCommand(columnReceipt,definition.id)}
                    item.state=table?.tableColumn(withIdentifier:.init(definition.id))?.isHidden==false ? .on:.off;menu.addItem(item)
                }
                return
            }
            let actionTarget=HistoryMenuActionTarget(self);menuActionTarget=actionTarget
            // NSMenuItem.target is weak; this coordinator retains the popup's
            // relay until the next revision popup replaces it.
            defer { applyConsumerPolicy(menu);normalizeSeparators(menu);emphasizeDefaultComparison(menu);bind(menu,to:actionTarget) }
            guard !model.selected.isEmpty,model.entries.filter({model.selected.contains($0.hash)}).count==model.selected.count else{return}
            @discardableResult func item(_ title: String, _ selector: Selector, icon: MenuIcon, enabled: Bool = true) -> NSMenuItem {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.image = icon.contextImage(defaults: model.colorPreferences); item.target = self; item.isEnabled = enabled; menu.addItem(item)
                return item
            }
            let pointed: LogReferenceMenuTarget? = {
                guard let hit = (table as? HistoryTableView)?.contextReference, model.entries.indices.contains(hit.row), let chosen = model.revision,
                    model.entries[hit.row].hash == chosen.hash, chosen.references.contains(where: { $0.name.utf8.elementsEqual(hit.name.utf8) }) else { return nil }
                return LogReferenceMenuTarget(hash: chosen.hash, name: hit.name)
            }()
            menu.autoenablesItems = false
            if model.selectedWorkingTree {
                item("Commit…", #selector(commitWorkingTree), icon: .commit, enabled: !model.busy)
                if model.workingCommandAvailable(.mergeAbort) { workingItem(.mergeAbort,menu:menu) }
                if model.workingTreeSnapshot?.entry.parents.isEmpty==false {
                    item("Show changes as unified diff", #selector(showDiff), icon: .unifiedDiff, enabled: model.canInspectHistory)
                    item("Compare with previous revision", #selector(compare), icon: .compare, enabled: model.canInspectHistory && model.onCompare != nil)
                }
                menu.addItem(.separator())
                for action in [RepositoryAction.stash, .stashPop, .stashList] where model.workingCommandAvailable(action) {
                    workingItem(action, menu: menu)
                }
                menu.addItem(.separator())
                for command in [LogBisectCommand.good, .bad, .skip, .reset] where model.bisectAvailable(command) {
                    let selector = command == .good ? #selector(bisectGood) : command == .bad ? #selector(bisectBad) : command == .skip ? #selector(bisectSkip) : #selector(bisectReset)
                    item(command.title, selector, icon: command.icon, enabled: model.canBisect(command))
                }
                menu.addItem(.separator())
                for action in [RepositoryAction.pull, .fetch, .submoduleUpdate] where model.workingCommandAvailable(action) { workingItem(action, menu: menu) }
                if model.workingCommandAvailable(.clean) { menu.addItem(.separator());workingItem(.clean,menu:menu) }
                menu.addItem(.separator());appendClipboardAndFind(menu,one:false)
                return
            }
            if model.selectedIsStash {
                for action in [RepositoryAction.stashPop, .stashList] where model.workingCommandAvailable(action) { workingItem(action, menu: menu) }
                menu.addItem(.separator())
            }
            let one = model.revision != nil, two = model.selected.count == 2
            if let revision=model.revision {
                if !model.bare {item("Compare with working tree",#selector(workingDiff),icon:.compare,enabled:model.canInspectHistory && model.onCompare != nil)}
                if !model.bare,revision.parents.count==1 {
                    item("Show changes as unified diff",#selector(showDiff),icon:.unifiedDiff,enabled:model.canInspectHistory)
                } else if !model.bare,revision.parents.count>1 {
                    let unified=item("Unified diff with",#selector(showDiff),icon:.unifiedDiff,enabled:model.canInspectHistory)
                    let choices=NSMenu();choices.autoenablesItems=false;unified.submenu=choices
                    let modes:[(String,LogRevisionDiffMode)]=[("All Parents",.allParents),("Only Merged Files",.combined),("Show extra changes after merge",.extraMergeChanges)] + model.parentChoices(for:revision).map{($0.title,.parent($0.number))}
                    for(title,mode) in modes {
                        let child=NSMenuItem(title:title,action:#selector(showParentDiff(_:)),keyEquivalent:"")
                        child.image=MenuIcon.unifiedDiff.contextImage(defaults:model.colorPreferences);child.target=self;child.isEnabled=unified.isEnabled;child.representedObject=mode;choices.addItem(child)
                    }
                }
                if revision.parents.count==1 {
                    item("Compare with previous revision",#selector(compare),icon:.compare,enabled:model.canInspectHistory && model.onCompare != nil)
                } else if revision.parents.count>1 {
                    let previous=item("Compare with previous revision",#selector(compare),icon:.compare,enabled:model.canInspectHistory && model.onCompare != nil)
                    let parents=NSMenu();parents.autoenablesItems=false;previous.submenu=parents
                    for choice in model.parentChoices(for:revision) {
                        let child=NSMenuItem(title:choice.title,action:#selector(compareParent(_:)),keyEquivalent:"")
                        child.image=MenuIcon.compare.contextImage(defaults:model.colorPreferences);child.target=self;child.isEnabled=previous.isEnabled;child.representedObject=NSNumber(value:choice.number);parents.addItem(child)
                    }
                }
            } else if model.selected.count>=2 {
                if model.canCompareRevisionSelection || model.includesWorkingTree && (two || model.continuousHistorySelection) {
                    item("Compare revisions",#selector(compare),icon:.compare,enabled:model.canInspectHistory && model.onCompare != nil)
                }
                if two,!model.bare {item("Show changes as unified diff",#selector(showDiff),icon:.unifiedDiff,enabled:model.canInspectHistory)}
            }
            if two,!model.includesWorkingTree {
                for range in model.selectedHistoryRanges {
                    let label=String(range.from.prefix(8))+range.separator+String(range.to.prefix(8))
                    item("Show log of "+label,#selector(showHistoryRange(_:)),icon:.log,enabled:!model.busy && model.onShowHistoryRange != nil).representedObject=range
                }
                item("Compare change sets",#selector(compareChangeSets(_:)),icon:.compare,enabled:!model.busy && model.onCommitChangeSets != nil)
            }
            menu.addItem(.separator())
            for command in [LogBisectCommand.good, .bad, .skip] where one && model.bisectAvailable(command) {
                let selector = command == .good ? #selector(bisectGood) : command == .bad ? #selector(bisectBad) : #selector(bisectSkip)
                item(command.title, selector, icon: command.icon, enabled: model.canBisect(command))
            }
            if one && model.bisectAvailable(.skip) { menu.addItem(.separator()) }
            let extended=(table as? HistoryTableView)?.contextExtendedMenu == true
            if model.historyLogAvailable(extended:extended) {
                item("Show log…",#selector(showHistory(_:)),icon:.log,enabled:!model.busy && model.onShowHistory != nil).representedObject=NSNumber(value:extended)
            }
            if one {item("Browse repository", #selector(browseRepository), icon: .repositoryBrowser, enabled: !model.busy && model.onBrowseRepository != nil)}
            if model.integrationAvailable {
                item(model.integrationTitle(.merge), #selector(mergeReference(_:)), icon: .merge, enabled: model.canIntegrate(.merge)).representedObject = pointed
            }
            if model.resetAvailable { item("Reset current branch to this…", #selector(reset), icon: .reset, enabled: !model.busy) }
            let switchBranches = model.switchBranchCandidates(target: pointed)
            if let revision = model.revision, !switchBranches.isEmpty {
                if switchBranches.count == 1 {
                    let reference = switchBranches[0]
                    item("Switch branch \"" + reference.label + "\"", #selector(switchBranchReference(_:)), icon: .checkout, enabled: !model.busy && model.onSwitchBranch != nil).representedObject = LogReferenceMenuTarget(hash: revision.hash, name: reference.name)
                } else {
                    let parent = item("Switch branch", #selector(switchBranchReference(_:)), icon: .checkout, enabled: !model.busy && model.onSwitchBranch != nil)
                    let submenu = NSMenu(); submenu.autoenablesItems = false; parent.submenu = submenu
                    for reference in switchBranches {
                        let choice = NSMenuItem(title: reference.label, action: #selector(switchBranchReference(_:)), keyEquivalent: "")
                        choice.image=MenuIcon.checkout.contextImage(defaults:model.colorPreferences);choice.target = self; choice.isEnabled = parent.isEnabled
                        choice.representedObject = LogReferenceMenuTarget(hash: revision.hash, name: reference.name); submenu.addItem(choice)
                    }
                }
            }
            if one && model.revision?.isHead == false && !model.bare && !model.selectedIsStash {
                item("Switch/Checkout to this…", #selector(checkoutReference(_:)), icon: .checkout, enabled: !model.busy).representedObject = pointed
            }
            if one,!model.selectedIsStash {
                item("Create branch at this version…", #selector(branchReference(_:)), icon: .branch, enabled: !model.busy).representedObject = pointed
                item("Create tag at this version…", #selector(tagReference(_:)), icon: .tag, enabled: !model.busy)
            }
            if model.integrationAvailable {
                item(model.integrationTitle(.rebase), #selector(rebaseRevision), icon: .rebase, enabled: model.canIntegrate(.rebase))
            }
            if one { item("Export this version…", #selector(exportRevision), icon: .export, enabled: model.canExportRevision) }
            if model.onRevertRevisions != nil || model.onPreparedRevert != nil {
                let selectedRows=model.entries.filter{model.selected.contains($0.hash)}
                let chosen = model.entries.filter { !$0.hash.isEmpty && model.selected.contains($0.hash) }
                let available = !model.isInvalidated && !model.busy && !model.bare && !model.mergeActive && !model.findBlocked && !model.orderingBlocked && model.window?.attachedSheet == nil
                if selectedRows.count>1,!chosen.isEmpty,selectedRows.count==model.selected.count {
                    item("Revert changes by these commits",#selector(revertCaptured(_:)),icon:.revert,enabled:available).representedObject=RevertTarget(chosen,selectedRows:selectedRows)
                } else if model.revertAvailable,let revision=model.revision {
                    if revision.parents.count > 1 {
                        let parent = NSMenuItem(title: "Revert change by this commit", action: nil, keyEquivalent: "")
                        parent.image = MenuIcon.revert.contextImage(defaults: model.colorPreferences); parent.isEnabled = available && model.canRevertRevision
                        let submenu = NSMenu(title: parent.title); submenu.autoenablesItems = false
                        for choice in model.parentChoices(for: revision) {
                            let child = NSMenuItem(title: choice.title, action: #selector(revertCaptured(_:)), keyEquivalent: "")
                            child.image=MenuIcon.revert.contextImage(defaults:model.colorPreferences);child.target = self; child.isEnabled = parent.isEnabled; child.representedObject = RevertTarget([revision], mainline: choice.number); submenu.addItem(child)
                        }
                        parent.submenu = submenu; menu.addItem(parent)
                    } else {
                        item("Revert change by this commit", #selector(revertCaptured(_:)), icon: .revert, enabled: available && model.canRevertRevision).representedObject = RevertTarget([revision])
                    }
                }
            } else if model.revertAvailable {
                // Keep the existing direct-model consumer for callers without a
                // native workflow factory, including the focused model fixture.
                if let revision = model.revision, revision.parents.count > 1 {
                    let parent = NSMenuItem(title: "Revert change by this commit", action: nil, keyEquivalent: "")
                    parent.image = MenuIcon.revert.contextImage(defaults:model.colorPreferences); parent.isEnabled = model.canRevertRevision
                    let submenu = NSMenu(title: parent.title); submenu.autoenablesItems = false
                    for choice in model.parentChoices(for: revision) {
                        let child = NSMenuItem(title: choice.title, action: #selector(revertParent), keyEquivalent: "")
                        child.image=MenuIcon.revert.contextImage(defaults:model.colorPreferences);child.tag = choice.number; child.target = self; child.isEnabled = model.canRevertRevision; submenu.addItem(child)
                    }
                    parent.submenu = submenu; menu.addItem(parent)
                } else { item("Revert change by this commit", #selector(revert), icon: .revert, enabled: model.canRevertRevision) }
            }
            if one && !model.selectedIsStash {
                item("Edit Notes", #selector(editNotes), icon: .rebaseEdit, enabled: model.canEditNotes)
            }
            if one { menu.addItem(.separator()) }
            if !one && model.bisectAvailable(.skip) {
                item(LogBisectCommand.skip.title, #selector(bisectSkip), icon: .bisect, enabled: model.canBisect(.skip)); menu.addItem(.separator())
            }
            let combineRows = model.entries.indices.filter { model.selected.contains(model.entries[$0].hash) }
            if model.contextMenuPolicy.contains(.combine), !model.busy, !model.bare, !model.mergeActive, !model.includesWorkingTree, combineRows.count > 1,
               combineRows.count == model.selected.count, model.continuousRevisionSelection,
               let headRow = model.entries.firstIndex(where: \.isHead), combineRows.first! >= headRow, model.onCombineRevisions != nil {
                let chosen = combineRows.map { model.entries[$0] }, offset = combineRows.first! - headRow, head = model.entries[headRow].hash, projection = model.historyProjectionEpoch
                let combine = item("Combine to one commit", #selector(combineRevisions(_:)), icon: .combine, enabled: false)
                combine.representedObject = CombineTarget(entries: chosen, offset: offset, head: head, projection: projection); combine.isHidden = true
                let request = OperationCancellation(); combineMenuCancellation = request
                let repository = model.repository
                combineMenuTask = Task { [weak self, weak combine] in
                    do {
                        guard let self else { return }
                        try await self.model.validateCombineSelection(chosen,offset:offset,head:head,token:request)
                        guard !Task.isCancelled,!request.isCancelled,!self.model.isInvalidated,self.model.historyProjectionEpoch == projection,self.model.continuousRevisionSelection,self.model.selected == Set(chosen.map(\.hash)) else { return }
                        combine?.isHidden = false; combine?.isEnabled = !self.model.busy && !self.model.findBlocked && !self.model.orderingBlocked && self.model.window?.attachedSheet == nil
                    } catch { /* Source omits Combine when ancestry cannot be resolved. */ }
                }
            }
            if model.cherryPickAvailable {
                item(model.selected.count == 1 ? "Cherry Pick this commit…" : "Cherry Pick selected commits…", #selector(cherryPick), icon: .cherryPick, enabled: model.canCherryPick)
            }
            if !model.selectedIsStash, model.formatPatchPreset != nil {
                item("Format Patch…", #selector(formatPatch), icon: .patch, enabled: !model.busy && model.onFormatPatch != nil)
            }
            if model.bisectAvailable(.start) { menu.addItem(.separator()); item(LogBisectCommand.start.title, #selector(bisectStart), icon: .bisect, enabled: model.canBisect(.start)) }
            menu.addItem(.separator())
            if one, let entry = model.revision {
                if model.historyPushAvailable(extended:extended) {
                    let label = pointed.flatMap { model.reference(for: $0) }.flatMap { ref -> String? in
                        let kind = ref.kind ?? HistoryReferenceLabel.shortName(ref.name).kind
                        return [.localBranch, .tag, .annotatedTag].contains(kind) ? "Push \"" + HistoryReferenceLabel.shortName(ref.name).text + "\"…" : nil
                    } ?? "Push…"
                    item(label, #selector(pushCaptured(_:)), icon: .push, enabled: !model.busy).representedObject = PushTarget(entry, pointedName: pointed?.name)
                    if model.hasGitSVN,!model.bare {
                        item(RepositoryAction.svnDCommit.title,#selector(svnDCommitFromHistory(_:)),icon:.commit,enabled:!model.busy && model.onHistorySVNDCommit != nil).representedObject=NSNumber(value:extended)
                    }
                }
                if entry.isHead && !model.bare && !model.mergeActive && model.onHistoryPull != nil {
                    item("Pull…", #selector(pullFromHistory), icon: .pull, enabled: !model.busy)
                }
            }
            let deletable = model.deletionCandidates(target: pointed)
            if let revision = model.revision, !deletable.isEmpty {
                func target(_ ref: RevisionReference) -> LogReferenceMenuTarget { LogReferenceMenuTarget(hash: revision.hash, name: ref.name) }
                if deletable.count == 1 {
                    item("Delete " + deletable[0].name, #selector(deleteReferenceItems(_:)), icon: .remove, enabled: !model.busy).representedObject = [target(deletable[0])]
                } else {
                    let parent = item("Delete branch/tag", #selector(deleteReferenceItems(_:)), icon: .remove, enabled: !model.busy)
                    let submenu = NSMenu(); submenu.autoenablesItems = false; parent.submenu = submenu
                    for ref in deletable {
                        let child = NSMenuItem(title: ref.name, action: #selector(deleteReferenceItems(_:)), keyEquivalent: ""); child.image=MenuIcon.remove.contextImage(defaults:model.colorPreferences);child.target = self; child.isEnabled = parent.isEnabled; child.representedObject = [target(ref)]; submenu.addItem(child)
                    }
                    let all = NSMenuItem(title: "All", action: #selector(deleteReferenceItems(_:)), keyEquivalent: ""); all.image=MenuIcon.remove.contextImage(defaults:model.colorPreferences);all.target = self; all.isEnabled = parent.isEnabled; all.representedObject = deletable.map(target); submenu.addItem(all)
                }
            }
            if one { menu.addItem(.separator()) }
            if model.canToggleRollup {
                let rollup = NSMenuItem(title: model.rollupTitle, action: #selector(toggleRollup), keyEquivalent: ""); rollup.image=MenuIcon.log.contextImage(defaults:model.colorPreferences);rollup.target = self; menu.addItem(rollup); menu.addItem(.separator())
            }
            appendClipboardAndFind(menu,pointed:pointed,one:one)
            if one { item("Show branches this commit is on", #selector(showContainingReferences), icon: .showBranches, enabled: !model.busy && model.onShowContainingReferences != nil) }
        }
        private func appendClipboardAndFind(_ menu:NSMenu,pointed:LogReferenceMenuTarget? = nil,one:Bool) {
            let clipboard = NSMenu(title: "Copy to clipboard")
            clipboard.autoenablesItems = false
            for (title, selector) in [("Full log details", #selector(copyDetails)), ("Full log details without changed paths", #selector(copyDetailsWithoutPaths)), ("Hashes", #selector(copyHashes)),
                ("Authors", #selector(copyAuthors)), ("Author names", #selector(copyAuthorNames)),
                ("Author emails", #selector(copyAuthorEmails)), ("Subjects", #selector(copySubjects)), ("Messages", #selector(copyMessages))] {
                let child = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                child.target = self; child.image = MenuIcon.copy.contextImage(defaults:model.colorPreferences); child.isEnabled = !model.selected.isEmpty
                clipboard.addItem(child)
            }
            let parent = NSMenuItem(title: "Copy to clipboard", action: nil, keyEquivalent: "")
            if one, model.revision?.references.isEmpty == false {
                let refs = NSMenuItem(title: "Tag/branch names", action: #selector(copyReferenceNames(_:)), keyEquivalent: "")
                refs.target = self; refs.image = MenuIcon.copy.contextImage(defaults:model.colorPreferences); refs.representedObject = pointed; refs.isEnabled = !model.busy
                clipboard.addItem(refs)
            }
            parent.image = MenuIcon.copy.contextImage(defaults:model.colorPreferences); parent.submenu = clipboard; menu.addItem(parent)
            let find=NSMenuItem(title:"Find…",action:#selector(findEntry(_:)),keyEquivalent:"")
            find.target=self;find.image=MenuIcon.historyFind.contextImage(defaults:model.colorPreferences)
            find.isEnabled = !model.isInvalidated && !model.busy && !model.findBlocked && !model.orderingBlocked && !model.referencePickerBlocked && (table?.window as? LogHistoryWindow) != nil
            find.representedObject=NSNumber(value:(table as? HistoryTableView)?.contextRow ?? table?.selectedRow ?? 0)
            menu.addItem(find)
        }
        private func sourceCommand(_ item: NSMenuItem) -> HistoryContextCommand? {
            guard let selector = item.action else { return nil }
            let name = NSStringFromSelector(selector)
            if name.hasPrefix("copy") { return .copyClipboard }
            switch name {
            case "workingDiff": return .compareWorkingTree
            case "commitWorkingTree": return .commit
            case "showDiff", "showParentDiff:": return model.selected.count == 2 ? .unifiedDiffTwo : .unifiedDiff
            case "compare", "compareParent:": return model.selected.count > 1 ? .compareTwo : .comparePrevious
            case "compareChangeSets:": return .compareChangeSets
            case "bisectGood": return .bisectGood
            case "bisectBad": return .bisectBad
            case "bisectSkip": return .bisectSkip
            case "bisectReset": return .bisectReset
            case "bisectStart": return .bisectStart
            case "showHistory:": return .showLog
            case "browseRepository": return .repositoryBrowser
            case "mergeReference:", "mergeRevision": return .merge
            case "reset": return .reset
            case "switchBranchReference:": return .switchBranch
            case "checkoutReference:", "checkout": return .checkout
            case "branchReference:", "branch": return .createBranch
            case "tagReference:", "tag": return .createTag
            case "rebaseRevision": return .rebase
            case "exportRevision": return .export
            case "revertCaptured:", "revert", "revertParent:": return .revert
            case "editNotes": return .editNote
            case "combineRevisions:": return .combine
            case "cherryPick": return .cherryPick
            case "formatPatch": return .createPatch
            case "pushCaptured:", "pushReference:", "push": return .push
            case "svnDCommitFromHistory:": return .svnDCommit
            case "pullFromHistory": return .pull
            case "deleteReferenceItems:": return .delete
            case "toggleRollup": return .rollup
            case "findEntry:": return .find
            case "showContainingReferences": return .showBranches
            case "workingCommand:":
                guard let value = item.representedObject as? String, let action = RepositoryAction(rawValue: value) else { return nil }
                switch action {
                case .mergeAbort: return .mergeAbort
                case .stash: return .stashSave
                case .stashPop: return .stashPop
                case .stashList: return .stashList
                case .pull: return .pull
                case .fetch: return .fetch
                case .submoduleUpdate: return .submoduleUpdate
                case .clean: return .cleanup
                default: return nil
                }
            default: return nil // Source range-log entries deliberately have no mask.
            }
        }
        private func applyConsumerPolicy(_ menu: NSMenu) {
            for item in menu.items where !item.isSeparatorItem {
                // ID_LOG's source exception has already been resolved by the
                // model against the captured row/Shift state when adding it.
                if let command = sourceCommand(item), command != .showLog, !model.contextMenuPolicy.contains(command) {
                    menu.removeItem(item); continue
                }
                if let submenu = item.submenu {
                    applyConsumerPolicy(submenu); normalizeSeparators(submenu)
                    if submenu.items.isEmpty { menu.removeItem(item) }
                }
            }
        }
        private func emphasizeDefaultComparison(_ menu: NSMenu) {
            guard model.colorPreferences.bool(forKey: "DiffByDoubleClickInLog"),
                  let item = menu.items.first(where: { sourceCommand($0) == .comparePrevious }) else { return }
            func emphasize(_ item: NSMenuItem) {
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            }
            emphasize(item)
            if let firstParent = item.submenu?.items.first { emphasize(firstParent) }
        }
        private func normalizeSeparators(_ menu:NSMenu) {
            for item in menu.items {if let submenu=item.submenu{normalizeSeparators(submenu)}}
            var previous=true
            for item in menu.items {
                if item.isSeparatorItem {if previous{menu.removeItem(item)};previous=true}
                else {previous=false}
            }
            if menu.items.last?.isSeparatorItem==true {menu.removeItem(at:menu.numberOfItems-1)}
        }
        @objc func findEntry(_ sender:NSMenuItem) {
            guard let table,let window=table.window as? LogHistoryWindow,!model.busy,!model.isInvalidated else{return}
            let mark=(sender.representedObject as? NSNumber)?.intValue ?? table.selectedRow
            model.findSearchIndex=max(0,mark);window.find()
        }
        private func bind(_ menu:NSMenu,to target:HistoryMenuActionTarget) {
            for item in menu.items {
                if let submenu=item.submenu { bind(submenu,to:target) }
                if item.action != nil,item.target === self { item.target=target }
            }
        }
        func menuDidClose(_ menu: NSMenu) { if menu === headerMenu {let old=columnReceipt;DispatchQueue.main.async{[weak self] in if self?.columnReceipt === old{self?.columnReceipt=nil;old?.consumed=true}}}; combineMenuTask?.cancel(); combineMenuTask = nil; combineMenuCancellation?.cancel(); combineMenuCancellation = nil; if menu !== headerMenu { (table as? HistoryTableView)?.contextReference = nil;(table as? HistoryTableView)?.contextRow=nil } }
        private final class PushTarget: NSObject {
            let entry: LogEntry, pointedName: String?
            init(_ entry: LogEntry, pointedName: String?) { self.entry = entry; self.pointedName = pointedName }
        }
        @objc func pushCaptured(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? PushTarget else { return }
            model.pushCaptured(target.entry, pointedName: target.pointedName)
        }
        @objc func pullFromHistory() { model.pullFromHistory() }
        @objc func showHistory(_ sender:NSMenuItem) { model.showHistory(extended:(sender.representedObject as? NSNumber)?.boolValue ?? false) }
        @objc func showHistoryRange(_ sender:NSMenuItem) { if let range=sender.representedObject as? HistoryRevisionRange { model.showHistoryRange(range) } }
        @objc func compareChangeSets(_ sender:NSMenuItem) { model.compareChangeSets(alternate:NSEvent.modifierFlags.contains(.shift)) }
        @objc func compareParent(_ sender:NSMenuItem) { if let number=sender.representedObject as? NSNumber { model.compare(parent:number.intValue) } }
        @objc func showParentDiff(_ sender:NSMenuItem) { if let mode=sender.representedObject as? LogRevisionDiffMode { model.diff(alternate:NSEvent.modifierFlags.contains(.shift),mode:mode) } }
        @objc func svnDCommitFromHistory(_ sender:NSMenuItem) { model.svnDCommitFromHistory(extended:(sender.representedObject as? NSNumber)?.boolValue ?? false) }
        @objc func pushReference(_ sender: NSMenuItem) { model.requestReference(.push, target: sender.representedObject as? LogReferenceMenuTarget) }
        @objc func switchBranchReference(_ sender: NSMenuItem) { if let target = sender.representedObject as? LogReferenceMenuTarget { model.switchBranch(target: target) } }
        @objc func mergeReference(_ sender: NSMenuItem) { model.requestIntegration(.merge, target: sender.representedObject as? LogReferenceMenuTarget) }
        @objc func branchReference(_ sender: NSMenuItem) { model.requestReference(.branch, target: sender.representedObject as? LogReferenceMenuTarget) }
        @objc func tagReference(_ sender: NSMenuItem) { model.requestReference(.tag, target: nil) }
        @objc func deleteReferenceItems(_ sender: NSMenuItem) { if let targets = sender.representedObject as? [LogReferenceMenuTarget] { model.deleteReferences(targets) } }
        @objc func checkoutReference(_ sender: NSMenuItem) { model.requestReference(.checkout, target: sender.representedObject as? LogReferenceMenuTarget) }
        @objc func copyReferenceNames(_ sender: NSMenuItem) { model.copyReferenceNames(target: sender.representedObject as? LogReferenceMenuTarget) }
        @objc func toggleRollup() { model.toggleRollup() }
        var columnCommandsAvailable:Bool {
            !retired && !model.isInvalidated && !model.confirmingQuit && !model.busy && !model.findBlocked && !model.orderingBlocked && !model.referencePickerBlocked && !model.revisionColumnWorkPending && table?.window != nil && table?.window === model.window && model.window?.attachedSheet==nil && NSApp.modalWindow==nil
        }
        @objc private func columnCommand(_ sender:NSMenuItem) {
            guard let command=sender.representedObject as? ColumnCommand,command.receipt.take() else{return}
            if let id=command.id{toggleColumnID(id)}else{requestResetColumns()}
        }
        @objc func toggleColumn(_ sender:NSMenuItem){guard columnCommandsAvailable,let id=sender.representedObject as? String else{return};toggleColumnID(id)}
        private func toggleColumnID(_ id:String) {
            guard columnCommandsAvailable,id != "graph",let column=table?.tableColumn(withIdentifier:.init(id)) else{return}
            if id=="bugs" && !model.issueProperties.showsBugIDColumn || id=="svn" && !model.hasGitSVN{return}
            column.isHidden.toggle();columnLayoutEpoch=UUID()
            model.colorPreferences.set(!column.isHidden,forKey:"Log.Column.Visible."+id)
            if !column.isHidden,!adjustedColumns.contains(id){fitColumn(table!.column(withIdentifier:column.identifier),automatic:true)}
        }
        @objc func requestResetColumns() {
            guard let receipt=captureColumns(),let window=table?.window else{return}
            let alert=NSAlert();alert.messageText="Are you sure to reset columns?"
            alert.addButton(withTitle:"Yes").keyEquivalent="\r";alert.addButton(withTitle:"No").keyEquivalent="\u{1b}"
            alert.window.alphaValue=window.alphaValue
            // The separate receipt is checked after the actual reply and detach.
            let owner=model
            let question=LogRevisionColumnQuestion(owner:window,alert:alert){[weak self,owner] accepted in
                guard let self else{owner.revisionColumnQuestionFinished();return}
                self.columnQuestion=nil;owner.revisionColumnQuestionFinished()
                if accepted,receipt.take(){self.resetColumns()}
            }
            columnQuestion=question;owner.revisionColumnQuestionStarted();question.begin(present:owner.presentRevisionColumnQuestion)
        }
        @objc func resetColumns() {
            guard columnCommandsAvailable,let table else{return}
            updating=true
            for(index,definition)in LogRevisionColumns.definitions.enumerated(){
                model.colorPreferences.removeObject(forKey:"Log.Column.Visible."+definition.id)
                guard let column=table.tableColumn(withIdentifier:.init(definition.id)) else{continue}
                column.isHidden = !definition.visible || definition.id=="graph" && model.historyWalk.followRenames || definition.id=="bugs" && !model.issueProperties.showsBugIDColumn || definition.id=="svn" && !model.hasGitSVN
                let current=table.column(withIdentifier:column.identifier);if current != index{table.moveColumn(current,toColumn:index)}
            }
            adjustedColumns=[];columnLayoutEpoch=UUID();fitAutomaticColumns();updating=false;saveColumns()
        }
        func fitColumn(_ index:Int,automatic:Bool) {
            guard columnCommandsAvailable,let table,table.tableColumns.indices.contains(index) else{return}
            let column=table.tableColumns[index],id=column.identifier.rawValue
            updating=true;column.width=measuredWidth(column,includeHeader:automatic);updating=false
            if automatic{adjustedColumns.remove(id)}else{adjustedColumns.insert(id)}
            columnLayoutEpoch=UUID();saveColumns()
        }
        private func measuredWidth(_ column:NSTableColumn,includeHeader:Bool=true,rows:IndexSet?=nil)->CGFloat {
            guard let table else{return column.width}
            let id=column.identifier.rawValue
            if id=="graph"{return max(65,CGFloat(model.graph.map(\.width).max() ?? 1)*floor(table.rowHeight*3/4)+24)}
            var width=includeHeader ? (column.title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:NSFont.systemFontSize)]).width+20 : column.minWidth
            if id=="actions"{return max(width,5*16+14)}
            for row in rows ?? IndexSet(integersIn: renderedEntries.indices) {
                guard let cell=tableView(table,viewFor:column,row:row) as? NSTableCellView,let field=cell.textField else{continue}
                let content=id=="message" ? field.attributedStringValue.size().width : (field.stringValue as NSString).size(withAttributes:[.font:field.font ?? NSFont.systemFont(ofSize:12)]).width
                width=max(width,content+14)
            }
            return min(column.maxWidth,max(column.minWidth,ceil(width)))
        }
        func fitAutomaticColumns(sampled: Bool = false) {
            guard let table else { return }
            var rows: IndexSet?
            if sampled {
                var candidates = IndexSet(integersIn: 0..<min(128, renderedEntries.count))
                let visible = table.rows(in: table.visibleRect)
                if visible.location != NSNotFound, visible.location < renderedEntries.count {
                    candidates.formUnion(IndexSet(integersIn: visible.location..<min(NSMaxRange(visible), renderedEntries.count)))
                }
                rows = candidates
            }
            for column in table.tableColumns where !adjustedColumns.contains(column.identifier.rawValue) {
                column.width = measuredWidth(column, rows: rows)
            }
        }
        func tableViewColumnDidResize(_ notification:Notification){
            guard !updating,let column=notification.userInfo?["NSTableColumn"] as? NSTableColumn else{return}
            adjustedColumns.insert(column.identifier.rawValue);columnLayoutEpoch=UUID();saveColumns()
        }
        func tableViewColumnDidMove(_ notification:Notification){guard !updating else{return};columnLayoutEpoch=UUID();saveColumns()}
        var savesColumnLayout=true
        func saveColumns(){
            guard savesColumnLayout,!updating,!retired,!model.isInvalidated,let table else{return}
            let prefs=model.colorPreferences
            prefs.set(table.tableColumns.map{$0.identifier.rawValue},forKey:"Log.Columns.Order")
            prefs.set(Array(adjustedColumns).sorted(),forKey:"Log.Columns.Adjusted")
            prefs.set(Dictionary(uniqueKeysWithValues:table.tableColumns.filter{adjustedColumns.contains($0.identifier.rawValue)}.map{($0.identifier.rawValue,Double($0.width))}),forKey:"Log.Columns.Widths")
        }
        func restoreColumns(){
            guard savesColumnLayout,let table else{return};updating=true;defer{updating=false}
            let prefs=model.colorPreferences,order=prefs.stringArray(forKey:"Log.Columns.Order") ?? []
            var used=Set<String>(),destination=0
            for name in order where used.insert(name).inserted {if let current=table.tableColumns.firstIndex(where:{$0.identifier.rawValue==name}){table.moveColumn(current,toColumn:destination);destination += 1}}
            let widths=prefs.dictionary(forKey:"Log.Columns.Widths") ?? [:]
            adjustedColumns=Set(prefs.stringArray(forKey:"Log.Columns.Adjusted") ?? Array(widths.keys))
            for column in table.tableColumns{if adjustedColumns.contains(column.identifier.rawValue),let width=widths[column.identifier.rawValue] as? NSNumber,width.doubleValue.isFinite,(Double(column.minWidth)...10000).contains(width.doubleValue){column.width=CGFloat(width.doubleValue)}}
        }
        @objc func showContainingReferences() { if !model.busy, model.selected.count == 1, let revision = model.revision { model.onShowContainingReferences?(revision.hash) } }
        @objc func browseRepository() { if let revision = model.revision { model.onBrowseRepository?(revision.hash) } }
        @objc func formatPatch() { if let preset = model.formatPatchPreset, !model.busy { model.onFormatPatch?(preset) } }
        @objc func editNotes() { model.editNotes() }
        @objc func exportRevision() { model.requestExport() }
        @objc func mergeRevision() { model.requestIntegration(.merge) }
        @objc func rebaseRevision() { model.requestIntegration(.rebase) }
        @objc func reset() { model.request(.reset) }
        @objc func push() { model.request(.push) }
        @objc func checkout() { model.request(.checkout) }
        @objc func branch() { model.request(.branch) }
        @objc func tag() { model.request(.tag) }
        @objc func revert() { model.request(.revert) }
        @objc func revertParent(_ sender: NSMenuItem) { model.request(.revert, mainline: sender.tag) }
        @objc func cherryPick() { model.request(.cherryPick) }
        @objc func doubleClickRevision() { guard revisionInputAvailable else { return }; model.doubleClickRevision() }
        @objc func showDiff() { model.diff(alternate: NSEvent.modifierFlags.contains(.shift)) }
        @objc func compare() { model.compare() }
        @objc func workingDiff() { model.compare(workingTree: true) }
        @objc func bisectStart() { model.requestBisect(.start) }
        @objc func bisectGood() { model.requestBisect(.good) }
        @objc func bisectBad() { model.requestBisect(.bad) }
        @objc func bisectSkip() { model.requestBisect(.skip) }
        @objc func bisectReset() { model.requestBisect(.reset) }
        @objc func commitWorkingTree() {
            guard model.selectedWorkingTree,!model.busy else { return }
            if model.onWorkingCommand != nil { model.requestWorkingCommand(.commit) }
            else { model.onCommit() }
        }
        private func workingItem(_ action: RepositoryAction, menu: NSMenu) {
            let item = NSMenuItem(title: action.title, action: #selector(workingCommand), keyEquivalent: "")
            item.image = action.icon.contextImage(defaults:model.colorPreferences); item.target = self; item.representedObject = action.rawValue
            item.isEnabled = model.canWorkingCommand(action); menu.addItem(item)
        }
        @objc func workingCommand(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? String, let action = RepositoryAction(rawValue: value) else { return }
            model.requestWorkingCommand(action)
        }
        @objc func copyAuthors() { model.copy(model.clipboardEntries.map { "\($0.author) <\($0.email)>" }.joined(separator: "\n")) }
        @objc func copyAuthorNames() { model.copy(model.clipboardEntries.map(\.author).joined(separator: "\n")) }
        @objc func copyAuthorEmails() { model.copy(model.clipboardEntries.map(\.email).joined(separator: "\n")) }
        @objc func copySubjects() { model.copy(LogEntry.historyClipboard(model.clipboardEntries, subjectsOnly: true)) }
        @objc func copyHashes() { model.copy(model.clipboardEntries.map(\.hash).joined(separator: "\n")) }
        @objc func copyMessages() { model.copy(LogEntry.historyClipboard(model.clipboardEntries, subjectsOnly: false)) }
        @objc func copyDetails() { model.copyDetails() }
        @objc func copyDetailsWithoutPaths() { model.copyDetails(includePaths: false) }
    }
}

/// A revision popup owns one selection/ref snapshot. Keep its original selectors
/// and payloads while refusing actions after another selection, reload or use.
@MainActor private final class HistoryMenuActionTarget:NSObject {
    private weak var coordinator:RevisionTable.Coordinator?
    private weak var model:LogWindowModel?
    private let generation:Int,projection:UUID,selection:Set<String>,hashes:[String],references:[[RevisionReference]]
    private let policy: HistoryContextMenuPolicy
    private var consumed=false
    init(_ coordinator:RevisionTable.Coordinator) {
        self.coordinator=coordinator;let model=coordinator.model;self.model=model
        generation=model.contextMenuGeneration;projection=model.historyProjectionEpoch;let selected=model.selected;selection=selected;policy=model.contextMenuPolicy
        let entries=model.entries.filter{selected.contains($0.hash)}
        hashes=entries.map(\.hash);references=entries.map(\.references)
    }
    private func invoke(_ selector:Selector,sender:NSMenuItem? = nil) {
        let inspection = ["compare", "workingDiff", "showDiff", "compareParent:", "showParentDiff:"].contains(NSStringFromSelector(selector))
        guard !consumed,let coordinator,let model,coordinator.model === model,!model.isInvalidated,
              (inspection ? model.canInspectHistory : !model.busy),!model.confirmingQuit,!model.findBlocked,!model.orderingBlocked,!model.referencePickerBlocked,model.contextMenuPolicy==policy,
              model.window?.attachedSheet==nil,model.contextMenuGeneration==generation,model.historyProjectionEpoch==projection,
              !selection.isEmpty,model.selected==selection else { return }
        let entries=model.entries.filter{selection.contains($0.hash)}
        guard entries.count==selection.count,entries.map(\.hash)==hashes,entries.map(\.references)==references else { return }
        consumed=true
        NSApp.sendAction(selector,to:coordinator,from:sender)
    }
    @objc func revertCaptured(_ sender:NSMenuItem) { invoke(NSSelectorFromString("revertCaptured:"),sender:sender) }
    @objc func combineRevisions(_ sender:NSMenuItem) { invoke(NSSelectorFromString("combineRevisions:"),sender:sender) }
    @objc func pushCaptured(_ sender:NSMenuItem) { invoke(NSSelectorFromString("pushCaptured:"),sender:sender) }
    @objc func pullFromHistory() { invoke(NSSelectorFromString("pullFromHistory")) }
    @objc func showHistory(_ sender:NSMenuItem) { invoke(NSSelectorFromString("showHistory:"),sender:sender) }
    @objc func showHistoryRange(_ sender:NSMenuItem) { invoke(NSSelectorFromString("showHistoryRange:"),sender:sender) }
    @objc func compareChangeSets(_ sender:NSMenuItem) { invoke(NSSelectorFromString("compareChangeSets:"),sender:sender) }
    @objc func compareParent(_ sender:NSMenuItem) { invoke(NSSelectorFromString("compareParent:"),sender:sender) }
    @objc func showParentDiff(_ sender:NSMenuItem) { invoke(NSSelectorFromString("showParentDiff:"),sender:sender) }
    @objc func svnDCommitFromHistory(_ sender:NSMenuItem) { invoke(NSSelectorFromString("svnDCommitFromHistory:"),sender:sender) }
    @objc func pushReference(_ sender:NSMenuItem) { invoke(NSSelectorFromString("pushReference:"),sender:sender) }
    @objc func switchBranchReference(_ sender:NSMenuItem) { invoke(NSSelectorFromString("switchBranchReference:"),sender:sender) }
    @objc func mergeReference(_ sender:NSMenuItem) { invoke(NSSelectorFromString("mergeReference:"),sender:sender) }
    @objc func branchReference(_ sender:NSMenuItem) { invoke(NSSelectorFromString("branchReference:"),sender:sender) }
    @objc func tagReference(_ sender:NSMenuItem) { invoke(NSSelectorFromString("tagReference:"),sender:sender) }
    @objc func deleteReferenceItems(_ sender:NSMenuItem) { invoke(NSSelectorFromString("deleteReferenceItems:"),sender:sender) }
    @objc func checkoutReference(_ sender:NSMenuItem) { invoke(NSSelectorFromString("checkoutReference:"),sender:sender) }
    @objc func copyReferenceNames(_ sender:NSMenuItem) { invoke(NSSelectorFromString("copyReferenceNames:"),sender:sender) }
    @objc func toggleRollup() { invoke(NSSelectorFromString("toggleRollup")) }
    @objc func findEntry(_ sender:NSMenuItem) {invoke(NSSelectorFromString("findEntry:"),sender:sender)}
    @objc func showContainingReferences() { invoke(NSSelectorFromString("showContainingReferences")) }
    @objc func browseRepository() { invoke(NSSelectorFromString("browseRepository")) }
    @objc func formatPatch() { invoke(NSSelectorFromString("formatPatch")) }
    @objc func editNotes() { invoke(NSSelectorFromString("editNotes")) }
    @objc func exportRevision() { invoke(NSSelectorFromString("exportRevision")) }
    @objc func mergeRevision() { invoke(NSSelectorFromString("mergeRevision")) }
    @objc func rebaseRevision() { invoke(NSSelectorFromString("rebaseRevision")) }
    @objc func reset() { invoke(NSSelectorFromString("reset")) }
    @objc func push() { invoke(NSSelectorFromString("push")) }
    @objc func checkout() { invoke(NSSelectorFromString("checkout")) }
    @objc func branch() { invoke(NSSelectorFromString("branch")) }
    @objc func tag() { invoke(NSSelectorFromString("tag")) }
    @objc func revert() { invoke(NSSelectorFromString("revert")) }
    @objc func revertParent(_ sender:NSMenuItem) { invoke(NSSelectorFromString("revertParent:"),sender:sender) }
    @objc func cherryPick() { invoke(NSSelectorFromString("cherryPick")) }
    @objc func showDiff() { invoke(NSSelectorFromString("showDiff")) }
    @objc func compare() { invoke(NSSelectorFromString("compare")) }
    @objc func workingDiff() { invoke(NSSelectorFromString("workingDiff")) }
    @objc func bisectStart() { invoke(NSSelectorFromString("bisectStart")) }
    @objc func bisectGood() { invoke(NSSelectorFromString("bisectGood")) }
    @objc func bisectBad() { invoke(NSSelectorFromString("bisectBad")) }
    @objc func bisectSkip() { invoke(NSSelectorFromString("bisectSkip")) }
    @objc func bisectReset() { invoke(NSSelectorFromString("bisectReset")) }
    @objc func commitWorkingTree() { invoke(NSSelectorFromString("commitWorkingTree")) }
    @objc func workingCommand(_ sender:NSMenuItem) { invoke(NSSelectorFromString("workingCommand:"),sender:sender) }
    @objc func copyAuthors() { invoke(NSSelectorFromString("copyAuthors")) }
    @objc func copyAuthorNames() { invoke(NSSelectorFromString("copyAuthorNames")) }
    @objc func copyAuthorEmails() { invoke(NSSelectorFromString("copyAuthorEmails")) }
    @objc func copySubjects() { invoke(NSSelectorFromString("copySubjects")) }
    @objc func copyHashes() { invoke(NSSelectorFromString("copyHashes")) }
    @objc func copyMessages() { invoke(NSSelectorFromString("copyMessages")) }
    @objc func copyDetails() { invoke(NSSelectorFromString("copyDetails")) }
    @objc func copyDetailsWithoutPaths() { invoke(NSSelectorFromString("copyDetailsWithoutPaths")) }
}


final class HistoryTableView: NSTableView {
    var onWindowChanged:(()->Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindowChanged?() }
    var contextReference: (row: Int, name: String)?
    var contextRow:Int?
    var contextExtendedMenu = false
    var onReturn: (() -> Bool)?
    var onFind: (() -> Bool)?
    var contextMenuAvailable:()->Bool = { true }
    var presentContextMenu:((NSMenu,NSPoint,NSView)->Void)?
    private func isContextKey(_ event:NSEvent)->Bool {
        event.keyCode==109 && event.modifierFlags.intersection([.shift,.command,.control,.option]) == .shift
    }
    @discardableResult func showKeyboardContextMenu(extended:Bool=false)->Bool {
        guard contextMenuAvailable(),let row=selectedRowIndexes.first,row>=0,row<numberOfRows,let menu else { return false }
        contextReference=nil;contextExtendedMenu=extended;contextRow=row
        scrollRowToVisible(row);layoutSubtreeIfNeeded();menu.update()
        let visible=rect(ofRow:row).intersection(visibleRect)
        let point=visible.isEmpty ? NSPoint(x:bounds.midX,y:rect(ofRow:row).midY) : NSPoint(x:visible.midX,y:visible.midY)
        if let presentContextMenu { presentContextMenu(menu,point,self) }
        else { menu.popUp(positioning:nil,at:point,in:self) }
        return true
    }
    @discardableResult func showReferenceContextMenu(row: Int, name: String, point: NSPoint) -> Bool {
        guard contextMenuAvailable(), row >= 0, row < numberOfRows, let menu else { return false }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        contextReference = (row, name); contextExtendedMenu = NSEvent.modifierFlags.contains(.shift); contextRow = row
        scrollRowToVisible(row); scrollToVisible(NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)); layoutSubtreeIfNeeded()
        // NSMenu.update() need not ask its delegate to populate a menu before
        // tracking begins. Prepare this pointed popup once, including its
        // captured action receipt, before rejecting an empty first-open menu.
        menu.delegate?.menuNeedsUpdate?(menu)
        guard !menu.items.isEmpty else { return false }
        if let presentContextMenu { presentContextMenu(menu, point, self) }
        else { menu.popUp(positioning: nil, at: point, in: self) }
        return true
    }
    override func accessibilityPerformShowMenu()->Bool { showKeyboardContextMenu() }
    private func performFind(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.shift, .command, .control, .option]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "f" && onFind?() == true
    }
    func performRevisionReturn(with event:NSEvent)->Bool {
        guard window?.firstResponder === self, event.type == .keyDown, [36,76].contains(event.keyCode),
              event.modifierFlags.intersection([.command,.control]).isEmpty else { return false }
        // CLogDlg::OnOK refuses Return while the revision list owns focus.
        // Its comparison preference may act, but a disabled comparison must
        // never fall through to the window's default OK/Close button.
        ComparisonToolInvocation.$alternate.withValue(event.modifierFlags.contains(.shift)) {_ = onReturn?()}
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if performRevisionReturn(with:event) { return true }
        if isContextKey(event) { return showKeyboardContextMenu(extended:true) }
        if performFind(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if isContextKey(event),showKeyboardContextMenu(extended:true) { return }
        if performFind(event) { return }
        if performRevisionReturn(with:event) { return }
        super.keyDown(with: event)
    }
    func reference(at point: NSPoint) -> (row: Int, name: String)? {
        let row = row(at: point)
        guard row >= 0, let column = tableColumns.firstIndex(where: { $0.identifier.rawValue == "message" }),
            let field = (view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField,
            let cell = field.cell as? LogReferenceTextCell,
            field.bounds.contains(field.convert(point, from: self)),
            let ref = cell.reference(at: field.convert(point, from: self)) else { return nil }
        return (row, ref.name)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard contextMenuAvailable() else { return nil }
        let point = convert(event.locationInWindow, from: nil), row = row(at: point)
        let mouse = event.type == .rightMouseDown || event.type == .leftMouseDown
        contextReference = mouse ? reference(at: point) : nil
        contextExtendedMenu = event.modifierFlags.contains(.shift)
        if mouse, row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        contextRow=mouse && row>=0 ? row:selectedRow
        menu?.update()
        return menu
    }
}

final class GraphCell: NSView, NSAccessibilityImage {
    private var colorUpdates: AnyCancellable?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); observeColors() }
    required init?(coder: NSCoder) { super.init(coder: coder); observeColors() }
    private func observeColors() { colorUpdates = StatusColorUpdates.shared.$revision.sink { [weak self] _ in self?.needsDisplay = true } }
    var graph: CommitGraphRow? { didSet { needsDisplay = true } }
    var parentCount = 0
    var workingTree = false
    var preferences: UserDefaults = .standard { didSet { needsDisplay = true } }
    override func isAccessibilityElement() -> Bool { graph != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? {
        guard let graph else { return nil }
        let node = workingTree ? "Working tree" : parentCount > 1 ? "Merge commit" : graph.junction ? "Branch point" : parentCount == 0 ? "Root commit" : "Commit"
        let boundary = graph.lanes.contains(where: \.isBoundary) ? ", boundary" : ""
        return "\(node)\(boundary), \(parentCount) \(parentCount == 1 ? "parent" : "parents"), graph lane \(graph.column + 1), \(graph.collapsed ? "collapsed" : "expanded")"
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let graph, let context = NSGraphicsContext.current?.cgContext else { return }
        let settings = LogColorPreferences.load(preferences)
        let width = floor(bounds.height * 3 / 4)
        let mergeLane = graph.lanes.firstIndex(where: \.isMerge) ?? 0
        let activeColor = LogPalette.lane(mergeLane, preferences: preferences)
        for (index,lane) in graph.lanes.enumerated() where lane != .empty {
            LogGraphDrawing.paint(context, lane: lane, rolled: graph.collapsed, x: CGFloat(index)*width, width: width, height: bounds.height, settings: settings, color: LogPalette.lane(index, preferences: preferences), activeColor: activeColor)
        }
    }
}

struct LogRevisionDialog: View {
    @ObservedObject var model: LogWindowModel
    let request: LogCommandRequest
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.command.rawValue.replacingOccurrences(of: "…", with: "")).font(.title2)
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            Text("Version: \(request.revision.hash)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(request.revision.subject)
            if request.command == .branch || request.command == .tag {
                TextField(request.command == .branch ? "Branch name" : "Tag name", text: $value).textFieldStyle(.roundedBorder)
            }
            if request.command == .revert {
                Text("Apply the reverse changes to the index and working tree without committing. Review and commit them from the Commit dialog.").foregroundStyle(.secondary)
            } else if request.command == .cherryPick {
                Text("Apply this commit to the current branch. Conflicts may require resolution before continuing.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.commandRequest = nil }.keyboardShortcut(.cancelAction)
                Button("OK") { model.execute(request, value: value) }.keyboardShortcut(.defaultAction)
                    .disabled((request.command == .branch || request.command == .tag) && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 550)
    }
}

/// Shared source confirmation for History and RefLog named-reference deletion.
@MainActor enum HistoryReferenceDeletionPresentation {
    static func alert(_ request: HistoryReferenceDeletion) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = request.message
        for option in request.choices { alert.addButton(withTitle: option.title).keyEquivalent = "" }
        let abort = alert.buttons.last!; abort.keyEquivalent = "\r"
        alert.window.defaultButtonCell = abort.cell as? NSButtonCell
        return alert
    }
    static func confirm(_ request: HistoryReferenceDeletion, parent: NSWindow) async -> HistoryReferenceDeleteChoice {
        guard parent.attachedSheet == nil else { return .abort }
        return await withCheckedContinuation { continuation in
            alert(request).beginSheetModal(for: parent) { response in
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                continuation.resume(returning: request.choices.indices.contains(index) ? request.choices[index].choice : .abort)
            }
        }
    }
}


/// Source all-branches control uses an indeterminate state for basic/local refs.
struct LogReferenceScopeCheckbox: NSViewRepresentable {
    @ObservedObject var model: LogWindowModel
    let scope: HistoryReferenceScope
    let enabled: Bool
    let change: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(change: change) }
    func makeNSView(context: Context) -> NSButton {
        let button = LogScopeCheckboxButton(checkboxWithTitle: "All Branches", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required,for:.vertical)
        button.setContentCompressionResistancePriority(.required,for:.vertical)
        return button
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSButton,context:Context)->CGSize? {nsView.fittingSize}
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = scope == .current ? .off : scope == .all ? .on : .mixed
        button.isEnabled = enabled; button.toolTip = scope.title
        (button as? LogScopeCheckboxButton)?.buildMenu = { [weak model] in model.map { LogControlMenus.make(model:$0,kind:.reference) } }
        context.coordinator.change = change; context.coordinator.next = scope == .current
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) { (button as? LogScopeCheckboxButton)?.buildMenu = nil; button.target = nil; button.action = nil; button.isEnabled = false; coordinator.change = { _ in } }
    final class Coordinator: NSObject {
        var change: (Bool) -> Void, next = true
        init(change: @escaping (Bool) -> Void) { self.change = change }
        @objc func clicked(_ sender: NSButton) { guard sender.isEnabled else { return }; change(next) }
    }
}

@MainActor final class LogScopeCheckboxButton: NSButton {
    var buildMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { buildMenu?() }
}

// Existing Log callers and receivers use the same shared transfer contract.
typealias LogFileListDrag = FileListSelectionDrag

@MainActor struct LogFileDragInteraction:NSViewRepresentable {
    let model:LogWindowModel,rows:[LogFileTableRow]
    typealias Probe=FileListDragInteraction.Probe
    func makeNSView(context:Context)->Probe{Probe()}
    func updateNSView(_ view:Probe,context:Context){
        view.rows=rows.map{.init(id:$0.rawID,isFile:$0.file != nil)}
        view.generation={ [weak model] in model?.fileDragGeneration }
        view.capture={ [weak model] ids in model?.captureFileDrag(ids) }
    }
    static func dismantleNSView(_ view:Probe,coordinator:()){view.retire()}
}
