import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class ResolveWindowController: NSWindowController, NSWindowDelegate {
    let model: ResolveWindowModel
    var onClosed: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onCommit: () -> Void = {}
    private(set) var retired = false
    var configureComparison: (FileComparisonWindowModel) -> Void = { _ in }
    private(set) var baseComparison: FileComparisonWindowController?
    private var question: (UUID, NSAlert, (NSApplication.ModalResponse?) -> Void)?
    var presentQuestion: (NSWindow, NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Bool = { owner, alert, reply in
        guard owner.attachedSheet == nil else { return false }; alert.beginSheetModal(for: owner, completionHandler: reply); return true
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], quick: ResolveChoice? = nil, preferences: UserDefaults = .standard) {
        model = ResolveWindowModel(repository: repository, access: access, paths: paths, quick: quick, preferences: preferences)
        let size = quick == nil ? NSSize(width: 780, height: 450) : NSSize(width: 480, height: 110)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Resolve – TurtleGit"
        window.contentMinSize = quick == nil ? NSSize(width: 660, height: 340) : size
        window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        window.contentViewController = NSHostingController(rootView: ResolveDialog(model: model, commit: { [weak self] in self?.commit() }).defaultAppStorage(preferences))
        window.setContentSize(size); window.center()
        model.close = { [weak self] in guard let self, !self.retired else { return }; self.window?.performClose(nil) }
        model.confirm = { [weak self] choice, entries in self?.confirm(choice, entries: entries) }
        model.onChanged = { [weak self] output in guard let self, !self.retired else { return }; self.onChanged(output) }
        model.onProgress = { [weak self] in
            guard let self, !self.retired, let window = self.window else { return }
            window.contentMinSize = NSSize(width: 660, height: 340)
            if window.frame.width < 660 || window.contentLayoutRect.height < 340 { window.setContentSize(NSSize(width: 780, height: 450)) }
        }
        model.onComparison = { [weak self] prepared in
            guard let self, !self.retired, self.baseComparison == nil else { return }
            let child = FileComparisonWindowController(repository: repository, access: access, conflict: prepared, preferences: preferences)
            self.configureComparison(child.model); self.baseComparison = child; self.model.hasChild = true
            child.onClosed = { [weak self] in
                guard let self else { return }; self.baseComparison = nil; self.model.hasChild = false
                if !self.retired { self.model.load() }
            }
            child.showWindow(nil); child.window?.makeKeyAndOrderFront(nil)
        }
        model.confirmCancellation = { [weak self] reply in
            Task { let answer = await self?.ask(title: "The process is still running.", message: "Are you sure to abort?", buttons: ["Yes", "No"]); reply(answer == .alertFirstButtonReturn) }
        }
        model.confirmSubmoduleDeletion = { [weak self] request in
            await self?.ask(title: "Delete submodule folder?", message: request.gitError + "\n\nMove “\(request.path)” to Trash to resolve its deletion?", buttons: ["Delete", "Abort"]) == .alertFirstButtonReturn
        }
        DialogGeometry.attach(window, identifier: quick == nil ? "ResolveDialog" : "QuickResolveDialog", legacyName: "ResolveDialog")
    }
    private func confirm(_ choice: ResolveChoice, entries: [ConflictEntry]) {
        let generation = model.generation
        Task {
            let message = choice == .current ? "The current working contents will be staged." : "This replaces the selected working contents with index stage \(choice.rawValue). A missing stage resolves the path as deleted."
            let answer = await ask(title: "Are you sure you want to mark the conflicted file(s) as resolved?", message: message, buttons: ["Yes", "No"])
            guard !retired, model.generation == generation else { return }
            if answer == .alertFirstButtonReturn { model.apply(entries, using: choice) } else { model.rejectConfirmation() }
        }
    }
    private func ask(title: String, message: String, buttons: [String]) async -> NSApplication.ModalResponse? {
        guard !retired, question == nil, let window, window.attachedSheet == nil else { return nil }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        let id = UUID(); model.hasQuestion = true
        return await withCheckedContinuation { continuation in
            question = (id, alert, { continuation.resume(returning: $0) })
            if !presentQuestion(window, alert, { [weak self] answer in self?.finishQuestion(id, answer: answer) }) { finishQuestion(id, answer: nil) }
        }
    }
    private func finishQuestion(_ id: UUID, answer: NSApplication.ModalResponse?) {
        guard let pending = question, pending.0 == id else { return }; question = nil; model.hasQuestion = false
        if pending.1.window.sheetParent === window { window?.endSheet(pending.1.window, returnCode: answer ?? .abort) }
        pending.1.window.orderOut(nil); pending.2(answer)
    }
    func commit() {
        guard !retired, model.success, !model.busy, !model.hasQuestion, !model.hasChild, !model.confirmingCancellation else { return }
        let callback = onCommit; model.closeProgress(commit: true); callback()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        return !model.hasQuestion && !model.hasChild && !model.confirmingCancellation && sender.attachedSheet == nil
    }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }; retired = true; model.invalidate(); baseComparison?.close(); baseComparison = nil
        if let pending = question { finishQuestion(pending.0, answer: nil) }
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class ResolveWindowModel: ObservableObject {
    static private(set) var activeOperations = 0
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    let preferences: UserDefaults
    let quick: ResolveChoice?
    let paths: [String]
    private(set) var active = true
    private(set) var generation = UUID()
    private var cancellation: OperationCancellation?
    private var refreshCancellation: OperationCancellation?
    private var loaded = false, reloadQueued = false
    @Published var entries: [ConflictEntry] = []
    @Published var checked = Set<String>()
    @Published var selection = Set<String>()
    @Published var rebase = false
    @Published var busy = false
    @Published var error: String?
    @Published var patch: String?
    @Published private(set) var showingProgress = false
    @Published private(set) var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var resolvedCount = 0
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published var hasQuestion = false
    @Published var hasChild = false
    private var autoClosePolicy: GitProgressAutoClose?
    private var pendingResolution: (UUID, [ConflictEntry], ResolveChoice)?
    var closeAfterResolution = true
    var close: () -> Void = {}
    var confirm: (ResolveChoice, [ConflictEntry]) -> Void = { _, _ in }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var confirmSubmoduleDeletion: @Sendable (SubmoduleDeletionRequest) async -> Bool = { request in await ConflictPrompts.deleteSubmodule(request) }
    var onChanged: (String) -> Void = { _ in }
    var onFinished: (Int) -> Void = { _ in }
    var onProgress: () -> Void = {}
    var onComparison: (ConflictBaseComparison) -> Void = { _ in }
    var onEdit: (String) -> Void = { _ in }
    var onSubmoduleReset: (GitRepository, String, @escaping () -> Void) -> Void = { _, _, _ in }
    var readConflicts: ((OperationCancellation) async throws -> ([ConflictEntry], Bool))?
    var executeResolution: (([ConflictEntry], ResolveChoice, OperationCancellation, @escaping @Sendable (GitOutputChunk) -> Void, @escaping @Sendable (ConflictResolutionProgress) -> Void) async throws -> String)?
    var canInteract: Bool { active && !busy && !showingProgress && !hasQuestion && !hasChild }
    var canCancel: Bool { active && busy && !cancelling && !confirmingCancellation && !hasQuestion && !hasChild }
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], quick: ResolveChoice?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.paths = paths; self.quick = quick; self.preferences = preferences
    }
    func invalidate() {
        if busy { cancelled = true }; saveActionLog(); active = false; generation = UUID(); cancellation?.cancel(); refreshCancellation?.cancel(); pendingResolution = nil; reloadQueued = false; patch = nil
    }
    private func begin() -> OperationCancellation {
        let token = OperationCancellation(); cancellation = token; generation = UUID(); busy = true; error = nil
        Self.activeOperations += 1; return token
    }
    private func live(_ token: OperationCancellation) -> Bool { active && cancellation === token }
    private func finish(_ token: OperationCancellation) {
        Self.activeOperations -= 1
        if cancellation === token {
            cancellation = nil; busy = false; cancelling = false; currentWork = ""; percentage = nil
            finishAutomaticClose()
            if active, reloadQueued, !showingProgress, !hasChild, !hasQuestion { reloadQueued = false; load() }
        }
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func refresh(_ token: OperationCancellation) async throws {
        try checkAccess()
        let next: ([ConflictEntry], Bool)
        if let readConflicts { next = try await readConflicts(token) }
        else { next = try await (repository.conflicts(paths: paths, cancellation: token), repository.conflictIsRebase(cancellation: token)) }
        try token.check(); guard live(token) else { return }
        let available = Set(next.0.map(\.path)); entries = next.0; rebase = next.1
        checked = loaded ? checked.intersection(available) : available; loaded = true; selection.formIntersection(available)
    }
    func load() {
        guard active else { return }
        if busy || hasQuestion || hasChild || showingProgress { reloadQueued = true; return }
        let token = begin()
        Task {
            defer { finish(token); withExtendedLifetime(access) {} }
            do {
                try await refresh(token); guard live(token), !token.isCancelled else { return }
                if let quick { guard !entries.isEmpty else { throw ResolveFailure.stale }; busy = false; request(quick, ids: Set(entries.map(\.path))) }
            } catch { if live(token), !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func resolveChecked() { guard canInteract else { return }; closeAfterResolution = true; apply(entries.filter { checked.contains($0.path) }, using: .current) }
    func request(_ choice: ResolveChoice, ids: Set<String>) {
        let selected = entries.filter { ids.contains($0.path) }
        guard canInteract, !selected.isEmpty else { return }
        closeAfterResolution = false; pendingResolution = (generation, selected, choice); confirm(choice, selected)
    }
    func rejectConfirmation() { pendingResolution = nil; if quick != nil { close() } else if reloadQueued { reloadQueued = false; load() } }
    func apply(_ selected: [ConflictEntry], using choice: ResolveChoice) {
        guard active, !busy, !hasQuestion, !hasChild else { return }
        if let pendingResolution {
            guard pendingResolution.0 == generation, pendingResolution.1 == selected, pendingResolution.2 == choice else { return }
        }
        pendingResolution = nil
        do { guard !selected.isEmpty else { throw ResolveFailure.selection }; try checkAccess() }
        catch { self.error = error.localizedDescription; return }
        ProgressActionLog.nextAttempt(self, savePrevious: showingProgress)
        let token = begin(); showingProgress = true; output = ""; success = false; cancelled = false; resolvedCount = 0; patch = nil
        autoClosePolicy = GitProgressAutoClose(preferences: preferences)
        onProgress(); LocalGitCommandProgress.begin()
        Task {
            defer { LocalGitCommandProgress.end(); finish(token); withExtendedLifetime(access) {} }
            do {
                let progress: @Sendable (ConflictResolutionProgress) -> Void = { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.live(token) else { return }
                        self.resolvedCount = max(self.resolvedCount, event.completed)
                        if self.busy { self.currentWork = event.path; self.percentage = event.total > 0 ? event.completed * 100 / event.total : nil }
                    }
                }
                let text = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in
                    guard let self, self.live(token) else { return }; self.output = state.output
                }, resultText: { $0 }) { [self] emit in
                    if let executeResolution { return try await executeResolution(selected, choice, token, emit, progress) }
                    return try await repository.resolveConflicts(selected, using: choice, confirmSubmoduleDeletion: confirmSubmoduleDeletion, cancellation: token, onOutput: emit, onProgress: progress)
                }
                guard live(token) else { return }
                resolvedCount = selected.count
                // A cancellation arriving after Git settled must still refresh the
                // actual index, while suppressing success/Commit post actions.
                if token.isCancelled { cancelled = true } else { success = true }
                onChanged(text); if success { onFinished(selected.count) }
            } catch ResolveFailure.submoduleCheckout(let path) {
                guard live(token), !token.isCancelled else { return }
                do {
                    guard let entry = selected.first(where: { $0.path == path }) else { throw ResolveFailure.stale }
                    let (root, revision) = try await repository.submoduleResetTarget(entry, using: choice, cancellation: token)
                    guard live(token), !token.isCancelled else { return }
                    // The retry retains the original stages and is fenced to this
                    // owner; closing/reloading cannot revive an old reset callback.
                    let ownerGeneration = generation; hasChild = true
                    onSubmoduleReset(GitRepository(root: root, executable: repository.executable), revision) { [weak self] in
                        guard let self, self.active, self.generation == ownerGeneration, self.hasChild, !self.busy else { return }
                        self.hasChild = false; self.apply(selected, using: choice)
                    }
                } catch { if live(token) { output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences) } }
            } catch {
                guard live(token) else { return }
                cancelled = token.isCancelled || error is OperationCancellationFailure || error is GitCommandCancellationFailure || (error as? ResolveFailure).map { if case .cancelled = $0 { return true }; return false } == true
                output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences)
                if cancelled { output = LocalGitCommandProgress.bounded(output + "\nResolution aborted. Earlier resolved items remain resolved.", preferences: preferences) }
                onChanged(output)
            }
            // Use a fresh read token after cancellation; retain ownership/count
            // until the refreshed conflict list has settled, including failures.
            guard live(token), !hasChild else { return }
            let refreshToken = OperationCancellation(); refreshCancellation = refreshToken
            defer { if refreshCancellation === refreshToken { refreshCancellation = nil } }
            do {
                let next = try await repository.conflicts(paths: paths, cancellation: refreshToken)
                guard live(token) else { return }
                let available = Set(next.map(\.path)); entries = next; checked.formIntersection(available); selection.formIntersection(available); reloadQueued = false
            } catch { if live(token) { output = LocalGitCommandProgress.bounded(output + "\nRefresh failed: " + error.localizedDescription, preferences: preferences) } }
            if live(token), token.isCancelled { cancelled = true; success = false }
        }
    }
    func cancel() {
        guard canCancel, let token = cancellation else { return }
        if !showingProgress || !preferences.bool(forKey: "ConfirmKillProcess") { cancelling = true; token.cancel(); refreshCancellation?.cancel(); return }
        confirmingCancellation = true; var answered = false
        confirmCancellation { [weak self] accepted in
            guard !answered, let self, self.active else { return }; answered = true; self.confirmingCancellation = false
            if accepted, self.busy, self.cancellation === token { self.cancelling = true; token.cancel(); self.refreshCancellation?.cancel() }
            self.finishAutomaticClose()
        }
    }
    private func finishAutomaticClose() {
        guard active, showingProgress, !busy, !hasQuestion, !hasChild, !confirmingCancellation, success, !cancelled,
              autoClosePolicy?.shouldClose(success: true, postActionCount: 1) == true else { return }
        closeProgress()
    }
    func closeProgress(commit: Bool = false) {
        guard active, !busy, !confirmingCancellation, !hasQuestion, !hasChild else { return }
        saveActionLog()
        if commit || quick != nil || (success && closeAfterResolution) { close() }
        else { showingProgress = false; load() }
    }
    func dismissSubmoduleReset() { guard active, hasChild, !busy else { return }; hasChild = false; showingProgress = false; load() }
    func editOrCompare(_ ids: Set<String>) {
        guard canInteract else { return }
        if ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) { onEdit(entry.path) }
        else { compare(ids) }
    }
    func compare(_ ids: Set<String>) {
        guard canInteract, !ids.isEmpty else { return }
        let selected = entries.filter { ids.contains($0.path) }; guard !selected.isEmpty else { return }
        let token = begin()
        Task {
            defer { finish(token); withExtendedLifetime(access) {} }
            do {
                let fresh = try await repository.conflicts(paths: selected.map(\.path), cancellation: token)
                guard fresh == selected else { throw ResolveFailure.stale }
                if selected.count == 1, !selected[0].isSubmodule, selected[0].stages.contains(where: { $0.number == 1 }) {
                    let prepared = try await repository.conflictBaseComparison(selected[0], cancellation: token)
                    guard live(token), !token.isCancelled else { return }; onComparison(prepared); return
                }
                let text = try await repository.run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--base", "--"] + selected.map(\.path), cancellation: token).text
                guard try await repository.conflicts(paths: selected.map(\.path), cancellation: token) == selected else { throw ResolveFailure.stale }
                guard live(token), !token.isCancelled else { return }; patch = text
            } catch { if live(token), !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct ResolveDialog: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: ResolveWindowModel
    let commit: () -> Void
    var body: some View {
        Group {
            if model.showingProgress {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.busy ? "Resolving selected conflicts…" : model.success ? "Resolved \(model.resolvedCount) files." : model.cancelled ? "Resolution aborted. Earlier resolved items remain resolved." : "Resolution failed.").font(.headline)
                    SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: model.success, preferences: model.preferences)
                    Text("Reminder: Commit your change after resolve").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if model.busy { LocalGitProgressIndicator(percentage: model.percentage); Text(model.cancelling ? "Cancelling…" : model.currentWork).font(.caption) }
                        Spacer()
                        if model.busy { Button("Cancel") { model.cancel() }.disabled(!model.canCancel) }
                        else if model.hasChild { Button("Back") { model.dismissSubmoduleReset() } }
                        else {
                            if model.success { Button { commit() } label: { CommandLabel(title: "Commit…", icon: .commit) } }
                            Button(model.quick == nil && (!model.success || !model.closeAfterResolution) ? "Back" : "Close") { model.closeProgress() }.keyboardShortcut(.defaultAction).disabled(model.hasQuestion || model.confirmingCancellation)
                        }
                    }
                }.padding(16)
            } else if model.quick != nil {
                HStack(spacing: 16) { ProgressView().controlSize(.small); Text(model.busy ? "Resolving selected conflicts…" : "Review the selected resolution.") }.padding(20)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Table(model.entries, selection: $model.selection) {
                        TableColumn("") { entry in
                            Toggle("Resolve \(entry.path)", isOn: Binding(get: { model.checked.contains(entry.path) }, set: { if $0 { model.checked.insert(entry.path) } else { model.checked.remove(entry.path) } })).labelsHidden().toggleStyle(.checkbox)
                        }.width(24)
                        TableColumn("Path") { entry in HStack { Image(nsImage: FileState.conflicted.icon.image() ?? NSImage()); Text(entry.path).foregroundStyle(FileState.conflicted.textColor) } }.width(min: 260, ideal: 440)
                        TableColumn("Extension") { Text(($0.path as NSString).pathExtension) }.width(70)
                        TableColumn("Status") { _ in Text("Conflicted").foregroundStyle(FileState.conflicted.textColor) }.width(95)
                    }.disabled(!model.canInteract).fileListFont().contextMenu(forSelectionType: String.self) { ids in
                        TurtleGitContextMenu {
                            Button { model.compare(ids) } label: { CommandLabel(title: "Compare with base", icon: .compare) }.disabled(ids.isEmpty)
                            Divider()
                            ResolveSelectionMenu(paths: Array(ids), rebase: model.rebase, canEdit: ids.count == 1 && model.entries.contains(where: { ids.contains($0.id) })) { action, paths in
                                if action == .editConflict, let path = paths.first { model.editOrCompare(Set(paths)) } else { model.request(action.resolveChoice ?? .current, ids: Set(paths)) }
                            }
                        }
                    } primaryAction: { ids in model.editOrCompare(ids) }
                    HStack {
                        SelectionAllCheckbox(checked: model.checked.count, total: model.entries.count, checkedCount: { model.checked.count }) { model.checked = $0 ? Set(model.entries.map(\.path)) : [] }.fixedSize().disabled(!model.canInteract)
                        Spacer()
                        Text("Reminder: Commit your change after resolve").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if model.busy { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("OK") { model.resolveChecked() }.disabled(model.checked.isEmpty || !model.canInteract).keyboardShortcut(.defaultAction)
                        Button(model.busy ? "Cancel read" : "Cancel") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction)
                        Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-resolve.html")!) } label: { CommandLabel(title: "Help", icon: .help) }
                    }
                }.padding(12)
                .background(Button("") { model.load() }.keyboardShortcut(KeyEquivalent("\u{f708}"), modifiers: []).hidden())
            }
        }.onAppear { model.load() }
        .alert("Could not resolve conflicts", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil; if model.quick != nil { model.close() } }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(get: { model.patch != nil }, set: { if !$0 { model.patch = nil } })) {
            VStack { Text("Compare with base").font(.headline); OutputView(text: model.patch ?? "").frame(minWidth: 850, minHeight: 520); Button("Close") { model.patch = nil }.keyboardShortcut(.cancelAction) }.padding(12)
        }
    }
}
struct ResolveSelectionMenu: View {
    let paths: [String]
    var rebase = false
    var canEdit = false
    let action: (RepositoryAction, [String]) -> Void
    var body: some View {
        if canEdit { Button { action(.editConflict, paths) } label: { CommandLabel(title: "Edit conflict…", icon: .editConflict) } }
        Button { action(.resolveCurrent, paths) } label: { CommandLabel(title: "Resolved", icon: .resolve) }.disabled(paths.isEmpty)
        Button { action(.resolveTheirs, paths) } label: { CommandLabel(title: rebase ? "Resolve using commit being replayed" : "Resolve conflict using ‘theirs’", icon: .resolve) }.disabled(paths.isEmpty)
        Button { action(.resolveMine, paths) } label: { CommandLabel(title: rebase ? "Resolve using branch being rebased onto" : "Resolve conflict using ‘mine’", icon: .resolve) }.disabled(paths.isEmpty)
    }
}
