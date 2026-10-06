import AppKit
import SwiftUI
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
        return self.path == path ? revision : self.path + ":" + String(revision.prefix(8))
    }
}

enum HistoricalOpenAction { case open, openWith, alternativeEditor }

@MainActor enum HistoricalPreviewFiles {
    private static var previews: [URL: HistoricalFilePreview] = [:]
    static func retain(_ preview: HistoricalFilePreview) { previews[preview.file] = preview }
    static func discard(_ file: URL) { previews.removeValue(forKey: file)?.discard() }
    static func discardAll() { for preview in previews.values { preview.discard() }; previews.removeAll() }
}

@MainActor final class LogWindowController: NSWindowController, NSWindowDelegate {
    let model: LogWindowModel
    var onClosed: () -> Void = {}
    private var selectionCompletion: ((LogEntry?) -> Void)?
    private var multipleSelectionCompletion: (([LogEntry]?) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, onChooseMultiple: (([LogEntry]?) -> Void)? = nil, onChoose: ((LogEntry?) -> Void)? = nil) {
        model = LogWindowModel(repository: repository, access: access, selecting: onChoose != nil || onChooseMultiple != nil, selectingMultiple: onChooseMultiple != nil)
        selectionCompletion = onChoose; multipleSelectionCompletion = onChooseMultiple
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Log Messages – TurtleGit"
        window.minSize = NSSize(width: 1080, height: 700)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: LogDialog(model: model))
        super.init(window: window)
        model.window = window
        window.delegate = self
        window.setContentSize(NSSize(width: 1120, height: 780))
        window.center()
        model.close = { [weak self] in
            guard let self else { return }
            if self.model.selecting { self.finishSelection(nil) } else { self.window?.performClose(nil) }
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
        model.unifiedWindow?.close(); model.invalidate(); completion?(nil); multiple?(nil); onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

enum LogIntegrationCommand { case merge, rebase }
enum LogBisectCommand: CaseIterable {
    case start, good, bad, skip
    var operation: BisectOperation? { switch self { case .start: return nil; case .good: return .good; case .bad: return .bad; case .skip: return .skip } }
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
    let selecting: Bool
    let selectingMultiple: Bool
    // Keep the security-scoped grant alive if the main repository window changes.
    private let access: RepositoryAccessLease?
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
    @Published var bisectActive = false
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
                    let marks = try await repository.run(["for-each-ref", "--points-at", chosen[0].hash, "--format=%(refname)", "refs/bisect/"]).text
                    guard marks.isEmpty else { throw LogBisectFailure.marked }
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
    @Published var selectedFiles = Set<String>()
    private var lastImportedWorkingMark: UUID?
    @Published var comparisonMark: PreparedFileComparisonMark?
    @Published var allBranches = false
    @Published var endRevision: String?
    @Published var historyPaths: [String] = []
    @Published var showWholeProject = true
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
        return !chosen.isEmpty && chosen.count == selected.count && !bare && !mergeActive && chosen.first?.isHead == false
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
    func requestIntegration(_ command: LogIntegrationCommand) {
        guard canIntegrate(command), let chosen = revision else { return }
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
                var references = chosen.references.map(\.name).filter { $0.hasPrefix("refs/") && !$0.hasPrefix("refs/stash") }
                if command == .rebase { references = references.filter { $0.hasPrefix("refs/heads/") } + references.filter { !$0.hasPrefix("refs/heads/") } }
                var target = chosen.hash
                for reference in references {
                    let resolved = try await repository.run(["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"], successfulExitCodes: 0...128)
                    if resolved.exitCode == 0 && resolved.text.trimmingCharacters(in: .newlines) == chosen.hash { target = command == .rebase && reference.hasPrefix("refs/heads/") ? String(reference.dropFirst("refs/heads/".count)) : reference; break }
                }
                guard request == generation, revision?.hash == chosen.hash, selected.count == 1 else { return }
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
        guard !busy, !jumping else { return }
        if jumpKind == .selectionHistory {
            highlightedRevision = nil
            if let hash = selectionNavigation.move(up: up) {
                if entries.contains(where: { $0.hash == hash }) { highlightedRevision = hash; scrollRevision = hash; scrollRequest += 1 }
                else { navigationNotice = "The revision \(hash) is not visible in the current log." }
            }
            return
        }
        let snapshot = entries, selection = selected, kind = jumpKind
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
    @Published var filterPaths = ""
    @Published var from = Date(timeIntervalSince1970: 0)
    @Published var to = Date()
    @Published var useDates = false
    @Published var busy = false
    @Published var bare = true
    @Published var error: String?
    var unifiedWindow: PatchWindowController?
    var unifiedViewerBusy: Bool { unifiedWindow?.model.busy == true || unifiedWindow?.window?.attachedSheet != nil }
    @Published var commandRequest: LogCommandRequest?
    private var generation = 0
    private(set) var isInvalidated = false
    private var detailGeneration = 0
    private var clipboardCancellation: OperationCancellation?
    private var clipboardGeneration = 0
    @Published var copyingDetails = false
    var clipboard = NSPasteboard.general
    private var limit = 200
    var onCreateReference: (Bool, String) -> Void = { _, _ in }
    var onPush: (String) -> Void = { _ in }
    var onCheckout: (String) -> Void = { _ in }
    var onCherryPick: (([String]) -> Void)?
    var onBrowseRepository: ((String) -> Void)?
    var onFormatPatch: ((FormatPatchPreset) -> Void)?
    var formatPatchPreset: FormatPatchPreset? {
        FormatPatchPreset.logSelection(orderedHashes: entries.map(\.hash), selected: selected)
    }
    var onReset: (String) -> Void = { _ in }
    var onCompare: ((ComparisonRevision, ComparisonRevision) -> Void)?
    var onUnifiedDiff: ((Data, Bool) async throws -> Void)?
    var presentHistoricalSave: (ComparisonFileContent, String) -> Void = { _, _ in }
    var presentHistoricalOpen: (ComparisonFileContent, HistoricalOpenAction) -> Void = { _, _ in }
    var presentHistoricalExport: (String, [CommitFile]) -> Void = { _, _ in }
    var confirmExportFailure: (String) async -> Bool = { _ in false }
    weak var window: NSWindow?
    var onFileLog: ((String, String?) -> Void)?
    var onBlame: ((String, String) -> Void)?
    var onPreparedFileCompare: ((PreparedFileComparisonMark, PreparedFileComparisonMark) -> Void)?
    var onFilePairCompare: ((String, [CommitFile]) -> Void)?
    var onFileCompare: ((ComparisonRevision, ComparisonRevision, [String]) -> Void)?
    var close: () -> Void = {}
    var finishSelection: (LogEntry?) -> Void = { _ in }
    var finishMultipleSelection: ([LogEntry]?) -> Void = { _ in }
    var revisions: [LogEntry] { entries.filter { selected.contains($0.hash) } }
    var revision: LogEntry? { revisions.count == 1 ? revisions.first : nil }
    var visibleFiles: [CommitFile] { files.filter { filterPaths.isEmpty || $0.path.localizedCaseInsensitiveContains(filterPaths) } }
    var message: String {
        guard let revision else { return selected.isEmpty ? "Select a revision to see its commit message and changed files." : "\(selected.count) revisions selected." }
        return "SHA-1: \(revision.hash)\nAuthor: \(revision.author) <\(revision.email)>\nDate: \(HistoryDateSettings.load().format(revision.date))\n" +
            (revision.parents.isEmpty ? "" : "Parents: \(revision.parents.joined(separator: " "))\n") + "\n" + revision.message + (revision.notes.isEmpty ? "" : "\n----\nNotes:\n" + revision.notes) + (revision.tagInfo.isEmpty ? "" : "\n----\nTag Info:\n" + HistoryDateSettings.load().tagInfo(revision.tagInfo))
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, selecting: Bool = false, selectingMultiple: Bool = false) { self.repository = repository; self.access = access; self.selecting = selecting; self.selectingMultiple = selectingMultiple }
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
        historyPaths = scope; showWholeProject = scope.isEmpty; reload()
    }
    private func cancelActionReads() {
        actionCancellation?.cancel(); actionCancellation = nil
        actionQueue = []; activeActionHash = nil; actionGeneration += 1
    }
    func requestActions(_ entry: LogEntry) {
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
    func invalidate() {
        isInvalidated = true
        cancelNoteRead()
        cancelJump()
        cancelActionReads()
        cancelClipboardRead()
        detailCancellation?.cancel(); detailCancellation = nil
        if loadingHistory { historyCancellation?.cancel(); historyCancellation = nil; busy = false }
        generation += 1; detailGeneration += 1
    }
    func reload(more: Bool = false) {
        guard !busy || loadingHistory else { return }
        isInvalidated = false
        cancelNoteRead()
        cancelJump(); highlightedRevision = nil; scrollRevision = nil
        cancelActionReads(); actionFailures = []
        detailCancellation?.cancel(); detailCancellation = nil; detailGeneration += 1
        historyCancellation?.cancel()
        let cancellation = OperationCancellation(); historyCancellation = cancellation
        if more { limit += 200 } else { limit = 200 }
        cancelClipboardRead()
        generation += 1; let request = generation
        var options = HistoryOptions(); options.endRevision = endRevision; options.allBranches = allBranches; options.search = search; options.searchFields = searchFields; options.searchCaseSensitive = searchCaseSensitive; options.searchRegex = searchRegex; options.limit = limit
        if !showWholeProject { options.paths = historyPaths }
        if useDates { options.since = Calendar.current.startOfDay(for: from); options.until = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)) }
        busy = true
        Task {
            do {
                let bare = try await repository.run(["rev-parse", "--is-bare-repository"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) == "true"
                let mergeActive = try await repository.logMergeActive(cancellation: cancellation)
                let bisectActive = try await repository.finderMetadata().bisectActive
                let currentBranch = try await repository.branch()
                let issueProperties = try await repository.issueTrackerProperties(cancellation: cancellation)
                let result = try await repository.history(options: options, cancellation: cancellation, issueProperties: issueProperties)
                guard request == generation else { return }
                self.bare = bare; self.mergeActive = mergeActive; self.bisectActive = bisectActive; self.currentBranch = currentBranch; self.issueProperties = issueProperties
                entries = result; graph = CommitGraph.layout(result)
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
        for entry in entries where hashes.contains(entry.hash) { selectionNavigation.add(entry.hash) }
        cancelClipboardRead()
        detailCancellation?.cancel(); detailCancellation = nil
        selected = hashes; selectedFiles = []; files = []
        detailGeneration += 1; let request = detailGeneration
        guard let revision else { return }
        let cancellation = OperationCancellation(); detailCancellation = cancellation
        Task {
            do {
                let result = try await repository.files(in: revision, cancellation: cancellation)
                guard request == detailGeneration else { return }
                files = result
                if revision.parents.count > 1 {
                    let choices = try? await repository.logParentChoices(revision, cancellation: cancellation)
                    guard request == detailGeneration else { return }
                    if let choices { parentMetadata[revision.hash] = choices }
                }
                detailCancellation = nil
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
        guard !busy, !unifiedViewerBusy, !workingTree || !bare else { return }
        let revisions = self.revisions
        guard (1...2).contains(revisions.count) else { return }
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
                if let onUnifiedDiff { try await onUnifiedDiff(bytes, alternate) }
                else if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate) {
                    unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: "Selected revision changes", onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
            } catch { self.error = error.localizedDescription }
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
    func copyFiles(_ ids: Set<String>, information: CopyFileInformation) {
        let selected = visibleFiles.filter { ids.contains($0.id) }; guard !selected.isEmpty else { return }
        let text: String
        if information == .all { text = ComparisonFileList.clipboard(selected, extended: true) }
        else {
            text = selected.map { file in
                switch information {
                case .fullPaths: return repository.root.appendingPathComponent(file.path).path
                case .relativePaths: return file.path
                case .names: return (file.path as NSString).lastPathComponent
                case .all: return ""
                }
            }.joined(separator: "\n")
        }
        copy(text)
    }
    func fileLog(_ ids: Set<String>, oldName: Bool = false) {
        guard !busy, let onFileLog, let revision, ids.count == 1,
              let file = files.first(where: { ids.contains($0.id) }) else { return }
        if oldName {
            guard let path = file.oldPath else { return }; onFileLog(path, nil)
        } else { onFileLog(file.path, revision.hash) }
    }
    func chooseHistoricalExport(_ ids: Set<String>) {
        guard !busy, let revision, window?.attachedSheet == nil else { return }
        let chosen = visibleFiles.filter { ids.contains($0.id) }
        guard chosen.contains(where: { !$0.isSubmodule && !$0.action.hasPrefix("D") }) else { return }
        presentHistoricalExport(revision.hash, chosen)
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
    func importWorkingComparisonMark(_ access: WorkingComparisonAccess?) {
        guard let access, access.mark.id != lastImportedWorkingMark else { return }
        lastImportedWorkingMark = access.mark.id
        comparisonMark = PreparedFileComparisonMark(path: access.file.path, revision: "", workingAccess: access)
    }
    func markForComparison(_ ids: Set<String>) {
        guard !busy, let revision, ids.count == 1, let file = files.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
        comparisonMark = PreparedFileComparisonMark(path: file.path, revision: revision.hash)
    }
    func compareWithMarkedFile(_ ids: Set<String>) {
        guard !busy, let revision, let comparisonMark, let onPreparedFileCompare, ids.count == 1,
              let file = files.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") else { return }
        let current = PreparedFileComparisonMark(path: file.path, revision: revision.hash)
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
    func selectedFileDiff(_ ids: Set<String>, alternate: Bool = false) {
        guard !busy, !unifiedViewerBusy, let revision else { return }
        let chosen = visibleFiles.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let bytes = try await repository.revisionFileDiffData(revision, files: chosen)
                if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate) {
                    unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: "Selected revision changes", onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func canCompareFilePair(_ ids: Set<String>) -> Bool {
        let chosen = visibleFiles.filter { ids.contains($0.id) }
        return chosen.count == 2 && chosen.allSatisfy { !$0.isSubmodule }
    }
    func compareFilePair(_ ids: Set<String>) {
        guard !busy, let revision, let onFilePairCompare else { return }
        let chosen = visibleFiles.filter { ids.contains($0.id) }
        guard chosen.count == 2, chosen.allSatisfy({ !$0.isSubmodule }) else { return }
        onFilePairCompare(revision.hash, chosen)
    }
    func compareFiles(_ ids: Set<String>, workingTree: Bool = false) {
        guard !busy, let onFileCompare, let revision, !workingTree || !bare else { return }
        let paths = files.filter { ids.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }
        let from: ComparisonRevision = workingTree ? .revision(revision.hash) : revision.parents.first.map { .revision($0) } ?? .emptyTree
        let to: ComparisonRevision = workingTree ? .workingTree : .revision(revision.hash)
        onFileCompare(from, to, paths)
    }
    func compare(workingTree: Bool = false) {
        guard !busy, let onCompare, !workingTree || !bare else { return }
        let chosen = revisions
        guard chosen.count == 1 || chosen.count == 2 && !workingTree else { return }
        if workingTree { onCompare(.revision(chosen[0].hash), .workingTree) }
        else if chosen.count == 2 { onCompare(.revision(chosen[1].hash), .revision(chosen[0].hash)) }
        else { onCompare(chosen[0].parents.first.map { .revision($0) } ?? .emptyTree, .revision(chosen[0].hash)) }
    }
}

struct LogDialog: View {
    @ObservedObject var model: LogWindowModel
    @AppStorage("LogDateFormat") private var shortDate = true
    @AppStorage("RelativeTimes") private var relativeTimes = false
    @AppStorage("UseSystemLocaleForDates") private var useSystemLocale = true
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(model.repository.root.lastPathComponent).foregroundStyle(.blue).lineLimit(1)
                Toggle("Dates", isOn: $model.useDates).toggleStyle(.checkbox)
                DatePicker("From:", selection: $model.from, displayedComponents: .date).disabled(!model.useDates)
                DatePicker("To:", selection: $model.to, displayedComponents: .date).disabled(!model.useDates)
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
                RevisionTable(model: model).frame(minHeight: 200, idealHeight: 350)
                OutputView(text: model.message).frame(minHeight: 110, idealHeight: 150)
                    .onChange(of: shortDate) { _ in model.objectWillChange.send() }
                    .onChange(of: relativeTimes) { _ in model.objectWillChange.send() }
                    .onChange(of: useSystemLocale) { _ in model.objectWillChange.send() }
                Table(model.visibleFiles, selection: $model.selectedFiles) {
                    TableColumn("Path") { file in
                        Text(file.path).foregroundStyle(model.selectedFiles.contains(file.id) ? Color.primary : Color.blue).help(file.oldPath.map { "Renamed from \($0)" } ?? file.path)
                    }.width(min: 260, ideal: 460)
                    TableColumn("Extension") { file in Text(file.fileExtension) }.width(80)
                    TableColumn("Status", value: \.status).width(95)
                    TableColumn("Lines added") { file in Text(file.addedText).foregroundStyle(model.selectedFiles.contains(file.id) ? Color.primary : Color.blue) }.width(90)
                    TableColumn("Lines removed") { file in Text(file.removedText).foregroundStyle(model.selectedFiles.contains(file.id) ? Color.primary : Color.blue) }.width(105)
                }.frame(minHeight: 130, idealHeight: 180)
                .contextMenu(forSelectionType: String.self) { ids in
                    TurtleGitContextMenu {
                        fileContextActions(ids)
                    }
                } primaryAction: { ids in
                    model.selectedFiles = ids; model.compareFiles(ids)
                }
            }
            Text("Showing \(model.entries.count) revision(s) • \(model.selected.count) revision(s) selected • \(model.files.count) changed file(s) (merge changes against first parent)")
                .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Toggle("All Branches", isOn: $model.allBranches).toggleStyle(.checkbox).disabled(model.endRevision != nil).onChange(of: model.allBranches) { _ in model.reload() }
                if !model.historyPaths.isEmpty {
                    Toggle("Show Whole Project", isOn: $model.showWholeProject).toggleStyle(.checkbox).onChange(of: model.showWholeProject) { _ in model.reload() }
                        .help(model.historyPaths.joined(separator: "\n"))
                }
                Spacer()
                TextField("Filter paths", text: $model.filterPaths).textFieldStyle(.roundedBorder).frame(maxWidth: 430)
            }
            HStack {
                Button("Refresh") { model.reload() }.disabled(model.busy)
                Button("Show next 200") { model.reload(more: true) }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
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
        .sheet(item: $model.noteRequest) { _ in LogNotesDialog(model: model) }
        .sheet(item: $model.commandRequest) { request in LogRevisionDialog(model: model, request: request) }

    }
    @ViewBuilder private func fileContextActions(_ ids: Set<String>) -> some View {
        Button { model.compareFiles(ids) } label: { CommandLabel(title: "Compare with base", icon: .compare) }.disabled(ids.isEmpty || model.onFileCompare == nil || model.busy)
        Button { model.selectedFileDiff(ids, alternate: NSEvent.modifierFlags.contains(.shift)) } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(ids.isEmpty || model.revision == nil || model.busy)
        Button { model.compareFiles(ids, workingTree: true) } label: { CommandLabel(title: "Compare with working tree", icon: .compare) }.disabled(ids.isEmpty || model.bare || model.onFileCompare == nil || model.busy)
        if model.canCompareFilePair(ids) {
            Button { model.compareFilePair(ids) } label: { CommandLabel(title: "Compare two files", icon: .compare) }.disabled(model.busy || model.revision == nil || model.onFilePairCompare == nil)
        }
        Divider()
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }) {
            Button { model.fileLog(ids) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(model.busy || model.onFileLog == nil)
            if file.oldPath != nil {
                Button { model.fileLog(ids, oldName: true) } label: { CommandLabel(title: "Show log of old name", icon: .log) }.disabled(model.busy || model.onFileLog == nil)
            }
            if !file.isSubmodule && !file.action.hasPrefix("D") {
                Button { if let revision = model.revision { model.onBlame?(file.path, revision.hash) } } label: { CommandLabel(title: "Blame", icon: .blame) }.disabled(model.busy || model.onBlame == nil)
            }
            Divider()
        }
        Button { model.chooseHistoricalExport(ids) } label: { CommandLabel(title: "Export…", icon: .export) }
            .disabled(model.busy || model.revision == nil || !model.visibleFiles.contains(where: { ids.contains($0.id) && !$0.isSubmodule && !$0.action.hasPrefix("D") }))
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }), !file.isSubmodule && !file.action.hasPrefix("D") {
            historicalFileActions(ids)
        }
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }), !file.action.hasPrefix("D"), !model.bare {
            Button { model.revealFile(ids) } label: { CommandLabel(title: "Reveal in Finder", icon: .explore) }.disabled(model.busy)
        }
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }), !file.isSubmodule, !file.action.hasPrefix("D") {
            preparedComparisonActions(ids, file: file)
        }
        Menu {
            ForEach(LogWindowModel.CopyFileInformation.allCases, id: \.self) { information in
                Button { model.copyFiles(ids, information: information) } label: { CommandLabel(title: information.rawValue, icon: .copy) }
            }
        } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }.disabled(ids.isEmpty)
    }
    @ViewBuilder private func preparedComparisonActions(_ ids: Set<String>, file: CommitFile) -> some View {
        Divider()
        Button { model.markForComparison(ids) } label: { CommandLabel(title: "Mark for comparison", icon: .compare) }.disabled(model.busy || model.revision == nil)
        if let mark = model.comparisonMark {
            Button { model.compareWithMarkedFile(ids) } label: { CommandLabel(title: "Compare with " + mark.label(for: file.path), icon: .compare) }.disabled(model.busy || model.revision == nil || model.onPreparedFileCompare == nil)
        }
    }
    @ViewBuilder private func historicalFileActions(_ ids: Set<String>) -> some View {
        Button { model.saveHistoricalFile(ids) } label: { CommandLabel(title: "Save revision to…", icon: .saveAs) }.disabled(model.busy)
        Button { model.openHistoricalFile(ids, action: .alternativeEditor) } label: { CommandLabel(title: "View revision in alternative editor", icon: .editor) }.disabled(model.busy)
        Button { model.openHistoricalFile(ids, action: .open) } label: { CommandLabel(title: "Open", icon: .open) }.disabled(model.busy)
        Button { model.openHistoricalFile(ids, action: .openWith) } label: { CommandLabel(title: "Open With…", icon: .open) }.disabled(model.busy)
    }

}

