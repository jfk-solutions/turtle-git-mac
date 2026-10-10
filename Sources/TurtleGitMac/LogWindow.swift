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
    func label(for path: String) -> String {
        if let workingAccess { return workingAccess.file.path }
        if revision.isEmpty { return self.path == path ? "Working tree" : self.path + ":Working tree" }
        return self.path == path ? revision : self.path + ":" + String(revision.prefix(8))
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

@MainActor final class LogWindowController: NSWindowController, NSWindowDelegate {
    let model: LogWindowModel
    private(set) var patchPreviewWindow: PatchWindowController?
    private var previousPatchParentFrame: NSRect?
    private var positioningPatch = false
    var onClosed: () -> Void = {}
    private var selectionCompletion: ((LogEntry?) -> Void)?
    private var multipleSelectionCompletion: (([LogEntry]?) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, onChooseMultiple: (([LogEntry]?) -> Void)? = nil, onChoose: ((LogEntry?) -> Void)? = nil, labelDefaults: UserDefaults = .standard, savesColumnLayout: Bool = true) {
        model = LogWindowModel(repository: repository, access: access, selecting: onChoose != nil || onChooseMultiple != nil, selectingMultiple: onChooseMultiple != nil, labelDefaults: labelDefaults)
        selectionCompletion = onChoose; multipleSelectionCompletion = onChooseMultiple
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Log Messages – TurtleGit"
        window.minSize = NSSize(width: 1080, height: 700)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: LogDialog(model: model, savesColumnLayout: savesColumnLayout).defaultAppStorage(labelDefaults))
        super.init(window: window)
        model.window = window
        model.onPatchPreviewVisibility = { [weak self] visible in self?.setPatchPreviewVisible(visible) }
        model.onPatchPreviewContent = { [weak self] bytes in self?.patchPreviewWindow?.model.setReadOnlyDiff(bytes) }
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
            return await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = request.message
                for option in request.choices { alert.addButton(withTitle: option.title).keyEquivalent = "" }
                let abort = alert.buttons.last!; abort.keyEquivalent = "\r"; alert.window.defaultButtonCell = abort.cell as? NSButtonCell
                alert.beginSheetModal(for: window) { response in
                    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    continuation.resume(returning: request.choices.indices.contains(index) ? request.choices[index].choice : .abort)
                }
            }
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
        model.presentHistoricalSave = { [weak self] content, short in
            // Let the originating context-menu tracking finish before presenting AppKit UI.
            DispatchQueue.main.async { [weak self] in self?.saveHistoricalFile(content, short: short) }
        }
        model.presentHistoricalOpen = { [weak self] content, action in
            DispatchQueue.main.async { [weak self] in self?.openHistoricalFile(content, action: action) }
        }
        model.presentHistoricalExport = { [weak self] revision, files in
            DispatchQueue.main.async { [weak self] in self?.chooseHistoricalExport(revision: revision, files: files) }
        }
        model.presentWorkingSave = { [weak self] path in
            DispatchQueue.main.async { [weak self] in self?.chooseWorkingCopy(paths: [path], save: true) }
        }
        model.presentWorkingExport = { [weak self] paths in
            DispatchQueue.main.async { [weak self] in self?.chooseWorkingCopy(paths: paths, save: false) }
        }
        model.presentWorkingOpen = { [weak self] file, action in
            DispatchQueue.main.async { [weak self] in self?.openWorkingFile(file, action: action) }
        }
        model.confirmExportFailure = { [weak self] message in
            guard let window = self?.window else { return false }
            return await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.messageText = "Could not export historical file"
                alert.informativeText = message; alert.alertStyle = .warning
                alert.addButton(withTitle: "Ignore"); alert.addButton(withTitle: "Abort")
                alert.beginSheetModal(for: window) { response in continuation.resume(returning: response == .alertFirstButtonReturn) }
            }
        }
        model.reload()

        DialogGeometry.attach(window, identifier: "LogWindowController")
    }
    private func chooseHistoricalExport(revision: String, files: [CommitFile]) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.title = "Export selected files"; panel.prompt = "Export"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak model] response in
            guard response == .OK, let folder = panel.url else { return }
            model?.exportHistoricalFiles(revision: revision, files: files, to: folder)
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
        panel.beginSheetModal(for: window) { [weak model] response in
            guard response == .OK, let target = panel.url else { return }
            model?.copyWorkingFiles(paths, to: target, save: save)
        }
    }
    private func openWorkingFile(_ file: URL, action: HistoricalOpenAction) {
        guard let window, window.attachedSheet == nil, !model.busy, !model.isInvalidated else { return }
        if action == .openWith {
            let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"
            panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let app = panel.url else { return }
                self?.launchWorkingFile(file, action: action, application: app)
            }
        } else { launchWorkingFile(file, action: action) }
    }
    private func launchWorkingFile(_ file: URL, action: HistoricalOpenAction, application: URL? = nil) {
        guard !model.busy, !model.isInvalidated else { return }
        do { try model.validateWorkingFileAccess(file) } catch { model.error = error.localizedDescription; return }
        let failed: @MainActor @Sendable (String?) -> Void = { [weak model] error in if let error { model?.error = error } }
        if action == .alternativeEditor { AlternativeEditor.open(file, completion: failed) }
        else if let application {
            let scoped = application.startAccessingSecurityScopedResource()
            NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if scoped { application.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async { failed(error?.localizedDescription) }
            }
        } else if !NSWorkspace.shared.open(file) { failed("Could not open the working file. Choose an application using Open With.") }
    }
    private func openHistoricalFile(_ content: ComparisonFileContent, action: HistoricalOpenAction) {
        guard let window, window.attachedSheet == nil else { return }
        if action == .openWith {
            let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"
            panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let app = panel.url else { return }
                self?.launchHistoricalFile(content, action: action, application: app)
            }
        } else { launchHistoricalFile(content, action: action) }
    }
    private func launchHistoricalFile(_ content: ComparisonFileContent, action: HistoricalOpenAction, application: URL? = nil) {
        do {
            let preview = try HistoricalFilePreview.create(content)
            HistoricalPreviewFiles.retain(preview)
            let failed: @MainActor @Sendable (String?) -> Void = { [weak model] error in
                if let error { HistoricalPreviewFiles.discard(preview.file); model?.error = error }
            }
            if action == .alternativeEditor { AlternativeEditor.open(preview.file, completion: failed) }
            else if let application {
                let scoped = application.startAccessingSecurityScopedResource()
                NSWorkspace.shared.open([preview.file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if scoped { application.stopAccessingSecurityScopedResource() }
                    DispatchQueue.main.async { failed(error?.localizedDescription) }
                }
            } else if !NSWorkspace.shared.open(preview.file) { failed("Could not open the historical file. Choose an application using Open With.") }
        } catch { model.error = error.localizedDescription }
    }
    private func saveHistoricalFile(_ content: ComparisonFileContent, short: String) {
        guard let window, window.attachedSheet == nil else { return }
        let name = (content.path as NSString).lastPathComponent as NSString
        let ext = name.pathExtension
        let panel = NSSavePanel(); panel.title = "Save file at revision " + short
        panel.nameFieldStringValue = name.deletingPathExtension + "-" + short + (ext.isEmpty ? "" : "." + ext)
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]; panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.repository.root.appendingPathComponent(content.path).deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak model] response in
            guard response == .OK, let url = panel.url else { return }
            do { try content.bytes.write(to: url, options: .atomic) } catch { model?.error = error.localizedDescription }
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
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard (!model.busy || model.loadingHistory), !model.unifiedViewerBusy, sender.attachedSheet == nil else { return false }
        if model.selecting { finishSelection(nil); return false }; return true
    }
    func windowWillClose(_ notification: Notification) {
        let completion = selectionCompletion; selectionCompletion = nil
        let multiple = multipleSelectionCompletion; multipleSelectionCompletion = nil
        model.unifiedWindow?.close(); model.invalidate()
        if let window, let child = window.attachedSheet { window.endSheet(child, returnCode: .abort); child.close() }
        completion?(nil); multiple?(nil); onClosed()
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
    case worktree, head, active
    var errorDescription: String? {
        switch self {
        case .worktree: return "This operation requires a working tree."
        case .head: return "The selected revision is already HEAD. Refresh the Log."
        case .active: return "Finish or abort the active Merge or Rebase before starting another operation."
        }
    }
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
    let repository: GitRepository
    let sshSettings: SSHTransportSettings
    private var deletionCancellation: OperationCancellation?
    let selecting: Bool
    let selectingMultiple: Bool
    // Keep the security-scoped grant alive if the main repository window changes.
    private let access: RepositoryAccessLease?
    private var statisticsWindow: StatisticsWindowController?
    @Published var entries: [LogEntry] = []
    @Published var revisionActions: [String: LogRevisionActions] = [:]
    @Published var actionFailures = Set<String>()
    private var actionQueue: [LogEntry] = []
    private var actionCancellation: OperationCancellation?
    private var activeActionHash: String?
    private var actionGeneration = 0
    var loadingActions: Bool { actionCancellation != nil }
    @Published var parentMetadata: [String: [LogParentChoice]] = [:]
    @Published var mergeActive = false
    @Published var conflictRebase = false
    @Published var bisectActive = false
    @Published private(set) var bisectGoodTerm = "good"
    @Published private(set) var bisectBadTerm = "bad"
    @Published var hasStash = false
    @Published var hasSubmodules = false
    var onWorkingCommand: ((RepositoryAction) -> Void)?
    private func workingCommandAllowed(_ action: RepositoryAction, working: Bool, stashRow: Bool, bare: Bool, merging: Bool, stash: Bool, submodules: Bool) -> Bool {
        switch action {
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
        workingCommandAvailable(action) && onWorkingCommand != nil && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil && !copyingDetails
    }
    func requestWorkingCommand(_ action: RepositoryAction) {
        guard canWorkingCommand(action) else { return }
        let selection = selected, request = generation, working = selectedWorkingTree, stashRow = selectedIsStash
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let fresh = try await repository.finderMetadata()
                guard workingCommandAllowed(action, working: working, stashRow: stashRow, bare: fresh.bare, merging: fresh.mergeActive, stash: fresh.hasStash, submodules: fresh.hasSubmoduleConfig) else { throw LogWorkingCommandFailure.unavailable }
                guard request == generation, selection == selected else { return }
                busy = false; onWorkingCommand?(action)
            } catch { if request == generation { self.error = error.localizedDescription } }
        }
    }
    @Published var showWorkingTree = true
    @Published var showUnversionedFiles = true
    @Published private(set) var workingTreeSnapshot: WorkingTreeHistory?
    @Published private(set) var workingIndexFiles: [WorkingTreeFile] = []
    private var workingSubmodules = Set<String>()
    var selectedWorkingTree: Bool { selected == [""] && workingTreeSnapshot != nil }
    var includesWorkingTree: Bool { selected.contains("") && workingTreeSnapshot != nil }
    func updateWorkingFiles() {
        guard selectedWorkingTree, let snapshot = workingTreeSnapshot else { return }
        let tracked = Set(snapshot.files.map(\.path))
        let ignored = workingIndexFiles.filter { ($0.assumeUnchanged || $0.skipWorktree) && !tracked.contains($0.id) }.map {
            CommitFile(path: $0.id, oldPath: nil, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: workingSubmodules.contains($0.id))
        }
        files = snapshot.files + ignored + (showUnversionedFiles ? snapshot.unversioned.filter { !tracked.contains($0.path) } : [])
    }
    @Published var currentBranch = ""
    var onExportRevision: ((String) -> Void)?
    var canExportRevision: Bool { revision != nil && !selectedIsStash && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil && onExportRevision != nil }
    func requestExport() {
        guard canExportRevision, let revision else { return }
        onExportRevision?(revision.references.first { $0.name.hasPrefix("refs/tags/") }?.name ?? revision.hash)
    }
    var onMergeRevision: ((String) -> Void)?
    var onRebaseRevision: ((String) -> Void)?
    var onBisect: ((LogBisectRequest) -> Void)?
    func bisectAvailable(_ command: LogBisectCommand) -> Bool {
        if selectedWorkingTree { return !bare && bisectActive && command != .start }
        if includesWorkingTree { return !bare && bisectActive && command == .skip }
        if command == .reset { return false }
        let chosen = revisions
        guard !bare, !chosen.isEmpty, chosen.count == selected.count, let first = chosen.first, !first.hash.isEmpty else { return false }
        if command == .start { return chosen.count == 2 && !bisectActive && !mergeActive && !isStash(first) }
        return bisectActive && !first.references.contains { $0.name.hasPrefix("refs/bisect/") } && (command == .skip || chosen.count == 1)
    }
    func canBisect(_ command: LogBisectCommand) -> Bool {
        bisectAvailable(command) && onBisect != nil && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil && !copyingDetails
    }
    func requestBisect(_ command: LogBisectCommand) {
        guard canBisect(command) else { return }
        let chosen = revisions, selection = selected, request = generation
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                guard try await !repository.isBare() else { throw BisectFailure.workingTree }
                let state = try await repository.bisectState()
                let handoff: LogBisectRequest
                if command == .start {
                    guard !state.active, try await !repository.logMergeActive() else { throw BisectFailure.active }
                    // Upstream uses the first reference, otherwise the hash. A
                    // moved reference falls back to the selected commit.
                    func preset(_ entry: LogEntry) async throws -> String {
                        guard let ref = entry.references.first?.name else { return entry.hash }
                        let result = try await repository.run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], successfulExitCodes: 0...128)
                        return result.exitCode == 0 && result.text.trimmingCharacters(in: .newlines) == entry.hash ? ref : entry.hash
                    }
                    let bad = try await preset(chosen[0]), good = try await preset(chosen[1])
                    handoff = LogBisectRequest(good: good, bad: bad, operation: nil, revisions: [])
                } else {
                    guard state.active else { throw BisectFailure.inactive }
                    if !selection.contains(""), let first = chosen.first {
                        let marks = try await repository.run(["for-each-ref", "--points-at", first.hash, "--format=%(refname)", "refs/bisect/"]).text
                        guard marks.isEmpty else { throw LogBisectFailure.marked }
                    }
                    handoff = LogBisectRequest(good: nil, bad: nil, operation: command.operation, revisions: chosen.map(\.hash))
                }
                guard generation == request, selected == selection else { return }
                busy = false; onBisect?(handoff)
            } catch { if generation == request { self.error = error.localizedDescription } }
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
    @Published var graph: [CommitGraphRow] = []
    @Published var selected = Set<String>()
    @Published var files: [CommitFile] = []
    @Published var fileGroups: [LogFileGroup] = []
    @Published var selectedFiles = Set<String>() { didSet { refreshPatchPreview() } }
    private(set) var fileSelectionMark: String?
    func markedFile(_ ids: Set<String>) -> CommitFile? {
        if let fileSelectionMark, ids.contains(fileSelectionMark), let file = visibleFiles.first(where: { $0.id == fileSelectionMark }) { return file }
        return visibleFiles.first { ids.contains($0.id) }
    }
    private var lastImportedWorkingMark: UUID?
    @Published var comparisonMark: PreparedFileComparisonMark?
    @Published var allBranches = false
    @Published private(set) var historyWalk = HistoryWalkOptions()
    @Published private(set) var rollupInfo: [String: HistoryRollupInfo] = [:]
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
        historyWalk.toggle(command)
        if historyWalk.followRenames { allBranches = false; showWholeProject = false }
        reload()
    }
    @Published var endRevision: String?
    @Published var revisionRange: HistoryRevisionRange?
    @Published var historyPaths: [String] = []
    @Published var showWholeProject = true
    @Published private(set) var unrelatedPathMode = HistoryUnrelatedPathMode.gray
    @Published private(set) var pathScopes: [HistoryPathScope] = []
    func unrelatedFile(_ file: CommitFile) -> Bool {
        !showWholeProject && !pathScopes.isEmpty && file.action != "?" && !pathScopes.contains { $0.contains(file) }
    }
    func grayFile(_ file: CommitFile) -> Bool { unrelatedPathMode == .gray && unrelatedFile(file) }
    func toggleUnrelatedPaths(_ mode: HistoryUnrelatedPathMode) {
        guard !busy, !isInvalidated, mode != .all else { return }
        unrelatedPathMode.toggle(mode)
        selectedFiles.formIntersection(Set(visibleFiles.map(\.id)))
        if fileSelectionMark.map({ !selectedFiles.contains($0) }) == true { fileSelectionMark = visibleFiles.first { selectedFiles.contains($0.id) }?.id }
    }
    func toggleUnversionedFiles() {
        guard !busy, !isInvalidated else { return }
        showUnversionedFiles.toggle(); labelDefaults.set(showUnversionedFiles, forKey: "AddBeforeCommit"); updateWorkingFiles()
        selectedFiles.formIntersection(Set(visibleFiles.map(\.id)))
    }
    var colorPreferences: UserDefaults { labelDefaults }
    func fileForeground(_ file: CommitFile, selected: Bool) -> Color {
        file.statusTextColor(selected: selected, gray: grayFile(file), preferences: labelDefaults)
    }
    private var detailCancellation: OperationCancellation?
    private var historyCancellation: OperationCancellation?
    var loadingHistory: Bool { historyCancellation != nil }
    @Published var issueProperties = IssueTrackerProperties()
    @Published var search = ""
    @Published var searchFields = LogSearchSelection.load()
    @Published var searchRegex = UserDefaults.standard.bool(forKey: "UseRegexFilter")
    @Published var searchCaseSensitive = UserDefaults.standard.bool(forKey: "FilterCaseSensitively")
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
    var integrationAvailable: Bool { revision != nil && revision?.isHead == false && !bare && !mergeActive && !selectedIsStash }
    func canIntegrate(_ command: LogIntegrationCommand) -> Bool {
        integrationAvailable && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil && !copyingDetails && (command == .merge ? onMergeRevision != nil : onRebaseRevision != nil)
    }
    func integrationTitle(_ command: LogIntegrationCommand) -> String {
        let branch = currentBranch.isEmpty ? "HEAD" : currentBranch
        return command == .merge ? "Merge to \"\(branch)\"…" : "Rebase \"\(branch)\" onto this…"
    }
    func requestIntegration(_ command: LogIntegrationCommand, target: LogReferenceMenuTarget? = nil) {
        guard !isInvalidated, canIntegrate(command), let chosen = revision else { return }
        let pointedReference: RevisionReference?
        if let target { guard command == .merge, let reference = reference(for: target) else { return }; pointedReference = reference }
        else { pointedReference = nil }
        let request = generation; busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let isBare = try await repository.isBare()
                let merging = try await repository.logMergeActive()
                let rebasing = try await repository.rebaseState().active
                let head = try await repository.rebaseCommit("HEAD").hash
                guard !isBare else { throw LogIntegrationFailure.worktree }
                guard !merging, !rebasing else { throw LogIntegrationFailure.active }
                guard head != chosen.hash else { throw LogIntegrationFailure.head }
                var references = (pointedReference.map { [$0] } ?? chosen.references).map(\.name).filter { $0.utf8.starts(with: "refs/".utf8) && !$0.utf8.starts(with: "refs/stash".utf8) }
                if command == .rebase { references = references.filter { $0.hasPrefix("refs/heads/") } + references.filter { !$0.hasPrefix("refs/heads/") } }
                var target = chosen.hash
                for reference in references {
                    let resolved = try await repository.run(["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"], successfulExitCodes: 0...128)
                    if resolved.exitCode == 0 && resolved.text.trimmingCharacters(in: .newlines) == chosen.hash { target = command == .rebase && reference.hasPrefix("refs/heads/") ? String(reference.dropFirst("refs/heads/".count)) : reference; break }
                }
                if pointedReference != nil, target == chosen.hash { throw CheckoutFailure.invalidRevision }
                guard !isInvalidated, request == generation, revision?.hash == chosen.hash, selected.count == 1 else { return }
                busy = false
                if command == .merge { onMergeRevision?(target) } else { onRebaseRevision?(target) }
            } catch { if request == generation { self.error = error.localizedDescription } }
        }
    }
    var canEditNotes: Bool { revision != nil && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil && !selectedIsStash }
    var canSaveNote: Bool { !savingNote && noteRequest?.accepts(noteText) == true }
    private func cancelNoteRead() {
        noteCancellation?.cancel(); noteCancellation = nil; loadingNote = false; noteGeneration += 1
    }
    func editNotes() {
        guard canEditNotes, let revision else { return }
        cancelNoteRead(); let token = OperationCancellation(); noteCancellation = token
        let request = noteGeneration; loadingNote = true; error = nil
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let note = try await repository.editableCommitNote(revision: revision.hash, cancellation: token)
                guard request == noteGeneration else { return }
                noteCancellation = nil; loadingNote = false; noteText = note.text; noteError = nil; noteRequest = note
            } catch {
                guard request == noteGeneration else { return }
                noteCancellation = nil; loadingNote = false
                if !token.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func cancelNote() { guard !savingNote else { return }; noteRequest = nil; noteText = ""; noteError = nil }
    func saveNote() {
        guard canSaveNote, let note = noteRequest else { return }
        let text = noteText; savingNote = true; busy = true; noteError = nil
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let display = try await repository.saveCommitNote(note, text: text)
                if let index = entries.firstIndex(where: { $0.hash == note.revision }) { entries[index].notes = display }
                savingNote = false; busy = false; cancelNote()
                onRevisionChanged("Saved note for " + note.revision)
            } catch let failure as CommitNoteFailure {
                savingNote = false; busy = false
                if case .savedButRefreshFailed = failure { cancelNote(); error = failure.localizedDescription }
                else { noteError = failure.localizedDescription }
            } catch { savingNote = false; busy = false; noteError = error.localizedDescription }
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
    private var jumpCancellation: OperationCancellation?
    private var jumpGeneration = 0
    private func cancelJump() {
        jumpCancellation?.cancel(); jumpCancellation = nil; jumping = false; jumpGeneration += 1
    }
    func jump(up: Bool) {
        guard !busy, !jumping, !includesWorkingTree else { return }
        if jumpKind == .selectionHistory {
            highlightedRevision = nil
            if let hash = selectionNavigation.move(up: up) {
                if entries.contains(where: { $0.hash == hash }) { highlightedRevision = hash; scrollRevision = hash; scrollRequest += 1 }
                else { navigationNotice = "The revision \(hash) is not visible in the current log." }
            }
            return
        }
        let snapshot = entries.filter { !$0.hash.isEmpty }, selection = selected, kind = jumpKind
        guard kind.candidates(entries: snapshot, selected: selection, up: up) != nil else { return }
        select([])
        let token = OperationCancellation(); jumpCancellation = token; let request = jumpGeneration
        jumping = true
        Task {
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
    private func showJumpNotFound() {
        guard !UserDefaults.standard.bool(forKey: "NoJumpNotFoundWarning") else { return }
        guard let window, window.attachedSheet == nil else { navigationNotice = "No more revisions found."; return }
        let alert = NSAlert(); alert.messageText = "No more revisions found."; alert.alertStyle = .informational
        alert.addButton(withTitle: "OK"); alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not show this message again"
        alert.beginSheetModal(for: window) { _ in
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "NoJumpNotFoundWarning") }
        }
    }
    @Published var filterPaths = "" { didSet { refreshPatchPreview() } }
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
        guard !busy, !isInvalidated else { return }; initializedHistoryLimit = true; historyLimit.scale = scale
        if scale == .noLimit { labelDefaults.removeObject(forKey: HistoryLimitDefaults.fromDateKey(root: repository.root)) }
        reload()
    }
    func changeHistoryFrom(_ date: Date) {
        guard !busy, !isInvalidated else { return }; initializedHistoryLimit = true
        from = min(date, to); historyLimit.from = HistoryLimitScope.startOfDay(from); historyLimit.scale = .selectedDate
        if defaultHistoryLimitScale == .selectedDate { HistoryLimitDefaults.saveFrom(historyLimit.from!, root: repository.root, defaults: labelDefaults) }
        reload()
    }
    func changeHistoryTo(_ date: Date) {
        guard !busy, !isInvalidated else { return }; initializedHistoryLimit = true
        to = max(date, from); historyLimit.until = HistoryLimitScope.endOfDay(to); reload()
    }
    @Published var busy = false {
        didSet { if !busy { scheduleRepositoryRefresh() } }
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
        guard pendingRepositoryRefresh, !busy, !isInvalidated, repositoryRefreshTask == nil else { return }
        repositoryRefreshTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.repositoryRefreshTask = nil
            guard self.pendingRepositoryRefresh, !self.busy, !self.isInvalidated else { return }
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
    private var generation = 0
    private(set) var isInvalidated = false
    private var detailGeneration = 0
    private let showBranchRevisionNumber: Bool
    @Published private(set) var branchRevisionNumber: String?
    private var clipboardCancellation: OperationCancellation?
    private var clipboardGeneration = 0
    @Published var copyingDetails = false
    var clipboard = NSPasteboard.general
    var onCreateReference: (Bool, String) -> Void = { _, _ in }
    var onPush: (String) -> Void = { _ in }
    var onCheckout: (String) -> Void = { _ in }
    var onSwitchBranch: ((String) -> Void)?
    var confirmReferenceDeletion: (HistoryReferenceDeletion) async -> HistoryReferenceDeleteChoice = { _ in .abort }
    var acknowledgeReferenceDeletionFailure: (String) async -> Void = { _ in }

    var onCherryPick: (([String]) -> Void)?
    var onBrowseRepository: ((String) -> Void)?
    var onFormatPatch: ((FormatPatchPreset) -> Void)?
    var formatPatchPreset: FormatPatchPreset? {
        guard !includesWorkingTree else { return nil }
        return FormatPatchPreset.logSelection(orderedHashes: entries.filter { !$0.hash.isEmpty }.map(\.hash), selected: selected)
    }
    var onReset: (String) -> Void = { _ in }
    var onCompare: ((ComparisonRevision, ComparisonRevision) -> Void)?
    var onUnifiedDiff: ((Data, Bool) async throws -> Void)?
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
    var visibleFiles: [CommitFile] {
        files.filter { (unrelatedPathMode != .hide || !unrelatedFile($0)) && (filterPaths.isEmpty || $0.path.localizedCaseInsensitiveContains(filterPaths)) }
    }
    var message: String {
        if selectedWorkingTree, let snapshot = workingTreeSnapshot { return "Working tree changes\n" + snapshot.entry.message + (snapshot.entry.parents.first.map { "\nHEAD: " + $0 } ?? "") }
        guard let revision else { return selected.isEmpty ? "Select a revision to see its commit message and changed files." : "\(selected.count) revisions selected." }
        return "SHA-1: \(revision.hash)" + (branchRevisionNumber.map { ", Branch RevNo: " + $0 } ?? "") + "\nAuthor: \(revision.author) <\(revision.email)>\nDate: \(HistoryDateSettings.load().format(revision.date))\n" +
            (revision.parents.isEmpty ? "" : "Parents: \(revision.parents.joined(separator: " "))\n") + "\n" + revision.message + (revision.notes.isEmpty ? "" : "\n----\nNotes:\n" + revision.notes) + (revision.tagInfo.isEmpty ? "" : "\n----\nTag Info:\n" + HistoryDateSettings.load().tagInfo(revision.tagInfo))
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, selecting: Bool = false, selectingMultiple: Bool = false, labelDefaults: UserDefaults = .standard, gravatar: LogGravatar? = nil, historyRegexExecutable: URL? = nil) {
        let limits = HistoryLimitDefaults.load(defaults: labelDefaults)
        self.historyLimit = HistoryLimitScope(defaults: limits, from: limits.scale == .selectedDate ? HistoryLimitDefaults.savedFrom(root: repository.root, defaults: labelDefaults) : nil)
        self.fullCommitMessageOnLogLine = labelDefaults.bool(forKey: "FullCommitMessageOnLogLine")
        self.drawTagsBranchesOnRightSide = labelDefaults.bool(forKey: "DrawTagsBranchesOnRightSide")
        self.symbolizeRefNames = labelDefaults.bool(forKey: "SymbolizeRefNames")
        self.includeWorkingTreeChanges = labelDefaults.object(forKey: "LogIncludeWorkingTreeChanges") == nil || labelDefaults.bool(forKey: "LogIncludeWorkingTreeChanges")
        self.includeBoundaryCommits = labelDefaults.bool(forKey: "LogIncludeBoundaryCommits")
        self.historyRegexExecutable = historyRegexExecutable
        self.showBranchRevisionNumber = labelDefaults.bool(forKey: "ShowBranchRevisionNumber")
        self.gravatar = gravatar ?? LogGravatar(defaults: labelDefaults)
        sshSettings = SSHTransportSettings(repository: repository); sshSettings.enabled = sshSettings.available
        self.repository = repository; self.access = access; self.selecting = selecting; self.selectingMultiple = selectingMultiple; self.labelDefaults = labelDefaults; showWorkingTree = includeWorkingTreeChanges && !selecting
        showGravatar = labelDefaults.object(forKey: gravatarDefaultsKey) == nil ? labelDefaults.bool(forKey: "EnableGravatar") : labelDefaults.bool(forKey: gravatarDefaultsKey)
        showUnversionedFiles = labelDefaults.object(forKey: "AddBeforeCommit") == nil || labelDefaults.bool(forKey: "AddBeforeCommit")
        if let stored = labelDefaults.object(forKey: labelDefaultsKey) as? NSNumber, stored.intValue >= 0 {
            referenceVisibility = HistoryReferenceVisibility(rawValue: stored.intValue).intersection(.all).union([.stash, .bisect])
        }
    }
    func selectSearchFields(_ fields: HistorySearchFields) {
        guard !busy else { return }
        searchFields = fields.intersection(LogSearchSelection.all)
        UserDefaults.standard.set(searchFields.rawValue, forKey: "SelectedLogFilters")
        if !search.isEmpty { reload() }
    }
    func toggleSearchFields() { selectSearchFields(LogSearchSelection.all.subtracting(searchFields)) }
    func selectAllSearchFields() { selectSearchFields(LogSearchSelection.all) }
    func setSearchRegex(_ enabled: Bool) {
        guard !busy else { return }
        searchRegex = enabled
        UserDefaults.standard.set(enabled, forKey: "UseRegexFilter")
        if !search.isEmpty { reload() }
    }
    func setSearchCaseSensitive(_ enabled: Bool) {
        guard !busy else { return }
        searchCaseSensitive = enabled
        UserDefaults.standard.set(enabled, forKey: "FilterCaseSensitively")
        if !search.isEmpty { reload() }
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
        let scope = paths.contains(".") ? [] : paths
        guard historyPaths != scope || showWholeProject != scope.isEmpty else { return }
        historyWalk.followRenames = false; canFollowRenames = false
        historyPaths = scope; showWholeProject = scope.isEmpty; reload()
    }
    func canReuseForRange(_ range: HistoryRevisionRange) -> Bool {
        !isInvalidated && !busy && !jumping && !loadingNote && !savingNote && noteRequest == nil && !unifiedViewerBusy && !copyingDetails &&
        revisionRange == range && endRevision == nil && historyPaths.isEmpty
    }
    func configureWholeProjectScope() {
        historyWalk.followRenames = false; canFollowRenames = false
        historyPaths = []; showWholeProject = true
    }
    private func cancelActionReads() {
        actionCancellation?.cancel(); actionCancellation = nil
        actionQueue = []; activeActionHash = nil; actionGeneration += 1
    }
    func requestActions(_ entry: LogEntry) {
        if entry.hash.isEmpty { if revisionActions[""] == nil, let snapshot = workingTreeSnapshot { revisionActions[""] = .classify(snapshot.files) }; return }
        guard !busy, revisionActions[entry.hash] == nil, !actionFailures.contains(entry.hash),
            activeActionHash != entry.hash, !actionQueue.contains(where: { $0.hash == entry.hash }) else { return }
        actionQueue.append(entry)
        guard actionCancellation == nil else { return }
        let cancellation = OperationCancellation(); actionCancellation = cancellation
        let request = actionGeneration
        Task {
            while request == actionGeneration && !actionQueue.isEmpty && !cancellation.isCancelled {
                let entry = actionQueue.removeFirst(); activeActionHash = entry.hash
                do {
                    let actions = try await repository.revisionActions(in: entry, cancellation: cancellation)
                    guard request == actionGeneration else { return }
                    revisionActions[entry.hash] = actions
                } catch {
                    guard request == actionGeneration else { return }
                    if !cancellation.isCancelled { actionFailures.insert(entry.hash) }
                }
                activeActionHash = nil
            }
            if request == actionGeneration { actionCancellation = nil; activeActionHash = nil }
        }
    }
    func showStatistics() {
        guard !busy, !isInvalidated, !entries.isEmpty else { return }
        if let statisticsWindow { statisticsWindow.showWindow(nil); statisticsWindow.window?.makeKeyAndOrderFront(nil); return }
        let controller = StatisticsWindowController(repository: repository, access: access, entries: entries)
        controller.onClosed = { [weak self] in self?.statisticsWindow = nil }
        statisticsWindow = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.model.start()
    }
    func invalidate() {
        statisticsWindow?.model.cancel(); statisticsWindow?.close(); statisticsWindow = nil
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
        guard !busy || loadingHistory else { return }
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
        var options = HistoryOptions(); options.endRevision = endRevision; options.revisionRange = revisionRange; options.allBranches = allBranches; options.search = search; options.searchFields = searchFields; options.searchCaseSensitive = searchCaseSensitive; options.searchRegex = searchRegex
        options.walk = historyWalk; options.regexExecutable = historyRegexExecutable
        options.includeBoundaryCommits = includeBoundaryCommits
        options.retainFilteredRows = true
        let referenceVisibility = referenceVisibility, rollupStates = rollupStates
        let scope = historyPaths
        if !showWholeProject { options.paths = historyPaths }
        historyLimit.apply(to: &options)
        busy = true
        Task {
            do {
                let bare = try await repository.run(["rev-parse", "--is-bare-repository"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) == "true"
                let mergeActive = try await repository.logMergeActive(cancellation: cancellation)
                let metadata = try await repository.finderMetadata(), bisectActive = metadata.bisectActive
                let bisect = bisectActive ? try await repository.bisectState() : nil
                let conflictRebase: Bool
                if bare { conflictRebase = false } else { conflictRebase = try await repository.conflictIsRebase() }
                let referenceContext = try await repository.historyReferenceContext(cancellation: cancellation)
                let currentBranch = try await repository.branch()
                let issueProperties = try await repository.issueTrackerProperties(cancellation: cancellation)
                let followAllowed = try await repository.canFollowHistory(paths: scope, revision: options.revisionRange?.to ?? options.endRevision, cancellation: cancellation)
                let pathScopes = try await repository.historyPathScopes(paths: scope, revision: options.revisionRange?.to ?? options.endRevision, cancellation: cancellation)
                let showPatch = patchPreviewPreferenceLoaded ? patchPreviewVisible : try await repository.run(["config", "--bool", "--get", "tgit.logshowpatch"], successfulExitCodes: 0...1, cancellation: cancellation).text.trimmingCharacters(in: .newlines) == "true"
                var result = try await repository.history(options: options, cancellation: cancellation, issueProperties: issueProperties)
                let working = showWorkingTree && includeWorkingTreeChanges && !selecting && !bare ? try await repository.workingTreeHistory(cancellation: cancellation) : nil
                let indexFiles = working == nil ? [] : try await repository.workingTreeStatus(refreshIndex: false)
                let submodules = working == nil ? Set<String>() : try await repository.submodulePaths()
                if let working { result.insert(working.entry, at: 0) }
                guard request == generation else { return }
                let formatter = ISO8601DateFormatter()
                let dates = result.compactMap { formatter.date(from: $0.committerDate.isEmpty ? $0.date : $0.committerDate) }
                let selectedFrom = historyLimit.scale.rawValue >= HistoryLimitScale.selectedDate.rawValue ? historyLimit.from.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil } : nil
                if let first = selectedFrom ?? dates.min() { from = first }
                if let last = historyLimit.until ?? dates.max() { to = last }
                self.bare = bare; self.mergeActive = mergeActive; self.bisectActive = bisectActive; self.bisectGoodTerm = bisect?.goodTerm ?? "good"; self.bisectBadTerm = bisect?.badTerm ?? "bad"; self.currentBranch = currentBranch; self.issueProperties = issueProperties
                self.conflictRebase = conflictRebase
                hasStash = metadata.hasStash; hasSubmodules = metadata.hasSubmoduleConfig
                canFollowRenames = followAllowed
                self.pathScopes = pathScopes
                if !patchPreviewPreferenceLoaded {
                    patchPreviewPreferenceLoaded = true
                    if patchPreviewVisible != showPatch { patchPreviewVisible = showPatch; onPatchPreviewVisibility?(showPatch) }
                }
                let filterActive = try await Task.detached { try HistorySearchActivity.isActive(options.search, regex: options.searchRegex, caseSensitive: options.searchCaseSensitive, executable: options.regexExecutable, cancellation: cancellation) }.value
                guard request == generation else { return }
                let projection = CommitGraph.project(result, walk: options.walk, references: referenceVisibility, rollupStates: rollupStates)
                self.referenceContext = referenceContext
                let highlightEntries = projection.entries
                let labeledHashes = Set(highlightEntries.filter { !visibleReferences(for: $0).isEmpty }.map(\.hash))
                let fullMessage = fullCommitMessageOnLogLine
                let highlights = try await Task.detached {
                    guard filterActive else { return [String: [String: [NSRange]]]() }
                    return try LogSearchHighlights.prepare(highlightEntries, query: options.search, regex: options.searchRegex, caseSensitive: options.searchCaseSensitive, fields: options.searchFields, fullMessage: fullMessage, labeled: labeledHashes, executable: options.regexExecutable, cancellation: cancellation, applyLabelGates: false)
                }.value
                guard request == generation else { return }
                loadedHighlightFields = options.searchFields
                searchHighlights = highlights
                historyFilterActive = filterActive; rollupInfo = projection.rollups
                entries = projection.entries; graph = projection.graph
                result = projection.entries
                workingTreeSnapshot = working; workingIndexFiles = indexFiles; workingSubmodules = submodules
                if let working { revisionActions[""] = .classify(working.files) } else { revisionActions.removeValue(forKey: "") }
                let hashes = Set(result.map(\.hash)); revisionActions = revisionActions.filter { hashes.contains($0.key) }
                parentMetadata = parentMetadata.filter { hashes.contains($0.key) }
                selected.formIntersection(Set(result.map(\.hash)))
                if selected.isEmpty, let first = result.first { selected = [first.hash] }
                historyCancellation = nil; busy = false; select(selected)
            } catch { if request == generation { historyCancellation = nil; if !cancellation.isCancelled { self.error = error.localizedDescription }; busy = false } }
        }
    }
    func select(_ hashes: Set<String>) {
        cancelNoteRead()
        cancelJump(); highlightedRevision = nil
        for entry in entries where !entry.hash.isEmpty && hashes.contains(entry.hash) { selectionNavigation.add(entry.hash) }
        cancelClipboardRead()
        detailCancellation?.cancel(); detailCancellation = nil
        selected = hashes; branchRevisionNumber = nil; refreshGravatar(); selectedFiles = []; fileSelectionMark = nil; files = []; fileGroups = []
        detailGeneration += 1; let request = detailGeneration
        if selectedWorkingTree { updateWorkingFiles(); return }
        guard let revision else { return }
        let cancellation = OperationCancellation(); detailCancellation = cancellation
        Task {
            do {
                if revision.parents.count > 1 {
                    let groups = try await repository.logFileGroups(in: revision, cancellation: cancellation)
                    guard request == detailGeneration else { return }
                    fileGroups = groups
                    files = groups.flatMap { group in group.files.map { $0.inParentGroup(group.id) } }
                } else {
                    let result = try await repository.files(in: revision, cancellation: cancellation)
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
                detailCancellation = nil; refreshPatchPreview()
            } catch { if request == detailGeneration { detailCancellation = nil; if !cancellation.isCancelled { self.error = error.localizedDescription } } }
        }
    }
    func request(_ command: LogRevisionCommand, mainline: Int? = nil) {
        if command == .cherryPick { requestCherryPick(); return }
        guard !busy, let revision else { return }
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
        let request = generation, cancellation = OperationCancellation(), factory = sshSettings.capture()
        deletionCancellation = cancellation; busy = true; error = nil
        Task {
            let coordinator = factory?(); defer { coordinator?.close() }
            var refresh = false
            defer { if deletionCancellation === cancellation { deletionCancellation = nil; busy = false; if refresh && !isInvalidated { reload() } } }
            for target in targets {
                guard !isInvalidated, !cancellation.isCancelled, generation == request, revision?.hash == chosen.hash else { break }
                var choice = HistoryReferenceDeleteChoice.abort
                do {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let snapshot = try await repository.prepareHistoryReferenceDeletion(target.name, cancellation: cancellation)
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
        commandRequest = nil; busy = true
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result: GitResult
                if request.command == .revert { result = try await repository.revertLogRevision(revision: hash, mainline: request.mainline) }
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
    func diff(workingTree: Bool = false, path: String? = nil, alternate: Bool = false) {
        guard !busy, !isInvalidated, !unifiedViewerBusy, !workingTree || !bare else { return }
        if includesWorkingTree { workingTreeDiff(path: path, alternate: alternate); return }
        let revisions = self.revisions
        guard (1...2).contains(revisions.count) else { return }
        let request = generation, selection = selected
        busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let bytes: Data
                if revisions.count == 2, !workingTree {
                    var args = ["diff", "--no-ext-diff", "--no-color", revisions[1].hash, revisions[0].hash, "--"]
                    if let path { args.append(path) }
                    bytes = try await repository.run(args).stdout
                } else { bytes = try await repository.revisionDiffData(revisions[0], path: path, workingTree: workingTree) }
                guard request == generation, selection == selected, !isInvalidated else { return }
                if let onUnifiedDiff { try await onUnifiedDiff(bytes, alternate) }
                else if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate) {
                    guard request == generation, selection == selected, !isInvalidated else { return }
                    unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: "Selected revision changes", onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
            } catch { if request == generation, selection == selected, !isInvalidated { self.error = error.localizedDescription } }
        }
    }
    func copyDetails(includePaths: Bool = true) {
        let hashes = revisions.map(\.hash); guard !hashes.isEmpty else { return }
        let dateSettings = HistoryDateSettings.load()
        cancelClipboardRead()
        let cancellation = OperationCancellation(); clipboardCancellation = cancellation
        let request = clipboardGeneration
        copyingDetails = true; error = nil
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                var text = ""
                for hash in hashes {
                    guard request == clipboardGeneration else { return }
                    text += try await repository.commitLogText(revision: hash, includePaths: includePaths, cancellation: cancellation, dateSettings: dateSettings)
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
    func canCopyFiles(_ ids: Set<String>) -> Bool {
        !busy && !isInvalidated && visibleFiles.contains { ids.contains($0.id) }
    }
    func copyFiles(_ ids: Set<String>, information: CopyFileInformation) {
        guard canCopyFiles(ids) else { return }
        let selected = visibleFiles.filter { ids.contains($0.id) }
        let kind: StatusListCopy
        switch information {
        case .fullPaths: kind = .fullPaths
        case .relativePaths: kind = .relativePaths
        case .names: kind = .names
        case .all: kind = .all
        }
        let statuses = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, fileStatus($0)) })
        copy(StatusListClipboard.text(selected, root: repository.root, statuses: statuses, copy: kind))
    }
    func fileLog(_ ids: Set<String>, oldName: Bool = false) {
        if selectedWorkingTree, !busy, ids.count == 1, let file = files.first(where: { ids.contains($0.id) }), file.action != "?", let onFileLog {
            onFileLog(oldName ? file.oldPath ?? file.path : file.path, nil); return
        }
        guard !busy, let onFileLog, let revision, ids.count == 1,
              let file = files.first(where: { ids.contains($0.id) }) else { return }
        if oldName {
            guard let path = file.oldPath else { return }; onFileLog(path, nil)
        } else { onFileLog(file.path, revision.hash) }
    }
    var onSubmoduleFileLog: ((URL, String?) -> Void)?
    func canShowSubmoduleFileLog(_ ids: Set<String>) -> Bool {
        !busy && !isInvalidated && !bare && onSubmoduleFileLog != nil && ids.count == 1 && visibleFiles.contains { ids.contains($0.id) && $0.isSubmodule && $0.action != "?" }
    }
    func showSubmoduleFileLog(_ ids: Set<String>) {
        guard canShowSubmoduleFileLog(ids), let file = visibleFiles.first(where: { ids.contains($0.id) }) else { return }
        let request = generation, selection = selected, fileSelection = selectedFiles
        let working = selectedWorkingTree, revision = self.revision
        let pinRevision = UserDefaults.standard.object(forKey: "LogSubmoduleShowRevision") == nil || UserDefaults.standard.bool(forKey: "LogSubmoduleShowRevision")
        busy = true
        Task {
            defer { busy = false }
            do {
                try validateWorkingFileAccess(repository.root.appendingPathComponent(file.path))
                let from: String, to: String?
                if working {
                    guard let fresh = try await repository.workingTreeHistory(), fresh.files.contains(where: { $0.path == file.path && $0.isSubmodule && $0.action == file.action }) else { throw RevisionComparisonFailure.selection }
                    from = fresh.entry.parents.first ?? ""; to = nil
                } else {
                    guard let revision else { throw RevisionComparisonFailure.selection }
                    let groups = try await repository.logFileGroups(in: revision)
                    guard let group = groups.first(where: { $0.id == (file.parentIndex ?? 0) }), group.files.contains(where: { $0.path == file.path && $0.isSubmodule && $0.action == file.action }) else { throw RevisionComparisonFailure.selection }
                    from = file.action.hasPrefix("D") ? group.parent ?? "" : revision.hash
                    to = revision.hash
                }
                let module = try await repository.submoduleComparison(path: file.path, from: from, to: to)
                guard let checkout = module.checkout else { throw LogSubmoduleHistoryFailure.uninitialized }
                try validateWorkingFileAccess(checkout)
                let endRevision: String?
                if !working && !file.action.hasPrefix("D") && pinRevision {
                    guard module.to.available, let hash = module.to.revision else { throw LogSubmoduleHistoryFailure.unavailableRevision }
                    endRevision = hash
                } else { endRevision = nil }
                guard request == generation, selection == selected, fileSelection == selectedFiles, !isInvalidated else { return }
                busy = false; onSubmoduleFileLog?(checkout, endRevision)
            } catch { if request == generation, selection == selected, fileSelection == selectedFiles, !isInvalidated { self.error = error.localizedDescription } }
        }
    }
    func canBlameFile(_ ids: Set<String>) -> Bool {
        guard !busy, !isInvalidated, onBlame != nil, ids.count == 1,
              let file = visibleFiles.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return false }
        if selectedWorkingTree { return !bare && workingTreeSnapshot?.entry.parents.first != nil && file.action != "?" && !file.action.hasPrefix("A") }
        return revision != nil
    }
    func workingConflictPaths(_ ids: Set<String>) -> [String] {
        guard selectedWorkingTree, !bare else { return [] }
        return visibleFiles.filter { ids.contains($0.id) && $0.action.hasPrefix("U") }.map(\.path)
    }
    func canWorkingConflict(_ action: RepositoryAction, ids: Set<String>) -> Bool {
        guard !busy, !isInvalidated, onConflictAction != nil, !workingConflictPaths(ids).isEmpty else { return false }
        return action == .editConflict ? ids.count == 1 : action.resolveChoice != nil
    }
    func requestWorkingConflict(_ action: RepositoryAction, ids: Set<String>) {
        guard canWorkingConflict(action, ids: ids), let onConflictAction else { return }
        let paths = workingConflictPaths(ids), selection = selected, request = generation, rebase = conflictRebase
        busy = true
        Task {
            defer { busy = false }
            do {
                for path in paths { try validateWorkingFileAccess(repository.root.appendingPathComponent(path)) }
                let fresh = try await repository.conflicts(paths: paths)
                guard Set(fresh.map(\.path)) == Set(paths) else { throw ResolveFailure.stale }
                if action == .resolveMine || action == .resolveTheirs {
                    guard try await repository.conflictIsRebase() == rebase else { throw ResolveFailure.stale }
                }
                guard !isInvalidated, request == generation, selected == selection else { return }
                busy = false; onConflictAction(action, paths)
            } catch { if !isInvalidated, request == generation, selected == selection { self.error = error.localizedDescription } }
        }
    }
    func primaryFileAction(_ ids: Set<String>) {
        if canWorkingConflict(.editConflict, ids: ids) { requestWorkingConflict(.editConflict, ids: ids) }
        else { compareFiles(ids) }
    }
    func blameFile(_ ids: Set<String>) {
        guard canBlameFile(ids), let onBlame, let file = visibleFiles.first(where: { ids.contains($0.id) }) else { return }
        if !selectedWorkingTree { if let revision { onBlame(file.path, revision.hash) }; return }
        let request = generation, selection = selected
        busy = true
        Task {
            defer { busy = false }
            do {
                try validateWorkingFileAccess(repository.root.appendingPathComponent(file.path))
                _ = try await repository.workingFileOpenLocation(path: file.path)
                let content = try await repository.historicalFile(revision: "HEAD", path: file.path)
                guard ["100644", "100755"].contains(content.mode ?? ""), case .revision(let hash) = content.revision else { throw GitBlameFailure.unsupported }
                guard !isInvalidated, request == generation, selected == selection else { return }
                busy = false; onBlame(file.path, hash)
            } catch { if !isInvalidated, request == generation, selected == selection { self.error = error.localizedDescription } }
        }
    }
    func chooseHistoricalExport(_ ids: Set<String>) {
        guard !busy, !isInvalidated, selectedWorkingTree || revision != nil, window?.attachedSheet == nil else { return }
        let chosen = visibleFiles.filter { ids.contains($0.id) }
        guard chosen.contains(where: { !$0.isSubmodule && !$0.action.hasPrefix("D") }) else { return }
        if selectedWorkingTree { presentWorkingExport(chosen.filter { !$0.isSubmodule && !$0.action.hasPrefix("D") }.map(\.path)) }
        else if let revision { presentHistoricalExport(revision.hash, chosen) }
    }
    func exportHistoricalFiles(revision: String, files: [CommitFile], to folder: URL) {
        guard !busy else { return }; busy = true
        Task { await performHistoricalExport(revision: revision, files: files, folder: folder) }
    }
    private func performHistoricalExport(revision: String, files: [CommitFile], folder: URL) async {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() }; busy = false }
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let export: HistoricalFileExport = try await repository.prepareHistoricalExport(revision: revision, files: files, to: folder)
            for path in export.paths {
                do { try await repository.exportHistoricalFile(export, path: path) }
                catch {
                    let destination: String = folder.appendingPathComponent(path).path
                    let lines: [String] = ["File: " + path, "Revision: " + export.revision, "Destination: " + destination, "", error.localizedDescription]
                    let message: String = lines.joined(separator: "\n")
                    let shouldContinue: Bool = await confirmExportFailure(message)
                    if !shouldContinue { break }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func saveHistoricalFile(_ ids: Set<String>) {
        if selectedWorkingTree {
            guard !busy, !isInvalidated, !bare, ids.count == 1, window?.attachedSheet == nil,
                  let file = visibleFiles.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
            presentWorkingSave(file.path); return
        }
        guard !busy, let revision, ids.count == 1, let window, window.attachedSheet == nil,
              let file = files.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
        busy = true
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let content = try await repository.historicalFile(revision: revision.hash, path: file.path)
                guard case .revision(let hash) = content.revision else { throw RevisionComparisonFailure.range }
                let short = try await repository.run(["rev-parse", "--short", hash]).text.trimmingCharacters(in: .newlines)
                busy = false; presentHistoricalSave(content, short)
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
    func openHistoricalFile(_ ids: Set<String>, action: HistoricalOpenAction) {
        if selectedWorkingTree { openWorkingFile(ids, action: action); return }
        guard !busy, let revision, ids.count == 1, let window, window.attachedSheet == nil,
              let file = files.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
        busy = true
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let content = try await repository.historicalFile(revision: revision.hash, path: file.path)
                busy = false; presentHistoricalOpen(content, action)
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
    func validateWorkingFileAccess(_ file: URL) throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true || access?.contains(file) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func openWorkingFile(_ ids: Set<String>, action: HistoricalOpenAction) {
        guard !busy, !isInvalidated, !bare, ids.count == 1, window?.attachedSheet == nil,
              let file = visibleFiles.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
        let request = generation, selection = selected
        busy = true
        Task {
            defer { busy = false }
            do {
                try validateWorkingFileAccess(repository.root.appendingPathComponent(file.path))
                let location = try await repository.workingFileOpenLocation(path: file.path)
                guard !isInvalidated, request == generation, selection == selected else { return }
                try validateWorkingFileAccess(location)
                busy = false; presentWorkingOpen(location, action)
            } catch { if !isInvalidated, request == generation { self.error = error.localizedDescription } }
        }
    }
    func copyWorkingFiles(_ paths: [String], to target: URL, save: Bool) {
        guard !busy, !isInvalidated, !bare, !paths.isEmpty, !save || paths.count == 1 else { return }
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
    func markForComparison(_ ids: Set<String>) {
        guard !busy, !isInvalidated, selectedWorkingTree || revision != nil, ids.count == 1, let file = visibleFiles.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
        comparisonMark = PreparedFileComparisonMark(path: file.path, revision: selectedWorkingTree ? "" : revision!.hash)
    }
    func compareWithMarkedFile(_ ids: Set<String>) {
        guard !busy, !isInvalidated, selectedWorkingTree || revision != nil, let comparisonMark, let onPreparedFileCompare, ids.count == 1,
              let file = visibleFiles.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
        let current = PreparedFileComparisonMark(path: file.path, revision: selectedWorkingTree ? "" : revision!.hash)
        onPreparedFileCompare(comparisonMark, current)
    }
    func revealFile(_ ids: Set<String>) {
        guard !busy, !bare, ids.count == 1, let file = files.first(where: { ids.contains($0.id) }), !file.action.hasPrefix("D") else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let destination = try await repository.fileRevealDestination(path: file.path)
                switch destination {
                case .select(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
                case .openDirectory(let url): if !NSWorkspace.shared.open(url) { self.error = "Could not open the file's containing folder in Finder." }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    @Published private(set) var historicalRevertTrash: [URL] = []
    @Published private(set) var workingDeleteTrash: [URL] = []
    @Published private(set) var workingDeleteResult: WorkingFileDeleteResult?
    var confirmWorkingDelete: (Int, Bool) async -> Bool = { _, _ in false }
    func canDeleteWorkingFiles(_ ids: Set<String>, keyboard: Bool = false) -> Bool {
        guard !busy, !isInvalidated, !bare, selectedWorkingTree,
              let file = markedFile(ids),
              let mark = workingIndexFiles.first(where: { $0.id == file.path }) else { return false }
        return keyboard ? mark.entry.canDeleteWithKeyboard : mark.entry.canDeleteFromStatusList
    }
    func deleteWorkingFiles(_ ids: Set<String>, permanently: Bool = false, keyboard: Bool = false) {
        guard canDeleteWorkingFiles(ids, keyboard: keyboard) else { return }
        let chosen = visibleFiles.filter { ids.contains($0.id) }
        let rows = chosen.compactMap { file in workingIndexFiles.first { $0.id == file.path }?.entry }
        guard rows.count == chosen.count, let marked = markedFile(ids), let mark = rows.first(where: { $0.path == marked.path }) else { return }
        let request = generation, selection = selected, fileSelection = selectedFiles
        workingDeleteTrash = []; workingDeleteResult = nil; busy = true
        Task {
            defer { busy = false }
            guard request == generation, selection == selected, fileSelection == selectedFiles, !isInvalidated,
                  await confirmWorkingDelete(rows.count, permanently),
                  request == generation, selection == selected, fileSelection == selectedFiles, !isInvalidated else { return }
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
                if request == generation, selection == selected, fileSelection == selectedFiles, !isInvalidated { self.error = error.localizedDescription }
            }
        }
    }
    var onIgnoreFiles: ((RepositoryAction, [String]) -> Void)?
    func canIgnoreFiles(_ ids: Set<String>) -> Bool {
        guard !busy, !isInvalidated, !bare, onIgnoreFiles != nil,
              let mark = markedFile(ids) else { return false }
        return mark.action == "?" || mark.action.hasPrefix("D")
    }
    func requestIgnoreFiles(_ ids: Set<String>, mask: Bool = false, folder: Bool = false) {
        guard canIgnoreFiles(ids) else { return }
        let chosen = visibleFiles.filter { ids.contains($0.id) }
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
                guard chosen.allSatisfy({ file in available.contains { $0.path == file.path && $0.oldPath == file.oldPath && $0.action == file.action && (working || $0.parentIndex == (file.parentIndex ?? 0)) } }) else { throw RevisionComparisonFailure.selection }
                guard request == generation, selection == selected, fileSelection == selectedFiles, !isInvalidated else { return }
                busy = false; onIgnoreFiles?(mask ? .ignoreMask : .ignore, ignorePaths)
            } catch { if request == generation, selection == selected, fileSelection == selectedFiles, !isInvalidated { self.error = error.localizedDescription } }
        }
    }
    var handleHistoricalRevertFailure: (String) async -> Bool = { _ in false }
    var showHistoricalRevertResult: (String) -> Void = { _ in }
    func canRevertHistoricalFiles(_ ids: Set<String>, parent: Bool) -> Bool {
        guard !busy, !isInvalidated, !bare, !selectedWorkingTree, let revision,
              let marked = markedFile(ids) else { return false }
        return parent ? revision.parents.indices.contains(marked.parentIndex ?? 0) : !marked.action.hasPrefix("D")
    }
    func revertHistoricalFiles(_ ids: Set<String>, parent: Bool) {
        guard canRevertHistoricalFiles(ids, parent: parent), let revision else { return }
        let chosen = visibleFiles.filter { ids.contains($0.id) }
        let request = generation, selection = selected, fileSelection = selectedFiles
        historicalRevertTrash = []; busy = true
        Task {
            var restored: [String: Int] = [:], failures = 0
            let recycle = UserDefaults.standard.object(forKey: "RevertWithRecycleBin") == nil || UserDefaults.standard.bool(forKey: "RevertWithRecycleBin")
            for file in chosen {
                guard request == generation, selection == selected, fileSelection == selectedFiles, !isInvalidated else { break }
                do {
                    try validateWorkingFileAccess(repository.root.appendingPathComponent(file.oldPath ?? file.path))
                    let targets = try await repository.prepareLogFileRevert(revision, files: [file], parent: parent)
                    guard request == generation, selection == selected, fileSelection == selectedFiles, !isInvalidated else { break }
                    for target in targets {
                        historicalRevertTrash += try await repository.revertLogFile(target, recycle: recycle)
                        restored[target.revision, default: 0] += 1
                    }
                } catch {
                    if let failure = error as? WorkingFileRevertFailure { historicalRevertTrash += failure.trashedFiles }
                    failures += 1
                    guard request == generation, selection == selected, !isInvalidated else { break }
                    if !(await handleHistoricalRevertFailure(file.path + "\n\n" + error.localizedDescription)) { break }
                }
            }
            if !restored.isEmpty || !historicalRevertTrash.isEmpty {
                onRevisionChanged("Historical files reverted"); requestRepositoryRefresh()
            }
            busy = false
            guard request == generation, selection == selected, fileSelection == selectedFiles, !isInvalidated else { return }
            let message = restored.keys.sorted().map { "\(restored[$0]!) file(s) reverted to \($0)." }.joined(separator: "\n")
            showHistoricalRevertResult(message + (failures == 0 ? "" : "\n\(failures) file(s) failed."))
        }
    }
    var confirmWorkingFlags: (IndexFlagAction) async -> Bool = { _ in false }
    func workingFlagMark(_ ids: Set<String>) -> WorkingTreeFile? {
        guard selectedWorkingTree, let file = markedFile(ids) else { return nil }
        return workingIndexFiles.first { $0.id == file.path }
    }
    func canWorkingFlag(_ action: IndexFlagAction, ids: Set<String>) -> Bool {
        guard !busy, !isInvalidated, !bare, let mark = workingFlagMark(ids) else { return false }
        return action.isAvailable(for: [mark])
    }
    func setWorkingFlag(_ action: IndexFlagAction, ids: Set<String>) {
        guard canWorkingFlag(action, ids: ids), let mark = workingFlagMark(ids) else { return }
        let paths = visibleFiles.filter { ids.contains($0.id) }.map(\.path)
        let request = generation, selection = selected
        busy = true
        Task {
            defer { busy = false }
            guard await confirmWorkingFlags(action), request == generation, selection == selected, !isInvalidated else { return }
            do {
                for path in paths { try validateWorkingFileAccess(repository.root.appendingPathComponent(path)) }
                try await repository.setIndexFlags(action, paths: paths, markedPath: mark.id)
                onRevisionChanged(action.rawValue); requestRepositoryRefresh()
            } catch {
                if let partial = error as? IndexFlagPartialFailure, !partial.updatedPaths.isEmpty { onRevisionChanged(partial.localizedDescription); requestRepositoryRefresh() }
                if request == generation, !isInvalidated { self.error = error.localizedDescription }
            }
        }
    }
    func fileStatus(_ file: CommitFile) -> String {
        if selectedWorkingTree, let flags = workingIndexFiles.first(where: { $0.id == file.path }), flags.assumeUnchanged || flags.skipWorktree { return flags.status }
        return file.status
    }
    var onWorkingAdd: (([String], WorkingFileAddMode) -> Void)?
    func canWorkingAdd(_ ids: Set<String>, mode: WorkingFileAddMode = .normal) -> Bool {
        guard !busy, !isInvalidated, !bare, selectedWorkingTree,
              onWorkingAdd != nil || mode == .normal && onWorkingFiles != nil,
              let mark = markedFile(ids), mark.action == "?" || workingFlagMark(ids)?.entry.hasUnversionedCopy == true else { return false }
        if mode == .normal { return true }
        guard !mark.isSubmodule, let type = try? FileManager.default.attributesOfItem(atPath: repository.root.appendingPathComponent(mark.path).path)[.type] as? FileAttributeType else { return false }
        return type != .typeDirectory
    }
    func requestWorkingAdd(_ ids: Set<String>, mode: WorkingFileAddMode = .normal) {
        guard canWorkingAdd(ids, mode: mode), let mark = markedFile(ids) else { return }
        let paths = visibleFiles.filter { ids.contains($0.id) }.map(\.path)
        let request = generation, selection = selected, fileSelection = selectedFiles
        busy = true
        Task {
            defer { busy = false }
            do {
                for path in paths { try validateWorkingFileAccess(repository.root.appendingPathComponent(path)) }
                guard let fresh = try await repository.workingTreeHistory() else { throw RevisionComparisonFailure.selection }
                let available = fresh.files + fresh.unversioned
                guard Set(paths).isSubset(of: Set(available.map(\.path))), fresh.unversioned.contains(where: { $0.path == mark.path }) else { throw RevisionComparisonFailure.selection }
                if mode != .normal, try await !repository.addSelectionIsFiles([mark.path]) { throw RevisionComparisonFailure.selection }
                guard request == generation, selection == selected, fileSelection == selectedFiles, !isInvalidated else { return }
                busy = false
                if let onWorkingAdd { onWorkingAdd(paths, mode) }
                else if mode == .normal { onWorkingFiles?(.add, paths) }
            } catch { if request == generation, selection == selected, fileSelection == selectedFiles, !isInvalidated { self.error = error.localizedDescription } }
        }
    }
    func canWorkingFiles(_ action: RepositoryAction, ids: Set<String>) -> Bool {
        if action == .add { return canWorkingAdd(ids) }
        guard !busy, !isInvalidated, !bare, selectedWorkingTree, onWorkingFiles != nil else { return false }
        let chosen = visibleFiles.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return false }
        if action == .revert { return chosen.contains { $0.action != "?" } }
        if action == .commit, let mark = workingFlagMark(ids), mark.assumeUnchanged || mark.skipWorktree { return false }
        return action == .commit
    }
    func requestWorkingFiles(_ action: RepositoryAction, ids: Set<String>) {
        if action == .add { requestWorkingAdd(ids); return }
        guard canWorkingFiles(action, ids: ids), let onWorkingFiles else { return }
        let paths = visibleFiles.filter { ids.contains($0.id) && (action != .revert || $0.action != "?") }.map(\.path)
        let request = generation, selection = selected
        busy = true
        Task {
            defer { busy = false }
            do {
                for path in paths { try validateWorkingFileAccess(repository.root.appendingPathComponent(path)) }
                guard let fresh = try await repository.workingTreeHistory() else { throw RevisionComparisonFailure.selection }
                let available = fresh.files + fresh.unversioned
                guard Set(paths).isSubset(of: Set(available.map(\.path))) else { throw RevisionComparisonFailure.selection }
                guard request == generation, selection == selected, !isInvalidated else { return }
                busy = false; onWorkingFiles(action, paths)
            } catch { if request == generation, selection == selected, !isInvalidated { self.error = error.localizedDescription } }
        }
    }
    func selectedFileDiff(_ ids: Set<String>, alternate: Bool = false) {
        guard !busy, !isInvalidated, !unifiedViewerBusy, selectedWorkingTree || revision != nil else { return }
        let working = selectedWorkingTree, revision = self.revision
        let chosen = visibleFiles.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, !working || workingTreeSnapshot?.entry.parents.first != nil && chosen.allSatisfy({ $0.action != "?" }) else { return }
        let request = generation, selection = selected
        busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let bytes: Data
                if working { bytes = try await repository.workingTreeFileDiffData(files: chosen) }
                else if let revision { bytes = try await repository.revisionFileDiffData(revision, files: chosen) }
                else { return }
                guard request == generation, selection == selected, !isInvalidated else { return }
                if let onUnifiedDiff { try await onUnifiedDiff(bytes, alternate) }
                else if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate) {
                    guard request == generation, selection == selected, !isInvalidated else { return }
                    unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: working ? "Selected working-tree changes" : "Selected revision changes", onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
            } catch { if request == generation, selection == selected, !isInvalidated { self.error = error.localizedDescription } }
        }
    }
    func canCompareFilePair(_ ids: Set<String>) -> Bool {
        let chosen = visibleFiles.filter { ids.contains($0.id) }
        return chosen.count == 2 && chosen[0].path != chosen[1].path && chosen.allSatisfy { !$0.isSubmodule }
    }
    func compareFilePair(_ ids: Set<String>) {
        if selectedWorkingTree {
            guard !busy, !isInvalidated, !bare, canCompareFilePair(ids), let onWorkingFilePairCompare else { return }
            onWorkingFilePairCompare(visibleFiles.filter { ids.contains($0.id) }.map(\.path)); return
        }
        guard !busy, let revision, let onFilePairCompare else { return }
        let chosen = visibleFiles.filter { ids.contains($0.id) }
        guard chosen.count == 2, chosen.allSatisfy({ !$0.isSubmodule }) else { return }
        onFilePairCompare(revision.hash, chosen)
    }
    func fileParentComparisonTitle(_ ids: Set<String>) -> String? {
        guard !selectedWorkingTree, let revision else { return nil }
        let index = markedFile(ids)?.parentIndex ?? 0
        guard let parent = parentChoices(for: revision).first(where: { $0.number == index + 1 }) else { return nil }
        return "Compare parent with working tree: " + parent.title
    }
    func canCompareFilesWithParent(_ ids: Set<String>) -> Bool {
        !busy && !isInvalidated && !bare && !selectedWorkingTree && revision?.parents.first != nil && (onFileCompare != nil || onFileComparisons != nil) && visibleFiles.contains { ids.contains($0.id) }
    }
    func compareFiles(_ ids: Set<String>, workingTree: Bool = false, parentWorkingTree: Bool = false) {
        guard !busy, !isInvalidated, onFileCompare != nil || onFileComparisons != nil else { return }
        let chosen = visibleFiles.filter { ids.contains($0.id) }; guard !chosen.isEmpty else { return }
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
        if let onFileComparisons { onFileComparisons(requests) }
        else { for (from, to, paths) in requests { onFileCompare?(from, to, paths) } }
    }
    func doubleClickRevision() {
        guard labelDefaults.bool(forKey: "DiffByDoubleClickInLog"), !busy, !isInvalidated, !unifiedViewerBusy,
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
        onCompare?(.revision(parent), chosen.hash.isEmpty ? .workingTree : .revision(chosen.hash))
    }
    func compare(workingTree: Bool = false) {
        guard !busy, let onCompare, !workingTree || !bare else { return }
        if includesWorkingTree, !workingTree, selected.count <= 2 {
            let base = revisions.first?.hash ?? workingTreeSnapshot?.entry.parents.first
            onCompare(base.map { .revision($0) } ?? .emptyTree, .workingTree); return
        }
        let chosen = revisions
        guard chosen.count == 1 || chosen.count == 2 && !workingTree else { return }
        if workingTree { onCompare(.revision(chosen[0].hash), .workingTree) }
        else if chosen.count == 2 { onCompare(.revision(chosen[1].hash), .revision(chosen[0].hash)) }
        else { onCompare(chosen[0].parents.first.map { .revision($0) } ?? .emptyTree, .revision(chosen[0].hash)) }
    }
    private func workingTreeDiff(path: String?, alternate: Bool) {
        guard selected.count <= 2, let base = revisions.first?.hash ?? workingTreeSnapshot?.entry.parents.first else { return }
        let request = generation, selection = selected
        busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", base, "--"]
                if let path { args.append(path) }
                let bytes = try await repository.run(args).stdout
                guard request == generation, selection == selected, !isInvalidated else { return }
                if let onUnifiedDiff { try await onUnifiedDiff(bytes, alternate) }
                else if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate) {
                    guard request == generation, selection == selected, !isInvalidated else { return }
                    unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: "Working tree changes", onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
            } catch { if request == generation, selection == selected, !isInvalidated { self.error = error.localizedDescription } }
        }
    }
}

