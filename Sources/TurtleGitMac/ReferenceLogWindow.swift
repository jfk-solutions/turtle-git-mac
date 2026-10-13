import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor final class ReferenceLogWindowController: NSWindowController, NSWindowDelegate {
    let model: ReferenceLogWindowModel
    var onClosed: () -> Void = {}
    private var selectionCompletion: ((ReferenceLogEntry?) -> Void)?
    private var notePresenter: CommitNotePresenter?
    var noteEditor: InputWindowController? { notePresenter?.editor }
    private(set) var findController: ReferenceLogFindController?
    init(repository: GitRepository, access: RepositoryAccessLease?, reference: String, onChoose: ((ReferenceLogEntry?) -> Void)? = nil, preferences: UserDefaults = .standard) {
        model = ReferenceLogWindowModel(repository: repository, access: access, reference: reference, selecting: onChoose != nil, preferences: preferences)
        selectionCompletion = onChoose
        let window = ReferenceLogNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 530), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – RefLog – TurtleGit"
        window.minSize = NSSize(width: 800, height: 360); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ReferenceLogDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        model.noteLog.window = window
        notePresenter = CommitNotePresenter(parent: window, model: model.noteLog, preferences: preferences)
        window.setContentSize(NSSize(width: 1000, height: 530)); window.center()
        model.close = { [weak self] in
            guard let self else { return }
            guard self.model.commandSurfaceAvailable, !self.model.unifiedViewerBusy, self.window?.attachedSheet == nil else { return }
            if self.model.selecting { self.finishSelection(nil) } else { self.window?.close() }
        }
        model.onChoose = { [weak self] entry in self?.finishSelection(entry) }
        model.confirmDelete = { [weak window] message, clear, proceed in
            guard let window, window.attachedSheet == nil else { return }
            let alert = Self.deletionAlert(message: message, clear: clear)
            alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { proceed() } }
        }
        model.presentDeletionFailure = { [weak self] issue in await self?.showDeletionFailure(issue) }
        model.openFind = { [weak self] in self?.openFind() }
        window.functionKey = { [weak self] code in
            guard let self, !self.model.busy else { return false }
            if code == 99 { self.model.openFind(); return true } // F3
            if code == 96 { self.model.reload(); return true } // F5
            return false
        }
        model.reload()

        DialogGeometry.attach(window, identifier: "ReferenceLogWindowController")
    }
    private func showDeletionFailure(_ issue: ReferenceLogDeleteIssue) async {
        guard let window, window.attachedSheet == nil else { return }
        await withCheckedContinuation { continuation in
            let alert = NSAlert(); alert.alertStyle = .critical
            alert.messageText = issue.details; alert.informativeText = issue.selector
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in continuation.resume() }
        }
    }
    static func deletionAlert(message: String, clear: Bool) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = message
        let delete = alert.addButton(withTitle: "Delete"), abort = alert.addButton(withTitle: "Abort")
        delete.keyEquivalent = clear ? "" : "\r"; abort.keyEquivalent = clear ? "\r" : ""
        alert.window.defaultButtonCell = (clear ? abort : delete).cell as? NSButtonCell
        return alert
    }
    func openFind(visible: Bool = true) {
        guard !model.busy else { return }
        if let findController {
            if visible { findController.showWindow(nil); findController.window?.makeKeyAndOrderFront(nil) }
            return
        }
        model.find = ""; model.matchCase = false
        let finder = ReferenceLogFindController(model: model)
        findController = finder
        finder.onClosed = { [weak self] in self?.findController = nil }
        if visible { finder.showWindow(nil); finder.window?.makeKeyAndOrderFront(nil) }
    }
    private func finishSelection(_ entry: ReferenceLogEntry?) {
        guard !model.unifiedViewerBusy else { return }
        guard let completion = selectionCompletion else { return }; selectionCompletion = nil
        if let window { window.sheetParent?.endSheet(window); window.close() }
        completion(entry)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.commandSurfaceAvailable, !model.unifiedViewerBusy, sender.attachedSheet == nil else { return false }
        if model.selecting { finishSelection(nil); return false }; return true
    }
    func windowWillClose(_ notification: Notification) {
        findController?.close(); findController = nil
        model.invalidate(); notePresenter?.close()
        model.unifiedWindow?.close(); model.unifiedWindow = nil
        let completion = selectionCompletion; selectionCompletion = nil; completion?(nil); onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class ReferenceLogWindowModel: ObservableObject {
    let repository: GitRepository
    let selecting: Bool
    let preferences: UserDefaults
    let noteLog: LogWindowModel
    private var noteChanges: AnyCancellable?
    var commandSurfaceAvailable: Bool { !invalidated && !busy && !noteLog.loadingNote && !noteLog.savingNote && noteLog.noteRequest == nil }
    private let access: RepositoryAccessLease?
    @Published var reference: String
    @Published var names: [String]
    @Published var entries: [ReferenceLogEntry] = []
    @Published var selection = Set<String>() {
        didSet { if !finding { searchIndex = entries.firstIndex { selection.contains($0.id) } ?? 0 }; refreshCombineCandidate() }
    }
    @Published var busy = false
    @Published var error: String?
    @Published var information: String?
    @Published private(set) var diffParents: [String: [LogParentChoice]] = [:]
    private var requestedDiffParents = Set<String>()
    private var invalidated = false
    var unifiedWindow: PatchWindowController?
    var unifiedViewerBusy: Bool { unifiedWindow?.model.busy == true || unifiedWindow?.model.confirmingQuit == true || unifiedWindow?.window?.attachedSheet != nil }
    var onUnifiedDiff: ((Data, Bool) async throws -> Void)?
    @Published private(set) var deletionReport: String?
    var presentDeletionFailure: (@Sendable (ReferenceLogDeleteIssue) async -> Void)?
    var openFind: () -> Void = {}
    @Published private(set) var searchWrapped = false
    private var searchIndex = 0
    private var finding = false
    @Published var find = "" { didSet { searchWrapped = false } }
    @Published var matchCase = false { didSet { searchWrapped = false } }
    private var generation = 0
    var onChoose: (ReferenceLogEntry) -> Void = { _ in }
    func accept() { if selecting { if !busy, let entry = selectedEntry { onChoose(entry) } } else { close() } }
    var onApply: (String) -> Void = { _ in }
    var onLog: ((String) -> Void)?
    var onLogRange: ((HistoryRevisionRange) -> Void)?
    var onBrowseRepository: ((String) -> Void)?
    var onCreateReference: ((Bool, String) -> Void)?
    var onExport: ((String) -> Void)?
    var onCompare: ((ComparisonRevision, ComparisonRevision) -> Void)?
    var onCheckout: ((String) -> Void)?
    var onReset: ((String) -> Void)?
    var onTransport: ((ReferenceLogTransportRequest) -> Void)?
    @Published private(set) var hasGitSVN = false
    var onBisect: ((ReferenceLogBisectRequest) -> Void)?
    var onCombineRevisions: (([LogEntry], Int, String) -> Void)? { didSet { refreshCombineCandidate() } }
    @Published private(set) var combineCandidate: ReferenceLogCombineCandidate?
    @Published private(set) var bisectActive = false
    private var combineToken: OperationCancellation?
    var readCombineCandidate: ([ReferenceLogEntry], Set<String>, String, OperationCancellation) async throws -> ReferenceLogCombineCandidate?
    var onFormatPatch: ((FormatPatchPreset) -> Void)?
    var onMergeRevision: ((String) -> Void)?
    var onRebaseRevision: ((String) -> Void)?
    var onCherryPick: (([String]) -> Void)?
    var onRevertRevisions: (([LogEntry], Int?) -> Void)?
    static private(set) var activeRevisionReads = 0
    private var revisionReadToken: OperationCancellation?
    var readOperationEntries: ([ReferenceLogEntry], Set<String>, OperationCancellation) async throws -> [LogEntry]
    var onSwitchBranch: ((String) -> Void)?
    @Published private(set) var referenceNamesByHash: [String: [String]] = [:]
    @Published private(set) var mergeActive = false
    @Published private(set) var currentHeadHash: String?
    @Published private(set) var currentBranch = ""
    @Published private(set) var hasWorkingTree = false
    @Published private(set) var currentStashHash: String?
    private var currentStashIndexParent: String?
    var onChanged: (String) -> Void = { _ in }
    var confirmDelete: (String, Bool, @escaping () -> Void) -> Void = { _, _, _ in }
    var close: () -> Void = {}
    var selectedEntry: ReferenceLogEntry? { let chosen = entries.filter { selection.contains($0.id) }; return chosen.count == 1 ? chosen.first : nil }
    init(repository: GitRepository, access: RepositoryAccessLease?, reference: String, selecting: Bool = false, preferences: UserDefaults = .standard) {
        noteLog = LogWindowModel(repository: repository, access: access, labelDefaults: preferences)
        readCombineCandidate = { try await repository.referenceLogCombineCandidate(snapshot: $0, selected: $1, expectedHead: $2, cancellation: $3) }
        readOperationEntries = { try await repository.referenceLogOperationEntries(snapshot: $0, selected: $1, cancellation: $2) }
        self.preferences = preferences; self.selecting = selecting; self.repository = repository; self.access = access; self.reference = reference; names = [reference]
        noteChanges = noteLog.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.invalidated else { return }
                self.objectWillChange.send()
                if self.noteLog.noteRequest == nil, let error = self.noteLog.error { self.noteLog.error = nil; self.error = error }
            }
        }
        noteLog.onRevisionChanged = { [weak self] in self?.onChanged($0) }
    }
    func reload() {
        guard !invalidated else { return }
        combineToken?.cancel(); combineToken = nil; combineCandidate = nil
        if noteLog.loadingNote { noteLog.cancelPendingNoteRead() }
        revisionReadToken?.cancel(); revisionReadToken = nil
        generation += 1; let request = generation, reference = reference; busy = true
        requestedDiffParents = Set(diffParents.keys)
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let refs = try await repository.referenceLogNames(), result = try await repository.referenceLog(reference)
                let bare = try await repository.isBare()
                let mergeActive = try await repository.logMergeActive()
                let bisectActive = try await repository.bisectState().active
                let hasGitSVN = try await repository.referenceLogHasGitSVN()
                let head = try await repository.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD"], successfulExitCodes: 0...1).text.trimmingCharacters(in: .newlines)
                let branch = try await repository.branch()
                let referenceNames = try await repository.referenceLogReferenceNamesByHash()
                var stashHash: String?, indexParent: String?
                if refs.contains("refs/stash") {
                    let hash = try await repository.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "refs/stash"], successfulExitCodes: 0...1).text.trimmingCharacters(in: .newlines)
                    if !hash.isEmpty {
                        stashHash = hash
                        let parents = ((try? await repository.run(["rev-list", "--parents", "-n", "1", hash, "--"]).text) ?? "").split(whereSeparator: \.isWhitespace)
                        if parents.count == 3 { indexParent = String(parents[2]) }
                    }
                }
                guard request == generation else { return }
                referenceNamesByHash = referenceNames
                currentStashHash = stashHash; currentStashIndexParent = indexParent
                hasWorkingTree = !bare; self.mergeActive = mergeActive; self.bisectActive = bisectActive; self.hasGitSVN = hasGitSVN
                currentHeadHash = head.isEmpty ? nil : head; currentBranch = branch
                names = Array(Set(refs + [reference])).sorted(); entries = result
                let hashes = Set(result.map(\.hash)); diffParents = diffParents.filter { hashes.contains($0.key) }
                selection.formIntersection(Set(result.map(\.id))); searchIndex = 0; searchWrapped = false; busy = false; refreshCombineCandidate()
            } catch { if request == generation { self.error = error.localizedDescription; busy = false } }
        }
    }
    func apply(_ ids: Set<String>) {
        guard !selecting, !busy, reference == "refs/stash", ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        // Hash pins the selected entry even if another process changes stash indices.
        onApply(entry.hash)
    }
    func delete(_ ids: Set<String>, clear: Bool = false) {
        guard !selecting, !busy, !entries.isEmpty,
              clear ? reference == "refs/stash" : (!ids.isEmpty && ids.isSubset(of: Set(entries.map(\.id)))) else { return }
        let expected = entries, reference = reference
        let message: String
        if clear { message = "Do you really want to delete ALL \(entries.count) stash?" }
        else if ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) {
            message = "\"\(entry.selector)\" will be permanently deleted. It can NOT be recovered!\n\nDo you really want to continue?"
        } else { message = "Do you really want to permanently delete the \(ids.count) selected refs? It can NOT be recovered!" }
        confirmDelete(message, clear) { [weak self] in
            guard let self, !self.busy else { return }
            guard self.reference == reference, self.entries == expected else { self.error = ReferenceLogFailure.stale.localizedDescription; return }
            self.busy = true; self.error = nil; self.deletionReport = nil
            Task {
                do {
                    let output = clear ? try await self.repository.deleteStashEntries([], expected: expected, clear: true) : try await self.repository.deleteReferenceLogEntries(ids, reference: reference, expected: expected, onFailure: self.presentDeletionFailure)
                    self.onChanged(output)
                }
                catch let failure as ReferenceLogDeleteBatchFailure {
                    self.deletionReport = failure.localizedDescription
                    self.onChanged(failure.output + failure.localizedDescription)
                    if self.presentDeletionFailure == nil { self.error = failure.localizedDescription }
                }
                catch { self.error = error.localizedDescription }
                self.reload()
            }
        }
    }
    func findNext() {
        guard !busy, !entries.isEmpty, !find.isEmpty else { return }
        searchWrapped = searchIndex >= entries.count
        let start = searchWrapped ? 0 : searchIndex
        for offset in 0..<entries.count {
            let index = (start + offset) % entries.count, entry = entries[index]
            // RefLogDlg searches the displayed ref, action, hash and message,
            // separated by newlines. Reflog messages do not carry a commit body.
            let text = [entry.selector, entry.action, entry.hash, entry.message, ""].joined(separator: "\n")
            if text.range(of: find, options: matchCase ? [] : [.caseInsensitive]) != nil {
                finding = true; selection = [entry.id]; finding = false
                searchIndex = index + 1; return
            }
        }
        error = "\"\(find)\" was not found."
    }
    func isOnStash(_ entry: ReferenceLogEntry) -> Bool {
        if entry.hash == currentStashHash { return true }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), index > 0 else { return false }
        return entries[index - 1].hash == currentStashHash && entry.hash == currentStashIndexParent
    }
    func canPerform(_ command: ReferenceLogRevisionCommand, ids: Set<String>) -> Bool {
        guard !busy, ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) else { return false }
        switch command {
        case .browseRepository: return onBrowseRepository != nil
        case .export: return onExport != nil
        case .createBranch, .createTag: return !selecting && !isOnStash(entry) && onCreateReference != nil
        }
    }
    func perform(_ command: ReferenceLogRevisionCommand, ids: Set<String>) {
        guard canPerform(command, ids: ids), let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        switch command {
        case .browseRepository: onBrowseRepository?(entry.hash)
        case .export: onExport?(entry.hash)
        case .createBranch: onCreateReference?(false, entry.hash)
        case .createTag: onCreateReference?(true, entry.hash)
        }
    }
    func activateRows(_ ids: Set<String>) {
        guard !busy else { return }
        if selecting { selection = ids; accept() }
        else if let entry = entries.first(where: { ids.contains($0.id) }) { onLog?(entry.hash) }
    }
    func canPerformHistory(_ command: ReferenceLogHistoryCommand, ids: Set<String>) -> Bool {
        guard !invalidated, !selecting, !busy, hasWorkingTree, currentHeadHash != nil, ids.count == 1,
              let entry = entries.first(where: { ids.contains($0.id) }), !isOnStash(entry) else { return false }
        switch command {
        case .reset: return onReset != nil
        case .checkout: return currentHeadHash != nil && entry.hash != currentHeadHash && onCheckout != nil
        }
    }
    func performHistory(_ command: ReferenceLogHistoryCommand, ids: Set<String>) {
        guard canPerformHistory(command, ids: ids), let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        switch command { case .reset: onReset?(entry.hash); case .checkout: onCheckout?(referenceNamesByHash[entry.hash]?.first { $0.hasPrefix("refs/remotes/") } ?? entry.hash) }
    }
    func switchBranches(_ ids: Set<String>) -> [String] {
        guard !invalidated, !selecting, !busy, hasWorkingTree,
              ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }), !isOnStash(entry) else { return [] }
        return (referenceNamesByHash[entry.hash] ?? []).filter { $0.hasPrefix("refs/heads/") && $0 != "refs/heads/" + currentBranch }
    }
    func switchBranch(_ ref: String, ids: Set<String>) {
        guard switchBranches(ids).contains(ref) else { return }
        onSwitchBranch?(ref)
    }
    func comparisonSides(_ command: ReferenceLogComparisonCommand, ids: Set<String>) -> (ComparisonRevision, ComparisonRevision)? {
        guard !busy, !ids.isEmpty else { return nil }
        let indices = entries.indices.filter { ids.contains(entries[$0].id) }
        guard indices.count == ids.count, let first = indices.first, let last = indices.last else { return nil }
        switch command {
        case .workingTree:
            guard ids.count == 1, hasWorkingTree else { return nil }
            return (.revision(entries[first].hash), .workingTree)
        case .revisions:
            guard ids.count >= 2, ids.count == 2 || last - first + 1 == ids.count else { return nil }
            return (.revision(entries[last].hash), .revision(entries[first].hash))
        }
    }
    func canCompare(_ command: ReferenceLogComparisonCommand, ids: Set<String>) -> Bool {
        onCompare != nil && comparisonSides(command, ids: ids) != nil
    }
    func compare(_ command: ReferenceLogComparisonCommand, ids: Set<String>) {
        guard let onCompare, let (from, to) = comparisonSides(command, ids: ids) else { return }
        onCompare(from, to)
    }
    func canCompareParent(_ ids: Set<String>, number: Int = 1) -> Bool {
        guard !invalidated, !busy, onCompare != nil, ids.count == 1,
              let entry = entries.first(where: { ids.contains($0.id) }),
              let parents = diffParents[entry.hash] else { return false }
        return parents.contains { $0.number == number }
    }
    func compareParent(_ ids: Set<String>, number: Int = 1) {
        guard canCompareParent(ids, number: number),
              let entry = entries.first(where: { ids.contains($0.id) }),
              let parent = diffParents[entry.hash]?.first(where: { $0.number == number }) else { return }
        onCompare?(.revision(parent.hash), .revision(entry.hash))
    }
    func showLog(_ ids: Set<String>) {
        guard !busy, ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        onLog?(entry.hash)
    }
    static func configureRevisionLog(_ log: LogWindowModel, revision: String) {
        log.revisionRange = nil
        log.endRevision = revision; log.selected = [revision]
        log.search = ""; log.useDates = false
        log.allBranches = false; log.showWorkingTree = false
        log.configureWholeProjectScope()
    }
    func logRange(_ command: ReferenceLogRangeCommand, ids: Set<String>) -> HistoryRevisionRange? {
        guard !busy, ids.count == 2 else { return nil }
        let selected = entries.filter { ids.contains($0.id) }
        guard selected.count == 2 else { return nil }
        let first = selected[0].hash, last = selected[1].hash
        return HistoryRevisionRange(from: command == .reverse ? first : last, to: command == .reverse ? last : first, kind: command == .symmetric ? .symmetricDifference : .difference)
    }
    func showLogRange(_ command: ReferenceLogRangeCommand, ids: Set<String>) {
        guard let range = logRange(command, ids: ids) else { return }
        onLogRange?(range)
    }
    static func configureRangeLog(_ log: LogWindowModel, range: HistoryRevisionRange) {
        log.endRevision = nil; log.revisionRange = range; log.selected = []
        log.search = ""; log.useDates = false; log.allBranches = false; log.showWorkingTree = false
        log.configureWholeProjectScope()
    }
    func clipboardText(_ ids: Set<String>, format: ReferenceLogCopyFormat, dates: HistoryDateSettings = .load()) -> String? {
        let chosen = entries.filter { ids.contains($0.id) }
        guard !busy, !chosen.isEmpty else { return nil }
        switch format {
        case .hashes: return chosen.map(\.hash).joined(separator: "\r\n")
        case .messages: return chosen.map { "* " + Self.message($0) + "\r\n\r\n" }.joined()
        case .full: return chosen.map {
            "Revision: " + $0.hash + "\r\nDate: " + Self.dateText($0, dates: dates) + "\r\nMessage: " + Self.message($0) + "\r\n"
        }.joined()
        }
    }
    private static func message(_ entry: ReferenceLogEntry) -> String {
        (entry.action.isEmpty ? "" : entry.action + ": ") + entry.message
    }
    static func dateText(_ entry: ReferenceLogEntry, dates: HistoryDateSettings = .load()) -> String {
        guard let date = entry.date else { return entry.timestamp }
        return dates.format(ISO8601DateFormatter().string(from: date))
    }
    func copy(_ ids: Set<String>, format: ReferenceLogCopyFormat = .hashes, pasteboard: NSPasteboard = .general) {
        guard commandSurfaceAvailable, let text = clipboardText(ids, format: format, dates: .load(defaults: preferences)) else { return }
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }
    func transportAvailable(_ command: ReferenceLogTransportCommand, ids: Set<String>, extended: Bool = false) -> Bool {
        guard commandSurfaceAvailable, !selecting, onTransport != nil, ids.count == 1,
              let entry = entries.first(where: { ids.contains($0.id) }) else { return false }
        let local = (referenceNamesByHash[entry.hash] ?? []).contains { $0.hasPrefix("refs/heads/") || $0.hasPrefix("refs/tags/") }
        switch command {
        case .push: return (!isOnStash(entry) && local) || extended
        case .pull: return hasWorkingTree && !mergeActive && entry.hash == currentHeadHash
        case .svnDCommit: return hasWorkingTree && hasGitSVN && ((!isOnStash(entry) && local) || extended)
        }
    }
    func transport(_ command: ReferenceLogTransportCommand, ids: Set<String>, extended: Bool = false) {
        guard transportAvailable(command, ids: ids, extended: extended),
              let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        let token = OperationCancellation(), request = generation, reference = self.reference
        let repository = self.repository, names = referenceNamesByHash[entry.hash] ?? []
        revisionReadToken = token; busy = true; error = nil; Self.activeRevisionReads += 1
        Task { [weak self, access] in
            defer {
                Self.activeRevisionReads -= 1; withExtendedLifetime(access) {}
                if let self, !self.invalidated, self.generation == request, self.revisionReadToken === token {
                    self.revisionReadToken = nil; self.busy = false
                }
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let prepared = try await repository.referenceLogTransportRequest(command: command, entry: entry, references: names, cancellation: token)
                guard let self, !self.invalidated, self.generation == request, self.reference == reference,
                      !token.isCancelled, self.entries.first(where: { $0.id == entry.id }) == entry else { return }
                self.revisionReadToken = nil; self.busy = false; self.onTransport?(prepared)
            } catch {
                guard let self, !self.invalidated, self.generation == request, !token.isCancelled else { return }
                self.revisionReadToken = nil; self.busy = false; self.error = error.localizedDescription
            }
        }
    }
    func operationAvailable(_ operation: ReferenceLogRevisionOperation, ids: Set<String>, mainline: Int? = nil) -> Bool {
        let chosen = entries.filter { ids.contains($0.id) }
        guard commandSurfaceAvailable, !selecting,
              !chosen.isEmpty, chosen.count == ids.count else { return false }
        switch operation {
        case .formatPatch: return !isOnStash(chosen[0]) && formatPatchPreset(ids) != nil && onFormatPatch != nil
        case .editNotes: return chosen.count == 1 && !isOnStash(chosen[0]) && !noteLog.isInvalidated
        case .merge, .rebase:
            guard hasWorkingTree, !mergeActive else { return false }
            return chosen.count == 1 && chosen[0].hash != currentHeadHash && !isOnStash(chosen[0]) && (operation == .merge ? onMergeRevision != nil : onRebaseRevision != nil)
        case .cherryPick:
            // Source gates by the first displayed selected entry, not by every
            // selected hash. Preserve display order for the Cherry Pick dialog.
            return hasWorkingTree && !mergeActive && chosen[0].hash != currentHeadHash && onCherryPick != nil
        case .revert:
            guard hasWorkingTree, !mergeActive, onRevertRevisions != nil else { return false }
            if chosen.count > 1 { return mainline == nil }
            guard !isOnStash(chosen[0]), let parents = diffParents[chosen[0].hash], !parents.isEmpty else { return false }
            if parents.count == 1 { return mainline == nil }
            return mainline.map { (1...parents.count).contains($0) } ?? false
        }
    }
    func performOperation(_ operation: ReferenceLogRevisionOperation, ids: Set<String>, mainline: Int? = nil) {
        guard operationAvailable(operation, ids: ids, mainline: mainline) else { return }
        let selected = entries.filter { ids.contains($0.id) }
        if operation == .formatPatch { if let preset = formatPatchPreset(ids) { onFormatPatch?(preset) }; return }
        if operation == .merge { onMergeRevision?(selected[0].hash); return }
        if operation == .rebase {
            let names = referenceNamesByHash[selected[0].hash] ?? []
            let target = names.first { $0.hasPrefix("refs/heads/") } ?? names.first ?? selected[0].hash
            onRebaseRevision?(target); return
        }
        let token = OperationCancellation(), request = generation, reference = self.reference
        revisionReadToken = token; busy = true; error = nil; Self.activeRevisionReads += 1
        let read = readOperationEntries, root = repository.root
        Task { [weak self, access] in
            defer {
                Self.activeRevisionReads -= 1; withExtendedLifetime(access) {}
                if let self, !self.invalidated, self.generation == request, self.revisionReadToken === token {
                    self.revisionReadToken = nil; self.busy = false
                }
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let metadata = try await read(selected, ids, token)
                guard let self, !self.invalidated, self.generation == request, self.reference == reference,
                      !token.isCancelled, self.entries.filter({ ids.contains($0.id) }) == selected else { return }
                self.revisionReadToken = nil; self.busy = false
                if operation == .editNotes {
                    self.noteLog.entries = metadata; self.noteLog.selected = Set(metadata.map(\.hash)); self.noteLog.editNotes()
                } else if operation == .cherryPick { self.onCherryPick?(metadata.map(\.hash)) }
                else { self.onRevertRevisions?(metadata, mainline) }
            } catch {
                guard let self, !self.invalidated, self.generation == request, !token.isCancelled else { return }
                self.revisionReadToken = nil; self.busy = false; self.error = error.localizedDescription
            }
        }
    }
    func refreshCombineCandidate() {
        combineToken?.cancel(); combineToken = nil; combineCandidate = nil
        guard !invalidated, commandSurfaceAvailable, !selecting, hasWorkingTree, !mergeActive,
              selection.count >= 2, let head = currentHeadHash, onCombineRevisions != nil else { return }
        let snapshot = entries, ids = selection, request = generation, reference = self.reference
        let token = OperationCancellation(), read = readCombineCandidate, root = repository.root
        combineToken = token; Self.activeRevisionReads += 1
        Task { [weak self, access] in
            defer {
                Self.activeRevisionReads -= 1; withExtendedLifetime(access) {}
                if let self, self.combineToken === token { self.combineToken = nil }
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let candidate = try await read(snapshot, ids, head, token)
                guard let self, !self.invalidated, !token.isCancelled, self.generation == request,
                      self.reference == reference, self.selection == ids, self.entries == snapshot else { return }
                self.combineToken = nil; self.combineCandidate = candidate
            } catch { /* Source omits Combine when its ancestry check fails. */ }
        }
    }
    func combineAvailable(_ ids: Set<String>) -> Bool {
        commandSurfaceAvailable && !selecting && hasWorkingTree && !mergeActive && onCombineRevisions != nil && combineCandidate?.selectors == ids && combineCandidate?.head == currentHeadHash
    }
    func combine(_ ids: Set<String>) {
        guard combineAvailable(ids), let candidate = combineCandidate else { return }
        onCombineRevisions?(candidate.entries, candidate.offset, candidate.head)
    }
    func bisectAvailable(_ command: LogBisectCommand, ids: Set<String>) -> Bool {
        let chosen = entries.filter { ids.contains($0.id) }
        guard command != .reset, commandSurfaceAvailable, !selecting, hasWorkingTree,
              chosen.count == ids.count, let first = chosen.first, onBisect != nil else { return false }
        if command == .start { return chosen.count == 2 && !bisectActive && !mergeActive && !isOnStash(first) }
        return bisectActive && !(referenceNamesByHash[first.hash] ?? []).contains { $0.hasPrefix("refs/bisect/") } && (command == .skip || chosen.count == 1)
    }
    func bisect(_ command: LogBisectCommand, ids: Set<String>) {
        guard bisectAvailable(command, ids: ids) else { return }
        let snapshot = entries.filter { ids.contains($0.id) }, refs = referenceNamesByHash, request = generation, reference = self.reference
        let token = OperationCancellation(), repository = self.repository, root = repository.root
        revisionReadToken = token; busy = true; error = nil; Self.activeRevisionReads += 1
        Task { [weak self, access] in
            defer {
                Self.activeRevisionReads -= 1; withExtendedLifetime(access) {}
                if let self, !self.invalidated, self.generation == request, self.revisionReadToken === token { self.revisionReadToken = nil; self.busy = false }
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result = try await repository.referenceLogBisectRequest(snapshot: snapshot, selected: ids, operation: command == .start ? nil : command.operation, references: refs, cancellation: token)
                guard let self, !self.invalidated, !token.isCancelled, self.generation == request,
                      self.reference == reference, self.entries.filter({ ids.contains($0.id) }) == snapshot else { return }
                self.revisionReadToken = nil; self.busy = false; self.onBisect?(result)
            } catch {
                guard let self, !self.invalidated, !token.isCancelled, self.generation == request else { return }
                self.revisionReadToken = nil; self.busy = false; self.error = error.localizedDescription
            }
        }
    }
    func formatPatchPreset(_ ids: Set<String>) -> FormatPatchPreset? { FormatPatchPreset.referenceLogSelection(entries: entries, selected: ids) }
    func invalidate() { combineToken?.cancel(); combineToken = nil; combineCandidate = nil; noteLog.invalidate(); noteChanges = nil; invalidated = true; generation += 1; revisionReadToken?.cancel(); revisionReadToken = nil }
    func requestDiffParents(_ entry: ReferenceLogEntry) {
        guard !invalidated, entries.contains(where: { $0.id == entry.id && $0.hash == entry.hash }), requestedDiffParents.insert(entry.hash).inserted else { return }
        let request = generation
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let parents = try await repository.referenceLogDiffParents(entry.hash)
                guard !invalidated, request == generation else { return }
                diffParents[entry.hash] = parents
            } catch { if !invalidated, request == generation { diffParents[entry.hash] = [] } }
        }
    }
    func canInspect(_ ids: Set<String>, mode: ReferenceLogDiffMode = .parent(1)) -> Bool {
        guard !invalidated, !busy, !unifiedViewerBusy, hasWorkingTree, (1...2).contains(ids.count) else { return false }
        let chosen = entries.filter { ids.contains($0.id) }
        guard chosen.count == ids.count else { return false }
        if chosen.count == 2 { return mode == .parent(1) }
        guard let parents = diffParents[chosen[0].hash] else { return false }
        switch mode {
        case .parent(let number): return number > 0 && number <= parents.count
        case .allParents, .onlyMergedFiles, .extraChanges: return parents.count > 1
        }
    }
    func inspect(_ ids: Set<String>, mode: ReferenceLogDiffMode = .parent(1), alternate: Bool = false) {
        guard canInspect(ids, mode: mode) else { return }
        let chosen = entries.filter { ids.contains($0.id) }, request = generation
        busy = true; information = nil
        Task {
            defer { if request == generation { busy = false }; withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let bytes: Data
                if chosen.count == 2 { bytes = try await repository.referenceLogUnifiedDiff(from: chosen[1].hash, to: chosen[0].hash) }
                else {
                    let result = try await repository.referenceLogUnifiedDiff(chosen[0].hash, mode: mode)
                    guard !invalidated, request == generation else { return }
                    if result.noExtraChanges { information = "No extra changes after merge"; return }
                    bytes = result.bytes
                }
                guard !invalidated, request == generation else { return }
                let viewerAlternate = chosen.count == 1 && mode == .extraChanges ? false : alternate
                if let onUnifiedDiff { try await onUnifiedDiff(bytes, viewerAlternate) }
                else if try await !UnifiedDiffApplication.openExternal(bytes, alternate: viewerAlternate) {
                    guard !invalidated, request == generation else { return }
                    unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: "Selected RefLog changes", onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
            } catch { if !invalidated, request == generation { self.error = error.localizedDescription } }
        }
    }
}
enum ReferenceLogCopyFormat { case full, hashes, messages }
enum ReferenceLogHistoryCommand: CaseIterable, Hashable {
    case reset, checkout
    var icon: MenuIcon { self == .reset ? .reset : .checkout }
    func title(branch: String) -> String { self == .reset ? "Reset \"" + (branch.isEmpty ? "(no branch)" : branch) + "\" to this…" : "Switch/Checkout to this…" }
}
enum ReferenceLogRangeCommand: CaseIterable, Hashable { case forward, reverse, symmetric }
enum ReferenceLogComparisonCommand {
    case workingTree, revisions
    var title: String { self == .workingTree ? "Compare with working tree" : "Compare revisions" }
    var icon: MenuIcon { .compare }
}
enum ReferenceLogRevisionCommand: CaseIterable, Hashable {
    case browseRepository, createBranch, createTag, export
    var title: String {
        switch self {
        case .browseRepository: return "Browse repository"
        case .createBranch: return "Create Branch at this version…"
        case .createTag: return "Create Tag at this version…"
        case .export: return "Export this version…"
        }
    }
    var icon: MenuIcon {
        switch self {
        case .browseRepository: return .repositoryBrowser
        case .createBranch: return .branch
        case .createTag: return .tag
        case .export: return .export
        }
    }
}

