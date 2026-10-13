// SPDX-License-Identifier: GPL-2.0-or-later
// Native consumers of AppUtils::EditNote and GitLogList::RevertSelectedCommits.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class HistoryNotesWindowController: InputWindowController {
    let model: HistoryNotesWindowModel
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String, preferences: UserDefaults) {
        let notes = HistoryNotesWindowModel(repository: repository, access: access, revision: revision)
        model = notes
        super.init(title: "Edit Notes", hint: "Edit Notes", text: "", preferences: preferences) { [notes] text, _, token in
            if token.isCancelled { throw CancellationError() }
            try await notes.saveText(text)
        }
        setInputState(ready: false, message: "Loading notes…")
        onTextChanged = { [weak notes] text in notes?.text = text }
        notes.onLoaded = { [weak self] note, settings in self?.configure(text: note.text, minimumLength: note.minimumLength, settings: settings) }
        notes.onStateChanged = { [weak self, weak notes] in
            guard let self, let notes, notes.snapshot == nil else { return }
            self.setInputState(ready: false, message: notes.error ?? (notes.loading ? "Loading notes…" : nil))
        }
        notes.close = { [weak self] in
            guard let self, !self.model.saving else { return }
            if let window = self.window { window.sheetParent?.endSheet(window); window.close() }
        }
    }
    override func windowShouldClose(_ sender: NSWindow) -> Bool { !model.saving && sender.attachedSheet == nil && super.windowShouldClose(sender) }
    override func windowWillClose(_ notification: Notification) { model.invalidate(); super.windowWillClose(notification) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class HistoryNotesWindowModel: ObservableObject {
    private(set) static var activeMutations = 0
    private(set) static var activeReads = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let revision: String
    @Published var text = ""
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published var error: String?
    private(set) var snapshot: CommitNoteSnapshot?
    private var invalidated = false
    private var cancellation: OperationCancellation?
    private var worker: Task<Void, Never>?
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var read: ((OperationCancellation) async throws -> (CommitNoteSnapshot, ProjectDialogSettings))?
    var onLoaded: (CommitNoteSnapshot, ProjectDialogSettings) -> Void = { _, _ in }
    var onStateChanged: () -> Void = {}
    var canSave: Bool { !invalidated && !loading && !saving && snapshot?.accepts(text) == true }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String) { self.repository = repository; self.access = access; self.revision = revision }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load() {
        guard !invalidated, !loading, !saving, snapshot == nil else { return }
        loading = true; error = nil; onStateChanged()
        let token = OperationCancellation(); cancellation = token
        Self.activeReads += 1
        worker = Task { [weak self, access, repository, revision] in
            defer { Self.activeReads -= 1 }
            _ = access
            do {
                guard let self else { return }; try self.validateAccess()
                let note: CommitNoteSnapshot, settings: ProjectDialogSettings
                if let read = self.read { (note, settings) = try await read(token) }
                else {
                    note = try await repository.editableCommitNote(revision: revision, cancellation: token)
                    settings = try await repository.projectDialogSettings(source: .effective, cancellation: token)
                }
                guard !self.invalidated, self.cancellation === token, !token.isCancelled else { return }
                self.snapshot = note; self.text = note.text
                self.loading = false; self.onLoaded(note, settings)
            } catch { if let self, !self.invalidated, self.cancellation === token, !token.isCancelled { self.error = error.localizedDescription } }
            guard let self, self.cancellation === token else { return }
            self.cancellation = nil; self.worker = nil; self.loading = false
            if !self.invalidated { self.onStateChanged() }
        }
    }
    private func beginSave(_ captured: String) -> CommitNoteSnapshot? {
        guard !invalidated, !loading, !saving, let snapshot, snapshot.accepts(captured) else { return nil }
        saving = true; error = nil; Self.activeMutations += 1
        return snapshot
    }
    func save() {
        let captured = text
        guard let note = beginSave(captured) else { return }
        worker = Task { [weak self] in
            guard let self else { Self.activeMutations -= 1; return }
            do { try await self.persistNote(note, text: captured); if !self.invalidated { self.worker = nil; self.close() } }
            catch { if !self.invalidated { self.worker = nil } }
        }
    }
    func saveText(_ captured: String) async throws {
        guard let note = beginSave(captured) else { throw CommitNoteFailure.invalidText }
        try await persistNote(note, text: captured)
    }
    private func persistNote(_ note: CommitNoteSnapshot, text: String) async throws {
        let result: Result<String, Error>
        do {
            guard !invalidated else { throw CancellationError() }
            try validateAccess()
            result = .success(try await repository.saveCommitNote(note, text: text))
        } catch { result = .failure(error) }
        saving = false; Self.activeMutations -= 1
        guard !invalidated else { return }
        switch result {
        case .success(let display): onChanged(display)
        case .failure(let failure):
            if let noteFailure = failure as? CommitNoteFailure, case .savedButRefreshFailed = noteFailure { onChanged(failure.localizedDescription) }
            error = failure.localizedDescription; throw failure
        }
    }
    func invalidate() { invalidated = true; cancellation?.cancel(); cancellation = nil; if !saving { worker?.cancel() }; worker = nil; loading = false }
}
@MainActor final class HistoryRevertWindowController: NSWindowController, NSWindowDelegate {
    let model: HistoryRevertWindowModel
    var onClosed: () -> Void = {}
    private var alert: NSAlert?
    private var pendingAnswer: ((Bool) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [LogEntry], mainline: Int?, preferences: UserDefaults) {
        model = HistoryRevertWindowModel(repository: repository, access: access, entries: entries, mainline: mainline)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Revert commits – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 600, height: 300)
        window.contentViewController = NSHostingController(rootView: HistoryRevertDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in guard let self, !self.model.busy, self.alert == nil else { return }; self.close() }
        model.ask = { [weak self] title, detail, accept, reject in await self?.question(title, detail: detail, accept: accept, reject: reject) ?? false }
        DialogGeometry.attach(window, identifier: "HistoryRevertWindowController")
    }
    private func question(_ title: String, detail: String, accept: String, reject: String) async -> Bool {
        guard let window, alert == nil, window.attachedSheet == nil, !model.invalidated else { return false }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        // Source confirmation defaults to No; multi-failure defaults to Abort.
        alert.addButton(withTitle: reject); alert.addButton(withTitle: accept)
        self.alert = alert
        return await withCheckedContinuation { continuation in
            var answered = false
            let answer: (Bool) -> Void = { result in guard !answered else { return }; answered = true; continuation.resume(returning: result) }
            pendingAnswer = answer
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.alert === alert else { answer(false); return }
                self.alert = nil; self.pendingAnswer = nil; answer(response == .alertSecondButtonReturn && !self.model.invalidated)
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && alert == nil }
    func windowWillClose(_ notification: Notification) {
        model.invalidate()
        let answer = pendingAnswer; pendingAnswer = nil
        if let alert { window?.endSheet(alert.window, returnCode: .abort) }; alert = nil; answer?(false)
        if let window { window.sheetParent?.endSheet(window) }; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class HistoryRevertWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let entries: [LogEntry]
    let mainline: Int?
    @Published private(set) var busy = false
    @Published private(set) var output = ""
    @Published private(set) var completed = 0
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var confirming = false
    private(set) var invalidated = false
    private var started = false
    private let cancellation = OperationCancellation()
    private var worker: Task<Void, Never>?
    var ask: (String, String, String, String) async -> Bool = { _, _, _, _ in false }
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onCommit: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [LogEntry], mainline: Int?) { self.repository = repository; self.access = access; self.entries = entries; self.mainline = mainline }
    func start() {
        guard !started, !invalidated else { return }; started = true; busy = true; Self.activeOperations += 1
        worker = Task { [weak self, access] in
            _ = access
            defer { Self.activeOperations -= 1 }
            guard let self else { return }
            self.confirming = true
            let accepted = await self.ask("Revert the selected commit(s)?", "", "Yes", "No")
            self.confirming = false
            guard !self.invalidated, accepted else { self.busy = false; if !self.invalidated { self.close() }; return }
            var changed = false, messages = ""
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(self.repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let path = try await self.repository.run(["rev-parse", "--git-path", "MERGE_MSG"], cancellation: self.cancellation).text.trimmingCharacters(in: .newlines)
                let messageURL = path.hasPrefix("/") ? URL(fileURLWithPath: path) : self.repository.root.appendingPathComponent(path)
                for entry in self.entries {
                    if self.cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                    if entry.hash.isEmpty { self.completed += 1; continue }
                    self.output += entry.hash + " " + entry.subject + "\n"
                    do {
                        let result = try await self.repository.revertLogRevision(revision: entry.hash, mainline: self.entries.count == 1 ? self.mainline : nil, cancellation: self.cancellation)
                        changed = true
                        if let message = try? String(contentsOf: messageURL, encoding: .utf8) {
                            messages += (messages.isEmpty ? "" : "\n") + message
                            try messages.write(to: messageURL, atomically: true, encoding: .utf8)
                        }
                        guard !self.invalidated else { return }
                        self.output += result.text
                    } catch {
                        guard !self.invalidated else { return }
                        self.output += error.localizedDescription + "\n"
                        if self.cancellation.isCancelled { break }
                        if self.entries.count == 1 { break }
                        self.confirming = true
                        let skip = await self.ask("Revert failed", error.localizedDescription, "Skip", "Abort")
                        self.confirming = false
                        guard skip, !self.invalidated else { break }
                    }
                    self.completed += 1
                }
                if self.cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                if !messages.isEmpty { try messages.write(to: messageURL, atomically: true, encoding: .utf8) }
            } catch { if !self.invalidated { self.output += error.localizedDescription + "\n" } }
            guard !self.invalidated else { return }
            self.cancelled = self.cancellation.isCancelled; self.success = changed && !self.cancelled
            self.onChanged(self.output)
            if self.success {
                self.confirming = true
                let commit = await self.ask("Revision(s) reverted. All changes are integrated into your working tree now.", "", "Commit", "OK")
                self.confirming = false; self.busy = false
                if commit, !self.invalidated { self.close(); self.onCommit() }
            } else { self.busy = false }
            self.worker = nil
        }
    }
    func cancel() { guard busy, !confirming else { return }; cancellation.cancel() }
    func invalidate() { invalidated = true; cancellation.cancel(); worker?.cancel(); worker = nil; busy = false }
}
private struct HistoryRevertDialog: View {
    @ObservedObject var model: HistoryRevertWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Revert selected commits").font(.headline)
            ProgressView(value: Double(model.completed), total: Double(max(1, model.entries.count)))
            ScrollView { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: .infinity)
            HStack {
                Text(model.busy ? "Reverting…" : model.cancelled ? "Cancelled" : model.success ? "Reverted" : "Revert failed").foregroundStyle(model.success ? Color.green : Color.secondary)
                Spacer()
                if model.busy { Button("Cancel", action: model.cancel).disabled(model.confirming).keyboardShortcut(.cancelAction) }
                else { Button("Close", action: model.close).keyboardShortcut(.defaultAction) }
            }
        }.padding(12).frame(minWidth: 600, minHeight: 300)
    }
}