struct LogFileTableRow: Identifiable {
    let id: String
    let file: CommitFile?
    let header: String?
}

extension LogWindowModel {
    var fileTableRows: [LogFileTableRow] {
        guard !selectedWorkingTree, !fileGroups.isEmpty else {
            return visibleFiles.map { LogFileTableRow(id: $0.id, file: $0, header: nil) }
        }
        return fileGroups.flatMap { group -> [LogFileTableRow] in
            let visible = visibleFiles.filter { $0.parentIndex == group.id }
            if (!filterPaths.isEmpty || unrelatedPathMode == .hide) && visible.isEmpty { return [] }
            let title = "Diff with parent \(group.id + 1): " + (group.parent.map { String($0.prefix(8)) } ?? "Empty tree")
            return [LogFileTableRow(id: "\0header\(group.id)", file: nil, header: title)] + visible.map { LogFileTableRow(id: $0.id, file: $0, header: nil) }
        }
    }
    var fileTableSelection: Binding<Set<String>> {
        Binding(get: { self.selectedFiles }, set: { ids in
            let valid = ids.intersection(Set(self.visibleFiles.map(\.id)))
            let added = valid.subtracting(self.selectedFiles)
            if added.count == 1 { self.fileSelectionMark = added.first }
            else if self.fileSelectionMark.map({ !valid.contains($0) }) ?? true { self.fileSelectionMark = self.visibleFiles.first { valid.contains($0.id) }?.id }
            self.selectedFiles = valid
        })
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
            HStack(spacing: 12) {
                Text(model.repository.root.lastPathComponent).foregroundStyle(.blue).lineLimit(1)
                Menu(model.historyLimitTitle) {
                    Button("No limitation") { model.chooseHistoryLimit(.noLimit) }
                    if model.defaultHistoryLimitScale.requiresNumber && model.historyLimit.number > 0 {
                        Divider()
                        Button(model.defaultHistoryLimitScale.title(number: model.historyLimit.number)) { model.chooseHistoryLimit(model.defaultHistoryLimitScale) }
                    }
                    Divider()
                    Button("Configure default") { model.configureHistoryDefaults = true }
                }.disabled(model.busy)
                DatePicker("From:", selection: Binding(get: { model.from }, set: { model.changeHistoryFrom($0) }), displayedComponents: .date).labelsHidden().disabled(model.busy)
                DatePicker("To:", selection: Binding(get: { model.to }, set: { model.changeHistoryTo($0) }), displayedComponents: .date).disabled(model.busy)
                Menu {
                    ForEach([("Subject", HistorySearchFields.subject), ("Messages", .messages), ("Paths", .paths), ("Authors", .authors), ("Emails", .emails), ("Revisions", .revisions), ("Refname", .referenceNames), ("Tag Info", .tagInfo), ("Notes", .notes)], id: \.0) { title, field in
                        Toggle(title, isOn: Binding(get: { model.searchFields.contains(field) }, set: { enabled in
                            var selected = model.searchFields
                            if enabled { selected.insert(field) } else { selected.remove(field) }
                            model.selectSearchFields(selected)
                        }))
                    }
                    if model.issueProperties.showsBugIDColumn {
                        Toggle("Bug IDs", isOn: Binding(get: { model.searchFields.contains(.bugIDs) }, set: { enabled in
                            var fields = model.searchFields
                            if enabled { fields.insert(.bugIDs) } else { fields.remove(.bugIDs) }
                            model.selectSearchFields(fields)
                        }))
                    }
                    Divider()
                    Button("Toggle filters") { model.toggleSearchFields() }
                    Button("All") { model.selectAllSearchFields() }
                    Divider()
                    Toggle("Use regular expression", isOn: Binding(get: { model.searchRegex }, set: { model.setSearchRegex($0) }))
                    Toggle("Case-sensitive", isOn: Binding(get: { model.searchCaseSensitive }, set: { enabled in
                        model.setSearchCaseSensitive(enabled)
                    }))
                } label: { CommandLabel(title: "Search in", icon: .log) }.disabled(model.busy)
                TextField("Search log", text: $model.search).textFieldStyle(.roundedBorder).help(model.searchRegex ? "Use an ECMAScript regular expression; begin with ! to invert. Invalid expressions leave the filter inactive." : "Require words, exclude with -word, offer alternatives with +word, quote phrases, or begin with ! to invert the filter.").onSubmit { model.reload() }
                Button("Search") { model.reload() }.disabled(model.busy)
                Picker("Jump", selection: $model.jumpKind) {
                    ForEach(HistoryJumpKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 150).help("Jump to revision")
                Button { model.jump(up: true) } label: { CommandLabel(title: "", icon: .jumpUp) }.help("Jump up").accessibilityLabel("Jump up").disabled(model.busy || model.jumping)
                Button { model.jump(up: false) } label: { CommandLabel(title: "", icon: .jumpDown) }.help("Jump down").accessibilityLabel("Jump down").disabled(model.busy || model.jumping)

            }.font(.system(size: 12))
            VSplitView {
                RevisionTable(model: model, savesColumnLayout: savesColumnLayout).frame(minHeight: 200, idealHeight: 350)
                HStack(alignment: .top, spacing: 0) {
                    OutputView(text: model.message, usesLogFont: true).frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.showGravatar { LogGravatarView(loader: model.gravatar) }
                }.frame(minHeight: 110, idealHeight: 150)
                    .onChange(of: shortDate) { _ in model.objectWillChange.send() }
                    .onChange(of: relativeTimes) { _ in model.objectWillChange.send() }
                    .onChange(of: useSystemLocale) { _ in model.objectWillChange.send() }
                Table(model.fileTableRows, selection: model.fileTableSelection) {
                    TableColumn("Path") { row in
                        if let header = row.header {
                            Text(header).fontWeight(.semibold).foregroundStyle(Color.accentColor).accessibilityAddTraits(.isHeader)
                        } else if let file = row.file {
                            Text(StatusListClipboard.displayedPath(file)).foregroundStyle(model.fileForeground(file, selected: model.selectedFiles.contains(file.id))).help(file.oldPath.map { "Renamed from \($0)" } ?? file.path)
                        }
                    }.width(min: 260, ideal: 460)
                    TableColumn("Extension") { row in Text(row.file.map { StatusListClipboard.fileExtension($0.path, isDirectory: $0.isSubmodule) } ?? "").foregroundStyle(row.file.map { model.fileForeground($0, selected: model.selectedFiles.contains(row.id)) } ?? .primary) }.width(80)
                    TableColumn("Status") { row in Text(row.file.map(model.fileStatus) ?? "").foregroundStyle(row.file.map { model.fileForeground($0, selected: model.selectedFiles.contains(row.id)) } ?? .primary) }.width(95)
                    TableColumn("Lines added") { row in Text(row.file?.addedText ?? "").foregroundStyle(row.file.map { model.fileForeground($0, selected: model.selectedFiles.contains(row.id)) } ?? .primary) }.width(90)
                    TableColumn("Lines removed") { row in Text(row.file?.removedText ?? "").foregroundStyle(row.file.map { model.fileForeground($0, selected: model.selectedFiles.contains(row.id)) } ?? .primary) }.width(105)
                }.fileListFont().frame(minHeight: 130, idealHeight: 180)
                .onDeleteCommand { model.deleteWorkingFiles(model.selectedFiles, permanently: NSEvent.modifierFlags.contains(.shift), keyboard: true) }
                .contextMenu(forSelectionType: String.self) { ids in
                    TurtleGitContextMenu {
                        fileContextActions(ids)
                    }
                } primaryAction: { ids in
                    model.selectedFiles = ids; model.primaryFileAction(ids)
                }
            }
            Text("Showing \(model.entries.filter { !$0.hash.isEmpty }.count) revision(s) • \(model.selectedWorkingTree ? "Working tree selected" : "\(model.revisions.count) revision(s) selected") • \(model.files.count) changed file(s)")
                .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Toggle("All Branches", isOn: $model.allBranches).toggleStyle(.checkbox).disabled(model.endRevision != nil || model.revisionRange != nil || model.historyWalk.followRenames).onChange(of: model.allBranches) { _ in model.reload() }
                Menu {
                    ForEach([HistoryWalkCommand.firstParent, .noMerges, .followRenames, .fullHistory], id: \.self) { command in
                        Toggle(command.rawValue, isOn: Binding(get: { model.historyWalk.contains(command) }, set: { _ in model.toggleHistoryWalk(command) })).disabled(!model.canToggleHistoryWalk(command))
                    }
                    Divider()
                    ForEach([HistoryWalkCommand.compressed, .labeled], id: \.self) { command in
                        Toggle(command.rawValue, isOn: Binding(get: { model.historyWalk.contains(command) }, set: { _ in model.toggleHistoryWalk(command) })).disabled(!model.canToggleHistoryWalk(command))
                    }
                } label: { Text(model.historyWalk.isActive ? "✓ Walk Behavior" : "Walk Behavior") }.disabled(model.busy || model.isInvalidated)
                Menu("View") {
                    Toggle("Hide Unrelated Changed Paths", isOn: Binding(get: { model.unrelatedPathMode == .hide }, set: { _ in model.toggleUnrelatedPaths(.hide) }))
                    Toggle("Gray Unrelated Changed Paths", isOn: Binding(get: { model.unrelatedPathMode == .gray }, set: { _ in model.toggleUnrelatedPaths(.gray) }))
                    Divider()
                    Toggle("Show Unversioned Files", isOn: Binding(get: { model.showUnversionedFiles }, set: { _ in model.toggleUnversionedFiles() }))
                    Divider()
                    Menu("Labels") {
                        ForEach(HistoryLabelCommand.allCases, id: \.self) { command in
                            Toggle(command.rawValue, isOn: Binding(get: { model.referenceVisibility.contains(command.flag) }, set: { _ in model.toggleHistoryLabel(command) }))
                        }
                    }
                    Divider()
                    Toggle("Gravatar", isOn: Binding(get: { model.showGravatar }, set: { _ in model.toggleGravatar() }))
                    Toggle("View Patch", isOn: Binding(get: { model.patchPreviewVisible }, set: { model.setPatchPreview($0) }))
                }.disabled(model.busy || model.isInvalidated)
                if !model.selecting && !model.bare {
                    Toggle("Show Working Tree Changes", isOn: $model.showWorkingTree).toggleStyle(.checkbox).disabled(!model.canShowWorkingTree).onChange(of: model.showWorkingTree) { _ in model.reload() }
                }
                if !model.historyPaths.isEmpty {
                    Toggle("Show Whole Project", isOn: $model.showWholeProject).toggleStyle(.checkbox).disabled(model.historyWalk.followRenames).onChange(of: model.showWholeProject) { _ in model.reload() }
                        .help(model.historyPaths.joined(separator: "\n"))
                }
                Spacer()
                TextField("Filter paths", text: $model.filterPaths).textFieldStyle(.roundedBorder).frame(maxWidth: 430)
            }
            HStack {
                Button("Refresh") { model.reload() }.disabled(model.busy)
                Button("Statistics") { model.showStatistics() }.disabled(model.busy || model.entries.isEmpty || model.isInvalidated)
                if model.busy { ProgressView().controlSize(.small) }
                if model.patchPreviewLoading { ProgressView("Reading patch…").controlSize(.small) }
                if let error = model.patchPreviewError { Text(error).foregroundStyle(.red).font(.caption) }
                if let error = model.patchPreferenceError { Text("Could not remember View Patch: " + error).foregroundStyle(.red).font(.caption) }
                if model.loadingNote { ProgressView("Reading notes…").controlSize(.small) }
                if model.copyingDetails { ProgressView("Reading log details for clipboard…").controlSize(.small) }
                Spacer()
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-showlog.html")!) }
                Button("OK") { model.accept() }.disabled(model.selecting && !model.canAcceptSelection).keyboardShortcut(.defaultAction)
                if model.selecting { Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction) }
            }
        }.padding(12).frame(minWidth: 1040, minHeight: 650)
        .alert("Git operation failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Log navigation", isPresented: Binding(get: { model.navigationNotice != nil }, set: { if !$0 { model.navigationNotice = nil } })) {
            Button("OK") { model.navigationNotice = nil }
        } message: { Text(model.navigationNotice ?? "") }
        .sheet(isPresented: $model.configureHistoryDefaults) { HistoryLimitSettings(defaults: model.colorPreferences, onClose: { model.configureHistoryDefaults = false }).frame(width: 440).padding(20) }
        .sheet(item: $model.noteRequest) { _ in LogNotesDialog(model: model) }
        .sheet(item: $model.commandRequest) { request in LogRevisionDialog(model: model, request: request) }

    }
    @ViewBuilder private func fileContextActions(_ ids: Set<String>) -> some View {
        if model.selectedWorkingTree {
            if model.markedFile(ids)?.action == "?" || model.workingFlagMark(ids)?.entry.hasUnversionedCopy == true {
                Button { model.requestWorkingFiles(.add, ids: ids) } label: { CommandLabel(title: "Add", icon: .add) }.disabled(!model.canWorkingFiles(.add, ids: ids))
                if NSEvent.modifierFlags.contains(.shift) {
                    ForEach([WorkingFileAddMode.executable, .symlink], id: \.self) { mode in
                        if model.canWorkingAdd(ids, mode: mode) {
                            Button { model.requestWorkingAdd(ids, mode: mode) } label: { CommandLabel(title: mode.rawValue, icon: .add) }
                        }
                    }
                }
            }
            Button { model.requestWorkingFiles(.commit, ids: ids) } label: { CommandLabel(title: "Commit…", icon: .commit) }.disabled(!model.canWorkingFiles(.commit, ids: ids))
            if model.visibleFiles.contains(where: { ids.contains($0.id) && $0.action != "?" }) {
                Button { model.requestWorkingFiles(.revert, ids: ids) } label: { CommandLabel(title: "Revert…", icon: .revert) }.disabled(!model.canWorkingFiles(.revert, ids: ids))
            }
            if let mark = model.workingFlagMark(ids) {
                IndexFlagsMenu(files: model.workingIndexFiles.filter { ids.contains($0.id) }, selectionMark: mark) { model.setWorkingFlag($0, ids: ids) }.disabled(model.busy || model.isInvalidated || model.bare)
            }
            Divider()
        }
        let conflicts = model.workingConflictPaths(ids)
        if !conflicts.isEmpty {
            ResolveSelectionMenu(paths: conflicts, rebase: model.conflictRebase, canEdit: ids.count == 1) { action, _ in model.requestWorkingConflict(action, ids: ids) }
                .disabled(model.busy || model.isInvalidated || model.onConflictAction == nil)
            Divider()
        }
        Button { model.compareFiles(ids) } label: { CommandLabel(title: "Compare with base", icon: .compare) }.disabled(ids.isEmpty || model.onFileCompare == nil || model.busy)
        Button { model.selectedFileDiff(ids, alternate: NSEvent.modifierFlags.contains(.shift)) } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(ids.isEmpty || model.busy || (model.selectedWorkingTree ? model.workingTreeSnapshot?.entry.parents.first == nil || model.visibleFiles.contains { ids.contains($0.id) && $0.action == "?" } : model.revision == nil))
        Button { model.compareFiles(ids, workingTree: true) } label: { CommandLabel(title: "Compare with working tree", icon: .compare) }.disabled(ids.isEmpty || model.selectedWorkingTree || model.bare || model.onFileCompare == nil || model.busy)
        if !model.bare, let title = model.fileParentComparisonTitle(ids) {
            Button { model.compareFiles(ids, parentWorkingTree: true) } label: { CommandLabel(title: title, icon: .compare) }.disabled(!model.canCompareFilesWithParent(ids))
        }
        if model.canCompareFilePair(ids) {
            Button { model.compareFilePair(ids) } label: { CommandLabel(title: "Compare two files", icon: .compare) }.disabled(model.busy || (model.selectedWorkingTree ? model.onWorkingFilePairCompare == nil || model.bare : model.revision == nil || model.onFilePairCompare == nil))
        }
        if !model.selectedWorkingTree && !model.bare {
            if model.canRevertHistoricalFiles(ids, parent: false) || model.busy {
                Button { model.revertHistoricalFiles(ids, parent: false) } label: { CommandLabel(title: "Revert to this revision", icon: .revert) }.disabled(!model.canRevertHistoricalFiles(ids, parent: false))
            }
            if let parentTitle = model.fileParentComparisonTitle(ids) {
                Button { model.revertHistoricalFiles(ids, parent: true) } label: { CommandLabel(title: parentTitle.replacingOccurrences(of: "Compare parent with working tree", with: "Revert to parent revision"), icon: .revert) }.disabled(!model.canRevertHistoricalFiles(ids, parent: true))
            }
        }
        Divider()
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }) {
            Button { model.fileLog(ids) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(model.busy || model.onFileLog == nil || model.selectedWorkingTree && file.action == "?")
            if file.isSubmodule && !model.bare {
                Button { model.showSubmoduleFileLog(ids) } label: { CommandLabel(title: "Show submodule log", icon: .log) }.disabled(!model.canShowSubmoduleFileLog(ids))
            }
            if file.oldPath != nil {
                Button { model.fileLog(ids, oldName: true) } label: { CommandLabel(title: "Show log of old name", icon: .log) }.disabled(model.busy || model.onFileLog == nil)
            }
            if !file.isSubmodule && !file.action.hasPrefix("D") {
                Button { model.blameFile(ids) } label: { CommandLabel(title: "Blame", icon: .blame) }.disabled(!model.canBlameFile(ids))
            }
            Divider()
        }
        Button { model.chooseHistoricalExport(ids) } label: { CommandLabel(title: "Export…", icon: .export) }
            .disabled(model.busy || !model.selectedWorkingTree && model.revision == nil || !model.visibleFiles.contains(where: { ids.contains($0.id) && !$0.isSubmodule && !$0.action.hasPrefix("D") }))
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }), !file.isSubmodule && !file.action.hasPrefix("D") {
            historicalFileActions(ids)
        }
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }), !file.action.hasPrefix("D"), !model.bare {
            Button { model.revealFile(ids) } label: { CommandLabel(title: "Reveal in Finder", icon: .explore) }.disabled(model.busy)
        }
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") {
            preparedComparisonActions(ids, file: file)
        }
        if model.canDeleteWorkingFiles(ids) {
            Button { model.deleteWorkingFiles(ids, permanently: NSEvent.modifierFlags.contains(.shift)) } label: { CommandLabel(title: "Delete", icon: .remove) }
        }
        if model.canIgnoreFiles(ids) {
            let paths = model.visibleFiles.filter { ids.contains($0.id) }.map(\.path)
            IgnoreSelectionMenu(paths: paths) { action, selected in
                model.requestIgnoreFiles(ids, mask: action.ignoresByExtension, folder: selected != paths)
            }
        }
        Menu {
            ForEach(LogWindowModel.CopyFileInformation.allCases, id: \.self) { information in
                Button { model.copyFiles(ids, information: information) } label: { CommandLabel(title: information.rawValue, icon: .copy) }
            }
        } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }.disabled(!model.canCopyFiles(ids))
    }
    @ViewBuilder private func preparedComparisonActions(_ ids: Set<String>, file: CommitFile) -> some View {
        Divider()
        Button { model.markForComparison(ids) } label: { CommandLabel(title: "Mark for comparison", icon: .compare) }.disabled(model.busy || !model.selectedWorkingTree && model.revision == nil)
        if let mark = model.comparisonMark {
            Button { model.compareWithMarkedFile(ids) } label: { CommandLabel(title: "Compare with " + mark.label(for: file.path), icon: .compare) }.disabled(model.busy || !model.selectedWorkingTree && model.revision == nil || model.onPreparedFileCompare == nil)
        }
    }
    @ViewBuilder private func historicalFileActions(_ ids: Set<String>) -> some View {
        let unavailable = model.busy || !model.selectedWorkingTree && model.revision == nil
        Button { model.saveHistoricalFile(ids) } label: { CommandLabel(title: model.selectedWorkingTree ? "Save As…" : "Save revision to…", icon: .saveAs) }.disabled(unavailable)
        Button { model.openHistoricalFile(ids, action: .alternativeEditor) } label: { CommandLabel(title: model.selectedWorkingTree ? "View in alternative editor" : "View revision in alternative editor", icon: .editor) }.disabled(unavailable)
        Button { model.openHistoricalFile(ids, action: .open) } label: { CommandLabel(title: "Open", icon: .open) }.disabled(unavailable)
        Button { model.openHistoricalFile(ids, action: .openWith) } label: { CommandLabel(title: "Open With…", icon: .open) }.disabled(unavailable)
    }

}

