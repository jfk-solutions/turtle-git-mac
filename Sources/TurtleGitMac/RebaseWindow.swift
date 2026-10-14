import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class RebaseWindowController: NSWindowController, NSWindowDelegate {
    let model: RebaseWindowModel
    var onClosed: () -> Void = {}
    private(set) var conflictBaseViewer: FileComparisonWindowController?
    var configureConflictBaseViewer: (FileComparisonWindowModel) -> Void = { _ in }
    private var conflictPanel: (UUID, NSOpenPanel, (URL?) -> Void)?
    var presentConflictPanel: (NSWindow, NSOpenPanel, @escaping (NSApplication.ModalResponse) -> Void) -> Bool = { owner, panel, reply in
        guard owner.attachedSheet == nil else { return false }; panel.beginSheetModal(for: owner, completionHandler: reply); return true
    }
    private var logPicker: LogWindowController?
    private var splitCommitPicker: CommitWindowController?
    private var stashRestore: StashRestoreWindowController?
    private var stashAlert: NSAlert?
    private var notePresenter: CommitNotePresenter?
    var noteEditor: InputWindowController? { notePresenter?.editor }
    private(set) static var activeReferencePickers = 0
    private var referenceRequest: RebaseReferenceRequest?
    private(set) var referencePicker: ReferenceBrowserWindowController?
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var presentReferencePicker: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    var makeReferencePicker: (GitRepository, RepositoryAccessLease?, String, UserDefaults, @escaping (String?) -> Void) -> ReferenceBrowserWindowController = { repository, access, initial, preferences, choose in
        ReferenceBrowserWindowController(repository: repository, access: access, initial: initial, preferences: preferences, onChoose: choose)
    }
    func showReferencePicker(_ target: RebaseReferenceTarget) {
        guard let owner = window, owner.attachedSheet == nil, referencePicker == nil, let request = model.beginReferenceSelection(target) else { return }
        referenceRequest = request; Self.activeReferencePickers += 1
        let child = makeReferencePicker(model.repository, model.repositoryAccess, target == .upstream ? request.upstream : request.onto, model.columnPreferences) { [weak self] value in
            guard let self, self.referenceRequest?.id == request.id else { return }
            self.finishReferencePicker(); self.model.acceptReferenceSelection(request, value: value)
        }
        referencePicker = child; configureReferencePicker(child.model)
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.referencePicker === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.referencePicker = nil
        }
        guard let window = child.window, presentReferencePicker(owner, window) else {
            finishReferencePicker(); child.abandonPresentation(); model.abandonReferenceSelection(request); return
        }
        child.model.load()
    }
    private func finishReferencePicker() {
        guard referenceRequest != nil else { return }; referenceRequest = nil; referencePicker = nil; Self.activeReferencePickers -= 1
    }
    private func retireReferencePicker() { let child = referencePicker; finishReferencePicker(); child?.abandonPresentation() }


    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = RebaseWindowModel(repository: repository, access: access, messageDefaults: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Rebase – TurtleGit"; window.minSize = NSSize(width: 930, height: 620); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RebaseDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); model.clientHooks.windowProvider = { [weak window] in window?.attachedSheet ?? window }; window.delegate = self; window.center(); model.close = { [weak window] in window?.close() }
        model.revisionMenuLog.window = window
        model.chooseConflictApplication = { [weak self] in await self?.chooseConflictLocation(application: true) }
        model.chooseConflictExport = { [weak self] in await self?.chooseConflictLocation(application: false) }
        model.onConflictBaseComparison = { [weak self] prepared in
            guard let self, !self.model.retired, self.conflictBaseViewer == nil else { return }
            let child = FileComparisonWindowController(repository: repository, access: access, conflict: prepared, preferences: preferences)
            self.configureConflictBaseViewer(child.model); self.conflictBaseViewer = child; self.model.viewingConflictBase = true
            child.onClosed = { [weak self] in
                guard let self else { return }; self.conflictBaseViewer = nil; self.model.viewingConflictBase = false
                if !self.model.retired { self.model.busy = false; self.model.refreshState() }
            }
            child.showWindow(nil); child.window?.makeKeyAndOrderFront(nil)
        }
        model.pickReference = { [weak self] target in self?.showReferencePicker(target) }
        notePresenter = CommitNotePresenter(parent: window, model: model.revisionMenuLog, preferences: preferences)
        model.onModeChanged = { [weak window, weak model] in
            window?.title = "\(repository.root.lastPathComponent) – \(model?.operationTitle ?? "Rebase") – TurtleGit"
        }
        model.pickAdditionalCommits = { [weak self] in
            guard let self, self.model.canAdd, let window = self.window, window.attachedSheet == nil, self.logPicker == nil else { return }
            self.model.pickingCommits = true
            let picker = LogWindowController(repository: repository, access: access, onChooseMultiple: { [weak self] revisions in
                guard let self else { return }; self.model.finishPickingCommits(revisions?.map(\.hash))
            })
            self.logPicker = picker
            picker.onClosed = { [weak self] in self?.logPicker = nil }
            self.model.configureLogPicker(picker.model)
            if let child = picker.window { window.beginSheet(child) } else { self.logPicker = nil; self.model.pickingCommits = false }
        }
        model.showSplitSelection = { [weak self] split, message in self?.showSplitSelection(split, message: message) }
        model.chooseStashBeforeReplay = { [weak self] in
            await self?.askStash(message: "Your working tree is not clean", detail: "Stash tracked changes before starting? Untracked and ignored files will remain in the working tree.", save: true) ?? false
        }
        model.chooseRestoreReplayStash = { [weak self] in
            await self?.askStash(message: "Restore stashed changes?", detail: "Do you want to pop the changes saved before this replay?", save: false) ?? false
        }
        model.restoreReplayStash = { [weak self] mode in
            guard let self, let window = self.window, window.attachedSheet == nil else { return }
            await withCheckedContinuation { continuation in
                let child = StashRestoreWindowController(repository: repository, access: access, pop: true, showChanges: mode, preferences: preferences)
                self.stashRestore = child
                child.onChanged = { [weak model = self.model] text in model?.output += text + "\n"; model?.onChanged() }
                child.onViewChanges = { [weak model = self.model] in model?.onShowStatus() }
                child.onClosed = { [weak self, weak child] in
                    if let sheet = child?.window { sheet.sheetParent?.endSheet(sheet); sheet.orderOut(nil) }
                    if self?.stashRestore === child { self?.stashRestore = nil }
                    continuation.resume()
                }
                if let sheet = child.window { window.beginSheet(sheet); child.start() }
                else { child.close() }
            }
        }
        model.chooseAnotherSplit = { [weak window] in
            guard let window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Add another commit?"; alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
            return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
        }
        model.chooseEmptyResult = { [weak self] in
            guard let window = self?.window else { return .cancel }
            let alert = NSAlert(); alert.messageText = "The current commit will be empty"
            alert.informativeText = "Skip the commit or keep the message-only commit?"
            alert.addButton(withTitle: "Commit"); alert.addButton(withTitle: "Skip")
            let cancel = alert.addButton(withTitle: "Cancel"); alert.buttons.first?.keyEquivalent = ""; cancel.keyEquivalent = "\r"; alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
            let answer = await alert.beginSheetModal(for: window)
            if answer == .alertFirstButtonReturn { return .commit }
            if answer == .alertSecondButtonReturn { return .skip }
            return .cancel
        }
        model.confirmConflictHints = { [weak self] in
            guard let window = self?.window else { return false }
            let alert = NSAlert(); alert.messageText = "Conflict hints remain in the commit message"
            alert.informativeText = "The message contains Git's commented conflict list. Ignore the warning to continue, or abort to edit the message."
            alert.addButton(withTitle: "Ignore"); let abort = alert.addButton(withTitle: "Abort")
            alert.buttons.first?.keyEquivalent = ""; abort.keyEquivalent = "\r"; alert.window.defaultButtonCell = abort.cell as? NSButtonCell
            let remember = NSButton(checkboxWithTitle: "Do not show again", target: nil, action: nil); alert.accessoryView = remember
            let answer = await alert.beginSheetModal(for: window)
            if answer == .alertFirstButtonReturn, remember.state == .on { preferences.set(true, forKey: "CommitMessageContainsConflictHint") }
            return answer == .alertFirstButtonReturn
        }
        model.chooseMainline = { [weak window] commit, choices in
            guard let window, window.attachedSheet == nil else { return nil }
            let alert = NSAlert(); alert.messageText = "TurtleGit"; alert.alertStyle = .informational
            alert.informativeText = "\"\(commit.hash)\" - \"\(commit.subject)\"\nis a merge commit.\n\nWhich parent do you want to pick?"
            for choice in choices { alert.addButton(withTitle: choice.title) }
            let cancel = alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.keyEquivalent = ""; cancel.keyEquivalent = "\r"; alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
            let response = await alert.beginSheetModal(for: window)
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            return choices.indices.contains(index) ? choices[index].number : nil
        }

        DialogGeometry.attach(window, identifier: "RebaseWindowController")
    }
    private func chooseConflictLocation(application: Bool) async -> URL? {
        guard !model.retired, conflictPanel == nil, let window, window.attachedSheet == nil else { return nil }
        let panel = NSOpenPanel(); panel.title = application ? "Open With" : "Export selected files"; panel.prompt = application ? "Open" : "Export"
        panel.canChooseFiles = application; panel.canChooseDirectories = !application; panel.allowsMultipleSelection = false; panel.canCreateDirectories = !application
        if application { panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true) }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            conflictPanel = (id, panel, { continuation.resume(returning: $0) })
            if !presentConflictPanel(window, panel, { [weak self] response in self?.finishConflictPanel(id, accepted: response == .OK) }) { finishConflictPanel(id, accepted: false) }
        }
    }
    private func finishConflictPanel(_ id: UUID, accepted: Bool) {
        guard let pending = conflictPanel, pending.0 == id else { return }; conflictPanel = nil
        let value = accepted && !model.retired ? pending.1.url : nil
        if pending.1.sheetParent === window { window?.endSheet(pending.1, returnCode: accepted ? .OK : .cancel) }
        pending.1.orderOut(nil); pending.2(value)
    }
    private func askStash(message: String, detail: String, save: Bool) async -> Bool {
        guard !model.retired, let window, window.attachedSheet == nil, stashAlert == nil else { return false }
        let alert = NSAlert(); alert.messageText = message; alert.informativeText = detail; alert.alertStyle = .warning
        let yes = alert.addButton(withTitle: save ? "Stash" : "Yes"); alert.addButton(withTitle: save ? "Abort" : "No")
        yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
        stashAlert = alert
        let response = await alert.beginSheetModal(for: window)
        if stashAlert === alert { stashAlert = nil }
        return !model.retired && response == .alertFirstButtonReturn
    }
    private func showSplitSelection(_ split: RebaseSplitState, message: String) {
        guard let window, window.attachedSheet == nil, splitCommitPicker == nil else { model.splitSelectionClosed(committed: false); return }
        let child = CommitWindowController(repository: model.repository, access: model.repositoryAccess, defaults: model.columnPreferences)
        splitCommitPicker = child
        let commit = child.model
        model.configureCommitSelection(commit)
        var committed = false
        commit.onCommitted = { [weak model] text in committed = true; model?.output += text + "\n"; model?.onChanged() }
        let originalClose = commit.close
        commit.close = { [weak window, weak child] in
            if let sheet = child?.window { window?.endSheet(sheet); sheet.orderOut(nil) }; originalClose()
        }
        child.onClosed = { [weak self] in self?.splitCommitPicker = nil; self?.model.splitSelectionClosed(committed: committed) }
        commit.loadReplaySplit(split, message: message)
        if let sheet = child.window { window.beginSheet(sheet) } else { splitCommitPicker = nil; model.splitSelectionClosed(committed: false) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.cancelPreparation() { return false }
        guard model.pickingReference == nil, !model.busy, !model.selectingSplit, !(model.active && model.hasReplayStash), sender.attachedSheet == nil else { return false }
        if !model.active && model.hasReplayStash { model.finishReplay(); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) { retireReferencePicker(); model.retire(); if let pending = conflictPanel { finishConflictPanel(pending.0, accepted: false) }; conflictBaseViewer?.close(); conflictBaseViewer = nil; notePresenter?.close(); if let alert = stashAlert { window?.endSheet(alert.window, returnCode: .abort); alert.window.orderOut(nil) }; stashAlert = nil; stashRestore?.close(); stashRestore = nil; logPicker?.close(); logPicker = nil; splitCommitPicker?.close(); splitCommitPicker = nil; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
enum RebaseReferenceTarget: Equatable { case upstream, onto }
struct RebaseReferenceRequest {
    let id = UUID()
    let target: RebaseReferenceTarget
    let branch: String
    let upstream: String
    let onto: String
}

@MainActor final class RebaseWindowModel: ObservableObject {
    let repository: GitRepository
    let fullCommitMessageOnLogLine: Bool
    private let access: RepositoryAccessLease?
    var columnPreferences: UserDefaults { messageDefaults }
    private let messageDefaults: UserDefaults
    lazy var clientHooks = ClientHookSession(preferences: messageDefaults)
    var repositoryAccess: RepositoryAccessLease? { access }
    @Published var options = RebaseOptions()
    @Published var ontoEnabled = false
    @Published private(set) var showsIssueColumn = false
    @Published private(set) var hasGitSVN = false
    @Published private(set) var issueColumnValues: [String:String] = [:]
    @Published private(set) var svnColumnValues: [String:String] = [:]
    @Published private(set) var loadingColumnMetadata = false
    private var columnToken: OperationCancellation?
    private var columnGeneration = UUID()
    private var columnSignature: [String] = []
    static private(set) var activeColumnReads = 0
    static private(set) var activeStashRestorations = 0
    var readColumnMetadata: ([LogEntry],OperationCancellation) async throws -> ReplayColumnMetadata
    @Published var references: [CheckoutReference] = []
    @Published var plan: RebasePlan?
    @Published var recovered: [RebaseEntry] = []
    @Published var replayRows: [RebaseEntry] = []
    @Published var draftEntries: [RebaseEntry] = []
    @Published var state: RebaseState?
    @Published var selection = Set<String>()
    @Published var files: [CommitFile] = []
    @Published var conflictRows: [StatusEntry] = []
    @Published var conflictStatistics: [String: CommitFile] = [:]
    @Published var conflicts: [ConflictEntry] = []
    @Published var selectedConflicts = Set<String>()
    @Published var checkedConflicts = Set<String>()
    private var conflictHead = ""
    var supportsConflictSelection: Bool { state?.stoppedAction == .pick || state?.stoppedAction == .edit }
    @Published var fileRecovery = false
    var onConflictBaseComparison: (ConflictBaseComparison) -> Void = { _ in }
    var onConflictFileLog: (String) -> Void = { _ in }
    var onConflictFileBlame: (String, String) -> Void = { _, _ in }
    var onConflictWorkingComparison: ([String]) -> Void = { _ in }
    var onConflictWorkingPair: ([String]) -> Void = { _ in }
    var chooseConflictApplication: () async -> URL? = { nil }
    var chooseConflictExport: () async -> URL? = { nil }
    var conflictPasteboard: NSPasteboard = .general
    var openConflictWorkingFile: (URL, URL?) async throws -> Void = { url, application in
        if let application {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, failure in
                    if let failure { reply.resume(throwing: failure) } else { reply.resume() }
                }
            }
        } else if !NSWorkspace.shared.open(url) { throw StatusFileActionFailure(message: "Could not open " + url.lastPathComponent + ".") }
    }
    var openConflictAlternativeEditor: (URL) async throws -> Void = { url in
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            AlternativeEditor.open(url) { failure in if let failure { reply.resume(throwing: StatusFileActionFailure(message: failure)) } else { reply.resume() } }
        }
    }
    var revealConflictFiles: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    @Published var viewingConflictBase = false
    @Published private(set) var preparingConflictFiles = false
    private var conflictFileCancellation: OperationCancellation?
    private var conflictMenuGeneration = UUID()
    var onConflictAction: (RepositoryAction, [String]) -> Void = { _, _ in }
    @Published var conflictPatch: String?
    @Published var selectedFiles = Set<String>()
    @Published var message = ""
    @Published var amendMessage = ""
    @Published var projectSettings = ProjectDialogSettings()
    @Published var output = ""
    @Published var tab = 0
    @Published var busy = false
    @Published var finished = false
    @Published var completedSuccessfully = false
    var completionAfterFetch = false
    var completionFromLog = false
    var completionAutoStart = false
    var onCompletedLog: (() -> Void)?
    var onCompletedPush: ((String) -> Void)?
    var onCompletedMail: ((FormatPatchPreset) -> Void)?
    @Published var error: String?
    @Published var confirmation: String?
    @Published private(set) var pickingReference: RebaseReferenceTarget?
    var pickReference: (RebaseReferenceTarget) -> Void = { _ in }
    private var referenceRequest: RebaseReferenceRequest?
    private var referenceCancellation: OperationCancellation?
    private var planCancellation: OperationCancellation?
    private var detailCancellation: OperationCancellation?
    private var initialCancellation: OperationCancellation?
    private var planSignature: Data?
    @Published private(set) var loadingPlan = false
    @Published private(set) var cancellingPreparation = false
    static private(set) var activePreparationReads = 0
    var readPlan: (RebaseOptions, OperationCancellation) async throws -> RebasePlan
    var validateOnto: (String, String, String, OperationCancellation) async throws -> String?
    var hasCancellablePreparation: Bool { conflictFileCancellation != nil || sessionCancellation != nil || conflictDiffCancellation != nil || planCancellation != nil || referenceCancellation != nil || initialCancellation != nil || detailCancellation != nil }
    @discardableResult func cancelPreparation() -> Bool {
        guard hasCancellablePreparation else { return false }
        cancellingPreparation = true;pendingSessionRefresh=false;sessionCancellation?.cancel();conflictDiffCancellation?.cancel();conflictFileCancellation?.cancel(); planCancellation?.cancel(); referenceCancellation?.cancel(); initialCancellation?.cancel(); detailCancellation?.cancel(); return true
    }
    func referenceChoices(_ target: RebaseReferenceTarget?) -> [CheckoutReference] {
        let selected = target == nil ? options.branch : options.upstream
        var result = target == nil ? references.filter { $0.target == .branch && !$0.isFetchHead } : references
        if !result.contains(where: { GitReferenceName.equal($0.name, selected) }) { result.insert(CheckoutReference(name: selected), at: 0) }
        return result
    }
    func chooseBranch(_ name: String) { guard editable else { return }; options.branch = name; reloadPlan() }
    func chooseUpstream(_ name: String) { guard editable else { return }; options.upstream = name; reloadPlan() }
    func reverseReferences() {
        guard editable else { return }; let old = options.branch; options.branch = options.upstream; options.upstream = old; reloadPlan()
    }
    func beginReferenceSelection(_ target: RebaseReferenceTarget) -> RebaseReferenceRequest? {
        guard editable, !isCherryPick else { return nil }
        planCancellation?.cancel()
        let request = RebaseReferenceRequest(target: target, branch: options.branch, upstream: options.upstream, onto: options.onto)
        referenceRequest = request; pickingReference = target; return request
    }
    private func acceptsReference(_ request: RebaseReferenceRequest) -> Bool {
        !retired && referenceRequest?.id == request.id && GitReferenceName.equal(options.branch, request.branch) && GitReferenceName.equal(options.upstream, request.upstream) && GitReferenceName.equal(options.onto, request.onto)
    }
    func abandonReferenceSelection(_ request: RebaseReferenceRequest) {
        guard referenceRequest?.id == request.id else { return }; referenceRequest = nil; pickingReference = nil
        if !retired { reloadPlan(); loadPendingHandoff() }
    }
    func acceptReferenceSelection(_ request: RebaseReferenceRequest, value: String?) {
        guard acceptsReference(request) else { if referenceRequest?.id == request.id { referenceRequest = nil; pickingReference = nil; if !retired { reloadPlan(force: true); loadPendingHandoff() } }; return }
        if request.target == .upstream {
            referenceRequest = nil; pickingReference = nil
            if let value { options.upstream = value }
            reloadPlan(force: value != nil); loadPendingHandoff(); return
        }
        let token = OperationCancellation(); referenceCancellation = token; Self.activePreparationReads += 1; cancellingPreparation = false
        Task {
            defer {
                Self.activePreparationReads -= 1; withExtendedLifetime(access) {}
                if referenceCancellation === token { referenceCancellation = nil; referenceRequest = nil; pickingReference = nil; cancellingPreparation = false; loadPendingHandoff() }
            }
            do {
                try requireAccess()
                let choice = try await validateOnto(value ?? "", request.branch, request.upstream, token)
                guard acceptsReference(request), !token.isCancelled else { return }
                referenceCancellation = nil; referenceRequest = nil; pickingReference = nil
                options.onto = choice ?? ""; ontoEnabled = choice != nil; cancellingPreparation = false; reloadPlan(force: true); loadPendingHandoff()
            } catch {
                guard acceptsReference(request), !token.isCancelled else { return }
                referenceCancellation = nil; referenceRequest = nil; pickingReference = nil; options.onto = ""; ontoEnabled = false; cancellingPreparation = false
                reloadPlan(); self.error = error.localizedDescription
            }
        }
    }

    @Published var pickingCommits = false
    @Published var splitCommit = false
    @Published var selectingSplit = false
    var showSplitSelection: (RebaseSplitState, String) -> Void = { _, _ in }
    var configureCommitSelection: (CommitWindowModel) -> Void = { _ in }
    var chooseAnotherSplit: () async -> Bool = { false }
    private(set) var retired = false
    @Published private(set) var hasReplayStash = false
    private var replayPreparationCancellation: OperationCancellation?
    var chooseStashBeforeReplay: () async -> Bool = { false }
    var chooseRestoreReplayStash: () async -> Bool = { false }
    var restoreReplayStash: (Int) async -> Void = { _ in }
    func retire() { retired = true;pendingSessionRefresh=false;sessionGeneration=UUID();conflictDiffGeneration=UUID();sessionCancellation?.cancel();conflictDiffCancellation?.cancel();conflictFileCancellation?.cancel(); planCancellation?.cancel(); referenceCancellation?.cancel(); initialCancellation?.cancel(); detailCancellation?.cancel(); planGeneration += 1; detailGeneration += 1; referenceRequest = nil; pickingReference = nil; loadingPlan = false; columnGeneration = UUID(); columnToken?.cancel(); columnToken = nil; loadingColumnMetadata = false; revisionMenuLog.invalidate(); replayPreparationCancellation?.cancel(); clientHooks.retire() }
    func finishReplay(after: (() -> Void)? = nil) {
        guard !retired, !busy, !active, !selectingSplit, !pickingCommits else { return }
        // Preserve immediate completion routing when there is no stash question
        // or restore operation to await.
        if !hasReplayStash { if let after { after() } else { close() }; return }
        busy=true;let request=OperationCancellation();replayPreparationCancellation=request
        Self.activeStashRestorations += 1
        Task {
            defer { busy=false;Self.activeStashRestorations -= 1;if replayPreparationCancellation === request { replayPreparationCancellation=nil };withExtendedLifetime(access) {} }
            do {
                if hasReplayStash {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let automatic=try await repository.replayAutomaticStash(cherryPick:isCherryPick,cancellation:request)
                    guard !retired,!request.isCancelled else { return }
                    let restore=automatic ? true : await chooseRestoreReplayStash()
                    guard !retired,!request.isCancelled else { return }
                    // Once-only, including No: source clears m_bStashed after this choice.
                    hasReplayStash=false
                    if restore { await restoreReplayStash(automatic ? 0 : 1) }
                }
                guard !retired,!request.isCancelled else { return }
                busy=false
                if let after { after() } else { close() }
            } catch { if !retired,!request.isCancelled { self.error=error.localizedDescription } }
        }
    }
    var close: () -> Void = {}
    var onChanged: () -> Void = {}
    var onShowStatus: () -> Void = {}
    var onModeChanged: () -> Void = {}
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    lazy var revisionMenuLog = LogWindowModel(repository: repository, access: access, labelDefaults: messageDefaults)
    var onShowRevisionLog: ((String) -> Void)?
    var pickAdditionalCommits: () -> Void = {}
    var chooseEmptyResult: () async -> RebaseEmptyChoice = { .cancel }
    var confirmConflictHints: () async -> Bool = { false }
    var chooseMainline: (LogEntry, [LogParentChoice]) async -> Int? = { _, _ in nil }
    var editorExecutable: URL? = Bundle.main.executableURL
    var isCherryPick: Bool { options.isCherryPick || state?.isCherryPick == true }
    var operationTitle: String { isCherryPick ? "Cherry Pick" : "Rebase" }
    var startTitle: String { isCherryPick ? "Continue" : "Start Rebase" }
    var helpURL: URL { URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-" + (isCherryPick ? "cherrypick" : "rebase") + ".html")! }
    private var planGeneration = 0
    private var detailGeneration = 0
    private var conflictIdentity:RebaseConflictIdentity?
    private var sessionCancellation:OperationCancellation?
    private var conflictDiffCancellation:OperationCancellation?
    private var sessionGeneration=UUID()
    private var conflictDiffGeneration=UUID()
    private var pendingSessionRefresh=false
    @Published private(set) var refreshingSession=false
    @Published private(set) var preparingConflictDiff=false
    var readSession:(RebaseConflictIdentity?,OperationCancellation) async throws -> RebaseSessionSnapshot
    private func applyConflictSnapshot(_ snapshot:RebaseSessionSnapshot) {
        conflictMenuGeneration = UUID()
        let previousPaths=conflictIdentity == snapshot.identity ? Set(conflictRows.map(\.path)):[]
        if conflictIdentity != snapshot.identity || !snapshot.fileRecovery {checkedConflicts=[]}
        state=snapshot.state;fileRecovery=snapshot.fileRecovery;conflictIdentity=snapshot.identity
        conflicts=snapshot.conflicts;conflictRows=snapshot.rows;conflictStatistics=snapshot.statistics;conflictHead=snapshot.head
        let paths=Set(snapshot.rows.map(\.path))
        checkedConflicts.formIntersection(paths);checkedConflicts.formUnion(paths.subtracting(previousPaths))
        selectedConflicts.formIntersection(Set(snapshot.rows.map(\.id)))
        if !snapshot.fileRecovery {checkedConflicts=[]}
    }
    private func loadConflictFiles(cancellation:OperationCancellation?=nil) async throws {
        try cancellation?.check();guard !retired else {return}
        let snapshot=try await repository.rebaseSessionSnapshot(retaining:conflictIdentity,includeReplay:false,cancellation:cancellation)
        try cancellation?.check();guard !retired else {return};applyConflictSnapshot(snapshot)
    }
    struct ConflictFileMenu {
        let generation: UUID
        let identity: RebaseConflictIdentity?
        let head: String
        let rows: [StatusEntry]
        let conflicts: [ConflictEntry]
        let statistics: [String: CommitFile]
        var paths: [String] { rows.map(\.path) }
    }
    func conflictFileMenu(_ ids: Set<String>) -> ConflictFileMenu {
        let rows = conflictRows.filter { ids.contains($0.id) }
        return ConflictFileMenu(generation: conflictMenuGeneration, identity: conflictIdentity, head: conflictHead, rows: rows, conflicts: conflicts.filter { ids.contains($0.id) }, statistics: conflictStatistics)
    }
    private func acceptsConflictFileMenu(_ menu: ConflictFileMenu, duringRequest: Bool = false) -> Bool {
        !retired && (duringRequest || !busy) && !viewingConflictBase && !selectingSplit && fileRecovery &&
        menu.generation == conflictMenuGeneration && menu.identity == conflictIdentity && menu.head == conflictHead &&
        !menu.rows.isEmpty && menu.rows.allSatisfy { conflictRows.contains($0) }
    }
    func canConflictFileCommand(_ command: StatusFileCommand, menu: ConflictFileMenu) -> Bool {
        guard acceptsConflictFileMenu(menu) else { return false }
        let ordinary = menu.rows.allSatisfy { row in menu.statistics[row.path]?.isSubmodule != true && !menu.conflicts.contains(where: { $0.path == row.path && $0.isSubmodule }) }
        switch command {
        case .log: return menu.rows.count == 1
        case .oldNameLog: return menu.rows.count == 1 && menu.rows[0].originalPath != nil
        case .blame: return menu.rows.count == 1 && ordinary && menu.rows[0].state != .deleted && menu.rows[0].state != .added
        case .editor, .open, .openWith: return menu.rows.count == 1 && ordinary && menu.rows[0].state != .deleted
        case .export: return ordinary && menu.rows.allSatisfy { $0.state != .deleted }
        case .reveal: return menu.rows.count == 1 && menu.rows[0].state != .deleted
        case .compareTwo: return menu.rows.count == 2 && ordinary && menu.rows.allSatisfy { $0.state != .deleted }
        case .submoduleLog, .delete: return false
        }
    }
    private func validateConflictFileMenu(_ menu: ConflictFileMenu, token: OperationCancellation) async throws {
        try requireAccess(); try token.check()
        guard acceptsConflictFileMenu(menu, duringRequest: true) else { throw RebaseFailure.changed }
        let fresh = try await readSession(menu.identity, token)
        guard fresh.identity == menu.identity, fresh.head == menu.head, fresh.fileRecovery,
              menu.rows.allSatisfy({ fresh.rows.contains($0) }),
              menu.conflicts.allSatisfy({ fresh.conflicts.contains($0) }) else { throw RebaseFailure.changed }
        try token.check(); guard acceptsConflictFileMenu(menu, duringRequest: true) else { throw RebaseFailure.changed }
    }
    private func conflictLocation(_ path: String) throws -> URL {
        _ = try RemovalRequest(paths: [path], keepLocal: true)
        let location = repository.root.appendingPathComponent(path).standardizedFileURL
        guard RepositoryAccessLease.pathIsContained(location.deletingLastPathComponent(), by: repository.root) else { throw ResolveFailure.outsideWorkingTree }
        return location
    }
    private func runConflictFileMenu(_ menu: ConflictFileMenu, operation: @escaping (OperationCancellation) async throws -> Void) {
        guard acceptsConflictFileMenu(menu) else { return }
        let token = OperationCancellation(); conflictFileCancellation = token; preparingConflictFiles = true; cancellingPreparation = false; busy = true; error = nil
        Self.activePreparationReads += 1
        Task {
            defer {
                Self.activePreparationReads -= 1; withExtendedLifetime(access) {}
                if conflictFileCancellation === token { conflictFileCancellation = nil; preparingConflictFiles = false; cancellingPreparation = false; if !retired { busy = false; loadPendingHandoff() } }
            }
            do { try await validateConflictFileMenu(menu, token: token); try await operation(token) }
            catch { if !retired, !token.isCancelled, conflictFileCancellation === token { self.error = error.localizedDescription } }
        }
    }
    func conflictFileCommand(_ command: StatusFileCommand, menu: ConflictFileMenu) {
        guard canConflictFileCommand(command, menu: menu) else { return }
        runConflictFileMenu(menu) { [self] token in
            switch command {
            case .log: onConflictFileLog(menu.paths[0])
            case .oldNameLog: if let old = menu.rows[0].originalPath { onConflictFileLog(old) }
            case .blame: onConflictFileBlame(menu.paths[0], menu.head)
            case .compareTwo: onConflictWorkingPair(menu.paths)
            case .reveal: revealConflictFiles(try menu.paths.map(conflictLocation))
            case .open, .openWith, .editor:
                let application = command == .openWith ? await chooseConflictApplication() : nil
                guard command != .openWith || application != nil else { return }
                try await validateConflictFileMenu(menu, token: token)
                let location = try conflictLocation(menu.paths[0])
                let type = try FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeSymbolicLink else { throw WorkingFileRestoreFailure.unsupported }
                let grant = application.map { RepositoryAccessLease(url: $0) }
                if GitRuntime.isAppStoreBuild, application != nil, grant?.hasSecurityScope != true { throw RepositoryAccessFailure.securityScopeUnavailable }
                defer { withExtendedLifetime(grant) {} }
                if command == .editor { try await openConflictAlternativeEditor(location) } else { try await openConflictWorkingFile(location, application) }
            case .export:
                guard let folder = await chooseConflictExport() else { return }
                let permission = RepositoryAccessLease(url: folder); defer { withExtendedLifetime(permission) {} }
                if GitRuntime.isAppStoreBuild && (!permission.hasSecurityScope || !permission.contains(folder)) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await validateConflictFileMenu(menu, token: token)
                let count = try await repository.exportWorkingFiles(paths: menu.paths, to: folder, cancellation: token)
                guard !retired, !token.isCancelled else { return }; output += "Exported \(count) files.\n"
            case .submoduleLog, .delete: break
            }
        }
    }
    func compareConflictWorkingFiles(_ menu: ConflictFileMenu) {
        guard acceptsConflictFileMenu(menu), menu.rows.allSatisfy({ $0.state != .conflicted }) else { return }
        runConflictFileMenu(menu) { [self] token in try token.check(); onConflictWorkingComparison(menu.paths) }
    }
    func conflictClipboardText(_ menu: ConflictFileMenu, copy: StatusListCopy) -> String {
        let files = menu.rows.map { entry in
            let statistics = menu.statistics[entry.path]
            return CommitFile(path: entry.path, oldPath: entry.originalPath, action: statistics?.action ?? "M", added: statistics?.added, removed: statistics?.removed, hasStatistics: statistics?.hasStatistics ?? false, isSubmodule: statistics?.isSubmodule ?? false)
        }
        let statuses = Dictionary(uniqueKeysWithValues: zip(files, menu.rows).map { ($0.0.id, $0.1.state.rawValue.capitalized) })
        return StatusListClipboard.text(files, root: repository.root, statuses: statuses, copy: copy)
    }
    func copyConflictFiles(_ menu: ConflictFileMenu, copy: StatusListCopy) {
        guard acceptsConflictFileMenu(menu) else { return }; let text = conflictClipboardText(menu, copy: copy)
        guard !text.isEmpty else { return }; conflictPasteboard.clearContents(); conflictPasteboard.setString(text, forType: .string)
    }
    func toggleConflictChecks(_ ids: Set<String>, mark: String?) {
        guard !retired, !busy, !selectingSplit, fileRecovery, supportsConflictSelection else { return }
        let available = Set(conflictRows.map(\.id)), selected = ids.intersection(available)
        guard !selected.isEmpty else { return }
        let shouldCheck = !(mark.map { checkedConflicts.contains($0) } ?? selected.allSatisfy { checkedConflicts.contains($0) })
        if shouldCheck { checkedConflicts.formUnion(selected) } else { checkedConflicts.subtract(selected) }
    }
    func conflictAction(_ action: RepositoryAction, ids: Set<String>) { conflictAction(action, menu: conflictFileMenu(ids)) }
    func conflictAction(_ action: RepositoryAction, menu: ConflictFileMenu) {
        let paths = menu.conflicts.map(\.path)
        guard acceptsConflictFileMenu(menu), !paths.isEmpty, action != .editConflict || paths.count == 1 && menu.rows.count == 1 else { return }
        runConflictFileMenu(menu) { [self] token in
            try token.check(); guard !retired else { return }; onConflictAction(action, paths)
        }
    }
    func compareConflictMenu(_ menu: ConflictFileMenu) {
        guard acceptsConflictFileMenu(menu) else { return }; compareConflicts(Set(menu.conflicts.map(\.id)))
    }
    func compareConflicts(_ ids:Set<String>) {
        let paths=conflicts.filter {ids.contains($0.id)}.map(\.path)
        guard !retired,!busy,!selectingSplit,!paths.isEmpty else {return}
        let captured=conflictIdentity,request=UUID(),token=OperationCancellation()
        conflictDiffGeneration=request;conflictDiffCancellation=token;preparingConflictDiff=true;cancellingPreparation=false;busy=true
        Self.activePreparationReads += 1
        Task {
            defer {
                Self.activePreparationReads -= 1;withExtendedLifetime(access) {}
                if conflictDiffCancellation === token {conflictDiffCancellation=nil;preparingConflictDiff=false;cancellingPreparation=false;if !retired {busy=viewingConflictBase;if !viewingConflictBase {loadPendingHandoff()}}}
            }
            do {
                try requireAccess()
                let fresh=try await repository.rebaseState(cancellation:token)
                guard RebaseConflictIdentity(fresh) == captured else {throw RebaseFailure.changed}
                if paths.count == 1, let entry = conflicts.first(where: { $0.path == paths[0] }), !entry.isSubmodule, entry.stages.contains(where: { $0.number == 1 }) {
                    let prepared = try await repository.conflictBaseComparison(entry, cancellation: token)
                    let current = try await repository.rebaseState(cancellation: token)
                    guard RebaseConflictIdentity(current) == captured else { throw RebaseFailure.changed }
                    guard !retired, !token.isCancelled, conflictDiffGeneration == request, conflictIdentity == captured else { return }
                    onConflictBaseComparison(prepared); return
                }
                let patch=try await repository.run(["diff","--no-ext-diff","--no-textconv","--no-color","--base","--"]+paths,cancellation:token).text
                let current=try await repository.rebaseState(cancellation:token)
                guard RebaseConflictIdentity(current) == captured else {throw RebaseFailure.changed}
                guard !retired,!token.isCancelled,conflictDiffGeneration == request,conflictIdentity == captured else {return}
                conflictPatch=patch
            } catch {if !retired,!token.isCancelled,conflictDiffGeneration == request {self.error=error.localizedDescription}}
        }
    }
    private var completion = "Rebase finished"
    private var pendingLoad: (upstream: String?, autoStart: Bool, preserveMerges: Bool, cherryPick: [String]?)?
    private func loadPendingHandoff() {
        guard !retired,!busy,pickingReference == nil,!pickingCommits,!selectingSplit else {return}
        if pendingSessionRefresh {pendingSessionRefresh=false;refreshState();return}
        guard let pending=pendingLoad else {return}
        pendingLoad = nil
        load(upstream: pending.upstream, autoStart: pending.autoStart, preserveMerges: pending.preserveMerges, cherryPick: pending.cherryPick)
    }
    var active: Bool { state?.active == true }
    var editable: Bool { !retired && !busy && pickingReference == nil && !active && !finished && !pickingCommits && !selectingSplit }
    var canAdd: Bool { editable && !options.preserveMerges }
    // Upstream displays newest first, while replay proceeds from the oldest commit.
    var entries: [RebaseEntry] {
        if active || finished && !replayRows.isEmpty { return replayRows.reversed() }
        if plan?.disposition == .upToDate || plan?.disposition == .equal { return [] }
        return Array((plan?.entries ?? draftEntries).reversed())
    }
    func entryNumber(_ entry: RebaseEntry) -> Int {
        if active || finished && !replayRows.isEmpty { return (replayRows.firstIndex(where: { $0.id == entry.id }) ?? 0) + 1 }
        return ((plan?.entries ?? draftEntries).firstIndex(where: { $0.id == entry.id }) ?? 0) + 1
    }
    private func restoreSessionContext() {
        guard let context = state?.session else { return }
        completionFromLog = context.fromLog ?? false; completionAfterFetch = context.afterFetch; completionAutoStart = context.autoStart
        options.branch = context.branch; options.upstream = context.upstream; options.onto = context.onto
        options.force = context.force; options.preserveMerges = context.preserveMerges; ontoEnabled = !context.onto.isEmpty
    }
    var completionActions: [RebaseCompletionAction] {
        guard finished, completedSuccessfully, !active, !isCherryPick, !completionFromLog else { return [] }
        return completionAfterFetch ? [.log, .push, .mail, .rebase] : [.log, .restart]
    }
    func canPerformCompletionAction(_ action: RebaseCompletionAction) -> Bool {
        guard !busy, !pickingCommits, !selectingSplit, revisionMenuAvailable, completionActions.contains(action) else { return false }
        switch action {
        case .log: return onCompletedLog != nil
        case .push: return onCompletedPush != nil
        case .mail: return onCompletedMail != nil && !options.upstream.isEmpty
        case .restart, .rebase: return true
        }
    }
    func performCompletionAction(_ action: RebaseCompletionAction) {
        guard canPerformCompletionAction(action) else { return }
        finishReplay { [weak self] in
            guard let self else { return }
            switch action {
            case .log: let callback = self.onCompletedLog; self.close(); callback?()
            case .push: let callback = self.onCompletedPush; self.close(); callback?("HEAD")
            case .mail:
                guard let preset = FormatPatchPreset(startRevision: self.options.upstream, endRevision: self.options.branch) else { return }
                let callback = self.onCompletedMail; self.close(); callback?(preset)
            case .restart: self.load()
            case .rebase: self.load(upstream: self.options.upstream, autoStart: self.completionAutoStart, preserveMerges: self.options.preserveMerges)
            }
        }
    }

    var canStart: Bool { editable && !loadingPlan && plan != nil && plan?.disposition != .upToDate && plan?.disposition != .equal && plan?.entries.first(where: { $0.action != .skip })?.action != .squash }
    var primaryActionTitle: String {
        if finished { return "Done" }
        if !active { return startTitle }
        if state?.squashMessage?.skipBaseHead != nil { return "Continue" }
        if state?.squashMessage != nil { return "Commit" }
        if state?.isEditPause == true { return "Amend" }
        if fileRecovery && supportsConflictSelection && state?.split == nil { return "Commit" }
        return "Continue"
    }
    var status: String {
        if finished { return completion }
        if state?.squashMessage?.skipBaseHead != nil { return "Continue retries the approved empty-group Skip." }
        if state?.squashMessage != nil { return "Edit the combined commit message, then Commit." }
        if active { return "Step \(state?.currentStep ?? 0) of \(state?.total ?? 0) • \(state?.conflicts.count ?? 0) unresolved paths" }
        if plan == nil { return "Choose valid branch and upstream revisions before starting." }
        switch plan?.disposition {
        case .equal: return "Branch and upstream are the same revision."
        case .upToDate: return "Branch is up to date. Enable Force Rebase to replay its commits."
        case .fastForward: return "The branch can fast-forward to upstream."
        default: return "\(plan?.entries.count ?? 0) commits in the \(operationTitle.lowercased()) plan"
        }
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, messageDefaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.messageDefaults = messageDefaults
        readColumnMetadata = { try await repository.replayColumnMetadata($0,cancellation:$1) }
        readPlan = { try await repository.rebasePlan($0, cancellation: $1) }
        readSession={try await repository.rebaseSessionSnapshot(retaining:$0,cancellation:$1)}
        validateOnto = { try await repository.rebaseOntoSelection($0, branch: $1, upstream: $2, cancellation: $3) }
        self.fullCommitMessageOnLogLine = messageDefaults.bool(forKey: "FullCommitMessageOnLogLine")
    }
    var revisionMenuAvailable: Bool { !retired && !busy && !selectingSplit && !pickingCommits && revisionMenuLog.noteRequest == nil && !revisionMenuLog.busy && !revisionMenuLog.loadingNote && !revisionMenuLog.savingNote && !revisionMenuLog.copyingDetails }
    func revisionMenuRows(_ ids: Set<String>) -> [RebaseEntry] { entries.filter { ids.contains($0.id) } }
    @discardableResult func prepareRevisionMenu(_ ids: Set<String>) -> LogWindowModel? {
        let rows = revisionMenuRows(ids)
        guard revisionMenuAvailable, !rows.isEmpty, rows.count == ids.count else { return nil }
        revisionMenuLog.entries = rows.map(\.commit)
        revisionMenuLog.selected = Set(rows.map { $0.commit.hash })
        return revisionMenuLog
    }
    func revisionMenuPatchPreset(_ ids: Set<String>) -> FormatPatchPreset? {
        let indexes = entries.indices.filter { ids.contains(entries[$0].id) }
        guard !indexes.isEmpty, indexes.count == ids.count else { return nil }
        if indexes.count == 1 { return FormatPatchPreset(startRevision: entries[indexes[0]].commit.hash) }
        guard indexes.count <= 2 || indexes.last! - indexes.first! + 1 == indexes.count else { return nil }
        return FormatPatchPreset(startRevision: entries[indexes.last!].commit.hash + "~1", endRevision: entries[indexes.first!].commit.hash)
    }
    func canPerformRevisionMenu(_ command: RebaseRevisionCommand, ids: Set<String>) -> Bool {
        let rows = revisionMenuRows(ids), one = rows.count == 1
        guard revisionMenuAvailable, !rows.isEmpty, rows.count == ids.count else { return false }
        switch command {
        case .workingTree: return one && !revisionMenuLog.bare && revisionMenuLog.onCompare != nil
        case .compare: return rows.count <= 2 && revisionMenuLog.onCompare != nil
        case .unified: return rows.count <= 2 && !revisionMenuLog.unifiedViewerBusy
        case .log: return one && onShowRevisionLog != nil
        case .browse: return one && revisionMenuLog.onBrowseRepository != nil
        case .branch, .tag, .push: return one
        case .notes: return one && revisionMenuLog.noteRequest == nil
        case .patch: return revisionMenuPatchPreset(ids) != nil && revisionMenuLog.onFormatPatch != nil
        default: return true
        }
    }
    func performRevisionMenu(_ command: RebaseRevisionCommand, ids: Set<String>, alternate: Bool = false) {
        guard canPerformRevisionMenu(command, ids: ids), let log = prepareRevisionMenu(ids) else { return }
        switch command {
        case .workingTree: log.compare(workingTree: true)
        case .compare: log.compare()
        case .unified: log.diff(alternate: alternate)
        case .log: if let revision = log.revision { onShowRevisionLog?(revision.hash) }
        case .browse: if let revision = log.revision { log.onBrowseRepository?(revision.hash) }
        case .branch: log.request(.branch)
        case .tag: log.request(.tag)
        case .push: log.request(.push)
        case .notes: log.editNotes()
        case .patch: if let preset = revisionMenuPatchPreset(ids) { log.onFormatPatch?(preset) }
        case .details: log.copyDetails()
        case .detailsWithoutPaths: log.copyDetails(includePaths: false)
        case .hashes: log.copy(log.revisions.map(\.hash).joined(separator: "\n"))
        case .authors: log.copy(log.revisions.map { "\($0.author) <\($0.email)>" }.joined(separator: "\n"))
        case .authorNames: log.copy(log.revisions.map(\.author).joined(separator: "\n"))
        case .authorEmails: log.copy(log.revisions.map(\.email).joined(separator: "\n"))
        case .subjects: log.copy(log.revisions.map(\.subject).joined(separator: "\n"))
        case .messages: log.copy(log.revisions.map(\.message).joined(separator: "\n\n"))
        }
    }
    func refreshColumnMetadata(force: Bool = false) {
        guard !retired else { return }
        let commits = entries.map(\.commit), signature = Array(Set(entries.map { $0.commit.hash + "\0" + $0.commit.message })).sorted()
        guard force || signature != columnSignature else { return }
        columnSignature = signature; columnToken?.cancel()
        let request = UUID(), token = OperationCancellation(), read = readColumnMetadata
        columnGeneration = request; columnToken = token; loadingColumnMetadata = true; Self.activeColumnReads += 1
        Task { [weak self, access] in
            defer {
                Self.activeColumnReads -= 1; withExtendedLifetime(access) {}
                if let self, self.columnToken === token { self.columnToken = nil; self.loadingColumnMetadata = false }
            }
            do {
                guard let self else { return }; try self.requireAccess()
                let result = try await read(commits,token)
                guard !self.retired, self.columnGeneration == request, !token.isCancelled else { return }
                self.showsIssueColumn = result.showsIssueIDs; self.hasGitSVN = result.hasGitSVN
                self.issueColumnValues = result.issueIDs; self.svnColumnValues = result.svnRevisions
            } catch {
                guard let self, !self.retired, self.columnGeneration == request, !token.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
    private func preparedRead<T>(_ token: OperationCancellation, _ read: () async throws -> T) async throws -> T {
        try token.check(); let value = try await read()
        if retired { token.cancel() }; try token.check(); return value
    }
    func load(upstream: String? = nil, autoStart: Bool = false, preserveMerges: Bool = false, cherryPick: [String]? = nil) {
        guard !retired else { return }
        if hasReplayStash && !active && !busy {
            finishReplay { [weak self] in self?.load(upstream: upstream, autoStart: autoStart, preserveMerges: preserveMerges, cherryPick: cherryPick) }
            return
        }
        guard !busy, pickingReference == nil, !pickingCommits, !selectingSplit else {
            if upstream != nil || cherryPick != nil { pendingLoad = (upstream, autoStart, preserveMerges, cherryPick) }
            return
        }; planCancellation?.cancel(); detailCancellation?.cancel(); planSignature = nil
        let token = OperationCancellation(); initialCancellation = token; cancellingPreparation = false; Self.activePreparationReads += 1
        busy = true; planGeneration += 1; detailGeneration += 1
        Task {
            var started = false
            defer { Self.activePreparationReads -= 1; withExtendedLifetime(access) {}; if initialCancellation === token { initialCancellation = nil; cancellingPreparation = false }; if !started && !retired { busy = false; refreshColumnMetadata(force:true); loadPendingHandoff() } }
            do {
                try requireAccess()
                projectSettings = try await preparedRead(token) { try await repository.projectDialogSettings(source: .effective, cancellation: token) }
                revisionMenuLog.bare = try await preparedRead(token) { try await repository.isBare(cancellation: token) }
                references = try await preparedRead(token) { try await repository.checkoutReferences(includeFetchHead:true,cancellation:token) }
                let session=try await preparedRead(token) {try await readSession(conflictIdentity,token)}
                applyConflictSnapshot(session);finished=false;completedSuccessfully=false;output="";error=nil;confirmation=nil;draftEntries=[]
                if fileRecovery {tab=0}
                if active { splitCommit = state?.split != nil && state?.split?.conflictRecovery != true; options.isCherryPick = state?.isCherryPick == true; onModeChanged(); options.branch = state?.branch ?? "HEAD"; options.upstream = state?.onto ?? ""; restoreSessionContext(); plan = nil; recovered=session.remaining;replayRows=session.replay; selection = Set(recovered.first.map { [$0.id] } ?? []); amendMessage = state?.squashMessage?.message ?? state?.message ?? ""; if state?.squashMessage != nil || state?.isEditPause == true { tab = 1 }; if amendMessage.isEmpty, let commit = recovered.first { amendMessage = commit.commit.message }; selectCommit(); return }
                finished = false; plan = nil; recovered = []; replayRows = []; selection = []; files = []; message = ""; options = RebaseOptions(); options.preserveMerges = preserveMerges; ontoEnabled = false
                if let cherryPick {
                    plan = try await preparedRead(token) { try await repository.cherryPickPlan(revisions: cherryPick, cancellation: token) }
                    options = plan!.options
                    options.addCherryPickedFrom = messageDefaults.bool(forKey: "CherrypickAddCherryPickedFrom")
                    updateAttribution()
                    options.squashDate = RebaseSquashDate(rawValue: messageDefaults.integer(forKey: "SquashDate")) ?? .first
                    plan?.options.squashDate = options.squashDate
                    onModeChanged(); selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit(); return
                }
                onModeChanged()
                options.squashDate = RebaseSquashDate(rawValue: messageDefaults.integer(forKey: "SquashDate")) ?? .first
                let branch = try await preparedRead(token) { try await repository.branch(cancellation: token) }; options.branch = branch.isEmpty ? "HEAD" : "refs/heads/" + branch
                let defaults = try await preparedRead(token) { try await repository.pullDefaults(cancellation: token) }
                options.upstream = upstream ?? (defaults.trackedRemote.isEmpty || defaults.trackedBranch.isEmpty ? "" : "refs/remotes/" + defaults.trackedRemote + "/" + defaults.trackedBranch)
                if !options.upstream.isEmpty { plan = try await preparedRead(token) { try await readPlan(options, token) }; selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit() }
                busy = false
                if autoStart && canStart { started = true; execute("start") }
            } catch { if !retired, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func reloadPlan(force: Bool = false) {
        guard editable, !isCherryPick else { return }
        var snapshot = options; if !ontoEnabled { snapshot.onto = "" }
        let signature = Data([snapshot.branch, snapshot.upstream, snapshot.onto, String(snapshot.force), String(snapshot.preserveMerges), String(snapshot.squashDate.rawValue)].joined(separator: "\0").utf8)
        if !force, planCancellation?.isCancelled != true, planSignature == signature, loadingPlan || plan != nil { return }
        planCancellation?.cancel(); detailCancellation?.cancel(); planGeneration += 1; detailGeneration += 1
        let request = planGeneration, token = OperationCancellation(); planCancellation = token; planSignature = signature
        plan = nil; draftEntries = []; selection = []; files = []; message = ""
        guard !snapshot.branch.isEmpty, !snapshot.upstream.isEmpty else { planCancellation = nil; loadingPlan = false; return }
        loadingPlan = true; cancellingPreparation = false; Self.activePreparationReads += 1
        Task {
            defer {
                Self.activePreparationReads -= 1; withExtendedLifetime(access) {}
                if planCancellation === token { planCancellation = nil; loadingPlan = false; cancellingPreparation = false }
            }
            do {
                try requireAccess(); let value = try await readPlan(snapshot, token)
                guard !retired, request == planGeneration, planCancellation === token, !token.isCancelled, editable else { return }
                plan = value; selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit()
            } catch RebaseFailure.revision { /* Incomplete or unavailable reference: keep Start unavailable. */ }
            catch { if !retired, request == planGeneration, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func requireAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func updateAttribution() {
        guard isCherryPick, var value = plan, !active else { return }
        value.options.addCherryPickedFrom = options.addCherryPickedFrom
        plan = value
        messageDefaults.set(options.addCherryPickedFrom, forKey: "CherrypickAddCherryPickedFrom")
    }
    private func prepareCherryPick() {
        guard canStart, var snapshot = plan else { return }
        busy = true
        Task {
            do {
                try requireAccess()
                for index in snapshot.entries.indices where snapshot.entries[index].action != .skip && snapshot.entries[index].commit.parents.count > 1 {
                    let commit = snapshot.entries[index].commit
                    let choices = try await repository.logParentChoices(commit)
                    guard let parent = await chooseMainline(commit, choices) else { busy = false; loadPendingHandoff(); return }
                    snapshot.entries[index].mainline = parent
                }
                plan = snapshot; busy = false; execute("start")
            } catch { busy = false; self.error = error.localizedDescription; loadPendingHandoff() }
        }
    }
    func finishPickingCommits(_ revisions: [String]?) {
        pickingCommits = false
        if let revisions, !revisions.isEmpty { addCommits(revisions) }
        else { loadPendingHandoff() }
    }
    func addCommits(_ revisions: [String]) {
        guard canAdd, !revisions.isEmpty else { return }
        let snapshot = plan, draft = draftEntries
        var settings = options; if !ontoEnabled { settings.onto = "" }
        planCancellation?.cancel(); busy = true; planGeneration += 1; detailGeneration += 1
        Task {
            defer { busy = false; loadPendingHandoff() }
            do {
                try requireAccess()
                let added: [RebaseEntry]
                if let snapshot {
                    let value = try await repository.addingRebaseCommits(snapshot, revisions: revisions)
                    plan = value; added = value.entries
                } else {
                    let draftResult = try await repository.addingRebaseEntries(draft, revisions: revisions)
                    var captured: RebasePlan?
                    do { captured = try await repository.rebasePlan(settings) }
                    catch RebaseFailure.revision { /* Draft Add is available before references are complete. */ }
                    if let captured {
                        let value = try await repository.addingRebaseCommits(captured, revisions: draftResult.reversed().map { $0.commit.hash })
                        plan = value; draftEntries = []; added = value.entries
                    } else { draftEntries = draftResult; added = draftResult }
                }
                selection = Set(added.suffix(revisions.count).map(\.id)); selectCommit()
            } catch { self.error = error.localizedDescription }
        }
    }
    func setAction(_ action: RebaseAction, ids: Set<String>? = nil) {
        guard !retired, editable else { return }
        var values = plan?.entries ?? draftEntries
        let targets = ids ?? selection
        for index in values.indices where targets.contains(values[index].id) {
            guard !options.preserveMerges || action != .squash || values[index].commit.parents.count == 1 else { continue }
            values[index].action = action
        }
        if plan != nil { plan?.entries = values } else { draftEntries = values }
    }
    struct RowDrag { let owner: UUID; let generation: Int; let rows: ReplayRowDrag }
    private let rowDragOwner = UUID()
    var canDragRows: Bool { !retired && editable && revisionMenuAvailable && revisionMenuLog.window?.attachedSheet == nil }
    func beginRowDrag(_ ids: Set<String>) -> RowDrag? {
        guard canDragRows, let rows = ReplayRowDrag(visible:entries,selected:ids) else { return nil }
        selection = ids
        return RowDrag(owner:rowDragOwner,generation:planGeneration,rows:rows)
    }
    func canDropRows(_ drag: RowDrag, before destination: Int) -> Bool {
        canDragRows && drag.owner == rowDragOwner && drag.generation == planGeneration && drag.rows.canDrop(visible:entries,before:destination)
    }
    @discardableResult func dropRows(_ drag: RowDrag, before destination: Int) -> Bool {
        guard canDropRows(drag,before:destination), let values = drag.rows.reordered(visible:entries,before:destination) else { return false }
        if plan != nil { plan?.entries = Array(values.reversed()) } else { draftEntries = Array(values.reversed()) }
        selection = drag.rows.selected; selectCommit(); return true
    }
    func canMove(up: Bool, toEnd: Bool = false) -> Bool {
        guard !retired, editable else { return false }
        let visible = entries
        let indexes = visible.indices.filter { selection.contains(visible[$0].id) }
        guard let first = indexes.first, let last = indexes.last else { return false }
        if toEnd { return up ? indexes != Array(0..<indexes.count) : indexes != Array((visible.count - indexes.count)..<visible.count) }
        return up ? first > 0 : last < visible.count - 1
    }
    func move(up: Bool, toEnd: Bool = false) {
        guard canMove(up: up, toEnd: toEnd) else { return }
        var visible = entries
        if toEnd {
            let selected = visible.filter { selection.contains($0.id) }, others = visible.filter { !selection.contains($0.id) }
            visible = up ? selected + others : others + selected
        } else {
            let indexes = visible.indices.filter { selection.contains(visible[$0].id) }
            for index in up ? indexes : Array(indexes.reversed()) { visible.swapAt(index, index + (up ? -1 : 1)) }
        }
        if plan != nil { plan?.entries = Array(visible.reversed()) } else { draftEntries = Array(visible.reversed()) }
    }
    func cycleActions() {
        guard !retired, editable else { return }
        var values = plan?.entries ?? draftEntries
        for index in values.indices where selection.contains(values[index].id) {
            if options.preserveMerges {
                switch values[index].action {
                case .pick: values[index].action = .skip
                case .skip: values[index].action = .edit
                case .edit: values[index].action = values[index].commit.parents.count == 1 ? .squash : .pick
                case .squash: values[index].action = .pick
                }
                continue
            }
            switch values[index].action {
            case .pick: values[index].action = .skip
            case .skip: values[index].action = .edit
            case .edit: values[index].action = index == 0 && (isCherryPick || values[index].commit.parents.count == 1) ? .pick : .squash
            case .squash: values[index].action = .pick
            }
        }
        if plan != nil { plan?.entries = values } else { draftEntries = values }
    }
    func selectCommit() {
        guard !retired else { return }; detailCancellation?.cancel()
        if !busy { refreshColumnMetadata() }
        detailGeneration += 1; let request = detailGeneration
        files = []; message = ""
        guard let entry = entries.first(where: { selection.contains($0.id) }) else { return }
        message = entry.commit.message
        let token = OperationCancellation(); detailCancellation = token; Self.activePreparationReads += 1
        Task {
            defer { Self.activePreparationReads -= 1; withExtendedLifetime(access) {}; if detailCancellation === token { detailCancellation = nil } }
            do { try requireAccess(); let changed = try await repository.files(in: entry.commit, cancellation: token); guard !retired, !token.isCancelled, request == detailGeneration else { return }; files = changed }
            catch { if !retired, !token.isCancelled, request == detailGeneration { self.error = error.localizedDescription } }
        }
    }
    func refreshState() {
        guard !retired,pickingReference == nil,!selectingSplit,!pickingCommits else {return}
        if busy {pendingSessionRefresh=true;return}
        let request=UUID(),token=OperationCancellation(),previous=conflictIdentity,wasActive=active
        sessionGeneration=request;sessionCancellation=token;refreshingSession=true;cancellingPreparation=false;busy=true
        Self.activePreparationReads += 1
        Task {
            defer {
                Self.activePreparationReads -= 1;withExtendedLifetime(access) {}
                if sessionCancellation === token {sessionCancellation=nil;refreshingSession=false;cancellingPreparation=false;if !retired {busy=false;loadPendingHandoff()}}
            }
            do {
                try requireAccess();let snapshot=try await readSession(previous,token)
                guard !retired,!token.isCancelled,sessionGeneration == request else {return}
                applyConflictSnapshot(snapshot);conflictPatch=nil;onModeChanged()
                if active {
                    restoreSessionContext();recovered=snapshot.remaining;replayRows=snapshot.replay
                    amendMessage=state?.squashMessage?.message ?? state?.message ?? ""
                    if state?.squashMessage != nil || state?.isEditPause == true {tab=1}
                    selectCommit()
                } else if wasActive {finished=true;completedSuccessfully=false;completion="\(operationTitle) session ended";recovered=[];replayRows=[];selection=[];files=[];message=""}
                onChanged()
            } catch {if !retired,!token.isCancelled,sessionGeneration == request {self.error=error.localizedDescription}}
        }
    }
    func request(_ action: String) {
        if action == "continue", splitCommit || state?.split != nil && state?.split?.conflictRecovery != true { beginSplitSelection(); return }
        if action == "continue", state?.split?.conflictRecovery == true { resumeConflictSelection(); return }
        if action == "start", isCherryPick { prepareCherryPick(); return }
        if action == "start" { guard canStart else { return }; confirmation = "Start rewriting the selected branch using this commit plan?" }
        else if action == "abort" { confirmation = "Abort this \(operationTitle.lowercased()) and restore its original branch? Current conflict-resolution edits will be discarded." }
        else if action == "skip" { confirmation = "Skip the current commit? Its changes and current conflict-resolution edits will be discarded." }
        else { execute(action) }
    }
    func execute(_ action: String) {
        guard !retired, !busy, !pickingCommits, !selectingSplit, action != "start" || canStart else { return }
        let snapshot = plan; busy = true; tab = 2
        let preparation = OperationCancellation(); replayPreparationCancellation = preparation
        Task {
            var followRecovery = false, followEmpty = false, finishingReplay = false
            var skippedID = action == "skip" ? state?.stoppedEntryID : nil
            defer { replayPreparationCancellation = nil; if !finishingReplay { busy = false }; if followEmpty { execute("continue") } else if followRecovery { resumeConflictSelection(afterCommit: true) } else { loadPendingHandoff() } }
            do {
                try requireAccess()
                let result: RebaseExecution
                switch action {
                case "start": guard let snapshot, let executable = editorExecutable else { throw RebaseFailure.plan }
                    let condition = try await repository.replayStashCondition(cherryPick: snapshot.options.isCherryPick, cancellation: preparation)
                    if condition.dirty {
                        let accepted = condition.automatic ? true : await chooseStashBeforeReplay()
                        guard !retired, accepted else { return }
                        let saved = try await repository.saveStash(StashSaveOptions(), cancellation: preparation)
                        guard !retired else { return }
                        output += saved.output + "\n"; onChanged()
                        if saved.created { hasReplayStash = true }
                    }
                    guard !retired else { return }
                    if !snapshot.options.isCherryPick {
                        _ = try await clientHooks.run(.preRebase, repository: repository, access: access, upstream: snapshot.options.upstream, rebasedBranch: snapshot.options.branch, cancellation: preparation, allowContinue: true)
                    }
                    guard !retired else { return }
                    replayRows = snapshot.entries; result = try await repository.startRebase(snapshot, editorExecutable: executable, afterFetch: completionAfterFetch, autoStart: completionAutoStart, fromLog: completionFromLog)
                case "abort": result = try await repository.abortRebase()
                case "skip": result = try await repository.skipRebase()
                default:
                    let rawText = amendMessage, paths = checkedConflicts, head = conflictHead
                    let stripComments = messageDefaults.bool(forKey: "StripCommentedLines")
                    let text = try await repository.prepareCommitMessageFile(rawText, stripComments: stripComments, sanitize: messageDefaults.object(forKey: "SanitizeCommitMsg") as? Bool ?? true).contents
                    if fileRecovery, state?.split == nil, !messageDefaults.bool(forKey: "CommitMessageContainsConflictHint"), try await repository.rebaseMessageContainsConflictHints(rawText, stripComments: stripComments) {
                        guard await confirmConflictHints() else { tab = 1; return }
                    }
                    if state?.squashMessage?.skipBaseHead != nil { result = try await repository.continueRebase() }
                    else if state?.squashMessage != nil, state?.split == nil, try await repository.rebaseSquashIsEmpty() {
                        let capturedState = state, capturedHead = try await repository.rebaseCommit("HEAD").hash
                        let choice = await chooseEmptyResult()
                        if choice == .cancel { tab = 1; return }
                        result = try await repository.continueRebase(squashMessage: text, emptySquashChoice: choice, expectedSquashHead: capturedHead, expectedSquashState: capturedState)
                    } else if fileRecovery, supportsConflictSelection, state?.split == nil, let captured = state {
                        let empty = try await repository.rebaseConflictSelectionIsEmpty(paths: paths, expected: captured, expectedHead: head)
                        let choice = empty ? await chooseEmptyResult() : RebaseEmptyChoice.commit
                        if choice == .cancel { tab = 0; return }
                        if empty, !(try await repository.rebaseConflictSelectionIsEmpty(paths: paths, expected: captured, expectedHead: head)) { throw RebaseFailure.changed }
                        if choice == .skip { skippedID = state?.stoppedEntryID; result = try await repository.skipRebase() }
                        else { result = try await repository.commitRebaseConflictSelection(message: text, paths: paths, expected: captured, expectedHead: head, allowEmpty: empty) }
                    } else { result = try await repository.continueRebase(squashMessage: state?.squashMessage == nil ? nil : text, editMessage: state?.isEditPause == true ? text : nil) }
                }
                guard !retired else { return }
                output += result.output + "\n"; state = result.state; finished = result.exitCode == 0 && !result.state.active; completedSuccessfully = finished && action != "abort"; completion = action == "abort" ? "\(operationTitle) aborted" : "\(operationTitle) finished"
                if result.exitCode == 0, let skippedID { replayRows = replayRows.map { var row = $0; if row.id == skippedID { row.action = .skip }; return row } }
                if finished, action != "abort" { replayRows = replayRows.map { var row = $0; row.progress = .completed; return row } }
                try await loadConflictFiles()
                if active { restoreSessionContext(); recovered = try await repository.remainingRebaseEntries(); replayRows = try await repository.rebaseReplayEntries(); amendMessage = state?.squashMessage?.message ?? state?.message ?? ""; if state?.squashMessage != nil || state?.isEditPause == true { tab = 1 }; if amendMessage.isEmpty, let commit = recovered.first { amendMessage = commit.commit.message }; selection = Set(state?.stoppedEntryID.isEmpty == false ? [state!.stoppedEntryID] : []) }
                if result.exitCode != 0, state?.needsFileRecovery == true, supportsConflictSelection, state?.split == nil, state?.conflicts.isEmpty == true, conflictRows.isEmpty { followEmpty = true; error = nil }
                if result.state.squashMessage != nil { tab = 1 }
                else if fileRecovery { tab = 0; if result.exitCode != 0 && !followEmpty { error = result.output } }
                else if result.exitCode != 0 { error = result.output }
                onChanged()
                if action == "abort", finished { busy = false; finishingReplay = true; finishReplay(); return }
                if action == "continue", state?.split?.conflictRecovery == true { followRecovery = true }
            } catch { if !retired { self.error = error.localizedDescription } }
        }
    }
    var canSplit: Bool { !busy && !selectingSplit && state?.canSplit == true }
    func beginSplitSelection() {
        guard canSplit else { return }; busy = true
        Task {
            do { try requireAccess(); let split = try await repository.beginRebaseSplit(); state = try await repository.rebaseState(); busy = false; selectingSplit = true; showSplitSelection(split, amendMessage) }
            catch { busy = false; self.error = error.localizedDescription }
        }
    }
    private func resumeConflictSelection(afterCommit: Bool = false) {
        guard !busy, !selectingSplit, let continuation = state?.split, continuation.conflictRecovery == true else { return }; busy = true
        Task {
            do {
                try requireAccess()
                let remaining = try await repository.rebaseSplitHasRemainingChanges()
                busy = false
                if remaining { selectingSplit = true; showSplitSelection(continuation, amendMessage) }
                else if afterCommit && state?.isEditPause == true { tab = 1 }
                else { execute("continue") }
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }
    func splitSelectionClosed(committed: Bool) {
        guard selectingSplit else { return }; selectingSplit = false; busy = true
        Task {
            do {
                state = try await repository.rebaseState(); splitCommit = state?.split != nil && state?.split?.conflictRecovery != true
                guard committed else { if state?.split?.parts == 0 { try await repository.cancelUnstartedRebaseSplit(); state = try await repository.rebaseState(); splitCommit = false }; busy = false; loadPendingHandoff(); return }
                if state?.split?.conflictRecovery == true {
                    try await loadConflictFiles(); amendMessage = try await repository.rebaseCommit("HEAD").message
                    busy = false; resumeConflictSelection(afterCommit: true); return
                }
                let remaining = try await repository.rebaseSplitHasRemainingChanges()
                let another = remaining ? true : await chooseAnotherSplit()
                busy = false
                if another { beginSplitSelection() }
                else { splitCommit = false; execute("continue") }
            } catch { busy = false; self.error = error.localizedDescription; loadPendingHandoff() }
        }
    }


}
enum RebaseCompletionAction: String, CaseIterable {
    case log = "Show log", restart = "Restart rebase", push = "Push…", mail = "Send Mail…", rebase = "Rebase…"
    var icon: MenuIcon {
        switch self { case .log: return .log; case .push: return .push; case .mail: return .sendMail; case .restart, .rebase: return .rebase }
    }
}

enum RebaseRevisionCommand: String, CaseIterable {
    case workingTree = "Compare with working tree", compare = "Compare with previous revision", unified = "Show changes as unified diff"
    case log = "Show log", browse = "Browse repository", branch = "Create branch at this version…", tag = "Create tag at this version…", push = "Push…", notes = "Edit Notes", patch = "Format Patch…"
    case details = "Full log details", detailsWithoutPaths = "Full log details without changed paths", hashes = "Hashes", authors = "Authors", authorNames = "Author names", authorEmails = "Author emails", subjects = "Subjects", messages = "Messages"
    var icon: MenuIcon {
        switch self {
        case .workingTree, .compare: return .compare
        case .unified: return .unifiedDiff
        case .log: return .log
        case .browse: return .repositoryBrowser
        case .branch: return .branch
        case .tag: return .tag
        case .push: return .push
        case .notes: return .rebaseEdit
        case .patch: return .patch
        default: return .copy
        }
    }
}
struct RebaseRevisionMenu: View {
    @ObservedObject var model: RebaseWindowModel
    @ObservedObject var log: LogWindowModel
    let ids: Set<String>
    var body: some View {
        ForEach(RebaseAction.allCases, id: \.self) { action in
            Button { model.setAction(action, ids: ids) } label: { CommandLabel(title: action == .skip ? "Skip" : action.rawValue.capitalized, icon: action.icon) }
                .disabled(ids.isEmpty || !model.editable || model.options.preserveMerges && action == .squash && model.entries.contains { ids.contains($0.id) && $0.commit.parents.count != 1 })
        }
        if !model.revisionMenuRows(ids).isEmpty {
            Divider()
            ForEach([RebaseRevisionCommand.workingTree, .compare, .unified], id: \.self) { command in commandButton(command) }
            Divider()
            ForEach([RebaseRevisionCommand.log, .browse, .branch, .tag, .push], id: \.self) { command in commandButton(command) }
            Divider()
            ForEach([RebaseRevisionCommand.notes, .patch], id: \.self) { command in commandButton(command) }
            Divider()
            Menu {
                ForEach([RebaseRevisionCommand.details, .detailsWithoutPaths, .hashes, .authors, .authorNames, .authorEmails, .subjects, .messages], id: \.self) { command in commandButton(command) }
            } label: { CommandLabel(title: "Copy to clipboard", icon: .copy) }
                .disabled(!model.revisionMenuAvailable)
        }
    }
    private func commandButton(_ command: RebaseRevisionCommand) -> some View {
        Button { model.performRevisionMenu(command, ids: ids, alternate: NSEvent.modifierFlags.contains(.shift)) } label: { CommandLabel(title: command == .compare && ids.count == 2 ? "Compare revisions" : command.rawValue, icon: command.icon) }
            .disabled(!model.canPerformRevisionMenu(command, ids: ids))
    }
}
struct RebaseRevisionMenuPresentation: ViewModifier {
    @ObservedObject var log: LogWindowModel
    func body(content: Content) -> some View {
        content.alert("Git operation failed", isPresented: Binding(get: { log.error != nil }, set: { if !$0 { log.error = nil } })) {
            Button("OK") { log.error = nil }
        } message: { Text(log.error ?? "") }
    }
}

struct RebaseReplayCell<Content: View>: View {
    @AppStorage("LogFontForLogCtrl") private var useLogFont = false
    @AppStorage("LogFontName") private var fontName = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize = MessageEditorFont.defaultSize
    let entry: RebaseEntry
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .font(useLogFont ? Font(MessageEditorFont.resolve(name: fontName, size: fontSize)) : nil)
            .foregroundStyle(entry.progress == .completed || entry.action == .skip ? Color.secondary : Color.primary)
            .fontWeight(entry.progress == .current ? .bold : .regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(entry.action == .edit ? Color.yellow.opacity(0.16) : entry.action == .squash ? Color.gray.opacity(0.16) : Color.clear)
            .accessibilityValue(entry.progress == .completed ? "Completed" : entry.progress == .current ? "Current" : "Pending")
    }
}

struct RebaseDialog: View {
    @ObservedObject var model: RebaseWindowModel
    @AppStorage("LogFontName") private var fontName = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize = MessageEditorFont.defaultSize
    @AppStorage("LogFontForLogCtrl") private var useLogFont = false
    @AppStorage("LogDateFormat") private var shortDate = true
    @AppStorage("RelativeTimes") private var relativeTimes = false
    @AppStorage("UseSystemLocaleForDates") private var systemDates = true
    private var dates: HistoryDateSettings { .init(shortDate: shortDate, relative: relativeTimes, useSystemLocale: systemDates) }
    private var messageFont: Font { Font(MessageEditorFont.resolve(name: fontName, size: fontSize)) }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                if model.isCherryPick {
                    Text("Branch:"); TextField("", text: .constant("")).disabled(true)
                    Image(nsImage: MenuIcon.reverse.image() ?? NSImage()).resizable().frame(width: 16, height: 16).opacity(0.4)
                    Text("Upstream:"); TextField("", text: .constant("HEAD")).disabled(true)
                    Button("…") {}.disabled(true); Toggle("Onto", isOn: .constant(false)).toggleStyle(.button).disabled(true)
                } else {
                Text("Branch:"); ReferencePopup(references: model.referenceChoices(nil), selection: Binding(get: { model.options.branch }, set: model.chooseBranch), accessibilityLabel: "Branch", displaysIcons: true)
                Button { model.reverseReferences() } label: { Image(nsImage: MenuIcon.reverse.image() ?? NSImage()).resizable().frame(width: 16, height: 16) }.accessibilityLabel("Reverse branch and upstream")
                Text("Upstream:"); ReferencePopup(references: model.referenceChoices(.upstream), selection: Binding(get: { model.options.upstream }, set: model.chooseUpstream), accessibilityLabel: "Upstream", displaysIcons: true)
                Button("…") { model.pickReference(.upstream) }.accessibilityLabel("Browse upstream references")
                Toggle("Onto", isOn: Binding(get: { model.ontoEnabled }, set: { _ in model.pickReference(.onto) })).toggleStyle(.button).help(model.options.onto)
                }
            }.disabled(!model.editable)
            VSplitView {
                VStack(spacing: 8) {
                    Table(model.entries, selection: $model.selection) {
                        TableColumn("REBASE") { entry in RebaseReplayCell(entry: entry) { HStack(spacing: 5) { Image(nsImage: entry.action.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(entry.action == .skip ? "Skip" : entry.action.rawValue.capitalized) } } }.width(90)
                        TableColumn("ID") { entry in RebaseReplayCell(entry: entry) { Text(String(model.entryNumber(entry))).frame(maxWidth: .infinity, alignment: .trailing) } }.width(40)
                        TableColumn("SHA-1") { entry in RebaseReplayCell(entry: entry) { Text(entry.commit.hash).font(useLogFont ? nil : .system(.caption, design: .monospaced)).lineLimit(1) } }.width(95)
                        TableColumn("Message") { entry in RebaseReplayCell(entry: entry) { Text(entry.commit.logLine(fullMessage: model.fullCommitMessageOnLogLine)).lineLimit(1) } }
                        TableColumn("Author") { entry in RebaseReplayCell(entry: entry) { Text(entry.commit.author) } }.width(130)
                        TableColumn("Date") { entry in RebaseReplayCell(entry: entry) { Text(dates.format(entry.commit.date)) } }.width(150)
                        Group {
                        TableColumn("Email") { entry in RebaseReplayCell(entry: entry) { Text(entry.commit.email) } }.width(200)
                        TableColumn("Commit Name") { entry in RebaseReplayCell(entry: entry) { Text(entry.commit.committer) } }.width(130)
                        TableColumn("Commit Email") { entry in RebaseReplayCell(entry: entry) { Text(entry.commit.committerEmail) } }.width(200)
                        TableColumn("Commit Date") { entry in RebaseReplayCell(entry: entry) { Text(dates.format(entry.commit.committerDate)) } }.width(150)
                        TableColumn("Bug-ID") { (entry: RebaseEntry) in RebaseReplayCell(entry:entry) { Text(model.issueColumnValues[entry.commit.hash] ?? "") } }.width(110)
                        TableColumn("SVN Rev") { (entry: RebaseEntry) in RebaseReplayCell(entry:entry) { Text(model.svnColumnValues[entry.commit.hash] ?? "") } }.width(100)
                        }
                    }.background(RebaseColumnLayout(model: model)).background(RebaseListInteraction(model: model)).contextMenu(forSelectionType: String.self) { ids in
                        TurtleGitContextMenu {
                            RebaseRevisionMenu(model: model, log: model.revisionMenuLog, ids: ids)
                        }
                    }
                    HStack {
                        Button("Pick ALL") { model.setAction(.pick, ids: Set(model.entries.map(\.id))) }.disabled(!model.editable)
                        Menu("Options") {
                            ForEach(RebaseAction.allCases.filter { $0 != .skip }, id: \.self) { action in Button { model.setAction(action, ids: Set(model.entries.map(\.id))) } label: { CommandLabel(title: "Select all: " + action.rawValue.capitalized, icon: action.icon) } }
                            Divider()
                            ForEach([RebaseAction.skip, .squash, .edit], id: \.self) { action in Button { model.setAction(action, ids: Set(model.entries.map(\.id)).subtracting(model.selection)) } label: { CommandLabel(title: "Unselected: " + (action == .skip ? "Skip" : action.rawValue.capitalized), icon: action.icon) } }
                        }.disabled(!model.editable)
                        Button("Up") { model.move(up: true, toEnd: NSEvent.modifierFlags.contains(.shift)) }.disabled(!model.canMove(up: true, toEnd: true))
                        Button("Down") { model.move(up: false, toEnd: NSEvent.modifierFlags.contains(.shift)) }.disabled(!model.canMove(up: false, toEnd: true))
                        Button { model.pickAdditionalCommits() } label: { CommandLabel(title: "Add", icon: .add) }.disabled(!model.canAdd)
                        Spacer()
                        if model.isCherryPick { Toggle("add \"cherry picked from\"", isOn: $model.options.addCherryPickedFrom) }
                        else { Toggle("Preserve merges", isOn: $model.options.preserveMerges); Toggle("Force Rebase", isOn: $model.options.force) }
                    }.disabled(!model.editable)
                }.frame(minHeight: 180)
                TabView(selection: $model.tab) {
                    Group {
                    if model.fileRecovery { RebaseConflictFiles(model: model) }
                    else {
                    Table(model.files, selection: $model.selectedFiles) {
                        TableColumn("Path", value: \.path)
                        TableColumn("Extension") { file in Text((file.path as NSString).pathExtension) }.width(70)
                        TableColumn("Status", value: \.status).width(100)
                        TableColumn("Lines added") { file in Text(file.added.map(String.init) ?? "–") }.width(85)
                        TableColumn("Lines removed") { file in Text(file.removed.map(String.init) ?? "–") }.width(95)
                    }.fileListFont()
                    }
                    }.tabItem { Text(model.fileRecovery ? "Conflict Files" : "Revision Files") }.tag(0)
                    Group {
                        if model.fileRecovery || model.state?.squashMessage != nil || model.state?.isEditPause == true || model.state?.split != nil {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.state?.squashMessage != nil ? "Combined commit message:" : "Edit commit message:")
                                ProjectMessageEditor(text: $model.amendMessage, settings: model.projectSettings, label: model.state?.squashMessage != nil ? "Combined commit message" : "Edit commit message")
                                if let squash = model.state?.squashMessage { Text("Author: first commit • Author date: " + (squash.datePolicy == .first ? "first commit" : squash.datePolicy == .latest ? "latest commit" : "current time")).font(.caption) }
                            }.padding(8)
                        } else { ScrollView { Text(model.message).font(messageFont).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8) } }
                    }.tabItem { Text("Commit Message") }.tag(1)
                    OutputView(text: model.output, usesLogFont: true).tabItem { Text("Progress") }.tag(2)
                }.frame(minHeight: 150)
            }
            if model.active {
                HStack { Button("Open Working Tree") { model.onShowStatus() }; Button("Refresh State") { model.refreshState() }; Spacer(); Button("Skip") { model.request("skip") } }
                HStack { if model.state?.canSplit == true { Toggle("Split commit", isOn: $model.splitCommit).disabled(!model.canSplit || model.state?.split != nil) } }
            }
            if model.busy { ProgressView().progressViewStyle(.linear) }
            else { ProgressView(value: model.finished ? 1 : Double(model.state?.currentStep ?? 0), total: model.finished ? 1 : Double(max(model.state?.total ?? 1, 1))) }
            HStack {
                if model.completionActions.isEmpty { Text(model.status).font(.caption) }
                else {
                    HStack(spacing: 0) {
                        Button { model.performCompletionAction(.log) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(!model.canPerformCompletionAction(.log))
                        Menu {
                            ForEach(model.completionActions, id: \.self) { action in
                                Button { model.performCompletionAction(action) } label: { CommandLabel(title: action.rawValue, icon: action.icon) }.disabled(!model.canPerformCompletionAction(action))
                            }
                        } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
                Spacer()
                Button(model.primaryActionTitle) { if model.finished { model.finishReplay() } else { model.request(model.active ? "continue" : "start") } }.keyboardShortcut(.defaultAction).disabled(!model.finished && !model.active && !model.canStart)
                Button(model.active || model.isCherryPick ? "Abort" : "Cancel") { if model.active { model.request("abort") } else { model.finishReplay() } }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(model.helpURL) }
            }
        }.padding(12).disabled(model.busy || model.selectingSplit || model.pickingReference != nil)
        .overlay(alignment: .bottomLeading) {
            if model.hasCancellablePreparation {
                HStack { ProgressView().controlSize(.small); Text(model.refreshingSession ? "Refreshing replay state…":model.preparingConflictFiles ? "Preparing file action…":model.preparingConflictDiff ? "Preparing conflict comparison…":model.loadingPlan ? "Preparing commit plan…" : "Reading references…").font(.caption); Button(model.cancellingPreparation ? "Cancelling…" : "Cancel") { model.cancelPreparation() }.disabled(model.cancellingPreparation) }.padding(12)
            }
        }
        .modifier(RebaseRevisionMenuPresentation(log: model.revisionMenuLog))
        .onChange(of: model.options.addCherryPickedFrom) { _ in model.updateAttribution() }
        .onChange(of: model.options.force) { _ in model.reloadPlan() }
        .onChange(of: model.options.preserveMerges) { _ in model.reloadPlan() }
        .onChange(of: model.busy) { if !$0 { model.refreshColumnMetadata() } }
        .onChange(of: model.selection) { _ in model.selectCommit() }
        .alert(model.operationTitle, isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil }; Button("Open Working Tree") { model.error = nil; model.onShowStatus() } } message: { Text(model.error ?? "") }
        .alert("Confirm " + model.operationTitle, isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })) {
            Button("Continue") { let text = model.confirmation ?? ""; model.confirmation = nil; model.execute(text.hasPrefix("Abort") ? "abort" : text.hasPrefix("Skip") ? "skip" : "start") }
            Button("Cancel", role: .cancel) {}
        } message: { Text(model.confirmation ?? "") }
        .sheet(isPresented: Binding(get: { model.conflictPatch != nil }, set: { if !$0 { model.conflictPatch = nil } })) {
            VStack { Text("Compare with base").font(.headline); OutputView(text: model.conflictPatch ?? "").frame(minWidth: 850, minHeight: 520); Button("Close") { model.conflictPatch = nil }.keyboardShortcut(.cancelAction) }.padding(12)
        }
    }
}
struct RebaseConflictFiles: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: RebaseWindowModel
    var body: some View {
        Table(model.conflictRows, selection: $model.selectedConflicts) {
            TableColumn("✓") { entry in Toggle("Commit \(entry.path)", isOn: Binding(get: { model.checkedConflicts.contains(entry.path) }, set: { if $0 { model.checkedConflicts.insert(entry.path) } else { model.checkedConflicts.remove(entry.path) } })).labelsHidden().toggleStyle(.checkbox).disabled(!model.supportsConflictSelection) }.width(28)
            TableColumn("Path") { entry in HStack(spacing: 5) { Image(nsImage: entry.state.icon.image() ?? NSImage()); Text(entry.path).foregroundStyle(entry.state.textColor) } }
            TableColumn("Extension") { Text(StatusListClipboard.fileExtension($0.path, isDirectory: model.conflictStatistics[$0.path]?.isSubmodule == true)) }.width(70)
            TableColumn("Status") { Text($0.state.rawValue.capitalized).foregroundStyle($0.state.textColor) }.width(110)
            TableColumn("Lines added") { Text(model.conflictStatistics[$0.path]?.added.map(String.init) ?? "–") }.width(85)
            TableColumn("Lines removed") { Text(model.conflictStatistics[$0.path]?.removed.map(String.init) ?? "–") }.width(95)
        }.fileListFont().contextMenu(forSelectionType: String.self) { ids in
            let menu = model.conflictFileMenu(ids)
            TurtleGitContextMenu {
                Button { model.compareConflictMenu(menu) } label: { CommandLabel(title: "Compare with base", icon: .compare) }.disabled(!model.conflicts.contains { ids.contains($0.id) } || model.busy)
                Divider()
                ResolveSelectionMenu(paths: model.conflicts.filter { ids.contains($0.id) }.map(\.path), rebase: true, canEdit: ids.count == 1 && model.conflicts.contains { ids.contains($0.id) }) { action, _ in model.conflictAction(action, menu: menu) }
                Divider()
                ForEach([StatusFileCommand.compareTwo, .log, .oldNameLog, .blame], id: \.self) { command in
                    if model.canConflictFileCommand(command, menu: menu) { Button { model.conflictFileCommand(command, menu: menu) } label: { CommandLabel(title: command.rawValue, icon: command.icon) } }
                }
                Divider()
                ForEach([StatusFileCommand.open, .openWith, .editor, .reveal, .export], id: \.self) { command in
                    if model.canConflictFileCommand(command, menu: menu) { Button { model.conflictFileCommand(command, menu: menu) } label: { CommandLabel(title: command.rawValue, icon: command.icon) } }
                }
                Menu {
                    Button { model.copyConflictFiles(menu, copy: .all) } label: { CommandLabel(title: "Copy all information to clipboard", icon: .copy) }
                    Button { model.copyConflictFiles(menu, copy: .fullPaths) } label: { CommandLabel(title: "Full paths", icon: .copy) }
                    Button { model.copyConflictFiles(menu, copy: .relativePaths) } label: { CommandLabel(title: "Relative paths", icon: .copy) }
                    Button { model.copyConflictFiles(menu, copy: .names) } label: { CommandLabel(title: "File/folder names", icon: .copy) }
                    ForEach(StatusListColumn.defaultColumns, id: \.self) { column in Button { model.copyConflictFiles(menu, copy: .column(column)) } label: { CommandLabel(title: "column '\(column.rawValue)'", icon: .copy) } }
                } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }.disabled(menu.rows.isEmpty || model.busy)
            }
        } primaryAction: { ids in
            if ids.count == 1 && model.conflicts.contains(where: { ids.contains($0.id) }) { model.conflictAction(.editConflict, ids: ids) }
            else { model.compareConflictWorkingFiles(model.conflictFileMenu(ids)) }
        }
        .background(RebaseConflictFileKeys(model: model))
    }
}
/// Scope upstream's unmodified action keys to the AppKit table hosted by this
/// SwiftUI list. Other fields, tables and windows retain their normal key handling.
struct RebaseListInteraction: NSViewRepresentable {
    let model: RebaseWindowModel
    func makeNSView(context: Context) -> Probe { Probe() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Probe, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? nsView.frame.height)
    }
    func updateNSView(_ view: Probe, context: Context) { view.model = model }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stopObserving() }
    final class Probe: NSView {
        weak var model: RebaseWindowModel?
        private var monitor: Any?
        private weak var dragTable: NSTableView?
        private var dragStart: NSPoint?
        private var rowDrag: RebaseWindowModel.RowDrag?
        private(set) var dropIndex: Int?
        private let marker = NSView()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }; return self.observe(event)
            }
        }
        func stopObserving() { cancelRowDrag(); if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { stopObserving() }
        func cancelRowDrag() { marker.removeFromSuperview(); rowDrag = nil; dragStart = nil; dragTable = nil; dropIndex = nil }
        func beginDrag(in table: NSTableView, ids: Set<String>) -> Bool {
            guard let model, window?.attachedSheet == nil, let drag = model.beginRowDrag(ids) else { return false }
            rowDrag = drag; dragTable = table; return true
        }
        func updateDrag(at point: NSPoint) -> Bool {
            guard let table = dragTable, let model, let drag = rowDrag, table.visibleRect.contains(point) else { marker.removeFromSuperview(); dropIndex = nil; return false }
            var adjusted = point; adjusted.y += min(10,table.rowHeight/2)
            var destination = table.row(at:adjusted)
            if destination < 0, table.row(at:point) >= 0 { destination = table.numberOfRows }
            guard destination >= 0, model.canDropRows(drag,before:destination) else { marker.removeFromSuperview(); dropIndex = nil; return false }
            dropIndex = destination
            let y = destination == table.numberOfRows ? table.rect(ofRow:destination-1).maxY : table.rect(ofRow:destination).minY
            marker.wantsLayer = true; marker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            marker.frame = NSRect(x:table.visibleRect.minX,y:y-1,width:table.visibleRect.width,height:2)
            if marker.superview !== table { table.addSubview(marker) }
            marker.setAccessibilityLabel("Insert selected commits here")
            return true
        }
        @discardableResult func finishDrag() -> Bool {
            defer { cancelRowDrag() }
            guard let model, let drag = rowDrag, let destination = dropIndex else { return false }
            let accepted = model.dropRows(drag,before:destination), table = dragTable
            if accepted { DispatchQueue.main.async { [weak model, weak table] in
                guard let model, let table, let row = model.entries.firstIndex(where:{ model.selection.contains($0.id) }) else { return }
                table.scrollRowToVisible(row)
            } }
            return accepted
        }
        private func rowTable() -> NSTableView? {
            guard let content = window?.contentView else { return nil }
            func find(_ view:NSView)->NSTableView? {
                if let table = view as? NSTableView, table.tableColumns.count == RebaseColumnLayout.Probe.names.count,
                   convert(bounds,to:nil).intersects(table.convert(table.visibleRect,to:nil)) { return table }
                return view.subviews.compactMap(find).first
            }
            return find(content)
        }
        private func observeMouse(_ event:NSEvent)->NSEvent? {
            guard let window, event.window === window else { if event.type == .leftMouseUp { cancelRowDrag() }; return event }
            if event.type == .leftMouseDown {
                cancelRowDrag()
                guard event.clickCount == 1, model?.canDragRows == true, let table = rowTable() else { return event }
                let point = table.convert(event.locationInWindow,from:nil)
                guard table.visibleRect.contains(point), table.row(at:point) >= 0 else { return event }
                dragTable = table; dragStart = point
            } else if event.type == .leftMouseDragged, let table = dragTable, let start = dragStart, let model {
                let point = table.convert(event.locationInWindow,from:nil)
                guard rowDrag != nil || hypot(point.x-start.x,point.y-start.y) >= 4 else { return event }
                if rowDrag == nil {
                    let visible = model.entries, ids = Set(table.selectedRowIndexes.compactMap { visible.indices.contains($0) ? visible[$0].id : nil })
                    guard beginDrag(in:table,ids:ids) else { cancelRowDrag(); return event }
                }
                _ = updateDrag(at:point); _ = table.autoscroll(with:event); return nil
            } else if event.type == .leftMouseUp, rowDrag != nil { _ = finishDrag(); return nil }
            else if event.type == .leftMouseUp { cancelRowDrag() }
            return event
        }
        func observe(_ event: NSEvent) -> NSEvent? {
            if event.type != .keyDown { return observeMouse(event) }
            if rowDrag != nil, event.keyCode == 53 { cancelRowDrag(); return nil }
            guard event.type == .keyDown, let window, event.window === window,
                  let table = window.firstResponder as? NSTableView,
                  convert(bounds, to: nil).intersects(table.convert(table.visibleRect, to: nil)),
                  let model, model.editable else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard flags.subtracting(.shift).isEmpty else { return event }
            let visible = model.entries
            let ids = Set(table.selectedRowIndexes.compactMap { visible.indices.contains($0) ? visible[$0].id : nil })
            guard !ids.isEmpty else { return event }
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            guard [" ", "p", "s", "q", "e", "u", "d"].contains(key) else { return event }
            model.selection = ids
            switch key {
            case " ": model.cycleActions()
            case "p": model.setAction(.pick)
            case "s": model.setAction(.skip)
            case "q": model.setAction(.squash)
            case "e": model.setAction(.edit)
            default: model.move(up: key == "u", toEnd: flags.contains(.shift))
            }
            // SwiftUI reconciles the identity-bound selection after replacing its
            // rows. Selecting AppKit indexes here would still use the old rows.
            DispatchQueue.main.async { [weak table, weak model] in
                guard let table, let model, model.selection == ids else { return }
                let visible = model.entries
                let selected = visible.indices.filter { ids.contains(visible[$0].id) }
                if let row = key == "d" ? selected.last : selected.first { table.scrollRowToVisible(row) }
            }
            return nil
        }
    }
}