@MainActor final class HistoryCombineWindowController: NSWindowController, NSWindowDelegate {
    let model: HistoryCombineWindowModel
    var onClosed: () -> Void = {}
    var configureCommit: (CommitWindowController) -> Void = { _ in }
    private(set) var commit: CommitWindowController?
    private var parentWarning: NSAlert?
    private var parentWarningAnswer: ((Bool) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [LogEntry], firstOffset: Int, expectedHead: String, preferences: UserDefaults) {
        model = HistoryCombineWindowModel(repository: repository, access: access, entries: entries, firstOffset: firstOffset, expectedHead: expectedHead)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 320), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Combine commits – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 600, height: 260)
        window.contentViewController = NSHostingController(rootView: HistoryCombineDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in guard let self, !self.model.busy else { return }; self.close() }
        model.presentCommit = { [weak self] plan in
            guard let self, !self.model.invalidated, let owner = self.window, owner.attachedSheet == nil else { return false }
            if plan.lastParentCount != 1 {
                guard await self.showParentWarning(), !self.model.invalidated else { return false }
            }
            let child = CommitWindowController(repository: repository, access: access, defaults: preferences)
            self.commit = child; self.configureCommit(child)
            child.model.loadHistoryCombine(plan, date: RebaseSquashDate(rawValue: preferences.integer(forKey: "SquashDate")) ?? .first)
            var committed = false
            // Publish only after replay or recovery, so sibling history views
            // never reload the temporary combined HEAD as the finished result.
            child.model.onCommitted = { _ in committed = true }
            return await withCheckedContinuation { continuation in
                child.onClosed = { [weak self, weak child, weak owner] in
                    if let window = child?.window, window.sheetParent === owner { owner?.endSheet(window) }
                    if self?.commit === child { self?.commit = nil }
                    continuation.resume(returning: committed)
                }
                guard let window = child.window else { self.commit = nil; continuation.resume(returning: false); return }
                window.alphaValue = owner.alphaValue; window.appearance = owner.appearance; owner.beginSheet(window)
            }
        }
        DialogGeometry.attach(window, identifier: "HistoryCombineWindowController")
    }
    private func showParentWarning() async -> Bool {
        guard let window, window.attachedSheet == nil, !model.invalidated else { return false }
        let alert = NSAlert(); alert.alertStyle = .informational
        alert.messageText = "The following commit dialog can only show changes of oldest commit if it has exactly one parent. This is not the case right now."
        alert.addButton(withTitle: "OK"); parentWarning = alert
        return await withCheckedContinuation { continuation in
            var answered = false
            let answer: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            parentWarningAnswer = answer
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.parentWarning === alert else { answer(false); return }
                self.parentWarning = nil; self.parentWarningAnswer = nil
                answer(response == .alertFirstButtonReturn && !self.model.invalidated)
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && commit == nil }
    func windowWillClose(_ notification: Notification) {
        model.invalidate()
        let answer = parentWarningAnswer; parentWarningAnswer = nil
        if let alert = parentWarning { window?.endSheet(alert.window, returnCode: .abort) }
        parentWarning = nil; answer?(false)
        if let child = commit {
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            // A forced owner close must not race rollback against an active
            // Commit mutation. Keep that dialog visible until it finishes;
            // its close resumes the owned worker, which restores original HEAD.
            if child.model.busy || child.window?.attachedSheet != nil { child.showWindow(nil) }
            else { child.close() }
        }
        if let window { window.sheetParent?.endSheet(window) }; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class HistoryCombineWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let entries: [LogEntry]
    let firstOffset: Int
    let expectedHead: String
    @Published private(set) var busy = false
    @Published private(set) var output = ""
    @Published private(set) var status = "Preparing Combine…"
    private(set) var invalidated = false
    private var started = false
    private let cancellation = OperationCancellation()
    private var worker: Task<Void, Never>?
    var presentCommit: (HistoryCombinePlan) async -> Bool = { _ in false }
    var onChanged: (String) -> Void = { _ in }
    var close: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [LogEntry], firstOffset: Int, expectedHead: String) { self.repository = repository; self.access = access; self.entries = entries; self.firstOffset = firstOffset; self.expectedHead = expectedHead }
    func start() {
        guard !started, !invalidated else { return }; started = true; busy = true; Self.activeOperations += 1
        worker = Task { [weak self, access] in
            _ = access
            defer { Self.activeOperations -= 1 }
            guard let self else { return }
            var recovery: HistoryCombinePlan?
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(self.repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let plan = try await self.repository.prepareHistoryCombine(hashes: self.entries.map(\.hash), firstOffset: self.firstOffset, expectedHead: self.expectedHead, cancellation: self.cancellation)
                let preparedOutput = try await self.repository.beginHistoryCombine(plan, cancellation: self.cancellation)
                recovery = plan
                guard !self.invalidated, !self.cancellation.isCancelled else { throw OperationCancellationFailure.cancelled }
                self.output = preparedOutput; self.status = "Edit the combined commit message"
                guard await self.presentCommit(plan), !self.invalidated, !self.cancellation.isCancelled else { throw OperationCancellationFailure.cancelled }
                self.status = "Replaying commits above the combined range…"
                let replayOutput = try await self.repository.finishHistoryCombine(plan, cancellation: self.cancellation)
                guard !self.invalidated, !self.cancellation.isCancelled else { throw OperationCancellationFailure.cancelled }
                self.output += replayOutput; recovery = nil; self.status = "Combined commits"
            } catch {
                var message = error.localizedDescription
                if let plan = recovery {
                    do { let result = try await self.repository.abortHistoryCombine(plan); message += "\nRestored original HEAD.\n" + result }
                    catch { message += "\n" + HistoryCombineFailure.rollback(error.localizedDescription).localizedDescription }
                }
                if !self.invalidated { self.output += "\n" + message; self.status = "Combine stopped" }
            }
            self.busy = false; self.worker = nil
            if !self.invalidated { self.onChanged(self.output) }
        }
    }
    func cancel() { guard busy else { return }; cancellation.cancel() }
    func invalidate() { invalidated = true; cancellation.cancel() }
}
private struct HistoryCombineDialog: View {
    @ObservedObject var model: HistoryCombineWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.status).font(.headline)
            if model.busy { ProgressView().controlSize(.small) }
            ScrollView { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: .infinity)
            HStack { Spacer(); if model.busy { Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction) } else { Button("Close", action: model.close).keyboardShortcut(.defaultAction) } }
        }.padding(12).frame(minWidth: 600, minHeight: 260)
    }
}