/// Native settings checkbox with the same two-way preference binding as the Dialogs page.
struct LogPreferenceCheckbox: NSViewRepresentable {
    let title: String
    @Binding var value: Bool
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title; button.state = value ? .on : .off; button.isEnabled = enabled
        context.coordinator.change = { value = $0 }
    }
    final class Coordinator: NSObject {
        var change: (Bool) -> Void = { _ in }
        @objc func clicked(_ sender: NSButton) { change(sender.state == .on) }
    }
}

struct LogDialogSettings: View {
    @AppStorage("ShowBranchRevisionNumber") private var showBranchRevisionNumber = false
    @AppStorage("AutoCloseGitProgress") private var autoCloseGitProgress = 0
    @AppStorage("ConfirmKillProcess") private var confirmKillProcess = false
    @AppStorage("ShowGitexeTimings") private var showGitexeTimings = true
    @AppStorage("DiffByDoubleClickInLog") private var diffByDoubleClick = false
    @AppStorage("EnableGravatar") private var enableGravatar = false
    @AppStorage("GravatarUrl") private var gravatarURL = LogGravatarRequest.defaultTemplate
    @AppStorage("GravatarUseMD5") private var gravatarMD5 = false
    @AppStorage("LogDateFormat") private var shortDate = true
    @AppStorage("RelativeTimes") private var relative = false
    @AppStorage("UseSystemLocaleForDates") private var useSystemLocale = true
    @AppStorage("DrawTagsBranchesOnRightSide") private var labelsOnRight = false
    @AppStorage("SymbolizeRefNames") private var symbolizeRefs = false
    @AppStorage("FullCommitMessageOnLogLine") private var fullMessage = false
    var body: some View {
        Form {
            MessageEditorFontSettings()
            HistoryLimitSettings()
            Picker("Autoclose Git progress dialog:", selection: Binding(get: { GitProgressAutoClose(rawValue: autoCloseGitProgress) ?? .manual }, set: { autoCloseGitProgress = $0.rawValue })) {
                ForEach(GitProgressAutoClose.allCases, id: \.self) { policy in Text(policy.title).tag(policy) }
            }.help("Successful operations close according to this policy. Failed operations stay open.")
            Toggle("Confirm to kill running git process", isOn: $confirmKillProcess)
                .help("When closing a progress dialog with a running git process, ask for confirmation before killing it")
            Toggle("Show Git execution timings and timestamp", isOn: $showGitexeTimings)
            Toggle("Display branch revision number", isOn: $showBranchRevisionNumber)
                .help("Show branch revision number (git rev-list --count --first-parent) in log dialog and after a push to a remote branch; this is not guaranteed to be unique, please see help")
            GroupBox("Log messages") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Can double-click in log list to compare with previous revision", isOn: $diffByDoubleClick)
                        .help("If checked, double-clicking on a revision in the log list compares it with the previous revision")
                    Toggle("Short date/time format in log messages", isOn: $shortDate).disabled(!useSystemLocale)
                    Toggle("Relative Times in log", isOn: $relative)
                    Toggle("Use system locale for date/time", isOn: $useSystemLocale)
                    LogPreferenceCheckbox(title: "Symbolize ref names", value: $symbolizeRefs).fixedSize(horizontal: false, vertical: true)
                    LogPreferenceCheckbox(title: "Draw tag/branch labels on right side", value: $labelsOnRight).fixedSize(horizontal: false, vertical: true)
                    LogPreferenceCheckbox(title: "Display subject and body of commit messages", value: $fullMessage).fixedSize(horizontal: false, vertical: true)
                    Text("Reopen history windows to apply reference-label and full-message choices.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Enable Gravatar", isOn: $enableGravatar).help("Enable showing Gravatar image in Log Dialog")
                    TextField("Gravatar URL", text: $gravatarURL).disabled(!enableGravatar).help("Allow to use custom Gravatar URL; %HASH% is replaced by the author email hash")
                    Toggle("Use MD5 for Gravatar", isOn: $gravatarMD5).disabled(!enableGravatar)
                }.padding(8)
            }
        }.padding(20)
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
                HStack {
                    StatusColorButton("Apply", action: { model.apply() }).frame(width: 70, height: 24).disabled(!model.modified)
                    StatusColorButton("Cancel", action: { model.cancel(); onClose?() }).frame(width: 70, height: 24)
                }
            }.padding(8)
        }
    }
}