private extension RebaseAction {
    var icon: MenuIcon {
        switch self { case .pick: return .rebasePick; case .skip: return .rebaseSkip; case .edit: return .rebaseEdit; case .squash: return .rebaseSquash }
    }
}

/// Clipboard and checked-row keys belong only to the lower conflict table.
/// Commit-message fields and the upper replay table retain their key behavior.
struct RebaseConflictFileKeys: NSViewRepresentable {
    let model: RebaseWindowModel
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.model = model }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Probe, context: Context) -> CGSize? { CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0) }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }
    final class Probe: NSView {
        weak var model: RebaseWindowModel?
        private var monitor: Any?
        private var closing: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop(); guard let window else { return }
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handle(event) ?? event }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let closing { NotificationCenter.default.removeObserver(closing) }; closing = nil
        }
        func table() -> NSTableView? {
            func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
            var parent = superview
            while let ancestor = parent {
                let found = tables(ancestor); if found.count == 1 { return found.first }
                if found.count > 1 { let area = convert(bounds, to: nil); let intersecting = found.filter { area.intersects($0.convert($0.visibleRect, to: nil)) }; return intersecting.count == 1 ? intersecting.first : nil }; parent = ancestor.superview
            }
            return nil
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let model, !model.retired, !model.busy, model.fileRecovery, event.window === window,
                  let table = table(), let responder = window?.firstResponder as? NSView,
                  responder === table || responder.isDescendant(of: table) else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .shift, .option]), key = event.charactersIgnoringModifiers?.lowercased()
            let indexes = table.selectedRowIndexes.filter { model.conflictRows.indices.contains($0) }
            let ids = Set(indexes.map { model.conflictRows[$0].id })
            if key == "c", flags == .command || flags == .control || flags == [.command, .shift] || flags == [.control, .shift] {
                model.copyConflictFiles(model.conflictFileMenu(ids), copy: flags.contains(.shift) ? .pathsAndStatus : .relativePaths); return nil
            }
            if event.keyCode == 49, flags.isEmpty || flags == .control {
                model.toggleConflictChecks(ids, mark: model.conflictRows.indices.contains(table.selectedRow) ? model.conflictRows[table.selectedRow].id : nil); return nil
            }
            return event
        }
    }
}