struct LogDialogSettings: View {
    @AppStorage("LogDateFormat") private var shortDate = true
    @AppStorage("RelativeTimes") private var relative = false
    @AppStorage("UseSystemLocaleForDates") private var useSystemLocale = true
    var body: some View {
        Form {
            GroupBox("Log messages") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Short date/time format in log messages", isOn: $shortDate).disabled(!useSystemLocale)
                    Toggle("Relative Times in log", isOn: $relative)
                    Toggle("Use system locale for date/time", isOn: $useSystemLocale)
                }.padding(8)
            }
        }.padding(20)
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
    @ObservedObject var model: LogWindowModel
    @AppStorage("LogDateFormat") private var shortDate = true
    @AppStorage("RelativeTimes") private var relativeTimes = false
    @AppStorage("UseSystemLocaleForDates") private var useSystemLocale = true
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = HistoryTableView()
        table.rowHeight = 24; table.intercellSpacing = NSSize(width: 4, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for definition in LogRevisionColumns.definitions {
            let id = definition.id
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = definition.title; column.width = definition.width
            column.isHidden = !LogRevisionColumns.visible(id) || id == "bugs" && !model.issueProperties.showsBugIDColumn
            column.minWidth = id == "graph" ? 38 : 70; table.addTableColumn(column)
        }
        table.allowsColumnReordering = true; table.allowsColumnResizing = true
        table.autosaveName = "TurtleGit.Log.RevisionColumns"
        table.autosaveTableColumns = true
        let headerMenu = NSMenu(); headerMenu.delegate = context.coordinator
        table.headerView?.menu = headerMenu; context.coordinator.headerMenu = headerMenu
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.doubleAction = #selector(Coordinator.showDiff); table.target = context.coordinator
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
        let dateSettings = HistoryDateSettings(shortDate: shortDate, relative: relativeTimes, useSystemLocale: useSystemLocale)
        let datesChanged = coordinator.dateSettings != dateSettings; coordinator.dateSettings = dateSettings
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("bugs"))?.isHidden = !model.issueProperties.showsBugIDColumn || !LogRevisionColumns.visible("bugs")
        let signature = model.entries.map { $0.hash + $0.references.map(\.name).joined() + String($0.isHead) + $0.issueIDs + String(model.revisionActions[$0.hash]?.rawValue ?? -1) + String(model.actionFailures.contains($0.hash)) }
        let highlightChanged = coordinator.highlightedRevision != model.highlightedRevision
        coordinator.highlightedRevision = model.highlightedRevision
        if signature != coordinator.signature || datesChanged || highlightChanged {
            coordinator.signature = signature
            table.reloadData()
            if let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("graph")) {
                column.width = max(column.width, CGFloat(max(65, min(240, (model.graph.map(\.width).max() ?? 1) * 14 + 24))))
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
        var signature: [String] = []
        var dateSettings = HistoryDateSettings.load()
        var highlightedRevision: String?
        var scrollRequest = 0
        init(model: LogWindowModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { model.entries.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            let entry = model.entries[row]
            if column?.identifier.rawValue == "graph" {
                let view = GraphCell(); view.graph = model.graph[row]; view.setAccessibilityLabel("\(entry.parents.count) parents, graph lane \(model.graph[row].column + 1)")
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
            text.lineBreakMode = .byTruncatingTail; text.maximumNumberOfLines = 1
            text.font = .systemFont(ofSize: 12, weight: entry.isHead ? .bold : .regular)
            if model.highlightedRevision == entry.hash { text.drawsBackground = true; text.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.3) }
            switch column?.identifier.rawValue {
            case "hash": text.stringValue = entry.hash; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            case "email": text.stringValue = entry.email
            case "committer": text.stringValue = entry.committer
            case "committerEmail": text.stringValue = entry.committerEmail
            case "committerDate": text.stringValue = dateSettings.format(entry.committerDate)
            case "bugs": text.stringValue = entry.issueIDs
            case "author": text.stringValue = entry.author
            case "date": text.stringValue = dateSettings.format(entry.date)
            default:
                let label = NSMutableAttributedString()
                for reference in entry.references {
                    let color: NSColor = reference.isCurrent ? .systemRed : reference.name.hasPrefix("refs/tags/") ? .systemYellow : reference.name.hasPrefix("refs/remotes/") ? .systemOrange : .systemGreen
                    label.append(NSAttributedString(string: " \(reference.label) ", attributes: [.backgroundColor: color.withAlphaComponent(0.3), .font: NSFont.systemFont(ofSize: 11, weight: .medium)]))
                    label.append(NSAttributedString(string: " "))
                }
                label.append(NSAttributedString(string: entry.subject, attributes: [.font: text.font!]))
                text.attributedStringValue = label
            }
            if column?.identifier.rawValue == "date" { text.toolTip = dateSettings.relative ? dateSettings.format(entry.date, absolute: true) : nil }
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
                    item.state = table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(definition.id))?.isHidden == false ? .on : .off
                    menu.addItem(item)
                }
                return
            }
            func item(_ title: String, _ selector: Selector, icon: MenuIcon, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.image = icon.contextImage(); item.target = self; item.isEnabled = enabled; menu.addItem(item)
            }
            menu.autoenablesItems = false
            let one = model.revision != nil, two = model.revisions.count == 2
            item("Compare with working tree", #selector(workingDiff), icon: .compare, enabled: one && !model.bare && !model.busy && model.onCompare != nil)
            item(two ? "Compare revisions" : "Compare with previous revision", #selector(compare), icon: .compare, enabled: (one || two) && !model.busy && model.onCompare != nil)
            item("Show changes as unified diff", #selector(showDiff), icon: .unifiedDiff, enabled: (one || two) && !model.busy)
            menu.addItem(.separator())
            for command in [LogBisectCommand.good, .bad, .skip] where one && model.bisectAvailable(command) {
                let selector = command == .good ? #selector(bisectGood) : command == .bad ? #selector(bisectBad) : #selector(bisectSkip)
                item(command.title, selector, icon: command.icon, enabled: model.canBisect(command))
            }
            if one && model.bisectAvailable(.skip) { menu.addItem(.separator()) }
            item("Browse repository", #selector(browseRepository), icon: .repositoryBrowser, enabled: one && !model.busy && model.onBrowseRepository != nil)
            if model.integrationAvailable {
                item(model.integrationTitle(.merge), #selector(mergeRevision), icon: .merge, enabled: model.canIntegrate(.merge))
            }
            item("Reset current branch to this…", #selector(reset), icon: .reset, enabled: one && !model.busy)
            item("Switch/Checkout to this…", #selector(checkout), icon: .checkout, enabled: one && !model.busy && !model.bare)
            item("Create branch at this version…", #selector(branch), icon: .branch, enabled: one && !model.busy)
            item("Create tag at this version…", #selector(tag), icon: .tag, enabled: one && !model.busy)
            item("Push…", #selector(push), icon: .push, enabled: one && !model.busy)
            if model.integrationAvailable {
                item(model.integrationTitle(.rebase), #selector(rebaseRevision), icon: .rebase, enabled: model.canIntegrate(.rebase))
            }
            if one && !model.selectedIsStash { item("Export this version…", #selector(exportRevision), icon: .export, enabled: model.canExportRevision) }
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
            parent.image = MenuIcon.copy.contextImage(); parent.submenu = clipboard; menu.addItem(parent)
        }
        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String,
                let column = table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }
            if id == "bugs" && !model.issueProperties.showsBugIDColumn { return }
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
                column.isHidden = !definition.visible || definition.id == "bugs" && !model.issueProperties.showsBugIDColumn
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
        @objc func showDiff() { model.diff(alternate: NSEvent.modifierFlags.contains(.shift)) }
        @objc func compare() { model.compare() }
        @objc func workingDiff() { model.compare(workingTree: true) }
        @objc func bisectStart() { model.requestBisect(.start) }
        @objc func bisectGood() { model.requestBisect(.good) }
        @objc func bisectBad() { model.requestBisect(.bad) }
        @objc func bisectSkip() { model.requestBisect(.skip) }
        @objc func copyAuthors() { model.copy(model.revisions.map { "\($0.author) <\($0.email)>" }.joined(separator: "\n")) }
        @objc func copyAuthorNames() { model.copy(model.revisions.map(\.author).joined(separator: "\n")) }
        @objc func copyAuthorEmails() { model.copy(model.revisions.map(\.email).joined(separator: "\n")) }
        @objc func copySubjects() { model.copy(model.revisions.map(\.subject).joined(separator: "\n")) }
        @objc func copyHashes() { model.copy(model.revisions.map(\.hash).joined(separator: "\n")) }
        @objc func copyMessages() { model.copy(model.revisions.map(\.message).joined(separator: "\n\n")) }
        @objc func copyDetails() { model.copyDetails() }
        @objc func copyDetailsWithoutPaths() { model.copyDetails(includePaths: false) }
    }
}

final class HistoryTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        menu?.update()
        return menu
    }
}

final class GraphCell: NSView {
    var graph: CommitGraphRow? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let graph else { return }
        let colors: [NSColor] = [.systemBlue, .systemRed, .systemGreen, .systemOrange, .systemPurple, .systemTeal]
        func point(_ column: Int, _ y: CGFloat) -> NSPoint { NSPoint(x: 12 + CGFloat(column) * 14, y: y) }
        let mid = bounds.height / 2
        for edge in graph.edges {
            let path = NSBezierPath(); path.lineWidth = 1.5
            let start = point(edge.from, edge.startsAtNode ? mid : 0)
            let end = point(edge.to, edge.endsAtNode ? mid : bounds.height)
            path.move(to: start)
            if edge.from == edge.to { path.line(to: end) }
            else { path.curve(to: end, controlPoint1: NSPoint(x: start.x, y: (start.y + end.y) / 2), controlPoint2: NSPoint(x: end.x, y: (start.y + end.y) / 2)) }
            colors[edge.color % colors.count].setStroke(); path.stroke()
        }
        let position = point(graph.column, mid)
        let rect = NSRect(x: position.x - 3.5, y: position.y - 3.5, width: 7, height: 7)
        colors[graph.color % colors.count].setFill()
        (graph.junction ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect)).fill()
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
