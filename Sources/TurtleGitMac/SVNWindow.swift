// SPDX-License-Identifier: GPL-2.0-or-later
// SVNFetchCommand, SVNRebaseCommand, AppUtils::SVNDCommit and SVNIgnoreTypeDlg.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SVNWindowModel: ObservableObject {
    enum Phase: Equatable { case loading, options, progress, finished }
    static private(set) var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let operation: GitSVNOperation
    @Published private(set) var phase = Phase.loading
    @Published private(set) var busy = false
    @Published private(set) var confirmingCancellation = false
    @Published var removeEmptyDirectories = false
    @Published var remember = false
    @Published var ignoreDestination = GitSVNIgnoreDestination.exclude
    @Published private(set) var output = ""
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var fetched: GitSVNFetchResult?
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var completionRange: NSRange?
    @Published private(set) var success = false
    let outputPreferences: UserDefaults
    let outputClipboard: NSPasteboard
    var close: () -> Void = {}
    var confirmStash: () async -> Bool = { false }
    var confirmPop: () async -> Bool = { false }
    var confirmCancel: () async -> Bool = { false }
    var confirmInformation: (String) async -> Void = { _ in }
    var pendingRebaseLog = false
    var onRepositoryLog: () -> Void = {}
    var openRebase: (String) async -> Bool = { _ in false }
    var onCompare: (String, String) -> Void = { _, _ in }
    var onLog: (GitSVNFetchResult) -> Void = { _ in }
    var onChanged: () -> Void = {}
    private var token = OperationCancellation()
    private var parser: GitCliOutputParser
    private var visible: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { visible.presentation }
    private var pump: Task<Void, Never>?
    private var opened = false, retired = false, closeAfterCancel = false
    private var stashHash: String?
    var title: String {
        switch operation { case .dcommit: return "SVN DCommit"; case .fetch: return "SVN Fetch"; case .rebase: return "SVN Rebase"; case .ignore: return "Import SVN Ignore" }
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, operation: GitSVNOperation, preferences: UserDefaults = .standard, clipboard: NSPasteboard = .general) {
        self.repository = repository; self.access = access; self.operation = operation
        outputPreferences = preferences; outputClipboard = clipboard
        visible = GitProgressOutputState(preferences: preferences); parser = GitCliOutputParser(limit: visible.limit)
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
        if retired { throw OperationCancellationFailure.cancelled }
    }
    func load() {
        guard !opened, !retired else { return }; opened = true
        launch {
            try self.checkAccess(); try await self.repository.checkGitSVNRuntime(cancellation: self.token)
            try self.checkAccess()
            guard try await self.repository.finderMetadata().hasGitSVN else { throw GitSVNFailure.remote }
            guard try await !self.repository.isBare() else { throw FinderCommandFailure.selection }
            try self.checkAccess()
            if self.operation == .dcommit {
                if let type = try await self.repository.svnCommitType(cancellation: self.token) {
                    try self.checkAccess(); self.removeEmptyDirectories = type; try await self.execute()
                } else { try self.checkAccess(); self.phase = .options }
            } else if self.operation == .ignore { self.phase = .options }
            else { try await self.execute() }
        }
    }
    func start() {
        guard !busy, !retired, phase == .options else { return }
        launch { try await self.execute() }
    }
    func retry() {
        guard !busy, !retired, !confirmingCancellation, phase == .finished, error != nil else { return }
        token = OperationCancellation(); parser = GitCliOutputParser(limit: visible.limit); visible.reset(); output = ""; error = nil; fetched = nil
        launch { try await self.execute() }
    }
    private func launch(_ action: @escaping () async throws -> Void) {
        guard !busy, !retired else { return }
        busy = true; success = false; completionRange = nil; currentWork = ""; percentage = nil
        let startedAt = ProcessInfo.processInfo.systemUptime
        var exitCode: Int32?
        Self.activeOperations += 1
        pump = Task { [weak self] in
            while !Task.isCancelled {
                self?.drain()
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
        }
        Task {
            defer {
                pump?.cancel(); pump = nil
                if !retired {
                    drain(); visible.consume(parser.finish(), parser: parser); output = visible.output
                    if phase == .finished {
                        let completion = SubmoduleProgressCompletion(success: success, cancelled: token.isCancelled, exitCode: exitCode, elapsed: ProcessInfo.processInfo.systemUptime - startedAt, preferences: outputPreferences)
                        currentWork = completion.currentWork; percentage = 100; completionRange = completion.append(to: &output)
                    }
                }
                busy = false; Self.activeOperations -= 1
                if closeAfterCancel && !retired { close() }
            }
            do { try await action() }
            catch {
                guard !retired else { return }
                if token.isCancelled { status = "Operation cancelled. Any created stash remains available." }
                else { self.error = error.localizedDescription; status = "\(title) failed." }
                exitCode = (error as? GitFailure)?.code
                drain()
                if !visible.hasOutput { parser.appendChunk(Data(("error: " + (self.error ?? status) + "\n").utf8)) }
                phase = .finished
            }
        }
    }
    private func drain() { guard !retired else { return }; visible.consume(parser.processPending(), parser: parser); output = visible.output; currentWork = visible.currentWork; percentage = visible.percentage }
    private func execute() async throws {
        try checkAccess(); try await repository.checkGitSVNRuntime(cancellation: token)
        try checkAccess(); phase = .progress; status = "\(title) is running…"; error = nil
        let parser = parser
        let emit: @Sendable (GitOutputChunk) -> Void = { parser.appendChunk($0.data) }
        if operation == .dcommit || operation == .rebase {
            if operation == .dcommit && remember { try await repository.rememberSVNCommitType(removeEmptyDirectories: removeEmptyDirectories, cancellation: token) }
            let dirty = try await repository.svnTrackedChanges(cancellation: token); try checkAccess()
            if dirty {
                let accepted = await confirmStash(); try checkAccess()
                guard accepted else { phase = .finished; status = "Aborted. Working changes were retained."; return }
                let stash = try await repository.svnStash(cancellation: token)
                try checkAccess()
                if stash.created { stashHash = stash.current; onChanged() }
            }
        }
        switch operation {
        case .dcommit:
            _ = try await repository.svnDCommit(removeEmptyDirectories: removeEmptyDirectories, cancellation: token, onOutput: emit)
            try checkAccess(); status = "SVN DCommit completed."; onChanged(); try await restoreCreatedStash()
        case .fetch:
            let result = try await repository.svnFetch(cancellation: token, onOutput: emit)
            try checkAccess(); fetched = result
            status = fetched?.changed == true ? "SVN Fetch completed. Review the fetched changes." : "Everything is up to date."
            onChanged()
        case .rebase:
            let head = try await repository.run(["rev-parse", "--verify", "HEAD"], cancellation: token).text.trimmingCharacters(in: .newlines)
            let result = try await repository.svnFetch(cancellation: token, onOutput: emit); try checkAccess(); fetched = result
            let plan = try await repository.svnRebasePlan(result, cancellation: token); try checkAccess()
            switch plan {
            case .upToDate: status = "Everything is up to date."; await confirmInformation(status)
            case .fastForward(let hash):
                _ = try await repository.svnFastForward(to: hash, expectedHead: head, cancellation: token, onOutput: emit)
                try checkAccess(); status = "Fast-forward completed."; onChanged(); await confirmInformation(status)
            case .rebase(let reference):
                status = "Continue in the Rebase dialog."
                let completed = await openRebase(reference); try checkAccess()
                guard completed else { phase = .finished; status = "Rebase was not completed. Any created stash was retained."; return }
                status = "Rebase completed."; onChanged()
            }
            try await restoreCreatedStash()
            if pendingRebaseLog && !retired { pendingRebaseLog = false; onRepositoryLog() }
        case .ignore:
            var excludeAccess: RepositoryAccessLease?
            if ignoreDestination == .exclude {
                let file = try await repository.svnIgnoreExcludeURL(cancellation: token)
                if GitRuntime.isAppStoreBuild {
                    guard access?.hasSecurityScope == true, access?.contains(file) == true else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(file.path) }
                    excludeAccess = access
                }
            }
            let result = try await repository.svnImportIgnore(ignoreDestination, excludeAccess: excludeAccess, cancellation: token, onOutput: emit)
            try checkAccess()
            if ignoreDestination == .exclude { parser.appendChunk(Data(("\n" + result).utf8)) }; status = "SVN ignore patterns imported."; onChanged()
        }
        try checkAccess(); success = true; phase = .finished
    }
    private func restoreCreatedStash() async throws {
        guard let hash = stashHash, !retired else { return }
        let accepted = await confirmPop(); try checkAccess(); guard accepted else { return }
        let result = try await repository.svnPopCreatedStash(hash, cancellation: token)
        try checkAccess(); parser.appendChunk(Data(result.utf8)); stashHash = nil; onChanged()
    }
    func cancel(closeWhenStopped: Bool = false) {
        guard !retired, !confirmingCancellation else { return }
        if !busy { close(); return }
        let request = token; confirmingCancellation = true
        Task {
            defer { confirmingCancellation = false }
            guard await confirmCancel(), !retired, token === request, busy else { return }
            closeAfterCancel = closeWhenStopped; token.cancel(); status = "Cancelling…"
        }
    }
    func retire() {
        retired = true; token.cancel(); pump?.cancel(); pump = nil
        confirmStash = { false }; confirmPop = { false }; confirmCancel = { false }; openRebase = { _ in false }
        onCompare = { _, _ in }; onLog = { _ in }; onChanged = {}; onRepositoryLog = {}; confirmInformation = { _ in }; close = {}
    }
}