private struct ReferenceLogDialog: View {
    @ObservedObject var model: ReferenceLogWindowModel
    @AppStorage("LogDateFormat") private var shortDate = true
    @AppStorage("RelativeTimes") private var relativeTimes = false
    @AppStorage("UseSystemLocaleForDates") private var useSystemLocale = true
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Ref:"); ReferenceLogPicker(names: model.names, selection: $model.reference).frame(maxWidth: .infinity).frame(height: 26) }
            ReferenceLogNativeTable(model: model, dates: HistoryDateSettings(shortDate: shortDate, relative: relativeTimes, useSystemLocale: useSystemLocale))
            if let report = model.deletionReport { Text(report).font(.caption).foregroundStyle(.red).lineLimit(3).help(report) }
            HStack {
                Button("Search…") { model.openFind() }.keyboardShortcut("f")
                if !model.selecting && model.reference == "refs/stash" { Button("Clear stash") { model.delete([], clear: true) }.disabled(model.entries.isEmpty) }
                Button("Refresh") { model.reload() }.keyboardShortcut("r")
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.accept() }.disabled(model.selecting && model.selectedEntry == nil).keyboardShortcut(.defaultAction)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-reflog.html")!) }
            }
        }.padding(12).disabled(!model.commandSurfaceAvailable)
        .onChange(of: model.reference) { _ in model.selection = []; model.reload() }
        .alert("RefLog", isPresented: Binding(get: { model.error != nil || model.information != nil }, set: { if !$0 { model.error = nil; model.information = nil } })) { Button("OK") { model.error = nil; model.information = nil } } message: { Text(model.error ?? model.information ?? "") }
    }
}

