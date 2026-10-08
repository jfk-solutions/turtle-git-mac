import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RebaseWindowController: NSWindowController, NSWindowDelegate {
    let model: RebaseWindowModel
    var onClosed: () -> Void = {}
    private var logPicker: LogWindowController?
    private var splitCommitPicker: CommitWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = RebaseWindowModel(repository: repository, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Rebase – TurtleGit"; window.minSize = NSSize(width: 930, height: 620); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RebaseDialog(model: model))
        super.init(window: window); window.delegate = self; window.center(); model.close = { [weak window] in window?.close() }
        model.revisionMenuLog.window = window
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
            if answer == .alertFirstButtonReturn, remember.state == .on { UserDefaults.standard.set(true, forKey: "CommitMessageContainsConflictHint") }
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
    private func showSplitSelection(_ split: RebaseSplitState, message: String) {
        guard let window, window.attachedSheet == nil, splitCommitPicker == nil else { model.splitSelectionClosed(committed: false); return }
        let child = CommitWindowController(repository: model.repository, access: model.repositoryAccess)
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
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && !model.selectingSplit && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { logPicker?.close(); logPicker = nil; splitCommitPicker?.close(); splitCommitPicker = nil; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class RebaseWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let messageDefaults: UserDefaults
    var repositoryAccess: RepositoryAccessLease? { access }
    @Published var options = RebaseOptions()
    @Published var ontoEnabled = false
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
    var onConflictAction: (RepositoryAction, [String]) -> Void = { _, _ in }
    @Published var conflictPatch: String?
    @Published var selectedFiles = Set<String>()
    @Published var message = ""
    @Published var amendMessage = ""
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
    @Published var browsing = false
    @Published var pickingCommits = false
    @Published var splitCommit = false
    @Published var selectingSplit = false
    var showSplitSelection: (RebaseSplitState, String) -> Void = { _, _ in }
    var configureCommitSelection: (CommitWindowModel) -> Void = { _ in }
    var chooseAnotherSplit: () async -> Bool = { false }
    var close: () -> Void = {}
    var onChanged: () -> Void = {}
    var onShowStatus: () -> Void = {}
    var onModeChanged: () -> Void = {}
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    lazy var revisionMenuLog = LogWindowModel(repository: repository, access: access)
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
    private var conflictStep: Int?
    private func loadConflictFiles() async throws {
        let current = state?.currentStep
        let previousPaths = conflictStep == current ? Set(conflictRows.map(\.path)) : []
        if !active || conflictStep != current { checkedConflicts = [] }
        if !active || conflictStep != current || state?.squashMessage?.skipBaseHead != nil { conflictStep = nil }
        if state?.needsFileRecovery == true { conflictStep = current }
        fileRecovery = active && conflictStep == current
        if fileRecovery {
            conflicts = try await repository.conflicts(paths: [])
            let group = state?.stoppedAction == .squash
            conflictRows = try await repository.commitDialogStatus(amendToParent: group).filter { $0.state != .untracked && $0.state != .ignored }
            conflictStatistics = Dictionary(try await repository.workingTreeFiles(amendToParent: group).map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
            let paths = Set(conflictRows.map(\.path))
            checkedConflicts.formIntersection(paths); checkedConflicts.formUnion(paths.subtracting(previousPaths))
            conflictHead = try await repository.rebaseCommit("HEAD").hash
            selectedConflicts.formIntersection(Set(conflictRows.map(\.id)))
        } else { conflicts = []; conflictRows = []; conflictStatistics = [:]; selectedConflicts = [] }
    }
    func conflictAction(_ action: RepositoryAction, ids: Set<String>) {
        guard !busy, !selectingSplit else { return }
        let paths = conflicts.filter { ids.contains($0.id) }.map(\.path)
        guard !paths.isEmpty, action != .editConflict || paths.count == 1 && ids.count == 1 else { return }
        onConflictAction(action, paths)
    }
    func compareConflicts(_ ids: Set<String>) {
        let paths = conflicts.filter { ids.contains($0.id) }.map(\.path)
        guard !busy, !selectingSplit, !paths.isEmpty else { return }; busy = true
        Task {
            defer { busy = false; loadPendingHandoff() }
            do { try requireAccess(); conflictPatch = try await repository.run(["diff", "--no-ext-diff", "--no-color", "--base", "--"] + paths).text }
            catch { self.error = error.localizedDescription }
        }
    }
    private var completion = "Rebase finished"
    private var pendingLoad: (upstream: String?, autoStart: Bool, preserveMerges: Bool, cherryPick: [String]?)?
    private func loadPendingHandoff() {
        guard !busy, !pickingCommits, !selectingSplit, let pending = pendingLoad else { return }
        pendingLoad = nil
        load(upstream: pending.upstream, autoStart: pending.autoStart, preserveMerges: pending.preserveMerges, cherryPick: pending.cherryPick)
    }
    var active: Bool { state?.active == true }
    var editable: Bool { !busy && !active && !finished && !pickingCommits && !selectingSplit }
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
        switch action {
        case .log: let callback = onCompletedLog; close(); callback?()
        case .push: let callback = onCompletedPush; close(); callback?("HEAD")
        case .mail:
            guard let preset = FormatPatchPreset(startRevision: options.upstream, endRevision: options.branch) else { return }
            let callback = onCompletedMail; close(); callback?(preset)
        case .restart: load()
        case .rebase: load(upstream: options.upstream, autoStart: completionAutoStart, preserveMerges: options.preserveMerges)
        }
    }
    var canStart: Bool { editable && plan != nil && plan?.disposition != .upToDate && plan?.disposition != .equal && plan?.entries.first(where: { $0.action != .skip })?.action != .squash }
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
    init(repository: GitRepository, access: RepositoryAccessLease?, messageDefaults: UserDefaults = .standard) { self.repository = repository; self.access = access; self.messageDefaults = messageDefaults }
    var revisionMenuAvailable: Bool { !busy && !selectingSplit && !pickingCommits && !revisionMenuLog.busy && !revisionMenuLog.loadingNote && !revisionMenuLog.savingNote && !revisionMenuLog.copyingDetails }
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
    func load(upstream: String? = nil, autoStart: Bool = false, preserveMerges: Bool = false, cherryPick: [String]? = nil) {
        guard !busy, !pickingCommits, !selectingSplit else {
            if upstream != nil || cherryPick != nil { pendingLoad = (upstream, autoStart, preserveMerges, cherryPick) }
            return
        }; busy = true; planGeneration += 1; detailGeneration += 1
        Task {
            var started = false
            defer { if !started { busy = false; loadPendingHandoff() } }
            do {
                try requireAccess()
                revisionMenuLog.bare = try await repository.isBare()
                references = try await repository.checkoutReferences(); state = try await repository.rebaseState(); finished = false; completedSuccessfully = false; output = ""; error = nil; confirmation = nil; draftEntries = []
                try await loadConflictFiles(); if fileRecovery { tab = 0 }
                if active { splitCommit = state?.split != nil && state?.split?.conflictRecovery != true; options.isCherryPick = state?.isCherryPick == true; onModeChanged(); options.branch = state?.branch ?? "HEAD"; options.upstream = state?.onto ?? ""; restoreSessionContext(); plan = nil; recovered = try await repository.remainingRebaseEntries(); replayRows = try await repository.rebaseReplayEntries(); selection = Set(recovered.first.map { [$0.id] } ?? []); amendMessage = state?.squashMessage?.message ?? state?.message ?? ""; if state?.squashMessage != nil || state?.isEditPause == true { tab = 1 }; if amendMessage.isEmpty, let commit = recovered.first { amendMessage = commit.commit.message }; selectCommit(); return }
                finished = false; plan = nil; recovered = []; replayRows = []; selection = []; files = []; message = ""; options = RebaseOptions(); options.preserveMerges = preserveMerges; ontoEnabled = false
                if let cherryPick {
                    plan = try await repository.cherryPickPlan(revisions: cherryPick)
                    options = plan!.options
                    options.addCherryPickedFrom = UserDefaults.standard.bool(forKey: "CherrypickAddCherryPickedFrom")
                    updateAttribution()
                    options.squashDate = RebaseSquashDate(rawValue: UserDefaults.standard.integer(forKey: "SquashDate")) ?? .first
                    plan?.options.squashDate = options.squashDate
                    onModeChanged(); selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit(); return
                }
                onModeChanged()
                options.squashDate = RebaseSquashDate(rawValue: UserDefaults.standard.integer(forKey: "SquashDate")) ?? .first
                let branch = try await repository.branch(); options.branch = branch.isEmpty ? "HEAD" : "refs/heads/" + branch
                let defaults = try await repository.pullDefaults()
                options.upstream = upstream ?? (defaults.trackedRemote.isEmpty || defaults.trackedBranch.isEmpty ? "" : "refs/remotes/" + defaults.trackedRemote + "/" + defaults.trackedBranch)
                if !options.upstream.isEmpty { plan = try await repository.rebasePlan(options); selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit() }
                busy = false
                if autoStart && canStart { started = true; execute("start") }
            } catch { self.error = error.localizedDescription }
        }
    }
    func reloadPlan() {
        guard editable, !isCherryPick else { return }; planGeneration += 1; detailGeneration += 1
        let request = planGeneration; var snapshot = options; if !ontoEnabled { snapshot.onto = "" }
        plan = nil; draftEntries = []; selection = []; files = []; message = ""
        Task {
            do { let value = try await repository.rebasePlan(snapshot); guard request == planGeneration, editable else { return }; plan = value; selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit() }
            catch RebaseFailure.revision { /* Keep incomplete editable references without interrupting typing. */ }
            catch { if request == planGeneration { self.error = error.localizedDescription } }
        }
    }
    private func requireAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func updateAttribution() {
        guard isCherryPick, var value = plan, !active else { return }
        value.options.addCherryPickedFrom = options.addCherryPickedFrom
        plan = value
        UserDefaults.standard.set(options.addCherryPickedFrom, forKey: "CherrypickAddCherryPickedFrom")
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
        busy = true; planGeneration += 1; detailGeneration += 1
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
        guard editable, !options.preserveMerges else { return }
        var values = plan?.entries ?? draftEntries
        let targets = ids ?? selection
        for index in values.indices where targets.contains(values[index].id) { values[index].action = action }
        if plan != nil { plan?.entries = values } else { draftEntries = values }
    }
    func canMove(up: Bool, toEnd: Bool = false) -> Bool {
        guard editable, !options.preserveMerges else { return false }
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
        guard editable, !options.preserveMerges else { return }
        var values = plan?.entries ?? draftEntries
        for index in values.indices where selection.contains(values[index].id) {
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
        detailGeneration += 1; let request = detailGeneration
        files = []; message = ""
        guard let entry = entries.first(where: { selection.contains($0.id) }) else { return }
        message = entry.commit.message
        Task {
            do { let changed = try await repository.files(in: entry.commit); guard request == detailGeneration else { return }; files = changed }
            catch { if request == detailGeneration { self.error = error.localizedDescription } }
        }
    }
    func refreshState() {
        guard !busy, !selectingSplit else { return }; busy = true
        Task {
            defer { busy = false; loadPendingHandoff() }
            do { let wasActive = active; state = try await repository.rebaseState(); try await loadConflictFiles(); onModeChanged(); if active { restoreSessionContext(); recovered = try await repository.remainingRebaseEntries(); replayRows = try await repository.rebaseReplayEntries(); amendMessage = state?.squashMessage?.message ?? state?.message ?? ""; if state?.squashMessage != nil || state?.isEditPause == true { tab = 1 }; selectCommit() } else if wasActive { finished = true; completedSuccessfully = false; completion = "\(operationTitle) session ended" }; onChanged() }
            catch { self.error = error.localizedDescription }
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
        guard !busy, !pickingCommits, !selectingSplit, action != "start" || canStart else { return }
        let snapshot = plan; busy = true; tab = 2
        Task {
            var followRecovery = false, followEmpty = false
            var skippedID = action == "skip" ? state?.stoppedEntryID : nil
            defer { busy = false; if followEmpty { execute("continue") } else if followRecovery { resumeConflictSelection(afterCommit: true) } else { loadPendingHandoff() } }
            do {
                try requireAccess()
                let result: RebaseExecution
                switch action {
                case "start": guard let snapshot, let executable = editorExecutable else { throw RebaseFailure.plan }; replayRows = snapshot.entries; result = try await repository.startRebase(snapshot, editorExecutable: executable, afterFetch: completionAfterFetch, autoStart: completionAutoStart, fromLog: completionFromLog)
                case "abort": result = try await repository.abortRebase()
                case "skip": result = try await repository.skipRebase()
                default:
                    let rawText = amendMessage, paths = checkedConflicts, head = conflictHead
                    let stripComments = messageDefaults.bool(forKey: "StripCommentedLines")
                    let text = try await repository.prepareCommitMessageFile(rawText, stripComments: stripComments, sanitize: messageDefaults.object(forKey: "SanitizeCommitMsg") as? Bool ?? true).contents
                    if fileRecovery, state?.split == nil, !UserDefaults.standard.bool(forKey: "CommitMessageContainsConflictHint"), try await repository.rebaseMessageContainsConflictHints(rawText, stripComments: stripComments) {
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
                if action == "continue", state?.split?.conflictRecovery == true { followRecovery = true }
            } catch { self.error = error.localizedDescription }
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
                .disabled(ids.isEmpty || !model.editable || model.options.preserveMerges)
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
        .sheet(item: $log.noteRequest) { _ in LogNotesDialog(model: log) }
    }
}

struct RebaseReplayCell<Content: View>: View {
    let entry: RebaseEntry
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
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
                Text("Branch:"); PushRefCombo(value: $model.options.branch, choices: model.references.filter { $0.name.hasPrefix("refs/heads/") }.map(\.name), local: true)
                Button { let branch = model.options.branch; model.options.branch = model.options.upstream; model.options.upstream = branch; model.reloadPlan() } label: { Image(nsImage: MenuIcon.reverse.image() ?? NSImage()).resizable().frame(width: 16, height: 16) }.accessibilityLabel("Reverse branch and upstream")
                Text("Upstream:"); PushRefCombo(value: $model.options.upstream, choices: model.references.map(\.name), local: true)
                Button("…") { model.browsing = true }.accessibilityLabel("Browse upstream references")
                Toggle("Onto", isOn: $model.ontoEnabled).toggleStyle(.button)
                }
            }.disabled(!model.editable)
            if model.ontoEnabled { HStack { Text("Onto:"); PushRefCombo(value: $model.options.onto, choices: model.references.map(\.name), local: true) }.disabled(!model.editable) }
            VSplitView {
                VStack(spacing: 8) {
                    Table(model.entries, selection: $model.selection) {
                        TableColumn("REBASE") { entry in RebaseReplayCell(entry: entry) { HStack(spacing: 5) { Image(nsImage: entry.action.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(entry.action == .skip ? "Skip" : entry.action.rawValue.capitalized) } } }.width(90)
                        TableColumn("ID") { entry in RebaseReplayCell(entry: entry) { Text(String(model.entryNumber(entry))) } }.width(40)
                        TableColumn("Hash") { entry in RebaseReplayCell(entry: entry) { Text(String(entry.commit.hash.prefix(9))).font(.system(.caption, design: .monospaced)) } }.width(95)
                        TableColumn("Message") { entry in RebaseReplayCell(entry: entry) { Text(entry.commit.subject) } }
                        TableColumn("Author") { entry in RebaseReplayCell(entry: entry) { Text(entry.commit.author) } }.width(130)
                        TableColumn("Date") { entry in RebaseReplayCell(entry: entry) { Text(HistoryDateSettings.load().format(entry.commit.date)) } }.width(150)
                    }.background(RebaseListInteraction(model: model)).contextMenu(forSelectionType: String.self) { ids in
                        TurtleGitContextMenu {
                            RebaseRevisionMenu(model: model, log: model.revisionMenuLog, ids: ids)
                        }
                    }
                    HStack {
                        Button("Pick ALL") { model.setAction(.pick, ids: Set(model.entries.map(\.id))) }.disabled(!model.editable || model.options.preserveMerges)
                        Menu("Options") {
                            ForEach(RebaseAction.allCases.filter { $0 != .skip }, id: \.self) { action in Button { model.setAction(action, ids: Set(model.entries.map(\.id))) } label: { CommandLabel(title: "Select all: " + action.rawValue.capitalized, icon: action.icon) } }
                            Divider()
                            ForEach([RebaseAction.skip, .squash, .edit], id: \.self) { action in Button { model.setAction(action, ids: Set(model.entries.map(\.id)).subtracting(model.selection)) } label: { CommandLabel(title: "Unselected: " + (action == .skip ? "Skip" : action.rawValue.capitalized), icon: action.icon) } }
                        }.disabled(!model.editable || model.options.preserveMerges)
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
                    }
                    }
                    }.tabItem { Text(model.fileRecovery ? "Conflict Files" : "Revision Files") }.tag(0)
                    Group {
                        if model.fileRecovery || model.state?.squashMessage != nil || model.state?.isEditPause == true || model.state?.split != nil {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.state?.squashMessage != nil ? "Combined commit message:" : "Edit commit message:")
                                TextEditor(text: $model.amendMessage).font(messageFont).accessibilityLabel(model.state?.squashMessage != nil ? "Combined commit message" : "Edit commit message")
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
                Button(model.primaryActionTitle) { if model.finished { model.close() } else { model.request(model.active ? "continue" : "start") } }.keyboardShortcut(.defaultAction).disabled(!model.finished && !model.active && !model.canStart)
                Button(model.active || model.isCherryPick ? "Abort" : "Cancel") { if model.active { model.request("abort") } else { model.close() } }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(model.helpURL) }
            }
        }.padding(12).disabled(model.busy || model.selectingSplit)
        .modifier(RebaseRevisionMenuPresentation(log: model.revisionMenuLog))
        .onChange(of: model.options.branch) { _ in model.reloadPlan() }
        .onChange(of: model.options.upstream) { _ in model.reloadPlan() }
        .onChange(of: model.options.onto) { _ in model.reloadPlan() }
        .onChange(of: model.ontoEnabled) { _ in model.reloadPlan() }
        .onChange(of: model.options.addCherryPickedFrom) { _ in model.updateAttribution() }
        .onChange(of: model.options.force) { _ in model.reloadPlan() }
        .onChange(of: model.options.preserveMerges) { _ in model.reloadPlan() }
        .onChange(of: model.selection) { _ in model.selectCommit() }
        .alert(model.operationTitle, isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil }; Button("Open Working Tree") { model.error = nil; model.onShowStatus() } } message: { Text(model.error ?? "") }
        .alert("Confirm " + model.operationTitle, isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })) {
            Button("Continue") { let text = model.confirmation ?? ""; model.confirmation = nil; model.execute(text.hasPrefix("Abort") ? "abort" : text.hasPrefix("Skip") ? "skip" : "start") }
            Button("Cancel", role: .cancel) {}
        } message: { Text(model.confirmation ?? "") }
        .sheet(isPresented: $model.browsing) { RebaseReferenceChooser(model: model) }
        .sheet(isPresented: Binding(get: { model.conflictPatch != nil }, set: { if !$0 { model.conflictPatch = nil } })) {
            VStack { Text("Compare with base").font(.headline); OutputView(text: model.conflictPatch ?? "").frame(minWidth: 850, minHeight: 520); Button("Close") { model.conflictPatch = nil }.keyboardShortcut(.cancelAction) }.padding(12)
        }
    }
}
struct RebaseConflictFiles: View {
    @ObservedObject var model: RebaseWindowModel
    var body: some View {
        Table(model.conflictRows, selection: $model.selectedConflicts) {
            TableColumn("✓") { entry in Toggle("Commit \(entry.path)", isOn: Binding(get: { model.checkedConflicts.contains(entry.path) }, set: { if $0 { model.checkedConflicts.insert(entry.path) } else { model.checkedConflicts.remove(entry.path) } })).labelsHidden().toggleStyle(.checkbox).disabled(!model.supportsConflictSelection) }.width(28)
            TableColumn("Path") { entry in HStack(spacing: 5) { Image(nsImage: entry.state.icon.image() ?? NSImage()); Text(entry.path).foregroundStyle(entry.state.textColor) } }
            TableColumn("Extension") { Text(($0.path as NSString).pathExtension) }.width(70)
            TableColumn("Status") { Text($0.state.rawValue.capitalized).foregroundStyle($0.state.textColor) }.width(110)
            TableColumn("Lines added") { Text(model.conflictStatistics[$0.path]?.added.map(String.init) ?? "–") }.width(85)
            TableColumn("Lines removed") { Text(model.conflictStatistics[$0.path]?.removed.map(String.init) ?? "–") }.width(95)
        }.contextMenu(forSelectionType: String.self) { ids in
            TurtleGitContextMenu {
                Button { model.compareConflicts(ids) } label: { CommandLabel(title: "Compare with base", icon: .compare) }.disabled(!model.conflicts.contains { ids.contains($0.id) } || model.busy)
                Divider()
                ResolveSelectionMenu(paths: model.conflicts.filter { ids.contains($0.id) }.map(\.path), rebase: true, canEdit: ids.count == 1 && model.conflicts.contains { ids.contains($0.id) }) { action, _ in model.conflictAction(action, ids: ids) }
            }
        } primaryAction: { ids in model.conflictAction(.editConflict, ids: ids) }
    }
}
private struct RebaseReferenceChooser: View {
    @ObservedObject var model: RebaseWindowModel
    @State private var selection: String?
    @State private var filter = ""
    var body: some View { VStack(spacing: 12) {
        Text("Browse upstream references").font(.headline); TextField("Filter", text: $filter)
        List(model.references.filter { filter.isEmpty || $0.label.localizedCaseInsensitiveContains(filter) }, selection: $selection) { Text($0.label).tag($0.name) }
        HStack { Spacer(); Button("Cancel") { model.browsing = false }.keyboardShortcut(.cancelAction); Button("OK") { if let selection { model.options.upstream = selection; model.browsing = false } }.keyboardShortcut(.defaultAction).disabled(selection == nil) }
    }.padding(16).frame(width: 650, height: 430) }
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
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }; return self.observe(event)
            }
        }
        func stopObserving() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { stopObserving() }
        func observe(_ event: NSEvent) -> NSEvent? {
            guard event.type == .keyDown, let window, event.window === window,
                  let table = window.firstResponder as? NSTableView,
                  convert(bounds, to: nil).intersects(table.convert(table.visibleRect, to: nil)),
                  let model, model.editable, !model.options.preserveMerges else { return event }
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