@MainActor final class SVNWindowController: NSWindowController, NSWindowDelegate {
    let model: SVNWindowModel
    var onClosed: () -> Void = {}
    private var retired = false
    private var question: NSAlert?
    private var reply: ((Bool) -> Void)?
    var presentQuestion: ((NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, operation: GitSVNOperation, preferences: UserDefaults = .standard, clipboard: NSPasteboard = .general) {
        model = SVNWindowModel(repository: repository, access: access, operation: operation, preferences: preferences, clipboard: clipboard)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 740, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "\(model.title)", preferences: preferences); window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 600, height: 310)
        window.contentViewController = NSHostingController(rootView: SVNDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in self?.window?.close() }
        model.confirmInformation = { [weak self] message in _ = await self?.ask(message, yes: "OK", no: nil) }
        model.confirmStash = { [weak self] in await self?.ask("Your working tree contains changes. Stash them before continuing?", yes: "Stash", no: "Abort") ?? false }
        model.confirmPop = { [weak self] in await self?.ask("Restore the stashed changes now?", yes: "Yes", no: "No") ?? false }
        model.confirmCancel = { [weak self] in await self?.ask("Abort the running Git operation?", yes: "Abort", no: "Keep Running") ?? false }
        DialogGeometry.attach(window, identifier: "SVN." + operation.rawValue)
    }
    func ask(_ message: String, yes: String, no: String?) async -> Bool {
        guard !retired, question == nil, let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = message; alert.informativeText = model.repository.root.path
        alert.addButton(withTitle: yes); if let no { alert.addButton(withTitle: no) }; question = alert
        return await withCheckedContinuation { continuation in
            var answered = false
            let finish: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            reply = finish
            let response: (NSApplication.ModalResponse) -> Void = { [weak self] result in
                guard let self, self.question === alert, !self.retired else { finish(false); return }
                self.question = nil; self.reply = nil; finish(result == .alertFirstButtonReturn)
            }
            if let presentQuestion { presentQuestion(alert, window, response) }
            else { alert.beginSheetModal(for: window, completionHandler: response) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.attachedSheet == nil else { return false }
        if model.busy { model.cancel(closeWhenStopped: true); return false }; return true
    }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }
        retired = true
        let alert = question; question = nil
        if let alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
        alert?.window.orderOut(nil)
        let finish = reply; reply = nil; finish?(false)
        model.retire()
        if let child = window?.attachedSheet {
            window?.endSheet(child, returnCode: .abort)
            if child.delegate is RebaseWindowController { child.makeKeyAndOrderFront(nil) }
            else { child.close() }
        }
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct SVNDialog: View {
    @ObservedObject var model: SVNWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            Text(model.repository.root.path).foregroundStyle(.secondary).textSelection(.enabled)
            if model.phase == .options {
                if model.operation == .dcommit {
                    GroupBox("DCommit Type") {
                        Picker("DCommit Type", selection: $model.removeEmptyDirectories) {
                            Text("Normal SVN Commit").tag(false); Text("Git Style Commit (--rmdir)").tag(true)
                        }.pickerStyle(.radioGroup).labelsHidden().disabled(model.busy).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    Toggle("Remember selection (\"svn.rmdir\" option)", isOn: $model.remember).disabled(model.busy)
                } else {
                    GroupBox("Type") {
                        Picker("Type", selection: $model.ignoreDestination) {
                            Text("Import svn ignore file to .git/info/exclude file (file will be overwritten)").tag(GitSVNIgnoreDestination.exclude)
                            Text("Create .gitignore file").tag(GitSVNIgnoreDestination.gitignore)
                        }.pickerStyle(.radioGroup).labelsHidden().disabled(model.busy).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                Spacer()
            } else {
                Text(model.currentWork.isEmpty ? " " : model.currentWork).font(.caption).lineLimit(1).help(model.currentWork)
                if let percentage = model.percentage { ProgressView(value: Double(percentage), total: 100) }
                SubmoduleProgressOutputView(text: model.output, completed: !model.busy, completionRange: model.completionRange, success: model.success, preferences: model.outputPreferences, clipboard: model.outputClipboard)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(model.error ?? model.status).foregroundStyle(model.error == nil ? Color.primary : Color.red).textSelection(.enabled)
            }
            HStack {
                if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
                if model.phase == .finished, model.operation == .fetch, let result = model.fetched, result.changed {
                    Button { model.onCompare(result.oldHash, result.newHash) } label: { CommandLabel(title: "Diff", icon: .compare) }
                    Button { model.onLog(result) } label: { CommandLabel(title: "Log", icon: .log) }
                }
                Spacer()
                if model.phase == .options { Button("OK") { model.start() }.keyboardShortcut(.defaultAction).disabled(model.busy) }
                if model.phase == .finished && model.error != nil { Button("Retry") { model.retry() } }
                Button(model.phase == .finished ? "Close" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                if model.operation != .ignore { Button("Help") { TurtleGitHelp.show(.svn) } }
            }
        }.padding(16)
    }
}