private struct ReferenceLogPicker: NSViewRepresentable {
    let names: [String]
    @Binding var selection: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel("Ref:")
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemTitles != names { button.removeAllItems(); button.addItems(withTitles: names) }
        button.selectItem(withTitle: selection)
    }
    final class Coordinator: NSObject {
        var parent: ReferenceLogPicker
        init(_ parent: ReferenceLogPicker) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) { if let title = sender.titleOfSelectedItem { parent.selection = title } }
    }
}

/// Function keys are handled by the owning RefLog window, without a global event monitor.
@MainActor final class ReferenceLogNativeWindow: NSWindow {
    var functionKey: (UInt16) -> Bool = { _ in false }
    func handleFunctionKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 99 || event.keyCode == 96 else { return false }
        return functionKey(event.keyCode)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleFunctionKey(event) || super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !handleFunctionKey(event) { super.keyDown(with: event) }
    }
}

@MainActor final class ReferenceLogFindController: NSWindowController, NSWindowDelegate {
    var onClosed: () -> Void = {}
    init(model: ReferenceLogWindowModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 170), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Find – RefLog – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ReferenceLogFindDialog(model: model, close: { [weak window] in window?.close() }))
        super.init(window: window); window.delegate = self; window.center()
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct ReferenceLogFindDialog: View {
    @ObservedObject var model: ReferenceLogWindowModel
    let close: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Find what:", text: $model.find).textFieldStyle(.roundedBorder).focused($focused).onSubmit { model.findNext() }
            Toggle("Match case", isOn: $model.matchCase).toggleStyle(.checkbox)
            if model.searchWrapped { Text("Search wrapped to the beginning.").font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Find Next") { model.findNext() }.disabled(model.find.isEmpty || model.busy).keyboardShortcut(.defaultAction)
                Button("Cancel", action: close).keyboardShortcut(.cancelAction) }
        }.padding(20).onAppear { focused = true }
    }
}

enum ReferenceLogRevisionOperation: CaseIterable {
    case merge, rebase, cherryPick, revert, editNotes, formatPatch
    var icon: MenuIcon { switch self { case .merge: return .merge; case .rebase: return .rebase; case .cherryPick: return .cherryPick; case .revert: return .revert; case .editNotes: return .rebaseEdit; case .formatPatch: return .patch } }
    func title(branch: String, count: Int) -> String {
        switch self {
        case .editNotes: return "Edit Notes…"
        case .formatPatch: return "Create patch…"
        case .merge: return "Merge into \"" + branch + "\"…"
        case .rebase: return "Rebase \"" + branch + "\" onto this…"
        case .cherryPick: return count == 1 ? "Cherry pick this commit…" : "Cherry pick selected commits…"
        case .revert: return count == 1 ? "Revert change by this commit" : "Revert changes by these commits"
        }
    }
}
