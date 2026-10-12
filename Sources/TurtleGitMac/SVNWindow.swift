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
    @Published var removeEmptyDirectories = false
    @Published var remember = false
    @Published var ignoreDestination = GitSVNIgnoreDestination.exclude
    @Published private(set) var output = ""
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var fetched: GitSVNFetchResult?
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
    private var pump: Task<Void, Never>?
    private var opened = false, retired = false, closeAfterCancel = false
    private var stashHash: String?
    var title: String {
        switch operation { case .dcommit: return "SVN DCommit"; case .fetch: return "SVN Fetch"; case .rebase: return "SVN Rebase"; case .ignore: return "Import SVN Ignore" }
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, operation: GitSVNOperation, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.operation = operation
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
            guard try await self.repository.finderMetadata().hasGitSVN else { throw GitSVNFailure.remote }
            guard try await !self.repository.isBare() else { throw FinderCommandFailure.selection }
            if self.operation == .dcommit {
                if let type = try await self.repository.svnCommitType(cancellation: self.token) {
                    self.removeEmptyDirectories = type; try await self.execute()
                } else { self.phase = .options }
            } else if self.operation == .ignore { self.phase = .options }
            else { try await self.execute() }
        }
    }
    func start() {
        guard !busy, !retired, phase == .options else { return }
        launch { try await self.execute() }
    }
    func retry() {
        guard !busy, !retired, phase == .finished, error != nil else { return }
        token = OperationCancellation(); parser = GitCliOutputParser(limit: visible.limit); visible.reset(); output = ""; error = nil
        launch { try await self.execute() }
    }
    private func launch(_ action: @escaping () async throws -> Void) {
        guard !busy, !retired else { return }
        busy = true; Self.activeOperations += 1
        pump = Task { [weak self] in
            while !Task.isCancelled {
                self?.drain()
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
        }
        Task {
            defer {
                pump?.cancel(); pump = nil; drain(); visible.consume(parser.finish(), parser: parser); output = visible.output
                busy = false; Self.activeOperations -= 1
                if closeAfterCancel && !retired { close() }
            }
            do { try await action() }
            catch {
                if token.isCancelled { status = "Operation cancelled. Any created stash remains available." }
                else { self.error = error.localizedDescription; status = "\(title) failed." }
                phase = .finished
            }
        }
    }
    private func drain() { visible.consume(parser.processPending(), parser: parser); output = visible.output }
    private func execute() async throws {
        try checkAccess(); try await repository.checkGitSVNRuntime(cancellation: token)
        phase = .progress; status = "\(title) is running…"; error = nil
        let parser = parser
        let emit: @Sendable (GitOutputChunk) -> Void = { parser.appendChunk($0.data) }
        if operation == .dcommit || operation == .rebase {
            if operation == .dcommit && remember { try await repository.rememberSVNCommitType(removeEmptyDirectories: removeEmptyDirectories, cancellation: token) }
            if try await repository.svnTrackedChanges(cancellation: token) {
                guard await confirmStash() else { phase = .finished; status = "Aborted. Working changes were retained."; return }
                try checkAccess()
                let stash = try await repository.svnStash(cancellation: token)
                if stash.created { stashHash = stash.current; onChanged() }
            }
        }
        switch operation {
        case .dcommit:
            _ = try await repository.svnDCommit(removeEmptyDirectories: removeEmptyDirectories, cancellation: token, onOutput: emit)
            status = "SVN DCommit completed."; onChanged(); try await restoreCreatedStash()
        case .fetch:
            fetched = try await repository.svnFetch(cancellation: token, onOutput: emit)
            status = fetched?.changed == true ? "SVN Fetch completed. Review the fetched changes." : "Everything is up to date."
            onChanged()
        case .rebase:
            let head = try await repository.run(["rev-parse", "--verify", "HEAD"], cancellation: token).text.trimmingCharacters(in: .newlines)
            let result = try await repository.svnFetch(cancellation: token, onOutput: emit); fetched = result
            switch try await repository.svnRebasePlan(result, cancellation: token) {
            case .upToDate: status = "Everything is up to date."; await confirmInformation(status)
            case .fastForward(let hash):
                _ = try await repository.svnFastForward(to: hash, expectedHead: head, cancellation: token, onOutput: emit)
                status = "Fast-forward completed."; onChanged(); await confirmInformation(status)
            case .rebase(let reference):
                status = "Continue in the Rebase dialog."
                guard !retired, await openRebase(reference) else { phase = .finished; status = "Rebase was not completed. Any created stash was retained."; return }
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
            if ignoreDestination == .exclude { parser.appendChunk(Data(("\n" + result).utf8)) }; status = "SVN ignore patterns imported."; onChanged()
        }
        phase = .finished
    }
    private func restoreCreatedStash() async throws {
        guard let hash = stashHash, !retired, await confirmPop() else { return }
        let result = try await repository.svnPopCreatedStash(hash, cancellation: token)
        parser.appendChunk(Data(result.utf8)); stashHash = nil; onChanged()
    }
    func cancel(closeWhenStopped: Bool = false) {
        guard !retired else { return }
        if !busy { close(); return }
        Task {
            guard await confirmCancel(), !retired, busy else { return }
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
    init(repository: GitRepository, access: RepositoryAccessLease?, operation: GitSVNOperation, preferences: UserDefaults = .standard) {
        model = SVNWindowModel(repository: repository, access: access, operation: operation, preferences: preferences)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 740, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – \(model.title) – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 600, height: 310)
        window.contentViewController = NSHostingController(rootView: SVNDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in self?.window?.close() }
        func ask(_ message: String, yes: String, no: String) async -> Bool {
            guard window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = message; alert.informativeText = repository.root.path
            alert.addButton(withTitle: yes); alert.addButton(withTitle: no)
            return await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) } }
        }
        model.confirmInformation = { message in
            guard window.attachedSheet == nil else { return }
            let alert = NSAlert(); alert.messageText = message; alert.informativeText = repository.root.path; alert.addButton(withTitle: "OK")
            _ = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        }
        model.confirmStash = { await ask("Your working tree contains changes. Stash them before continuing?", yes: "Stash", no: "Abort") }
        model.confirmPop = { await ask("Restore the stashed changes now?", yes: "Yes", no: "No") }
        model.confirmCancel = { await ask("Abort the running Git operation?", yes: "Abort", no: "Keep Running") }
        DialogGeometry.attach(window, identifier: "SVN." + operation.rawValue)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.attachedSheet == nil else { return false }
        if model.busy { model.cancel(closeWhenStopped: true); return false }; return true
    }
    func windowWillClose(_ notification: Notification) {
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
                ScrollView([.horizontal, .vertical]) { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor)).overlay(Rectangle().stroke(Color(nsColor: .separatorColor)))
                Text(model.error ?? model.status).foregroundStyle(model.error == nil ? Color.primary : Color.red).textSelection(.enabled)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                if model.phase == .finished, model.operation == .fetch, let result = model.fetched, result.changed {
                    Button { model.onCompare(result.oldHash, result.newHash) } label: { CommandLabel(title: "Diff", icon: .compare) }
                    Button { model.onLog(result) } label: { CommandLabel(title: "Log", icon: .log) }
                }
                Spacer()
                if model.phase == .options { Button("OK") { model.start() }.keyboardShortcut(.defaultAction).disabled(model.busy) }
                if model.phase == .finished && model.error != nil { Button("Retry") { model.retry() } }
                Button(model.phase == .finished ? "Close" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                if model.operation != .ignore { Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/")!) } }
            }
        }.padding(16)
    }
}