/// Normal Log column labels/defaults from GitLogListBase and TortoiseLoglistCommon.
/// Rebase/ID/Actions/SVN-specific columns still require their own backend ports.
private enum LogRevisionColumns {
    static let definitions: [(id: String, title: String, width: Double, visible: Bool)] = [
        ("graph", "Graph", 65, true), ("hash", "SHA-1", 92, false), ("actions", "Actions", 90, true),
        ("message", "Message", 420, true), ("author", "Author", 140, true),
        ("date", "Date", 170, true), ("email", "Email", 200, false),
        ("committer", "Commit Name", 140, false), ("committerEmail", "Commit Email", 200, false),
        ("committerDate", "Commit Date", 170, false), ("bugs", "Bug-ID", 110, true)
    ]
    static func visible(_ id: String) -> Bool {
        guard let definition = definitions.first(where: { $0.id == id }) else { return false }
        return (UserDefaults.standard.object(forKey: "Log.Column.Visible." + id) as? NSNumber)?.boolValue ?? definition.visible
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
        table.allowsMultipleSelection = !model.selecting || model.selectingMultiple; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for definition in LogRevisionColumns.definitions {
            let id = definition.id
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = definition.title; column.width = definition.width
            column.isHidden = !LogRevisionColumns.visible(id) || id == "graph" && model.historyWalk.followRenames || id == "bugs" && !model.issueProperties.showsBugIDColumn
            column.minWidth = id == "graph" ? 38 : 70; table.addTableColumn(column)
        }
        table.allowsColumnReordering = true; table.allowsColumnResizing = true
        if savesColumnLayout {
            table.autosaveName = "TurtleGit.Log.RevisionColumns"
            table.autosaveTableColumns = true
        }
        let headerMenu = NSMenu(); headerMenu.delegate = context.coordinator
        table.headerView?.menu = headerMenu; context.coordinator.headerMenu = headerMenu
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClickRevision); table.target = context.coordinator
        table.menu = NSMenu(); table.menu?.delegate = context.coordinator
        context.coordinator.table = table
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
        let font = useLogFont ? MessageEditorFont.resolve(name: fontName, size: fontSize) : nil
        let fontChanged = coordinator.logFont != font; coordinator.logFont = font
        table.rowHeight = font.map { max(24, ceil($0.ascender - $0.descender + $0.leading) + 4) } ?? 24
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("bugs"))?.isHidden = !model.issueProperties.showsBugIDColumn || !LogRevisionColumns.visible("bugs")
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("graph"))?.isHidden = !LogRevisionColumns.visible("graph") || model.historyWalk.followRenames
        let graphChanged = coordinator.graph != model.graph; coordinator.graph = model.graph
        let signature = model.entries.map { $0.hash + $0.references.map { $0.name + ($0.kind?.rawValue ?? "") + ($0.displayName ?? "") }.joined() + String($0.isHead) + model.bisectGoodTerm + model.bisectBadTerm + $0.issueIDs + String(model.revisionActions[$0.hash]?.rawValue ?? -1) + String(model.actionFailures.contains($0.hash)) + String(model.rollupInfo[$0.hash]?.collapsed ?? false) }.map { Data($0.utf8) }
        let labelsChanged = coordinator.referenceVisibility != model.referenceVisibility || coordinator.referenceContext != model.referenceContext
        coordinator.referenceVisibility = model.referenceVisibility
        coordinator.referenceContext = model.referenceContext
        let searchHighlightsChanged = coordinator.searchHighlights != model.searchHighlights
        coordinator.searchHighlights = model.searchHighlights
        let highlightChanged = coordinator.highlightedRevision != model.highlightedRevision
        coordinator.highlightedRevision = model.highlightedRevision
        if signature != coordinator.signature || graphChanged || datesChanged || highlightChanged || searchHighlightsChanged || labelsChanged || fontChanged || colorsChanged {
            coordinator.signature = signature
            table.reloadData()
            if let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("graph")) {
                column.width = max(column.width, CGFloat(max(65, min(240, Int(CGFloat(model.graph.map(\.width).max() ?? 1) * floor(table.rowHeight * 3 / 4)) + 24))))
            }
        }
        let indices = IndexSet(model.entries.enumerated().compactMap { model.selected.contains($0.element.hash) ? $0.offset : nil })
        if table.selectedRowIndexes != indices { table.selectRowIndexes(indices, byExtendingSelection: false) }
        if coordinator.scrollRequest != model.scrollRequest {
            coordinator.scrollRequest = model.scrollRequest
            if let hash = model.scrollRevision, let row = model.entries.firstIndex(where: { $0.hash == hash }) { table.scrollRowToVisible(row) }
        }
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
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: LogWindowModel
        weak var table: NSTableView?
        var headerMenu: NSMenu?
        var updating = false
        var signature: [Data] = []
        var logFont: NSFont?
        var graph: [CommitGraphRow] = []
        var dateSettings = HistoryDateSettings.load()
        var searchHighlights: [String: [String: [NSRange]]] = [:]
        var highlightedRevision: String?
        var referenceVisibility = HistoryReferenceVisibility.all
        var referenceContext = HistoryReferenceContext()
        var scrollRequest = 0
        var colorRevision = -1
        init(model: LogWindowModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { model.entries.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            let entry = model.entries[row]
            if column?.identifier.rawValue == "graph" {
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
            let text = NSTextField(labelWithString: "")
            if column?.identifier.rawValue == "message" {
                let painter = LogReferenceTextCell(textCell: "")
                painter.isEditable = false; painter.isSelectable = false; painter.isBordered = false; painter.drawsBackground = false
                text.cell = painter
            }
            text.lineBreakMode = .byTruncatingTail; text.maximumNumberOfLines = 1
            if let logFont { text.font = entry.isHead ? NSFontManager.shared.convert(logFont, toHaveTrait: .boldFontMask) : logFont }
            else { text.font = .systemFont(ofSize: 12, weight: entry.isHead ? .bold : .regular) }
            if model.highlightedRevision == entry.hash { text.drawsBackground = true; text.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.3) }
            switch column?.identifier.rawValue {
            case "hash": text.stringValue = entry.hash; if logFont == nil { text.font = .monospacedSystemFont(ofSize: 11, weight: .regular) }
            case "email": text.stringValue = entry.email
            case "committer": text.stringValue = entry.committer
            case "committerEmail": text.stringValue = entry.committerEmail
            case "committerDate": text.stringValue = dateSettings.format(entry.committerDate)
            case "bugs": text.stringValue = entry.issueIDs
            case "author": text.stringValue = entry.author
            case "date": text.stringValue = dateSettings.format(entry.date)
            default:
                let label = NSMutableAttributedString()
                let badges = NSMutableAttributedString()
                for badge in model.visibleReferenceLabels(for: entry) {
                    let reference = badge.reference
                    let color = LogPalette.native(LogColorRole.reference(reference, goodTerm: model.bisectGoodTerm, badTerm: model.bisectBadTerm), preferences: model.colorPreferences)
                    let foreground = NSColor(name: nil) { _ in LogPalette.foreground(background: color) }
                    let badgeFont = logFont ?? NSFont.systemFont(ofSize: 11, weight: .medium)
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
            let cell = NSTableCellView(); cell.addSubview(text); cell.textField = text
            text.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let hashes = Set(table.selectedRowIndexes.compactMap { model.entries.indices.contains($0) ? model.entries[$0].hash : nil })
            if hashes != model.selected { model.select(hashes) }
        }
        private func applySearchHighlights(_ text: NSMutableAttributedString, hash: String, column: String) {
            for range in searchHighlights[hash]?[column] ?? [] where range.length > 0 && range.location >= 0 && NSMaxRange(range) <= text.length {
                text.addAttribute(.foregroundColor, value: LogPalette.native(.filterMatch, preferences: model.colorPreferences), range: range)
            }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === headerMenu {
                menu.autoenablesItems = false
                let reset = NSMenuItem(title: "Reset columns", action: #selector(requestResetColumns), keyEquivalent: ""); reset.target = self; menu.addItem(reset)
                menu.addItem(.separator())
                for definition in LogRevisionColumns.definitions {
                    if definition.id == "bugs" && !model.issueProperties.showsBugIDColumn { continue }
                    let item = NSMenuItem(title: definition.title, action: #selector(toggleColumn), keyEquivalent: "")
                    item.representedObject = definition.id; item.target = self
                    item.isEnabled = definition.id != "graph" || !model.historyWalk.followRenames
                    item.state = table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(definition.id))?.isHidden == false ? .on : .off
                    menu.addItem(item)
                }
                return
            }
            @discardableResult func item(_ title: String, _ selector: Selector, icon: MenuIcon, enabled: Bool = true) -> NSMenuItem {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.image = icon.contextImage(); item.target = self; item.isEnabled = enabled; menu.addItem(item)
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
                item("Compare with previous revision", #selector(compare), icon: .compare, enabled: !model.busy && model.onCompare != nil)
                item("Show changes as unified diff", #selector(showDiff), icon: .unifiedDiff, enabled: !model.busy && model.workingTreeSnapshot?.entry.parents.first != nil)
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
                return
            }
            if model.selectedIsStash {
                for action in [RepositoryAction.stashPop, .stashList] where model.workingCommandAvailable(action) { workingItem(action, menu: menu) }
                menu.addItem(.separator())
            }
            let one = model.revision != nil, two = model.revisions.count == 2
            item("Compare with working tree", #selector(workingDiff), icon: .compare, enabled: one && !model.bare && !model.busy && model.onCompare != nil)
            item(two || model.includesWorkingTree ? "Compare revisions" : "Compare with previous revision", #selector(compare), icon: .compare, enabled: (one || two || model.includesWorkingTree && model.selected.count == 2) && !model.busy && model.onCompare != nil)
            item("Show changes as unified diff", #selector(showDiff), icon: .unifiedDiff, enabled: (one || two || model.includesWorkingTree && model.selected.count == 2) && !model.busy)
            menu.addItem(.separator())
            for command in [LogBisectCommand.good, .bad, .skip] where one && model.bisectAvailable(command) {
                let selector = command == .good ? #selector(bisectGood) : command == .bad ? #selector(bisectBad) : #selector(bisectSkip)
                item(command.title, selector, icon: command.icon, enabled: model.canBisect(command))
            }
            if one && model.bisectAvailable(.skip) { menu.addItem(.separator()) }
            item("Browse repository", #selector(browseRepository), icon: .repositoryBrowser, enabled: one && !model.busy && model.onBrowseRepository != nil)
            if model.integrationAvailable {
                item(model.integrationTitle(.merge), #selector(mergeReference(_:)), icon: .merge, enabled: model.canIntegrate(.merge)).representedObject = pointed
            }
            item("Reset current branch to this…", #selector(reset), icon: .reset, enabled: one && !model.busy)
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
                        choice.target = self; choice.image = MenuIcon.checkout.contextImage(); choice.isEnabled = parent.isEnabled
                        choice.representedObject = LogReferenceMenuTarget(hash: revision.hash, name: reference.name); submenu.addItem(choice)
                    }
                }
            }
            item("Switch/Checkout to this…", #selector(checkoutReference(_:)), icon: .checkout, enabled: one && !model.busy && !model.bare && !model.selectedIsStash).representedObject = pointed
            item("Create branch at this version…", #selector(branchReference(_:)), icon: .branch, enabled: one && !model.busy && !model.selectedIsStash).representedObject = pointed
            item("Create tag at this version…", #selector(tagReference(_:)), icon: .tag, enabled: one && !model.busy && !model.selectedIsStash)
            let pushLabel = pointed.flatMap { model.reference(for: $0) }.flatMap { ref -> String? in
                let kind = ref.kind ?? HistoryReferenceLabel.shortName(ref.name).kind
                return [.localBranch, .tag, .annotatedTag].contains(kind) ? "Push \"" + HistoryReferenceLabel.shortName(ref.name).text + "\"…" : nil
            } ?? "Push…"
            item(pushLabel, #selector(pushReference(_:)), icon: .push, enabled: one && !model.busy).representedObject = pointed
            if model.integrationAvailable {
                item(model.integrationTitle(.rebase), #selector(rebaseRevision), icon: .rebase, enabled: model.canIntegrate(.rebase))
            }
            if one && !model.selectedIsStash { item("Export this version…", #selector(exportRevision), icon: .export, enabled: model.canExportRevision) }
            let deletable = model.deletionCandidates(target: pointed)
            if let revision = model.revision, !deletable.isEmpty {
                func target(_ ref: RevisionReference) -> LogReferenceMenuTarget { LogReferenceMenuTarget(hash: revision.hash, name: ref.name) }
                if deletable.count == 1 {
                    item("Delete " + deletable[0].name, #selector(deleteReferenceItems(_:)), icon: .remove, enabled: !model.busy).representedObject = [target(deletable[0])]
                } else {
                    let parent = item("Delete branch/tag", #selector(deleteReferenceItems(_:)), icon: .remove, enabled: !model.busy)
                    let submenu = NSMenu(); submenu.autoenablesItems = false; parent.submenu = submenu
                    for ref in deletable {
                        let child = NSMenuItem(title: ref.name, action: #selector(deleteReferenceItems(_:)), keyEquivalent: ""); child.target = self; child.image = MenuIcon.remove.contextImage(); child.isEnabled = parent.isEnabled; child.representedObject = [target(ref)]; submenu.addItem(child)
                    }
                    let all = NSMenuItem(title: "All", action: #selector(deleteReferenceItems(_:)), keyEquivalent: ""); all.target = self; all.image = MenuIcon.remove.contextImage(); all.isEnabled = parent.isEnabled; all.representedObject = deletable.map(target); submenu.addItem(all)
                }
            }
            menu.addItem(.separator())
            if model.revertAvailable {
                if let revision = model.revision, revision.parents.count > 1 {
                    let parent = NSMenuItem(title: "Revert change by this commit", action: nil, keyEquivalent: "")
                    parent.image = MenuIcon.revert.contextImage(); parent.isEnabled = model.canRevertRevision
                    let submenu = NSMenu(title: parent.title); submenu.autoenablesItems = false
                    for choice in model.parentChoices(for: revision) {
                        let child = NSMenuItem(title: choice.title, action: #selector(revertParent), keyEquivalent: "")
                        child.tag = choice.number; child.target = self; child.isEnabled = model.canRevertRevision; submenu.addItem(child)
                    }
                    parent.submenu = submenu; menu.addItem(parent)
                } else {
                    item("Revert change by this commit", #selector(revert), icon: .revert, enabled: model.canRevertRevision)
                }
            }
            if !one && model.bisectAvailable(.skip) {
                item(LogBisectCommand.skip.title, #selector(bisectSkip), icon: .bisect, enabled: model.canBisect(.skip)); menu.addItem(.separator())
            }
            if model.cherryPickAvailable {
                item(model.selected.count == 1 ? "Cherry Pick this commit…" : "Cherry Pick selected commits…", #selector(cherryPick), icon: .cherryPick, enabled: model.canCherryPick)
            }
            item("Edit Notes", #selector(editNotes), icon: .rebaseEdit, enabled: model.canEditNotes)
            item("Format Patch…", #selector(formatPatch), icon: .patch, enabled: model.formatPatchPreset != nil && !model.busy && model.onFormatPatch != nil)
            if model.bisectAvailable(.start) { menu.addItem(.separator()); item(LogBisectCommand.start.title, #selector(bisectStart), icon: .bisect, enabled: model.canBisect(.start)) }
            menu.addItem(.separator())
            if model.canToggleRollup {
                let rollup = NSMenuItem(title: model.rollupTitle, action: #selector(toggleRollup), keyEquivalent: ""); rollup.target = self; menu.addItem(rollup); menu.addItem(.separator())
            }
            let clipboard = NSMenu(title: "Copy to clipboard")
            clipboard.autoenablesItems = false
            for (title, selector) in [("Full log details", #selector(copyDetails)), ("Full log details without changed paths", #selector(copyDetailsWithoutPaths)), ("Hashes", #selector(copyHashes)),
                ("Authors", #selector(copyAuthors)), ("Author names", #selector(copyAuthorNames)),
                ("Author emails", #selector(copyAuthorEmails)), ("Subjects", #selector(copySubjects)), ("Messages", #selector(copyMessages))] {
                let child = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                child.target = self; child.image = MenuIcon.copy.contextImage(); child.isEnabled = !model.selected.isEmpty
                clipboard.addItem(child)
            }
            let parent = NSMenuItem(title: "Copy to clipboard", action: nil, keyEquivalent: "")
            if one, model.revision?.references.isEmpty == false {
                let refs = NSMenuItem(title: "Tag/branch names", action: #selector(copyReferenceNames(_:)), keyEquivalent: "")
                refs.target = self; refs.image = MenuIcon.copy.contextImage(); refs.representedObject = pointed; refs.isEnabled = !model.busy
                clipboard.addItem(refs)
            }
            parent.image = MenuIcon.copy.contextImage(); parent.submenu = clipboard; menu.addItem(parent)
        }
        func menuDidClose(_ menu: NSMenu) { if menu !== headerMenu { (table as? HistoryTableView)?.contextReference = nil } }
        @objc func pushReference(_ sender: NSMenuItem) { model.requestReference(.push, target: sender.representedObject as? LogReferenceMenuTarget) }
        @objc func switchBranchReference(_ sender: NSMenuItem) { if let target = sender.representedObject as? LogReferenceMenuTarget { model.switchBranch(target: target) } }
        @objc func mergeReference(_ sender: NSMenuItem) { model.requestIntegration(.merge, target: sender.representedObject as? LogReferenceMenuTarget) }
        @objc func branchReference(_ sender: NSMenuItem) { model.requestReference(.branch, target: sender.representedObject as? LogReferenceMenuTarget) }
        @objc func tagReference(_ sender: NSMenuItem) { model.requestReference(.tag, target: nil) }
        @objc func deleteReferenceItems(_ sender: NSMenuItem) { if let targets = sender.representedObject as? [LogReferenceMenuTarget] { model.deleteReferences(targets) } }
        @objc func checkoutReference(_ sender: NSMenuItem) { model.requestReference(.checkout, target: sender.representedObject as? LogReferenceMenuTarget) }
        @objc func copyReferenceNames(_ sender: NSMenuItem) { model.copyReferenceNames(target: sender.representedObject as? LogReferenceMenuTarget) }
        @objc func toggleRollup() { model.toggleRollup() }
        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String,
                let column = table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }
            if id == "bugs" && !model.issueProperties.showsBugIDColumn || id == "graph" && model.historyWalk.followRenames { return }
            column.isHidden.toggle()
            UserDefaults.standard.set(!column.isHidden, forKey: "Log.Column.Visible." + id)
        }
        @objc func requestResetColumns() {
            guard let window = table?.window, window.attachedSheet == nil else { return }
            let alert = NSAlert(); alert.messageText = "Are you sure to reset columns?"
            alert.addButton(withTitle: "Yes").keyEquivalent = "\r"
            alert.addButton(withTitle: "No").keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { self.resetColumns() }
            }
        }
        @objc func resetColumns() {
            guard let table else { return }
            for (index, definition) in LogRevisionColumns.definitions.enumerated() {
                UserDefaults.standard.removeObject(forKey: "Log.Column.Visible." + definition.id)
                let id = NSUserInterfaceItemIdentifier(definition.id)
                guard let column = table.tableColumn(withIdentifier: id) else { continue }
                column.isHidden = !definition.visible || definition.id == "graph" && model.historyWalk.followRenames || definition.id == "bugs" && !model.issueProperties.showsBugIDColumn
                column.width = definition.width
                let current = table.column(withIdentifier: id)
                if current != index { table.moveColumn(current, toColumn: index) }
            }
        }
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
        @objc func doubleClickRevision() { model.doubleClickRevision() }
        @objc func showDiff() { model.diff(alternate: NSEvent.modifierFlags.contains(.shift)) }
        @objc func compare() { model.compare() }
        @objc func workingDiff() { model.compare(workingTree: true) }
        @objc func bisectStart() { model.requestBisect(.start) }
        @objc func bisectGood() { model.requestBisect(.good) }
        @objc func bisectBad() { model.requestBisect(.bad) }
        @objc func bisectSkip() { model.requestBisect(.skip) }
        @objc func bisectReset() { model.requestBisect(.reset) }
        @objc func commitWorkingTree() { if model.selectedWorkingTree && !model.busy { model.onCommit() } }
        private func workingItem(_ action: RepositoryAction, menu: NSMenu) {
            let item = NSMenuItem(title: action.title, action: #selector(workingCommand), keyEquivalent: "")
            item.image = action.icon.contextImage(); item.target = self; item.representedObject = action.rawValue
            item.isEnabled = model.canWorkingCommand(action); menu.addItem(item)
        }
        @objc func workingCommand(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? String, let action = RepositoryAction(rawValue: value) else { return }
            model.requestWorkingCommand(action)
        }
        @objc func copyAuthors() { model.copy(model.revisions.map { "\($0.author) <\($0.email)>" }.joined(separator: "\n")) }
        @objc func copyAuthorNames() { model.copy(model.revisions.map(\.author).joined(separator: "\n")) }
        @objc func copyAuthorEmails() { model.copy(model.revisions.map(\.email).joined(separator: "\n")) }
        @objc func copySubjects() { model.copy(LogEntry.historyClipboard(model.revisions, subjectsOnly: true)) }
        @objc func copyHashes() { model.copy(model.revisions.map(\.hash).joined(separator: "\n")) }
        @objc func copyMessages() { model.copy(LogEntry.historyClipboard(model.revisions, subjectsOnly: false)) }
        @objc func copyDetails() { model.copyDetails() }
        @objc func copyDetailsWithoutPaths() { model.copyDetails(includePaths: false) }
    }
}

final class HistoryTableView: NSTableView {
    var contextReference: (row: Int, name: String)?
    func reference(at point: NSPoint) -> (row: Int, name: String)? {
        let row = row(at: point)
        guard row >= 0, let column = tableColumns.firstIndex(where: { $0.identifier.rawValue == "message" }),
            let field = (view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField,
            let cell = field.cell as? LogReferenceTextCell,
            let ref = cell.reference(at: field.convert(point, from: self)) else { return nil }
        return (row, ref.name)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil), row = row(at: point)
        let mouse = event.type == .rightMouseDown || event.type == .leftMouseDown
        contextReference = mouse ? reference(at: point) : nil
        if mouse, row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
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

/// IDD_INPUTDLG as configured by CAppUtils::EditNote: hint, editor, OK/Cancel; no checkbox.
struct LogNotesDialog: View {
    @ObservedObject var model: LogWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Notes").font(.headline)
            LogNotesEditor(text: $model.noteText, enabled: !model.savingNote, accept: model.saveNote)
                .frame(minHeight: 190, maxHeight: .infinity).border(Color.secondary.opacity(0.3))
            HStack {
                if model.savingNote { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.saveNote() }.disabled(!model.canSaveNote).keyboardShortcut(.return, modifiers: .command)
                Button("Cancel") { model.cancelNote() }.disabled(model.savingNote).keyboardShortcut(.cancelAction)
            }
        }.padding(12).frame(minWidth: 560, idealWidth: 680, minHeight: 280, idealHeight: 360)
        .interactiveDismissDisabled(model.savingNote)
        .alert("Saving notes failed.", isPresented: Binding(get: { model.noteError != nil }, set: { if !$0 { model.noteError = nil } })) {
            Button("OK") { model.noteError = nil }
        } message: { Text(model.noteError ?? "") }
    }
}
struct LogNotesEditor: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    var accept: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let editor = NotesTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.isRichText = false; editor.allowsUndo = true; editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textContainerInset = NSSize(width: 5, height: 5); editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Notes"); editor.delegate = context.coordinator
        editor.string = text; editor.undoManager?.removeAllActions(); editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        scroll.documentView = editor
        DispatchQueue.main.async { [weak editor] in if let editor { editor.window?.makeFirstResponder(editor) } }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NotesTextView else { return }
        editor.accept = accept; editor.isEditable = enabled
        if editor.string != text { editor.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LogNotesEditor
        init(_ parent: LogNotesEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? NSTextView { parent.text = editor.string } }
    }
}
final class NotesTextView: NSTextView {
    var accept: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && !event.modifierFlags.intersection([.command, .control]).isEmpty { accept(); return }
        super.keyDown(with: event)
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
